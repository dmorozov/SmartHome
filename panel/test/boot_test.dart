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
      });
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
  });
}
