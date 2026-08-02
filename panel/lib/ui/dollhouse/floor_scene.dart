import 'dart:ui';

import '../../domain/house.dart';
import 'iso.dart';

/// Which way a vertical surface faces in the 2:1 isometric view: x-running
/// surfaces face the viewer, y-running surfaces sit in shade.
enum WallFacing { facing, shaded }

/// A plinth quad below a viewer-facing outline segment.
class PlinthFace {
  const PlinthFace({required this.quad, required this.facing});

  final Path quad;
  final WallFacing facing;
}

/// One glass Wall, projected, classified, in paint order.
class WallQuad {
  const WallQuad({
    required this.quad,
    required this.capA,
    required this.capB,
    required this.facing,
    required this.viewerFarExterior,
  });

  final Path quad;

  /// The top edge, for the bright cap line that catches the light.
  final Offset capA;
  final Offset capB;

  final WallFacing facing;

  /// Exterior Wall with the outside to the north or west — the far side of
  /// the shell, drawn more opaque so the house reads as a solid.
  final bool viewerFarExterior;
}

/// The radial warmth painted inside a lit Room.
class RoomGlow {
  const RoomGlow({required this.center, required this.radius});

  final Offset center;
  final double radius;
}

/// A Room's projected shape plus its per-Room decisions.
class RoomShape {
  const RoomShape({
    required this.room,
    required this.outline,
    required this.glow,
    required this.labelAnchor,
  });

  final Room room;

  /// Projected footprint — the glow's clip and the Room's stroke.
  final Path outline;

  /// Non-null exactly when the Room is lit.
  final RoomGlow? glow;
  final Offset labelAnchor;
}

/// The fully decided drawable scene for one Floor, and the one authority for
/// what a widget-local point hits.
///
/// Every geometric and classification decision is made here, leaving the
/// painter to stroke and fill: which outline segments get a plinth, what
/// order the glass Walls stack in, which of them face the viewer, where the
/// glow and the label go. The painter maps those classifications to colours;
/// it decides nothing about shape.
class FloorScene {
  FloorScene({
    required this.floor,
    required this.projection,
    required this.litRooms,
  });

  /// Pixel extrusion below the slab (the visible plinth "walls").
  static const wallDepth = 22.0;

  /// Glass wall height, meters.
  static const wallHeightM = 1.5;

  final Floor floor;
  final IsoProjection projection;
  final Set<String> litRooms;

  late final List<RoomShape> roomShapes = [
    for (final room in floor.rooms)
      RoomShape(
        room: room,
        outline: projection.projectPolygon(room.footprint),
        glow: litRooms.contains(room.id)
            ? RoomGlow(
                center: projection.project(room.bounds.center),
                radius: room.bounds.longestSide * projection.scale,
              )
            : null,
        // Above the room center — ceiling lights tend to sit exactly there.
        labelAnchor:
            projection.project(room.bounds.center) - const Offset(0, 24),
      ),
  ];

  /// Union of the projected Room footprints. Rooms tile the Floor, so there
  /// is no perimeter concept (ADR-0004) — partial upper floors and the
  /// protruding garage just work.
  late final Path slab = _buildSlab();

  /// Quads under the south- and east-outward outline segments only — the
  /// viewer-facing edges in the isometric view.
  late final List<PlinthFace> plinthFaces = _buildPlinthFaces();

  /// Back-to-front by plan depth (painter's algorithm), classified.
  late final List<WallQuad> wallQuads = _buildWallQuads();

  /// The Room at widget-local [local]: on the slab directly, or in the
  /// plinth band, resolved to the Room owning the extruded face (sampled one
  /// [wallDepth] up). Null anywhere else.
  ///
  /// The painter's hit region is exactly the non-null region and the tap
  /// handler acts on this same answer, so what the Floor claims and what it
  /// does cannot drift apart.
  Room? roomAtLocal(Offset local) =>
      floor.roomAt(projection.unproject(local)) ??
      floor.roomAt(projection.unproject(local - const Offset(0, wallDepth)));

  Path _buildSlab() {
    Path? union;
    for (final shape in roomShapes) {
      union = union == null
          ? shape.outline
          : Path.combine(PathOperation.union, union, shape.outline);
    }
    return union ?? Path();
  }

  List<PlinthFace> _buildPlinthFaces() {
    const depth = Offset(0, wallDepth);
    final faces = <PlinthFace>[];
    for (final seg in floor.outline()) {
      // Only the viewer-facing edges extrude: north- and west-outward
      // segments are the far side of the slab and would draw over it.
      if (seg.outward != PlanDirection.south &&
          seg.outward != PlanDirection.east) {
        continue;
      }
      final a = projection.project(seg.a);
      final b = projection.project(seg.b);
      faces.add(PlinthFace(
        quad: Path()..addPolygon([a, b, b + depth, a + depth], true),
        facing: seg.horizontal ? WallFacing.facing : WallFacing.shaded,
      ));
    }
    return faces;
  }

  List<WallQuad> _buildWallQuads() {
    // Painter's algorithm: back-to-front by plan depth.
    final walls = [...floor.walls]..sort((w1, w2) =>
        (w1.a.dx + w1.a.dy + w1.b.dx + w1.b.dy)
            .compareTo(w2.a.dx + w2.a.dy + w2.b.dx + w2.b.dy));
    final up = Offset(0, -wallHeightM * projection.scale);
    final quads = <WallQuad>[];
    for (final wall in walls) {
      final pa = projection.project(wall.a);
      final pb = projection.project(wall.b);
      final outside = floor.outsideOf(wall);
      quads.add(WallQuad(
        quad: Path()..addPolygon([pa, pb, pb + up, pa + up], true),
        capA: pa + up,
        capB: pb + up,
        facing: wall.horizontal ? WallFacing.facing : WallFacing.shaded,
        viewerFarExterior: outside == PlanDirection.north ||
            outside == PlanDirection.west,
      ));
    }
    return quads;
  }
}
