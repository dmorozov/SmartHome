import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/house_loader.dart';
import 'package:panel/domain/house.dart';

const _house = '''
name: "Test House"
floors:
  - id: ground-floor
    name: "Ground Floor"
    level: 0
    rooms:
      - id: den
        name: "Den"
        footprint: [[0, 0], [4, 0], [4, 3], [2, 3], [2, 5], [0, 5]]
    walls:
      - [[0, 0], [4, 0]]
''';

const _devices = '''
devices:
  - id: light-den
    name: "Den Light"
    kind: light
    connectivity: local
    room: den
    position: [2, 1.5]
''';

void main() {
  test('parses geometry, walls and devices into the domain', () {
    final house = loadHouse(houseYaml: _house, devicesYaml: _devices);
    expect(house.name, 'Test House');
    final floor = house.floors.single;
    expect(floor.level, 0);
    expect(floor.walls.single.horizontal, isTrue);
    final den = floor.rooms.single;
    expect(den.footprint, hasLength(6)); // rectilinear L-shape
    expect(den.contains(const Offset(1, 4)), isTrue); // inside the L's leg
    expect(den.contains(const Offset(3, 4)), isFalse); // in the notch
    expect(den.bounds, const Rect.fromLTRB(0, 0, 4, 5));
    final light = den.devices.single;
    expect(light.kind, DeviceKind.light);
    expect(light.position, const Offset(2, 1.5));
  });

  test('rejects a device pointing at a missing room', () {
    const orphan = '''
devices:
  - id: light-x
    name: "X"
    kind: light
    connectivity: local
    room: renamed-room
    position: [1, 1]
''';
    expect(
      () => loadHouse(houseYaml: _house, devicesYaml: orphan),
      throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('renamed-room'))),
    );
  });

  test('rejects an unknown device kind', () {
    const bad = '''
devices:
  - id: gizmo
    name: "Gizmo"
    kind: flux-capacitor
    connectivity: local
    room: den
    position: [1, 1]
''';
    expect(
      () => loadHouse(houseYaml: _house, devicesYaml: bad),
      throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('flux-capacitor'))),
    );
  });
}
