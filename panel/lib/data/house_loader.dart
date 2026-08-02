import 'dart:math' as math;
import 'dart:ui';

import 'package:yaml/yaml.dart';

import '../domain/house.dart';

/// A pin sitting exactly on its Room's edge is legal — HOUSE-PLAN.md tells
/// the family to place TVs and thermostats against a wall — and even-odd
/// point-in-polygon is ambiguous exactly on the boundary. Meters: generous
/// against a typed coordinate, tiny against room scale.
const _pinEps = 0.05;

/// Builds the [House] from the two House Plan files (ADR-0004):
/// `house.yaml` — converter-generated geometry, never hand-edited — and
/// `devices.yaml` — hand-maintained Device declarations referencing rooms
/// by id. Throws [FormatException] with an actionable message on mismatch.
///
/// The returned [House] carries the full House Plan guarantee the Dollhouse
/// assumes: every Room footprint is a closed rectilinear polygon (>= 3
/// corners, axis-aligned edges), every Wall is axis-aligned and non-
/// degenerate, Room and Floor ids are unique across the house, and every
/// Device references an existing Room with its position inside (or within
/// [_pinEps] of the edge of) that Room's footprint. Geometry the converter
/// would reject therefore also dies here — the hand-written-YAML escape
/// hatch (ADR-0004) gets the same enforcement, instead of surfacing as
/// silent paint-time garbage two modules downstream.
House loadHouse({required String houseYaml, required String devicesYaml}) {
  final houseDoc = loadYaml(houseYaml);
  final devicesDoc = loadYaml(devicesYaml);

  final devicesByRoom = <String, List<Device>>{};
  final seenIds = <String>{};
  final seenEntities = <String, String>{};
  for (final d in devicesDoc['devices'] as YamlList) {
    final id = d['id'] as String;
    if (!seenIds.add(id)) {
      throw FormatException('devices.yaml: duplicate device id "$id"');
    }
    final entityId = d['entity'] as String?;
    if (entityId != null) {
      if (!RegExp(r'^[a-z_]+\.[a-z0-9_]+$').hasMatch(entityId)) {
        throw FormatException(
            'devices.yaml: device "$id" has entity "$entityId", which is not '
            'a Home Assistant entity id (domain.object_id)');
      }
      final clash = seenEntities[entityId];
      if (clash != null) {
        throw FormatException(
            'devices.yaml: devices "$clash" and "$id" both bind to entity '
            '"$entityId" — one entity, one Device.');
      }
      seenEntities[entityId] = id;
    }
    final device = Device(
      id: id,
      name: d['name'] as String,
      kind: _kind(d['kind'] as String, id),
      connectivity: switch (d['connectivity'] as String) {
        'local' => Connectivity.local,
        'cloud' => Connectivity.cloud,
        final c => throw FormatException(
            'devices.yaml: device "$id" has unknown connectivity "$c" '
            '(local | cloud)'),
      },
      position: _point(d['position'], 'device "$id" position'),
      entityId: entityId,
    );
    devicesByRoom.putIfAbsent(d['room'] as String, () => []).add(device);
  }

  final roomIds = <String>{};
  final floorIds = <String>{};
  final floors = <Floor>[
    for (final f in houseDoc['floors'] as YamlList)
      () {
        final floorId = f['id'] as String;
        if (!floorIds.add(floorId)) {
          throw FormatException(
              'house.yaml: duplicate floor id "$floorId" — floor ids must be '
              'unique across the whole house');
        }
        return Floor(
          id: floorId,
          name: f['name'] as String,
          level: f['level'] as int,
          rooms: [
            for (final r in f['rooms'] as YamlList)
              () {
                final id = r['id'] as String;
                if (!roomIds.add(id)) {
                  throw FormatException(
                      'house.yaml: duplicate room id "$id" — room ids must be '
                      'unique across the whole house (devices.yaml '
                      'references them)');
                }
                final footprint = [
                  for (final p in r['footprint'] as YamlList)
                    _point(p, 'room "$id" footprint point'),
                ];
                _checkFootprint(id, footprint);
                return Room(
                  id: id,
                  name: r['name'] as String,
                  footprint: footprint,
                  devices: devicesByRoom[id] ?? const [],
                );
              }(),
          ],
          walls: [
            for (final w in (f['walls'] as YamlList?) ?? YamlList())
              () {
                final wall = Wall(
                    _point(w[0], 'wall point'), _point(w[1], 'wall point'));
                _checkWall(floorId, wall);
                return wall;
              }(),
          ],
        );
      }(),
  ];

  final orphaned = devicesByRoom.keys.where((r) => !roomIds.contains(r));
  if (orphaned.isNotEmpty) {
    throw FormatException(
        'devices.yaml references room(s) missing from house.yaml: '
        '${orphaned.join(", ")} — renamed in Sweet Home 3D? Update the '
        'room: references to the new slugs.');
  }
  for (final floor in floors) {
    for (final room in floor.rooms) {
      for (final device in room.devices) {
        _checkPin(room, device);
      }
    }
  }

  return House(name: houseDoc['name'] as String, floors: floors);
}

