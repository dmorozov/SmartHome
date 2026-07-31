import 'dart:ui';

/// Static structure of the house, as the Panel draws it. This is Panel-side
/// configuration — the Hub knows devices, not geometry.
///
/// Plan coordinates are meters: x grows east (screen down-right in the
/// isometric projection), y grows south (screen down-left). Each Floor has
/// its own plan origin at its north-west corner.
class House {
  const House({required this.name, required this.floors});

  final String name;

  /// Ordered lowest level first.
  final List<Floor> floors;
}

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
}

/// A Wall segment on a Floor, meters in plan space. Axis-aligned.
class Wall {
  const Wall(this.a, this.b);

  final Offset a;
  final Offset b;

  bool get horizontal => a.dy == b.dy;
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

enum DeviceKind {
  light,
  outlet,
  thermostat,
  camera,
  doorbell,
  oven,
  tv,
  washer,
  dryer,
  litterRobot,
  feeder,
  garageDoor,
  evCharger,
  energyMonitor,
}

/// Local Device: works with no vendor cloud. Cloud Device: grandfathered,
/// second-class — may lag or break (see CONTEXT.md).
enum Connectivity { local, cloud }
