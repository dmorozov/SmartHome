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
/// expands it.
class Floor {
  const Floor({
    required this.id,
    required this.name,
    required this.level,
    required this.rooms,
  });

  final String id;
  final String name;

  /// Stacking order: 0 = ground, 1 = upstairs, -1 = basement.
  final int level;
  final List<Room> rooms;

  Iterable<Device> get devices => rooms.expand((r) => r.devices);
}

/// A named area on a Floor. Rooms display aggregate state (lit) and hold
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

  /// Plan-space rectangle on the Floor, in meters.
  final Rect footprint;
  final List<Device> devices;
}

/// A controllable or observable thing in the house, pinned to a Room.
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.kind,
    required this.connectivity,
    required this.position,
  });

  final String id;
  final String name;
  final DeviceKind kind;
  final Connectivity connectivity;

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