// ── House Plan geometry (house.yaml) ────────────────────────────────────

/// Rectilinear polygon, at least a triangle's worth of corners. Everything
/// downstream splits an edge into horizontal-or-vertical with no third case
/// (`Floor.outline`, `Wall.horizontal`), so a diagonal does not fail — it
/// draws wrong.
void _checkFootprint(String roomId, List<Offset> footprint) {
  if (footprint.length < 3) {
    throw FormatException(
        'house.yaml: room "$roomId" footprint has fewer than 3 corners');
  }
  for (var i = 0; i < footprint.length; i++) {
    final a = footprint[i];
    final b = footprint[(i + 1) % footprint.length];
    if (a.dx != b.dx && a.dy != b.dy) {
      throw FormatException(
          'house.yaml: room "$roomId" footprint edge (${_xy(a)})→(${_xy(b)}) '
          'is diagonal — right angles only (ADR-0004); regenerate with the '
          'converter, or fix the hand-written coordinates');
    }
  }
}

/// Axis-aligned and going somewhere. A zero-length Wall projects to a point
/// and a diagonal one to a skewed quad shaded as if it ran east–west.
void _checkWall(String floorId, Wall wall) {
  final (a, b) = (wall.a, wall.b);
  if (a == b) {
    throw FormatException(
        'house.yaml: wall (${_xy(a)})→(${_xy(b)}) on floor "$floorId" has '
        'zero length');
  }
  if (a.dx != b.dx && a.dy != b.dy) {
    throw FormatException(
        'house.yaml: wall (${_xy(a)})→(${_xy(b)}) on floor "$floorId" is '
        'diagonal — right angles only (ADR-0004)');
  }
}

// ── Devices against the House Plan (devices.yaml × house.yaml) ──────────

/// A Device pins to a point in its own Room. The position is house-global,
/// so moving a Device between Rooms means editing two lines, and editing
/// only `room:` is the mistake this catches (HOUSE-PLAN.md §5).
void _checkPin(Room room, Device device) {
  if (room.contains(device.position)) return;
  for (var i = 0; i < room.footprint.length; i++) {
    final a = room.footprint[i];
    final b = room.footprint[(i + 1) % room.footprint.length];
    if (_segmentDistance(a, b, device.position) <= _pinEps) return;
  }
  throw FormatException(
      'devices.yaml: device "${device.id}" position [${_xy(device.position)}] '
      'is outside its room "${room.id}" — positions are meters from the '
      'house NW corner, not room-relative (HOUSE-PLAN.md §5); recompute from '
      "the converter's origin-shift line");
}

/// Distance from [p] to segment [a]–[b]. Exact for the axis-aligned
/// segments [_checkFootprint] guarantees: clamping into the segment's box
/// lands on the segment itself.
double _segmentDistance(Offset a, Offset b, Offset p) {
  final x = p.dx.clamp(math.min(a.dx, b.dx), math.max(a.dx, b.dx)).toDouble();
  final y = p.dy.clamp(math.min(a.dy, b.dy), math.max(a.dy, b.dy)).toDouble();
  return (p - Offset(x, y)).distance;
}

DeviceKind _kind(String slug, String deviceId) => switch (slug) {
      'light' => DeviceKind.light,
      'outlet' => DeviceKind.outlet,
      'thermostat' => DeviceKind.thermostat,
      'camera' => DeviceKind.camera,
      'doorbell' => DeviceKind.doorbell,
      'oven' => DeviceKind.oven,
      'tv' => DeviceKind.tv,
      'washer' => DeviceKind.washer,
      'dryer' => DeviceKind.dryer,
      'litter-robot' => DeviceKind.litterRobot,
      'feeder' => DeviceKind.feeder,
      'garage-door' => DeviceKind.garageDoor,
      'ev-charger' => DeviceKind.evCharger,
      'energy-monitor' => DeviceKind.energyMonitor,
      _ => throw FormatException(
          'devices.yaml: device "$deviceId" has unknown kind "$slug"'),
    };

Offset _point(dynamic pair, String what) {
  if (pair is! YamlList || pair.length != 2) {
    throw FormatException('$what must be a [x, y] pair, got: $pair');
  }
  return Offset(
      (pair[0] as num).toDouble(), (pair[1] as num).toDouble());
}

/// `13, 10.6` — a point the way the YAML files write it, whole meters
/// without a trailing `.0`, so the culprit in an error message can be
/// grepped straight back into the file it came from.
String _xy(Offset p) => '${_meters(p.dx)}, ${_meters(p.dy)}';

String _meters(double v) =>
    v.isFinite && v == v.roundToDouble() ? '${v.toInt()}' : '$v';
