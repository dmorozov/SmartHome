import 'dart:math' as math;
import 'dart:ui';

import 'package:yaml/yaml.dart';

import '../domain/house.dart';
import 'bindings_parser.dart';

/// A pin sitting exactly on its Room's edge is legal — HOUSE-PLAN.md tells
/// the family to place TVs and thermostats against a wall — and even-odd
/// point-in-polygon is ambiguous exactly on the boundary. Meters: generous
/// against a typed coordinate, tiny against room scale.
const _pinEps = 0.05;

/// Builds the [House] from the two House Plan files (ADR-0004, reshaped by
/// ADR-0005): `house.yaml` — converter-generated, never hand-edited, and
/// now carrying the Placements read out of the drawing as well as the
/// geometry — joined with `bindings.yaml`, the one remaining hand-
/// maintained file, which says only which Hub entity each Key binds to and
/// whether the Device is Local or Cloud. Throws [FormatException] with an
/// actionable message on mismatch.
///
/// The join is on the **Key**: the author types it once in Sweet Home 3D,
/// and it becomes [Device.id], so everything downstream — the states map,
/// toggles, pin widget keys, logs — keys on it exactly as it did when ids
/// were hand-written. That is why this cutover stops at this file.
///
/// The returned [House] carries the full House Plan guarantee the Dollhouse
/// assumes: every Room footprint is a closed rectilinear polygon (>= 3
/// corners, axis-aligned edges), every Wall is axis-aligned and non-
/// degenerate, Room and Floor ids are unique across the house, and every
/// Device references an existing Room with its position inside (or within
/// [_pinEps] of the edge of) that Room's footprint. Geometry the converter
/// would reject therefore also dies here — the hand-written-YAML escape
/// hatch (ADR-0004) gets the same enforcement, instead of surfacing as
/// silent paint-time garbage two modules downstream. The converter now
/// computes Room membership rather than a person typing it, so [_checkPin]
/// passes by construction; it stays as the backstop for a mangled file.
House loadHouse({required String houseYaml, required String bindingsYaml}) {
  final houseDoc = loadYaml(houseYaml);
  final bindings = parseBindings(bindingsYaml);

  final devicesByRoom = <String, List<Device>>{};
  final seenKeys = <String>{};
  // Bindings are consumed as Placements claim them; whatever is left over
  // is a binding for a Device that no longer exists in the drawing.
  final unclaimed = bindings.keys.toSet();
  // Absent `devices:` is not an error — it is a house.yaml generated before
  // markers existed. It loads as a house with no Devices, which the
  // `house.loaded … devices=0` log makes obvious.
  for (final p in (houseDoc['devices'] as YamlList?) ?? YamlList()) {
    final key = p['key'] as String;
    if (!seenKeys.add(key)) {
      throw FormatException(
          'house.yaml: duplicate Device key "$key" — the converter rejects '
          'duplicate keys, so regenerate rather than editing house.yaml');
    }
    final binding = bindings[key];
    if (binding == null) {
      throw FormatException(
          'bindings.yaml: no entry for Device "$key" — add one; '
          'connectivity alone is enough until the hardware exists');
    }
    unclaimed.remove(key);
    final device = Device(
      id: key,
      name: p['name'] as String,
      kind: _kind(p['kind'] as String, key),
      connectivity: binding.connectivity,
      position: _point(p['position'], 'device "$key" position'),
      entityId: binding.entityId,
    );
    devicesByRoom.putIfAbsent(p['room'] as String, () => []).add(device);
  }
  if (unclaimed.isNotEmpty) {
    final stale = unclaimed.toList()..sort();
    throw FormatException(
        'bindings.yaml binds ${stale.join(", ")}, which no longer exist in '
        'house.yaml — marker deleted from the drawing? Delete the '
        'binding(s) too, or put the marker back and re-run the converter.');
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
                      'unique across the whole house (Device markers '
                      'reference them)');
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
        'house.yaml: Device(s) reference room(s) that do not exist: '
        '${orphaned.join(", ")} — the converter computes Room membership, so '
        'this file was hand-edited or truncated; regenerate it.');
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

// ── Devices against the House Plan (Placements × bindings.yaml) ────────

/// A Device pins to a point in its own Room. The converter computes both
/// the Room and the position from one marker in the drawing, so they can no
/// longer disagree — this is the backstop for a `house.yaml` that was
/// hand-edited or truncated, which is the escape hatch ADR-0004 kept and
/// therefore the case that still needs guarding.
void _checkPin(Room room, Device device) {
  if (room.contains(device.position)) return;
  for (var i = 0; i < room.footprint.length; i++) {
    final a = room.footprint[i];
    final b = room.footprint[(i + 1) % room.footprint.length];
    if (_segmentDistance(a, b, device.position) <= _pinEps) return;
  }
  throw FormatException(
      'house.yaml: Device "${device.id}" position [${_xy(device.position)}] '
      'is outside its room "${room.id}" — the converter computes membership '
      'from the drawing, so this file was hand-edited or truncated; '
      'regenerate it');
}

/// Distance from [p] to segment [a]–[b]. Exact for the axis-aligned
/// segments [_checkFootprint] guarantees: clamping into the segment's box
/// lands on the segment itself.
double _segmentDistance(Offset a, Offset b, Offset p) {
  final x = p.dx.clamp(math.min(a.dx, b.dx), math.max(a.dx, b.dx)).toDouble();
  final y = p.dy.clamp(math.min(a.dy, b.dy), math.max(a.dy, b.dy)).toDouble();
  return (p - Offset(x, y)).distance;
}

/// The slug list lives in the Device vocabulary; this only owns the error,
/// because only this caller knows the slug came from a generated file.
DeviceKind _kind(String slug, String deviceId) =>
    kindFromSlug(slug) ??
    (throw FormatException(
        'house.yaml: Device "$deviceId" has unknown kind "$slug" — the '
        'converter validates kinds, so regenerate rather than hand-edit '
        '(one of: ${deviceKindSlugs.join(", ")})'));

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
