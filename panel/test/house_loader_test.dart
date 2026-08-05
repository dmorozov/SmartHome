import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/house_loader.dart';
import 'package:panel/domain/house.dart';

/// Geometry as the converter emits it, walls list last so a test can append
/// one.
const _geometry = '''
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

/// The Placements the converter reads out of the drawing — Key, name, kind,
/// and the Room and position it computed.
const _placements = '''
devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: [2, 1.5]
''';

/// The hand-maintained half: which Hub entity the Key binds to, and whether
/// the Device needs a vendor cloud. Nothing else.
const _bindings = '''
bindings:
  light-den:
    entity: input_boolean.light_den
    connectivity: local
''';

/// One complete generated `house.yaml`. Each optional part splices in where
/// the converter would have put it.
String _plan({
  String extraRoom = '',
  String extraWall = '',
  String extraFloor = '',
  String placements = _placements,
}) {
  var yaml = _geometry;
  if (extraRoom.isNotEmpty) {
    yaml = yaml.replaceFirst('    walls:', '$extraRoom\n    walls:');
  }
  return '$yaml$extraWall$extraFloor$placements';
}

void main() {
  test('joins Placements with their bindings on the Key', () {
    final house = loadHouse(houseYaml: _plan(), bindingsYaml: _bindings);
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
    // The Key is the identity everything downstream already keys on, which
    // is why this cutover stopped at the loader.
    expect(light.id, 'light-den');
    expect(light.name, 'Den Light');
    expect(light.kind, DeviceKind.light);
    expect(light.position, const Offset(2, 1.5)); // from the drawing
    expect(light.entityId, 'input_boolean.light_den'); // from bindings.yaml
    expect(light.connectivity, Connectivity.local); // from bindings.yaml
    // A light has no live view, so no stream — and putting one here would
    // be refused rather than ignored; see below.
    expect(light.streamName, isNull); // from bindings.yaml
  });

  group('the Placement × binding join', () {
    test('rejects a Placement with no binding entry', () {
      // The everyday case: a marker was added to the drawing and nobody
      // added its line here yet.
      expect(
        () => loadHouse(houseYaml: _plan(), bindingsYaml: 'bindings:\n'),
        _rejects('no entry for Device "light-den"'),
      );
    });

    test('rejects a binding whose Device is no longer in the drawing', () {
      // The other direction, which nothing caught before: the marker was
      // deleted and the binding was left behind, silently binding nothing.
      expect(
        () => loadHouse(houseYaml: _plan(), bindingsYaml: '''
$_bindings  ghost-lamp:
    connectivity: local
'''),
        _rejects('bindings.yaml still has "ghost-lamp"'),
      );
    });

    test('a key that could be hiding a password is placed by position instead '
        'of named, so the stale-binding line stops publishing a paste', () {
      // Measured on shipped code, driving the real `loadHouse` over the real
      // shipped assets with one extra key:
      //
      //   E house.invalid error="FormatException: bindings.yaml binds
      //   rtsp://admin:hunter2@192.168.68.44/live, which no longer exist…"
      //
      // A key is as hand-typed as a value, and a paste that lands one column
      // to the left makes the whole camera URL the key — which then matches no
      // Placement, which is exactly this complaint.
      const pasted = 'rtsp://admin:hunter2@192.168.68.44/live';
      try {
        loadHouse(houseYaml: _plan(), bindingsYaml: '''
$_bindings  $pasted:
    connectivity: local
''');
        fail('expected a FormatException');
      } on FormatException catch (e) {
        final logged = e.toString();
        for (final part in [pasted, 'hunter2', 'admin', '192.168.68.44']) {
          expect(logged, isNot(contains(part)), reason: 'leaked "$part"');
        }
        // And the reader can still walk to the line: bindings.yaml keeps the
        // order it was typed in, so a position is a place in the file.
        expect(logged, contains('2nd binding'));
        expect(logged, contains('house.yaml'));
      }
    });

    test('a stream name on a Device that cannot play video is not echoed: '
        'this message is the only place it could ever be published', () {
      // A value reaching here has passed `^[A-Za-z0-9._-]+$`, so it cannot be
      // a URL — but a bare API token pasted where a stream name goes has the
      // shape of a legal name. On a camera that name is logged on every Popup
      // and has to be; on a light the stream is refused, so nothing else in
      // the Panel ever sees it and this line was the whole exposure.
      const token = 'hunter2_api_token';
      try {
        loadHouse(houseYaml: _plan(), bindingsYaml: '''
bindings:
  light-den:
    stream: $token
    connectivity: local
