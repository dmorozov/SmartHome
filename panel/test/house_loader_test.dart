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

  // The House Plan guarantee: what the converter rejects, the hand-written
  // escape hatch (ADR-0004) must be rejected for too. Every case below
  // loaded silently before and surfaced as corrupt painting, or worse — a
  // duplicate room id quietly attached one device list to two Rooms.
  group('geometry the Dollhouse assumes', () {
    test('rejects a duplicate room id', () {
      expect(
        () => loadHouse(
            houseYaml: _houseWith('''
      - id: den
        name: "Second Den"
        footprint: [[4, 0], [8, 0], [8, 3], [4, 3]]'''),
            devicesYaml: _devices),
        _rejects('duplicate room id "den"'),
      );
    });

    test('rejects a duplicate floor id', () {
      expect(
        () => loadHouse(houseYaml: '''
$_house  - id: ground-floor
    name: "Ground Floor Again"
    level: 1
    rooms:
      - id: attic
        name: "Attic"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
''', devicesYaml: _devices),
        _rejects('duplicate floor id "ground-floor"'),
      );
    });

    test('rejects a diagonal footprint edge', () {
      expect(
        () => loadHouse(
            houseYaml: _houseWith('''
      - id: wedge
        name: "Wedge"
        footprint: [[0, 6], [4, 6], [2, 9]]'''),
            devicesYaml: _devices),
        _rejects('edge (4, 6)→(2, 9) is diagonal'),
      );
    });

    test('rejects a footprint with fewer than 3 corners', () {
      expect(
        () => loadHouse(
            houseYaml: _houseWith('''
      - id: slit
        name: "Slit"
        footprint: [[0, 6], [4, 6]]'''),
            devicesYaml: _devices),
        _rejects('room "slit" footprint has fewer than 3 corners'),
      );
    });

    test('rejects a diagonal wall', () {
      expect(
        () => loadHouse(
            houseYaml: '$_house      - [[0, 0], [4, 3]]\n',
            devicesYaml: _devices),
        _rejects('wall (0, 0)→(4, 3) on floor "ground-floor" is diagonal'),
      );
    });

    test('rejects a zero-length wall', () {
      expect(
        () => loadHouse(
            houseYaml: '$_house      - [[2, 2], [2, 2]]\n',
            devicesYaml: _devices),
        _rejects('wall (2, 2)→(2, 2) on floor "ground-floor" has zero length'),
      );
    });
  });

  group('devices against the plan', () {
    test('rejects a device pinned outside its room', () {
      // The documented mistake: `room:` moved to the den, `position:` left
      // where it was (HOUSE-PLAN.md §5) — it lands in the L's notch.
      const stale = '''
devices:
  - id: light-den
    name: "Den Light"
    kind: light
    connectivity: local
    room: den
    position: [3, 4]
''';
      expect(
        () => loadHouse(houseYaml: _house, devicesYaml: stale),
        _rejects('position [3, 4] is outside its room "den"'),
      );
    });

    test('accepts a device pinned exactly on its room boundary', () {
      // "Near a wall for a TV" is what the runbook tells the family to do.
      // Even-odd point-in-polygon answers no for a point on den's east
      // wall and yes for the same point on its west wall, so the boundary
      // allowance — not `contains` — is what makes this legal either way.
      const onEdge = '''
devices:
  - id: tv-den
    name: "Den TV"
    kind: tv
    connectivity: local
    room: den
    position: [4, 1.5]
''';
      final den = loadHouse(houseYaml: _house, devicesYaml: onEdge)
          .floors
          .single
          .rooms
          .single;
      expect(den.contains(const Offset(4, 1.5)), isFalse, reason: 'on-edge');
      expect(den.devices.single.position, const Offset(4, 1.5));
    });
  });
}

/// [_house] plus one more room on the ground floor — the walls block sits
/// after the rooms, so an extra room appends to the room list.
String _houseWith(String roomYaml) => _house
    .replaceFirst('    walls:', '$roomYaml\n    walls:');

Matcher _rejects(String culprit) => throwsA(
    isA<FormatException>().having((e) => e.message, 'message', contains(culprit)));
