import 'package:flutter_test/flutter_test.dart';
import 'package:panel/boot.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/diagnostics/log.dart';

import 'support/fake_channel.dart';

/// A House Plan small enough to count by eye: one Floor, two Rooms, two
/// Placements — one bound to an entity, one not, so `bound` and `devices`
/// must differ for the counts to mean anything.
const _house = '''
name: "Boot House"
floors:
  - id: ground-floor
    name: "Ground Floor"
    level: 0
    rooms:
      - id: den
        name: "Den"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
      - id: hall
        name: "Hall"
        footprint: [[4, 0], [6, 0], [6, 3], [4, 3]]
    walls:
      - [[0, 0], [4, 0]]
devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: [2, 1.5]
  - key: light-hall
    name: "Hall Light"
    kind: light
    room: hall
    position: [5, 1.5]
''';

/// The hand-maintained half. `light-hall` has no entity — hardware still in
/// its box — which is what makes `bound` differ from `devices`.
const _bindings = '''
bindings:
  light-den:
    entity: light.den
    connectivity: local
  light-hall:
    connectivity: local
''';

/// The composition root, reachable at last. Every case below needed a
/// separately compiled build before this module existed — the knowledge was
/// untestable, not merely untested.
void main() {
  late List<LogRecord> records;

  setUp(() {
    records = <LogRecord>[];
    Log.sink = records.add;
    Log.level = LogLevel.debug;
  });

  tearDown(() {
    Log.sink = Log.printRecord;
    Log.level = LogLevel.warn;
  });

  /// The one `hub.configured` line, or null if the boot never got that far.
  LogRecord? configured() =>
      records.where((r) => r.area == 'hub' && r.event == 'configured').
          firstOrNull;

  PanelBoot boot({
    String kind = 'fake',
    String url = 'http://localhost:8123',
    String token = '',
    String houseYaml = _house,
    String bindingsYaml = _bindings,
  }) {
    final assembly = bootPanel(
      hubKind: kind,
      hubUrl: url,
      hubToken: token,
      houseYaml: houseYaml,
      bindingsYaml: bindingsYaml,
      // An idle socket: the ha path picks its adapter without dialling.
      haConnect: (_) => FakeChannel(),
    );
    addTearDown(assembly.controller.dispose);
    return assembly;
  }

  group('the assembly', () {
    test('fake kind yields a FakeHub behind the FAKE HUB label', () {
      final assembly = boot();

      expect(assembly.hub, isA<FakeHub>());
      expect(assembly.hubLabel, 'FAKE HUB');
      expect(assembly.controller.status, HubStatus.up);
      expect(assembly.house.name, 'Boot House');
      expect(assembly.controller.house, same(assembly.house));
    });

    test('ha kind yields an HaHubClient behind the HUB label', () {
      final assembly = boot(kind: 'ha', token: 'a-token');

      expect(assembly.hub, isA<HaHubClient>());
      expect(assembly.hubLabel, 'HUB');
      // Chosen, not yet connected: nothing has answered the handshake.
      expect(assembly.controller.status, HubStatus.retrying);
    });
  });

  group('configuration refused', () {
    test('an unknown kind throws, naming the kind and the choices', () {
      expect(
        () => boot(kind: 'mqtt'),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            contains('unknown HUB "mqtt" (fake | ha)'))),
      );
      // Nothing was configured, so nothing claims to have been.
      expect(configured(), isNull);
    });

    test('ha without a token logs the breadcrumb before it throws', () {
      // Ordering is the point: the crash is the visible event, and this
      // line is the only thing that says why. Emitting it after the throw
      // would mean never emitting it at all.
      expect(() => boot(kind: 'ha'), throwsA(isA<ArgumentError>()));

      final record = configured();
      expect(record, isNotNull);
      expect(record!.fields?['token'], 'absent');
      // Emitted, and emitted last: the throw comes straight after it, so a
      // log written on the far side of the throw would never exist at all.
      expect(records.last, same(record));
    });
  });

  group('diagnostics', () {
    test('HA_URL is cut down to an address, because hub.configured is a line '
        'a *healthy* boot emits', () {
      // Measured, on every good `HUB=ha` start:
      //
      //   I hub.configured url=http://admin:hunter2@ha.local:8123 token=set
      //
      // The asymmetry that hid it: `GO2RTC_URL`, one field over in the same
      // `HubConfig`, went through a build-it-up-from-scheme/host/port rule
      // while this one was handed to `Log.info` whole — and the comment on
      // the line beside it already said "`set`, never the token itself: these
      // lines end up in logs". Home Assistant behind a reverse proxy with
      // basic auth is the ordinary way this value acquires a credential.
      const password = 'hunter2';
      boot(
          kind: 'ha',
          url: 'http://admin:$password@ha.local:8123',
          token: 'a-token');

      expect(configured()!.toString(),
          '[panel] I hub.configured url=http://ha.local:8123 auth=set '
          'token=set');
    });

    test('a reverse-proxy mount point and a query credential are reported as '
        'present and never as text', () {
      // `/hunter2/` is the exact case that cost `go2rtcForLog` its `path`
      // field one setting over, and `?api_password=` is Home Assistant's own
      // spelling — which `webSocketUrl` carries through, so before this it was
      // printed on this line and twice more per connect.
      const password = 'hunter2';
      records.clear();
      boot(kind: 'ha', url: 'https://ha.local/$password/', token: 't');
      expect(configured()!.toString(),
          '[panel] I hub.configured url=https://ha.local path=set token=set');

      records.clear();
      boot(
          kind: 'ha',
          url: 'http://ha.local:8123/?api_password=$password',
          token: 't');
      expect(configured()!.toString(),
          '[panel] I hub.configured url=http://ha.local:8123 query=set '
          'token=set');
    });

    test('the everyday address still prints whole, because telling a stale '
        'address from a dead Hub is what this line is for', () {
      // The withholding must not creep over the ordinary case: `hub.config`'s
      // stated job is separating "pointed at the wrong Hub" from "the Hub is
      // down", and neither is legible without the host and port.
      boot(kind: 'ha', url: 'http://192.168.68.10:8123', token: 't');

      expect(configured()!.toString(),
          '[panel] I hub.configured url=http://192.168.68.10:8123 token=set');
    });

    test('an HA_URL nobody can take apart is refused at boot, and neither the '
        'refusal nor the log repeats it', () {
      // `Uri.tryParse` hardly ever fails: `admin:hunter2@ha.local:8123` parses
      // as scheme `admin` with the rest as a path — `host` empty, `userInfo`
      // empty, nothing that looks like a credential to any accessor — so a
      // strip-based rule printed the lot.
      //
      // It used to boot, too, and dial `ws:/api/websocket`, which reaches no
      // Hub: the Panel spent forever on a wall retrying an address that could
      // never work, with `url=unusable` as the entire explanation. A host-less
      // HA_URL is not something the Panel can recover from by waiting, so it
      // now refuses the way an empty HA_TOKEN already does (ADR-0007: say when
      // you cannot recover, rather than retrying something hopeless).
      const password = 'hunter2';

      expect(
          () => boot(kind: 'ha', url: 'admin:$password@ha.local:8123', token: 't'),
          throwsA(isA<ArgumentError>().having(
              (e) => e.message.toString(), 'message', isNot(contains(password)))));

      // `hub.configured` is emitted before the dial, so it is on the record —
      // and it is the line whose `unusable` used to predict, exactly, that
      // something further down would print the whole string.
      expect(configured()!.toString(),
          '[panel] I hub.configured url=unusable token=set');
      expect(records.map((r) => r.toString()).join('\n'),
          isNot(contains(password)));
    });

    test('the token never reaches the log, only the fact that it is set', () {
      const secret = 'super-secret-token-abc123';
      boot(kind: 'ha', token: secret);

      expect(configured()?.fields?['token'], 'set');
      // The whole record, rendered — fields, error, everything a sink or
      // journald would see.
      expect(records.map((r) => r.toString()).join('\n'), isNot(contains(secret)));
    });

    test('a loaded House Plan reports its counts, bound apart from total', () {
      boot();

      final loaded =
          records.singleWhere((r) => r.area == 'house' && r.event == 'loaded');
      expect(loaded.level, LogLevel.info);
      expect(loaded.fields, {
        'name': 'Boot House',
        'floors': 1,
        'rooms': 2,
        'devices': 2,
        // The at-a-glance answer to "which Devices can never show state":
        // one of the two has no entity, and the difference is the point.
        'bound': 1,
        // Neither light plays video, and the line says zero rather than
        // omitting the field: "this house has no live views" is an answer,
        // and a missing key would read as an older Panel build.
        'streams': 0,
      });
    });

    test('a Device with a live view is counted apart from the rest', () {
      // Two Devices watching one camera is legal — nothing refuses it — so
      // this count against `devices` is the only place a copy-pasted
      // `stream:` ever becomes visible.
      boot(houseYaml: '''
$_house  - key: cam-hall
    name: "Hall Camera"
    kind: camera
    room: hall
    position: [5, 2]
''', bindingsYaml: '''
$_bindings  cam-hall:
    stream: hall_cam
    connectivity: cloud
''');

      final loaded =
          records.singleWhere((r) => r.area == 'house' && r.event == 'loaded');
      expect(loaded.fields?['devices'], 3);
      expect(loaded.fields?['streams'], 1);
    });

    test('a malformed House Plan leaves one fatal line and rethrows', () {
      // A binding whose Device was deleted from the drawing — the most
      // likely hand-edit mistake, now that bindings.yaml is the only file
      // a person types into.
      const stale = '''
bindings:
  light-den:
    entity: light.den
    connectivity: local
  light-hall:
    connectivity: local
  ghost-lamp:
    connectivity: local
''';
      expect(() => boot(bindingsYaml: stale), throwsA(isA<FormatException>()));

      final invalid =
          records.singleWhere((r) => r.area == 'house' && r.event == 'invalid');
      expect(invalid.level, LogLevel.error);
      expect(invalid.error, isA<FormatException>());
      // Nothing claims the House Plan loaded.
      expect(records.where((r) => r.event == 'loaded'), isEmpty);
    });

    test('a House Plan the YAML parser itself refuses names the position and '
        'not the line, so the worse typo stops being the one that publishes '
        'the password', () {
      // The channel nobody was guarding, measured on shipped code: `loadYaml`
      // runs before every semantic check, and the yaml package's exception is
      // a `SourceSpanFormatException` whose `toString()` reproduces the
      // offending source line with a caret under it. `house.invalid` is the
      // only artefact a fatal boot leaves in journald, so three ordinary
      // mis-pastes each published the camera password — while the *cleaner*
      // paste, the one that parses and is then refused, did not:
      //
      //   E house.invalid error="Error on line 5, column 5: Duplicate mapping
      //   key.\n  ╷\n5 │     stream: rtsp://admin:hunter2@…\n  │     ^^^^^^"
      const password = 'hunter2';
      const pasted = 'rtsp://admin:$password@192.168.68.44/live';
      final mispastes = {
        // A duplicated key: the line above was edited and the old one left.
        'duplicate mapping key': '''
bindings:
  cam-den:
    stream: den_cam
    stream: $pasted
    connectivity: cloud
''',
        // A tab, which is what an editor with tab indentation produces.
        'a tab in the indentation': 'bindings:\n  cam-den:\n'
            '\t    stream: $pasted\n    connectivity: cloud\n',
        // A URL containing ": ", which YAML reads as a second mapping value.
        'a colon-space inside the pasted URL': '''
bindings:
  cam-den:
    stream: rtsp://admin: $password@192.168.68.44/live
    connectivity: cloud
''',
        // An alias nobody defined — the same accident by way of an editor's
        // autocomplete.
        'an undefined alias': '''
bindings:
  cam-den:
    stream: *rtsp_admin_${password}_cam
    connectivity: cloud
''',
      };

      for (final mispaste in mispastes.entries) {
        records.clear();
        expect(() => boot(bindingsYaml: mispaste.value),
            throwsA(isA<FormatException>()), reason: mispaste.key);

        final invalid = records
            .singleWhere((r) => r.area == 'house' && r.event == 'invalid');
        // The whole record as journald would see it: fields, error and all.
        final logged = invalid.toString();
        for (final secret in [password, 'admin', '192.168.68.44', pasted]) {
          expect(logged, isNot(contains(secret)),
              reason: '${mispaste.key} leaked "$secret"');
        }
        // And it is still actionable: the file and a position are the useful
        // half and carry no secret.
        expect(logged, contains('bindings.yaml'), reason: mispaste.key);
        expect(logged, contains('line '), reason: mispaste.key);
        expect(logged, contains('column '), reason: mispaste.key);
      }
    });

    test('house.yaml comes through the same door, because it is the other '
        'file a hand-edit can break', () {
      // Generated, but the hand-written escape hatch is the one ADR-0004
      // deliberately kept, and the parser prints the line it choked on
      // whichever file that line came from.
      const secret = 'hunter2';
      expect(
          () => boot(houseYaml: '$_house  - key: cam-den\n'
              '\tname: "$secret"\n'),
          throwsA(isA<FormatException>()));

      final invalid =
          records.singleWhere((r) => r.area == 'house' && r.event == 'invalid');
      expect(invalid.toString(), isNot(contains(secret)));
      expect(invalid.toString(), contains('house.yaml'));
      expect(invalid.toString(), contains('line '));
    });

    test('a house.yaml the parser accepts and the loader refuses places the '
        'entry instead of quoting it, so the paste that gets *past* YAML '
        'stops being the one that publishes the password', () {
      // The other half of the door above, and the one that was left open.
      // `readYaml` was widened to house.yaml; the thirteen semantic checks
      // behind it were not, and every one of them printed its culprit raw.
      // Measured through this same `bootPanel` before the fix:
      //
      //   E house.invalid error="FormatException: house.yaml: duplicate room
      //   id \"rtsp://admin:hunter2@192.168.68.44/live\" — …"
      //
      // house.yaml being generated is not a defence — `house_loader.dart`
      // says four times over that the hand-edit is the escape hatch ADR-0004
      // kept, and a generated file reaches none of these messages at all.
      //
      // Driven through the real `bootPanel` and asserted on the rendered
      // `LogRecord`, not on the exception: the record is what journald gets,
      // and an exception whose `message` is clean can still be logged dirty.
      const password = 'hunter2';
      const pasted = 'rtsp://admin:$password@192.168.68.44/live';

      // Each case: the House Plan, its bindings, and the term that has to
      // survive — because a complaint that names nothing is not a fix, it is
      // the same fault one drawer down.
      final mispastes = <String, (String, String, String)>{
        'a Device key, twice over': (
          _plan(devices: '''devices:
  - key: $pasted
    name: "Den Light"
    kind: light
    room: den
    position: [2, 1.5]
  - key: $pasted
    name: "Den Light Again"
    kind: light
    room: den
    position: [1, 1]
'''),
          // Bound, so the first copy gets all the way past the join and the
          // *duplicate* is what fails — the message under test.
          'bindings:\n  $pasted:\n    connectivity: local\n',
          'the 2nd entry under devices:',
        ),
        'a Device key with no binding': (
          _plan(devices: '''devices:
  - key: $pasted
    name: "Den Light"
    kind: light
    room: den
    position: [2, 1.5]
'''),
          'bindings:\n',
          'the 1st entry under devices:',
        ),
        'a kind': (
          _plan(devices: '''devices:
  - key: light-den
    name: "Den Light"
    kind: $pasted
    room: den
    position: [2, 1.5]
'''),
          _lightBinding,
          'Device "light-den" has an unknown kind',
        ),
        'the room a Device names': (
          _plan(devices: '''devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: $pasted
    position: [2, 1.5]
'''),
          _lightBinding,
          'the room: on Device "light-den"',
        ),
        'a duplicated room id': (
          _plan(rooms: '''      - id: $pasted
        name: "Den"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
      - id: $pasted
        name: "Den Again"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
''', devices: ''),
          'bindings:\n',
          'the 2nd room under floor "ground-floor"',
        ),
        'a duplicated floor id': (
          _plan(floorId: pasted, extraFloor: '''  - id: $pasted
    name: "Attic"
    level: 1
    rooms:
      - id: attic
        name: "Attic"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
''', devices: ''),
          'bindings:\n',
          'the 2nd entry under floors:',
        ),
        'a room id on a diagonal footprint': (
          _plan(rooms: '''      - id: $pasted
        name: "Wedge"
        footprint: [[0, 0], [4, 0], [2, 3]]
''', devices: ''),
          'bindings:\n',
          'footprint edge (4, 0)→(2, 3) is diagonal',
        ),
        'a room id on a footprint too short to be a polygon': (
          _plan(rooms: '''      - id: $pasted
        name: "Slit"
        footprint: [[0, 0], [4, 0]]
''', devices: ''),
          'bindings:\n',
          'the 1st room under floor "ground-floor" footprint has fewer than 3',
        ),
        'a floor id on a diagonal wall': (
          _plan(floorId: pasted, walls: '      - [[0, 0], [4, 3]]\n',
              devices: ''),
          'bindings:\n',
          'wall (0, 0)→(4, 3) on the 1st entry under floors: is diagonal',
        ),
        'a floor id on a zero-length wall': (
          _plan(floorId: pasted, walls: '      - [[2, 2], [2, 2]]\n',
              devices: ''),
          'bindings:\n',
          'has zero length',
        ),
        'a room id a Device is pinned outside of': (
          _plan(rooms: '''      - id: $pasted
        name: "Den"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
''', devices: '''devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: $pasted
    position: [99, 99]
'''),
          _lightBinding,
          'is not inside the 1st room under floor "ground-floor"',
        ),
        'a wall end where a [x, y] pair goes': (
          _plan(walls: '      - ["$pasted", [1, 1]]\n', devices: ''),
          'bindings:\n',
          'the first end of the 1st wall under floor "ground-floor"',
        ),
        'a footprint corner where a [x, y] pair goes': (
          _plan(rooms: '''      - id: den
        name: "Den"
        footprint: ["$pasted", [4, 0], [4, 3], [0, 3]]
''', devices: ''),
          'bindings:\n',
          'the 1st footprint corner of room "den"',
        ),
        'a Device position where a [x, y] pair goes': (
          _plan(devices: '''devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: "$pasted"
'''),
          _lightBinding,
          'the position: on Device "light-den"',
        ),
        'one half of a Device position, where a number goes': (
          _plan(devices: '''devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: ["$pasted", 2]
'''),
          _lightBinding,
          'the position: on Device "light-den" must be two numbers',
        ),
      };

      for (final mispaste in mispastes.entries) {
        final (houseYaml, bindingsYaml, locator) = mispaste.value;
        records.clear();
        expect(() => boot(houseYaml: houseYaml, bindingsYaml: bindingsYaml),
            throwsA(isA<FormatException>()), reason: mispaste.key);

        final invalid = records
            .singleWhere((r) => r.area == 'house' && r.event == 'invalid');
        // The whole record as journald would see it: fields, error and all.
        final logged = invalid.toString();
        for (final secret in [password, 'admin', '192.168.68.44', pasted]) {
          expect(logged, isNot(contains(secret)),
              reason: '${mispaste.key} leaked "$secret"');
        }
        // And the operator can still walk to it. house.yaml keeps the order
        // the converter wrote, so an ordinal is a place in the file — and an
        // id that survived `isQuiet` is provably not a URL, which is why the
        // neighbouring `"ground-floor"` and `"light-den"` are still named.
        //
        // Against the same rendered line, with log.dart's quote escaping
        // undone: the escaping is what a reader's eye undoes too, and writing
        // the locators pre-escaped would hide what they actually say.
        expect(logged.replaceAll(r'\"', '"'), contains(locator),
            reason: mispaste.key);
      }
    });

    test('the house\'s own name is withheld when it could be hiding one, '
        'because house.loaded is the line a *healthy* boot emits', () {
      // The thirteen above are crash-only. This one was measured on every
      // good start, and `name:` is house.yaml's first line — the one a paste
      // over the top of the file silently replaces:
      //
      //   I house.loaded name=rtsp://admin:hunter2@192.168.68.44/live floors=1
      const password = 'hunter2';
      boot(
        houseYaml: _plan(name: 'rtsp://admin:$password@192.168.68.44/live'),
        bindingsYaml: _lightBinding,
      );

      final loaded =
          records.singleWhere((r) => r.area == 'house' && r.event == 'loaded');
      expect(loaded.fields?['name'], 'withheld');
      expect(records.map((r) => r.toString()).join('\n'),
          isNot(contains(password)));
      // Withheld, not dropped: the counts beside it are what actually answer
      // "which house.yaml did this Panel load", and they are untouched.
      expect(loaded.fields?['rooms'], 1);
      expect(loaded.fields?['devices'], 1);
    });

    test('an ordinary house name is still printed, so withholding cannot creep '
        'over the everyday line', () {
      boot(
          houseYaml: _plan(name: 'Morozov House'),
          bindingsYaml: _lightBinding);

      expect(
          records
              .singleWhere((r) => r.area == 'house' && r.event == 'loaded')
              .fields?['name'],
          'Morozov House');
    });

    test('a house name that is itself a bare token still prints — the '
        'accepted residual, pinned so it is a decision and not a surprise',
        () {
      // `isQuiet`'s charset is very nearly base64url's, so a secret typed
      // where a name goes has the shape of a name and passes:
      //
      //   I house.loaded name=sk_live_51H8hunter2abcdefghij floors=1 …
      //
      // Accepted, and argued in `isQuiet`'s own docstring: that predicate
      // answers "could a URL or a `user:pass` pair be hiding in here", which
      // is the mis-paste question — the accident that actually happens, one
      // keystroke, silently. Nothing that looks only at characters can answer
      // "is this value itself a secret somebody typed on purpose", and a
      // predicate that tried would refuse `ground-floor-2` too.
      //
      // Pinned as an expectation rather than left implicit so that a future
      // round tightening `isQuiet` has to come here and change a decision.
      boot(
          houseYaml: _plan(name: 'sk_live_51H8hunter2abcdefghij'),
          bindingsYaml: _lightBinding);

      expect(
          records
              .singleWhere((r) => r.area == 'house' && r.event == 'loaded')
              .fields?['name'],
          'sk_live_51H8hunter2abcdefghij');
    });
  });
}

/// The one binding the default [_plan] Device needs.
const _lightBinding = '''
bindings:
  light-den:
    connectivity: local
''';

/// A House Plan with one hole in it, so a case can be the line of YAML it is
/// about rather than a whole file. Every default here is a value the loader
/// accepts, so anything a case does not name is not what failed.
String _plan({
  String name = 'Boot House',
  String floorId = 'ground-floor',
  String rooms = '''      - id: den
        name: "Den"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
''',
  String walls = '      - [[0, 0], [4, 0]]\n',
  String extraFloor = '',
  String devices = '''devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: [2, 1.5]
''',
}) =>
    'name: "$name"\n'
    'floors:\n'
    '  - id: $floorId\n'
    '    name: "Ground Floor"\n'
    '    level: 0\n'
    '    rooms:\n'
    '$rooms'
    '    walls:\n'
    '$walls'
    '$extraFloor'
    '$devices';
