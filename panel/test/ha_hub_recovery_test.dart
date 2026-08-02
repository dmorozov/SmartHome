import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/device_state.dart';

import 'support/fake_channel.dart';
import 'test_house.dart';

/// The Panel's recovery promise — "recover on its own from a Hub restart, a
/// network blip, or the appliance rebooting, with nobody there to press
/// anything" — pinned without sleeping.
///
/// Two seams make that possible and neither is new: the injectable connect
/// factory the adapter already takes, and the zone, which owns every Timer
/// the backoff schedules. `fakeAsync` moves the clock; nothing waits.
void main() {
  late List<LogRecord> records;

  setUp(() {
    records = <LogRecord>[];
    Log.sink = records.add;
  });

  tearDown(() => Log.sink = Log.printRecord);

  /// A client and the server it dials, both inside [async]'s zone. Uses the
  /// production retry defaults: under a fake clock they cost nothing, and
  /// their arithmetic is exactly what is under test.
  (HaHubClient, FakeHubServer) dial(FakeAsync async) {
    final server = FakeHubServer();
    final hub = HaHubClient(
      house: loadTestHouse(),
      url: Uri.parse('ws://test/api/websocket'),
      token: 'test-token',
      connect: server.connect,
      retryFloor: const Duration(seconds: 1),
      retryCeiling: const Duration(seconds: 30),
    );
    async.flushMicrotasks();
    return (hub, server);
  }

  /// The Hub's whole opening act on [channel]: greet, accept the token,
  /// answer the snapshot with [entities].
  void handshake(FakeAsync async, FakeChannel channel,
      {List<Map<String, dynamic>> entities = const []}) {
    channel.serverSays({'type': 'auth_required', 'ha_version': '2026.7'});
    async.flushMicrotasks();
    channel.serverSays({'type': 'auth_ok', 'ha_version': '2026.7'});
    async.flushMicrotasks();
    // The client keys off the payload's shape, not the id it sent, so any
    // id works — and after a reconnect the real one is no longer 1.
    channel.serverSays(
        {'id': 0, 'type': 'result', 'success': true, 'result': entities});
    async.flushMicrotasks();
  }

  test('backs off from the floor, doubles, and then holds the ceiling', () {
    fakeAsync((async) {
      final (hub, server) = dial(async);
      handshake(async, server.current);
      expect(hub.status.value, HubStatus.up);

      // 16 doubles to 32, which the ceiling clamps — and every attempt after
      // that waits the same 30 s, forever, which is the promise: a Panel
      // whose Hub is off for a week keeps knocking without hammering it.
      for (final seconds in const [1, 2, 4, 8, 16, 30, 30, 30]) {
        final before = server.attempts.length;
        server.current.serverDrops();
        async.flushMicrotasks();
        expect(hub.status.value, HubStatus.retrying);

        async.elapse(Duration(seconds: seconds) - const Duration(seconds: 1));
        expect(server.attempts, hasLength(before),
            reason: 'retried before the ${seconds}s backoff elapsed');
        async.elapse(const Duration(seconds: 1));
        expect(server.attempts, hasLength(before + 1),
            reason: 'no retry after the ${seconds}s backoff elapsed');
      }

      hub.dispose();
    });
  });

  test('a Hub that answers again resets the backoff to the floor', () {
    fakeAsync((async) {
      final (hub, server) = dial(async);
      handshake(async, server.current);
      for (final seconds in const [1, 2, 4, 8, 16, 30]) {
        server.current.serverDrops();
        async.flushMicrotasks();
        async.elapse(Duration(seconds: seconds));
      }

      handshake(async, server.current);
      expect(hub.status.value, HubStatus.up);

      // Without the reset, one bad afternoon would leave the Panel half a
      // minute behind every future blip for the rest of its uptime.
      final before = server.attempts.length;
      server.current.serverDrops();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));

      expect(server.attempts, hasLength(before + 1));
      hub.dispose();
    });
  });

  test('a Hub restart replays the handshake and re-seeds the snapshot', () {
    fakeAsync((async) {
      final (hub, server) = dial(async);
      handshake(async, server.current,
          entities: [entityFrame('input_boolean.light_hall', 'on')]);
      expect((hub.states['light-hall'] as SwitchState).on, isTrue);

      server.current.serverDrops();
      async.flushMicrotasks();
      expect(hub.status.value, HubStatus.retrying);
      // Readings survive the outage: the badge says they are stale, the
      // house does not blank itself because a socket blinked.
      expect(hub.states.containsKey('light-hall'), isTrue);

      async.elapse(const Duration(seconds: 1));
      final restarted = server.current;
      expect(restarted, isNot(same(server.attempts.first)),
          reason: 'the Hub coming back is a new socket');

      restarted.serverSays({'type': 'auth_required', 'ha_version': '2026.7'});
      async.flushMicrotasks();
      expect(restarted.sent.single,
          {'type': 'auth', 'access_token': 'test-token'},
          reason: 'a restarted Hub has forgotten the session');

      restarted.serverSays({'type': 'auth_ok', 'ha_version': '2026.7'});
      async.flushMicrotasks();
      expect(restarted.sent.map((m) => m['type']),
          containsAllInOrder(['auth', 'get_states', 'subscribe_events']));

      // Re-seeding is the point of asking again: while the Panel was away
      // the light went off, and only the fresh snapshot says so.
      restarted.serverSays({
        'id': 0,
        'type': 'result',
        'success': true,
        'result': [entityFrame('input_boolean.light_hall', 'off')],
      });
      async.flushMicrotasks();

      expect((hub.states['light-hall'] as SwitchState).on, isFalse);
      expect(hub.status.value, HubStatus.up);
      hub.dispose();
    });
  });

  test('a rejected token gives up: status says so, retries stop, nothing '
      'is thrown', () {
    fakeAsync((async) {
      final (hub, server) = dial(async);
      server.current.serverSays({'type': 'auth_required', 'ha_version': '2026.7'});
      async.flushMicrotasks();
      server.current.serverSays({
        'type': 'auth_invalid',
        'message': 'Invalid access token or password',
      });
      async.flushMicrotasks();

      expect(hub.status.value, HubStatus.gaveUp);
      expect(server.current.closed, isTrue);
      // Knocking forever on a door that will never open is a busy loop
      // nobody can see; the wall says NEEDS NEW TOKEN instead.
      async.elapse(const Duration(minutes: 5));
      expect(server.attempts, hasLength(1));
      // And it is not silent: one greppable line for whoever reads
      // journald, since the person at the wall cannot see a stack trace.
      // (Before this landed, the same case threw into the socket's stream
      // listener, where no caller could catch it — this test would have
      // failed on the loose exception rather than on any assertion.)
      expect(records.where((r) => r.event == 'auth_invalid'), hasLength(1));

      hub.dispose();
    });
  });

  test('a disposed client stops dialling, even with a retry already due', () {
    // Two things stop it — the cancelled timer and the disposed check in
    // the connect path — and only their combined effect is observable here.
    // Pull either one out and this still passes; that is defence in depth,
    // not two chances to assert it.
    fakeAsync((async) {
      final (hub, server) = dial(async);
      handshake(async, server.current);
      server.current.serverDrops();
      async.flushMicrotasks();

      hub.dispose();
      async.elapse(const Duration(minutes: 1));

      expect(server.attempts, hasLength(1),
          reason: 'a disposed client kept dialling');
    });
  });
}
