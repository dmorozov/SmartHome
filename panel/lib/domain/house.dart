import 'dart:ui';

import 'device_vocabulary.dart';

export 'device_vocabulary.dart';

part 'plan_geometry.dart';

/// Static structure of the house, as the Panel draws it. This is Panel-side
/// configuration — the Hub knows devices, not geometry.
///
/// Plan coordinates are meters: x grows east (screen down-right in the
/// isometric projection), y grows south (screen down-left). All Floors share
/// one plan origin — the house's NW corner (ADR-0004) — which is what lets a
/// single projection over [House.planExtent] draw every Floor.
class House {
  const House({required this.name, required this.floors});

  final String name;

  /// Ordered lowest level first.
  final List<Floor> floors;

  /// Union plan extent across all Floors — the box every Floor projects
  /// within, so one IsoProjection serves the whole Dollhouse. Measured from
  /// the shared origin, so a partial upper Floor contributes its far edge,
  /// not its width.
  Size get planExtent {
    var w = 0.0, d = 0.0;
    for (final floor in floors) {
      final extent = floor.planExtent;
      if (extent.width > w) w = extent.width;
      if (extent.height > d) d = extent.height;
    }
    return Size(w, d);
  }
}

/// Compass direction in plan space: x grows east, y grows south (ADR-0004).
enum PlanDirection { north, south, east, west }

/// One level of the house in the Dollhouse. Floors stack; tapping one
/// expands it. A Floor need not span the whole house footprint.
class Floor {
  const Floor({
    required this.id,
    required this.name,
    required this.level,
    required this.rooms,
    this.walls = const [],
  });

  final String id;
  final String name;

  /// Stacking order: 0 = ground, 1 = upstairs, -1 = basement.
  final int level;
  final List<Room> rooms;

  /// Drawn Walls only — an undrawn room boundary is an open passage
  /// (ADR-0004).
  final List<Wall> walls;

  Iterable<Device> get devices => rooms.expand((r) => r.devices);

  /// The Floor's outer outline as axis-aligned segments. Rooms tile the
  /// Floor (ADR-0004; the converter enforces that — the Panel trusts it), so
  /// the outline is each room edge minus every collinear edge of the other
  /// rooms. There is no perimeter concept: the protruding garage and a
  /// partial upper Floor both fall out of the union.
  List<OutlineSeg> outline() => _outlineSegments(rooms);

  /// The Room containing plan-space point [p], or null when [p] is outside
  /// the Floor's footprint. Rooms tile the Floor, so at most one matches.
  /// The single authority for "what is at this plan point".
  Room? roomAt(Offset p) {
    for (final room in rooms) {
      if (room.contains(p)) return room;
    }
    return null;
  }

  /// Which side of [wall] lies outside every Room, or null for an interior
  /// Wall (Rooms on both sides).
  PlanDirection? outsideOf(Wall wall) => _wallOutsideSide(rooms, wall);

  /// This Floor's extent measured from the one plan origin shared by all
  /// Floors: the house's NW corner (ADR-0004). A partial upper Floor whose
  /// rooms start at x=6 still reports its extent from x=0.
  Size get planExtent {
    var w = 0.0, d = 0.0;
    for (final room in rooms) {
      final bounds = room.bounds;
      if (bounds.right > w) w = bounds.right;
      if (bounds.bottom > d) d = bounds.bottom;
    }
    return Size(w, d);
  }
}

/// A Wall segment on a Floor, meters in plan space. Axis-aligned.
class Wall {
  const Wall(this.a, this.b);

  final Offset a;
  final Offset b;

  /// One convention for "runs east–west", shared with the outline algorithm:
  /// the converter emits mm-rounded coordinates, so exact equality would let
  /// a Wall read as horizontal for its face shading and near-horizontal for
  /// its exterior classification.
  bool get horizontal => (a.dy - b.dy).abs() <= _eps;
}

/// A named area on a Floor. Rooms tile their Floor completely — every point
/// belongs to exactly one Room. Rooms display aggregate state (lit) and hold
/// pinned Devices; tapping a Room acts on it (toggles its lights).
class Room {
  const Room({
    required this.id,
    required this.name,
    required this.footprint,
    this.devices = const [],
  });

  final String id;
  final String name;

  /// Rectilinear polygon on the Floor, in meters (right angles only).
  final List<Offset> footprint;
  final List<Device> devices;

  Rect get bounds {
    var minX = footprint.first.dx, maxX = minX;
    var minY = footprint.first.dy, maxY = minY;
    for (final p in footprint) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Even-odd point-in-polygon test in plan space.
  bool contains(Offset p) {
    var inside = false;
    for (var i = 0; i < footprint.length; i++) {
      final a = footprint[i];
      final b = footprint[(i + 1) % footprint.length];
      if ((a.dy > p.dy) != (b.dy > p.dy)) {
        final xt = a.dx + (p.dy - a.dy) * (b.dx - a.dx) / (b.dy - a.dy);
        if (p.dx < xt) inside = !inside;
      }
    }
    return inside;
  }
}

/// A controllable or observable thing in the house, pinned to a Room.
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.kind,
    required this.connectivity,
    required this.position,
    this.entityId,
  });

  final String id;
  final String name;
  final DeviceKind kind;
  final Connectivity connectivity;

  /// The Hub entity this Device's state comes from, e.g.
  /// `light.hall_ceiling`. Null while a Device has no Hub counterpart yet —
  /// it still renders, with unknown state.
  final String? entityId;

  /// Plan-space position on the Floor (same space as Room.footprint), meters.
  final Offset position;
}