''');
        fail('expected a FormatException');
      } on FormatException catch (e) {
        expect(e.toString(), isNot(contains(token)));
        expect(e.toString(), contains('"light-den"'));
        expect(e.toString(), contains('only a camera or a doorbell'));
      }
    });

    test('accepts a binding with no entity — the Device just has no state',
        () {
      // Hardware still in its box. It must render as an unknown-state pin,
      // never be dropped and never crash the boot.
      final house = loadHouse(houseYaml: _plan(), bindingsYaml: '''
bindings:
  light-den:
    connectivity: cloud
''');
      final light = house.floors.single.rooms.single.devices.single;
      expect(light.entityId, isNull);
      expect(light.connectivity, Connectivity.cloud);
    });

    test('loads a house.yaml with no devices section as a house with none',
        () {
      // A House Plan generated before markers existed is not an error.
      final house =
          loadHouse(houseYaml: _plan(placements: ''), bindingsYaml: 'bindings:\n');
      expect(house.floors.single.rooms.single.devices, isEmpty);
    });

    test('rejects two Devices bound to one entity', () {
      // Two pins driving one entity would toggle each other, and neither
      // could be reasoned about from across the room.
      expect(
        () => loadHouse(houseYaml: _plan(), bindingsYaml: '''
$_bindings  other-lamp:
    entity: input_boolean.light_den
    connectivity: local
'''),
        _rejects('both bind to entity "input_boolean.light_den"'),
      );
    });

    test('a camera carries its go2rtc stream through the join', () {
      final camera = loadHouse(houseYaml: _plan(placements: '''
devices:
  - key: cam-den
    name: "Den Camera"
    kind: camera
    room: den
    position: [1, 1]
'''), bindingsYaml: '''
bindings:
  cam-den:
    stream: den_cam
    connectivity: cloud
''').floors.single.rooms.single.devices.single;
      expect(camera.streamName, 'den_cam');
    });

    test('a doorbell carries its snapshot entity through the join', () {
      final doorbell = loadHouse(houseYaml: _plan(placements: '''
devices:
  - key: doorbell
    name: "Front Door"
    kind: doorbell
    room: den
    position: [1, 1]
'''), bindingsYaml: '''
bindings:
  doorbell:
    snapshot: camera.front_door_snapshot
    connectivity: cloud
''').floors.single.rooms.single.devices.single;
      expect(doorbell.snapshotEntityId, 'camera.front_door_snapshot');
    });

    test('a snapshot on a light is refused: nothing would ever fetch it', () {
      // The same wrong-belief failure as a stream on a light: the author
      // thinks a still face is wired up, and nothing will ever read it.
      expect(
        () => loadHouse(houseYaml: _plan(), bindingsYaml: '''
bindings:
  light-den:
    entity: input_boolean.light_den
    snapshot: camera.den
    connectivity: local
'''),
        _rejects('only a camera or a doorbell wears a still-image face'),
      );
    });

    test('a stream on a light is refused: nothing would ever play it', () {
      // The same failure as a binding whose marker was deleted — a line
      // someone typed that nothing will ever read. Ignoring it would leave
      // the author sure a camera feed is wired up.
      expect(
        () => loadHouse(houseYaml: _plan(), bindingsYaml: '''
bindings:
  light-den:
    entity: input_boolean.light_den
    stream: den_cam
    connectivity: local
'''),
        _rejects('only a camera or a doorbell plays video'),
      );
    });

    test('rejects an entity id that is not domain.object_id', () {
      expect(
        () => loadHouse(houseYaml: _plan(), bindingsYaml: '''
bindings:
  light-den:
    entity: LightDen
    connectivity: local
'''),
        // Not `entity "LightDen"`: the parser no longer echoes a rejected
        // value, because this complaint is fatal and gets logged, and the
        // same paste can be a camera URL with its password in it.
        _rejects('not a Home Assistant entity id'),
      );
    });

    test('rejects unknown connectivity, and demands it be stated', () {
      for (final line in ['    connectivity: wifi', '']) {
        expect(
          () => loadHouse(houseYaml: _plan(), bindingsYaml: '''
bindings:
  light-den:
    entity: input_boolean.light_den
$line
'''),
          _rejects('(local | cloud)'),
          reason: line.isEmpty ? 'omitted entirely' : line,
        );
      }
    });
  });

  // These are backstops now, not everyday errors: the converter validates
  // kinds, computes membership and rejects duplicate Keys, so reaching one
  // of these means house.yaml was hand-edited or truncated — which is
  // exactly the escape hatch ADR-0004 kept, and it gets the same
  // enforcement as the generated path.
  group('a mangled generated file', () {
    test('rejects an unknown device kind', () {
      expect(
        () => loadHouse(houseYaml: _plan(placements: '''
devices:
  - key: gizmo
    name: "Gizmo"
    kind: flux-capacitor
    room: den
    position: [1, 1]
