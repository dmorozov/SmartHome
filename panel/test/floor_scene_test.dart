import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/dollhouse/floor_scene.dart';
import 'package:panel/ui/dollhouse/iso.dart';

Room _room(String id, List<Offset> pts) =>
    Room(id: id, name: id, footprint: pts);

/// The decisions a Floor's drawing used to make inline, now answerable
/// without a Canvas: which edges extrude, what order the glass stacks in,
/// which surfaces face the viewer, and what a tap lands on. Colours are the
/// painter's business and appear nowhere here.
void main() {
  final roomA =
      _room('a', const [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)]);
  final roomB =
      _room('b', const [Offset(4, 0), Offset(7, 0), Offset(7, 3), Offset(4, 3)]);
  final projection = IsoProjection(planSize: const Size(7, 3), scale: 40);

  FloorScene scene(List<Room> rooms,
          {List<Wall> walls = const [], Set<String> lit = const {}}) =>
      FloorScene(
        floor: Floor(
            id: 'f', name: 'F', level: 0, rooms: rooms, walls: walls),
        projection: projection,
        litRooms: lit,
      );

  group('plinth', () {
    test('extrudes exactly the south- and east-outward outline segments', () {
      // The protruding-garage shape: b covers only the lower half of a's
      // east side.
      final a =
          _room('a', const [Offset(0, 0), Offset(4, 0), Offset(4, 4), Offset(0, 4)]);
      final b =
          _room('b', const [Offset(4, 2), Offset(6, 2), Offset(6, 4), Offset(4, 4)]);
      final s = scene([a, b]);

      final viewerFacing = s.floor.outline().where((seg) =>
          seg.outward == PlanDirection.south ||
          seg.outward == PlanDirection.east);

      expect(s.plinthFaces.length, viewerFacing.length);
      // …and that is a strict subset: the north/west edges are the far side
      // of the slab and would extrude over it.
      expect(s.floor.outline().length, greaterThan(s.plinthFaces.length));
      // South edges run x, so they face the viewer; east edges run y.
      expect(s.plinthFaces.where((f) => f.facing == WallFacing.facing).length,
          viewerFacing.where((seg) => seg.horizontal).length);
      expect(s.plinthFaces.where((f) => f.facing == WallFacing.shaded).length,
          viewerFacing.where((seg) => !seg.horizontal).length);
    });

    test('each face hangs exactly one wallDepth below its own edge', () {
      final s = scene([roomA]);
      final edges = s.floor
          .outline()
          .where((seg) =>
              seg.outward == PlanDirection.south ||
              seg.outward == PlanDirection.east)
          .toList();

      // Faces come out in outline order, one per viewer-facing edge.
      expect(s.plinthFaces.length, edges.length);
      for (var i = 0; i < edges.length; i++) {
        final a = projection.project(edges[i].a);
        final b = projection.project(edges[i].b);
        final quad = s.plinthFaces[i].quad.getBounds();

        expect(quad.top, closeTo(math.min(a.dy, b.dy), 0.01));
        expect(quad.bottom - math.max(a.dy, b.dy),
            closeTo(FloorScene.wallDepth, 0.01));
      }
    });
  });

  group('glass walls', () {
    test('are ordered back-to-front by plan depth', () {
      final s = scene([roomA, roomB], walls: const [
        Wall(Offset(4, 0), Offset(4, 3)), // deepest
        Wall(Offset(0, 0), Offset(4, 0)), // shallowest
        Wall(Offset(0, 3), Offset(4, 3)),
      ]);

      // Depth in the 2:1 projection is screen y, so the painter's-algorithm
      // order is exactly "cap line never moves back up the screen".
      final depths = [for (final w in s.wallQuads) w.capA.dy + w.capB.dy];
      for (var i = 1; i < depths.length; i++) {
        expect(depths[i], greaterThanOrEqualTo(depths[i - 1]));
      }
      expect(depths.length, 3);
    });

    test('x-running walls face the viewer, y-running walls sit in shade', () {
      final s = scene([roomA], walls: const [
        Wall(Offset(0, 0), Offset(4, 0)), // depth key 4 — first
        Wall(Offset(6, 0), Offset(6, 4)), // depth key 16 — second
      ]);

      expect(s.wallQuads[0].facing, WallFacing.facing);
      expect(s.wallQuads[1].facing, WallFacing.shaded);
    });

    test('only viewer-far exterior walls are flagged', () {
      final s = scene([roomA, roomB], walls: const [
        Wall(Offset(0, 0), Offset(4, 0)), // north exterior — key 4
        Wall(Offset(0, 3), Offset(4, 3)), // south exterior — key 10
        Wall(Offset(4, 0), Offset(4, 3)), // shared interior — key 11
      ]);

      expect(s.wallQuads[0].viewerFarExterior, isTrue);
      expect(s.wallQuads[1].viewerFarExterior, isFalse);
      expect(s.wallQuads[2].viewerFarExterior, isFalse);
    });
  });

  group('rooms', () {
    test('glow only where the Room is lit', () {
      final s = scene([roomA, roomB], lit: {'a'});

      final a = s.roomShapes.firstWhere((r) => r.room.id == 'a');
      final b = s.roomShapes.firstWhere((r) => r.room.id == 'b');
      expect(b.glow, isNull);
      expect(a.glow!.center, projection.project(roomA.bounds.center));
      expect(a.glow!.radius, roomA.bounds.longestSide * projection.scale);
    });

    test('label anchors sit 24px above the projected Room centre', () {
      final s = scene([roomA]);

      expect(s.roomShapes.single.labelAnchor,
          projection.project(roomA.bounds.center) - const Offset(0, 24));
    });
  });

  group('roomAtLocal', () {
    final s = scene([roomA, roomB]);

    test('a point on the slab returns its Room', () {
      expect(s.roomAtLocal(projection.project(const Offset(2, 1.5)))?.id, 'a');
      expect(s.roomAtLocal(projection.project(const Offset(5, 1.5)))?.id, 'b');
    });

    test('a point in the plinth band resolves to the Room above it', () {
      final southEdge = projection.project(const Offset(2, 3));

      expect(
          s
              .roomAtLocal(
                  southEdge + const Offset(0, FloorScene.wallDepth / 2))
              ?.id,
          'a');
    });

    test('a point in the empty isometric corner returns null', () {
      expect(s.roomAtLocal(Offset.zero), isNull);
    });
  });
}
