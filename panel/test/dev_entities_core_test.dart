import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/device_vocabulary.dart';

import '../tool/dev_entities_core.dart';

/// The dev-Hub generator's core, now reachable without running a CLI.
///
/// Its one non-negotiable property is the last test: what this produces
/// today must be exactly the package the dev Hub is already serving, or
/// every binding in `bindings.yaml` silently stops resolving.
void main() {
  DevPackage generate(List<DevDevice> devices) =>
      generateDevPackage(devices, sourceLabel: 'test');

  test('reads Placements out of a generated house.yaml', () {
    final devices = readPlacements('''
name: "H"
floors: []
devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: [1, 1]
''');
    expect(devices, hasLength(1));
    expect(devices.single.key, 'light-den');
    expect(devices.single.kind, DeviceKind.light);
  });

  test('a house.yaml with no devices section says how to fix it', () {
    expect(
      () => readPlacements('name: "H"\nfloors: []\n'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message',
          allOf(contains('devices:'), contains('sh3d_to_yaml.py')))),
    );
  });

  test('an unknown kind names the valid ones', () {
    expect(
      () => readPlacements('''
devices:
  - key: x
    name: "X"
    kind: flux-capacitor
'''),
      throwsA(isA<FormatException>().having((e) => e.message, 'message',
          allOf(contains('flux-capacitor'), contains('energy-monitor')))),
    );
  });

  group('seeds come from the Device vocabulary', () {
    test('each family lands in the right Home Assistant domain', () {
      final package = generate(const [
        DevDevice('a-light', 'A Light', DeviceKind.light),
        DevDevice('a-door', 'A Door', DeviceKind.garageDoor),
        DevDevice('a-meter', 'A Meter', DeviceKind.energyMonitor),
        DevDevice('a-washer', 'A Washer', DeviceKind.washer),
        DevDevice('a-stat', 'A Stat', DeviceKind.thermostat),
      ]);
      expect(package.binding, {
        'a-light': 'input_boolean.a_light',
        'a-door': 'input_boolean.a_door',
        // Readings bind to the domain production will use, not the helper
        // that backs them — so the Panel learns the real mapping.
        'a-meter': 'sensor.a_meter',
        'a-washer': 'sensor.a_washer',
        'a-stat': 'climate.a_stat',
      });
    });

    test('the seeded values are the table\'s, not a copy of them', () {
      // The triplication this phase killed: these numbers used to be typed
      // in the generator, in FakeHub and in the live-Hub test.
      final package = generate(const [
        DevDevice('meter', 'Meter', DeviceKind.energyMonitor),
        DevDevice('washer', 'Washer', DeviceKind.washer),
        DevDevice('outlet', 'Outlet', DeviceKind.outlet),
      ]);
      expect(package.text, contains('initial: 812.0'));
      expect(package.text, contains('initial: "Idle"'));
      expect(package.text, contains('initial: true')); // outlet seeds on
    });
  });

  test('two Devices whose names collide are refused, naming both', () {
    // Home Assistant derives entity ids from names, so these would become
    // one entity and one of the two pins would go dark.
    expect(
      () => generate(const [
        DevDevice('a', 'Hall Light', DeviceKind.light),
        DevDevice('b', 'hall  light', DeviceKind.light),
      ]),
      throwsA(isA<FormatException>().having((e) => e.message, 'message',
          allOf(contains('"a"'), contains('"b"'), contains('Rename')))),
    );
  });

  test('reproduces the package the dev Hub is serving, byte for byte', () {
    // The acceptance test for the whole refactor. A diff here means the
    // stand-ins changed shape, which means every entity id in
    // bindings.yaml may have moved — silently, since nothing throws.
    final devices = readPlacements(
        File('assets/house/house.yaml').readAsStringSync(),
        source: 'assets/house/house.yaml');
    final package = generateDevPackage(devices,
        sourceLabel: 'panel/assets/house/house.yaml');
    expect(package.text,
        File('../hub/dev/ha-config/packages/panel_dev.yaml').readAsStringSync());
    expect(devices, hasLength(33));
  });
}
