import 'dart:ui';

import 'package:yaml/yaml.dart';

import '../domain/house.dart';

/// Builds the [House] from the two House Plan files (ADR-0004):
/// `house.yaml` — converter-generated geometry, never hand-edited — and
/// `devices.yaml` — hand-maintained Device declarations referencing rooms
/// by id. Throws [FormatException] with an actionable message on mismatch.
House loadHouse({required String houseYaml, required String devicesYaml}) {
  final houseDoc = loadYaml(houseYaml);
  final devicesDoc = loadYaml(devicesYaml);

  final devicesByRoom = <String, List<Device>>{};
  final seenIds = <String>{};
  for (final d in devicesDoc['devices'] as YamlList) {
    final id = d['id'] as String;
    if (!seenIds.add(id)) {
      throw FormatException('devices.yaml: duplicate device id "$id"');
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
    );
    devicesByRoom.putIfAbsent(d['room'] as String, () => []).add(device);
  }

  final roomIds = <String>{};
  final floors = <Floor>[
    for (final f in houseDoc['floors'] as YamlList)
      Floor(
        id: f['id'] as String,
        name: f['name'] as String,
        level: f['level'] as int,
        rooms: [
          for (final r in f['rooms'] as YamlList)
            () {
              final id = r['id'] as String;
              roomIds.add(id);
              return Room(
                id: id,
                name: r['name'] as String,
                footprint: [
                  for (final p in r['footprint'] as YamlList)
                    _point(p, 'room "$id" footprint point'),
                ],
                devices: devicesByRoom[id] ?? const [],
              );
            }(),
        ],
        walls: [
          for (final w in (f['walls'] as YamlList?) ?? YamlList())
            Wall(_point(w[0], 'wall point'), _point(w[1], 'wall point')),
        ],
      ),
  ];

  final orphaned = devicesByRoom.keys.where((r) => !roomIds.contains(r));
  if (orphaned.isNotEmpty) {
    throw FormatException(
        'devices.yaml references room(s) missing from house.yaml: '
        '${orphaned.join(", ")} — renamed in Sweet Home 3D? Update the '
        'room: references to the new slugs.');
  }

  return House(name: houseDoc['name'] as String, floors: floors);
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