'''), bindingsYaml: '''
bindings:
  gizmo:
    connectivity: local
'''),
        _rejects('the value is "flux-capacitor"'),
      );
    });

    test('rejects a duplicate Device key', () {
      expect(
        () => loadHouse(houseYaml: _plan(placements: '''
devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: [2, 1.5]
  - key: light-den
    name: "Den Light Again"
    kind: light
    room: den
    position: [1, 1]
'''), bindingsYaml: _bindings),
        _rejects('Device "light-den" repeats a Device key already used'),
      );
    });

    test('rejects a Device pointing at a missing room', () {
      expect(
        () => loadHouse(houseYaml: _plan(placements: '''
devices:
  - key: light-x
    name: "X"
    kind: light
    room: renamed-room
    position: [1, 1]
'''), bindingsYaml: '''
bindings:
  light-x:
    connectivity: local
'''),
        _rejects('renamed-room'),
      );
    });
  });

  // The House Plan guarantee: what the converter rejects, the hand-written
  // escape hatch (ADR-0004) must be rejected for too. Every case below
  // loaded silently before and surfaced as corrupt painting, or worse — a
  // duplicate room id quietly attached one device list to two Rooms.
  group('geometry the Dollhouse assumes', () {
    test('rejects a duplicate room id', () {
      expect(
        () => loadHouse(
            houseYaml: _plan(extraRoom: '''
      - id: den
        name: "Second Den"
        footprint: [[4, 0], [8, 0], [8, 3], [4, 3]]'''),
            bindingsYaml: _bindings),
        _rejects('room "den" repeats a room id already used'),
      );
    });

    test('rejects a duplicate floor id', () {
      expect(
        () => loadHouse(
            houseYaml: _plan(extraFloor: '''  - id: ground-floor
    name: "Ground Floor Again"
    level: 1
    rooms:
      - id: attic
        name: "Attic"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
'''),
            bindingsYaml: _bindings),
        _rejects('floor "ground-floor" repeats a floor id already used'),
      );
    });

    test('rejects a diagonal footprint edge', () {
      expect(
        () => loadHouse(
            houseYaml: _plan(extraRoom: '''
      - id: wedge
        name: "Wedge"
        footprint: [[0, 6], [4, 6], [2, 9]]'''),
            bindingsYaml: _bindings),
        _rejects('edge (4, 6)→(2, 9) is diagonal'),
      );
    });

    test('rejects a footprint with fewer than 3 corners', () {
      expect(
        () => loadHouse(
            houseYaml: _plan(extraRoom: '''
      - id: slit
        name: "Slit"
        footprint: [[0, 6], [4, 6]]'''),
            bindingsYaml: _bindings),
        _rejects('room "slit" footprint has fewer than 3 corners'),
      );
    });

    test('rejects a diagonal wall', () {
      expect(
        () => loadHouse(
            houseYaml: _plan(extraWall: '      - [[0, 0], [4, 3]]\n'),
            bindingsYaml: _bindings),
        _rejects('wall (0, 0)→(4, 3) on floor "ground-floor" is diagonal'),
      );
    });

    test('rejects a zero-length wall', () {
      expect(
        () => loadHouse(
            houseYaml: _plan(extraWall: '      - [[2, 2], [2, 2]]\n'),
            bindingsYaml: _bindings),
        _rejects('wall (2, 2)→(2, 2) on floor "ground-floor" has zero length'),
      );
    });
  });

  group('devices against the plan', () {
    test('rejects a Device pinned outside its room', () {
      // Unreachable through the converter now — it computes membership —
      // so this pins the backstop against a truncated or hand-mangled file.
      // The position lands in the L's notch.
      expect(
        () => loadHouse(houseYaml: _plan(placements: '''
devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: [3, 4]
'''), bindingsYaml: _bindings),
        _rejects('position [3, 4] is not inside room "den"'),
      );
    });

    test('accepts a device pinned exactly on its room boundary', () {
      // Markers get dropped onto walls — a TV, a thermostat — and even-odd
      // point-in-polygon answers no for a point on den's east wall and yes
      // for the same point on its west wall, so the boundary allowance, not
      // `contains`, is what makes this legal either way.
      final den = loadHouse(houseYaml: _plan(placements: '''
devices:
  - key: tv-den
    name: "Den TV"
    kind: tv
    room: den
    position: [4, 1.5]
'''), bindingsYaml: '''
bindings:
  tv-den:
    connectivity: local
''').floors.single.rooms.single;
      expect(den.contains(const Offset(4, 1.5)), isFalse, reason: 'on-edge');
      expect(den.devices.single.position, const Offset(4, 1.5));
    });
  });
}

Matcher _rejects(String culprit) => throwsA(isA<FormatException>()
    .having((e) => e.message, 'message', contains(culprit)));
