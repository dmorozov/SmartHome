import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/device_state.dart';

import 'support/fake_channel.dart';
import 'test_house.dart';

/// The HubClient contract, run against every adapter.
///
/// Two adapters make the seam real, and this is where "real" is cashed out:
/// each case is stated once and executed twice, so an invariant the fake
/// honours and production violates cannot hide behind `HUB=fake` being the
/// default build. Every assertion crosses the interface — the closures in
/// [HubWorld] only stage the scenario, each in whatever way its adapter's
/// world actually works.
void main() {
  runHubContract('FakeHub', _fakeWorld);
  runHubContract('HaHubClient', _haWorld);
}

/// The hands that move an adapter's world.
typedef HubWorld = ({
  HubClient hub,

  /// Brings the world to the fixture: `light-hall` known off, `thermostat`
  /// known 21.4 °C now / 21.0 °C target.
  Future<void> Function() seed,
  Future<void> Function(DeviceState state) push,
  Future<void> Function(String deviceId) makeUnknown,
  Future<void> Function() dropHub,
  Future<void> Function() returnHub,
  Future<void> Function() dispose,
});

void runHubContract(String adapter, Future<HubWorld> Function() build) {
  group('HubClient contract · $adapter', () {
    late HubWorld world;
    late List<LogRecord> records;

    setUp(() async {
      records = <LogRecord>[];
      Log.sink = records.add;
      Log.level = LogLevel.warn;
      world = await build();
    });

    tearDown(() async {
      await world.dispose();
      Log.sink = Log.printRecord;
      Log.level = LogLevel.warn;
    });

    /// Every `hub.toggle_refused` line the adapter has emitted so far.
    Iterable<LogRecord> refusals() =>
        records.where((r) => r.event == 'toggle_refused');

    test('togglable answers from Device kind, not from live state', () async {
      expect(world.hub.togglable('light-hall'), isTrue);
      expect(world.hub.togglable('thermostat'), isFalse);
      expect(world.hub.togglable('no-such-device'), isFalse);

      await world.seed();
      await world.makeUnknown('light-hall');

      // The Panel's knowledge of a Device lapses routinely — a snapshot gap,
      // an entity gone unavailable, no `entity:` bound yet (ADR-0004). A
      // pin's affordance must not flap along with it.
      expect(world.hub.states.containsKey('light-hall'), isFalse);
      expect(world.hub.togglable('light-hall'), isTrue);
    });

    test('toggle on a non-togglable Device changes nothing, emits nothing, '
        'and refuses observably', () async {
      await world.seed();
      final before = Map.of(world.hub.states);
      final changes = <String>[];
      final sub = world.hub.stateChanges.listen(changes.add);
      addTearDown(sub.cancel);

      await world.hub.toggle('thermostat');
      await pumpEventQueue();

      expect(world.hub.states, before);
      expect(changes, isEmpty);
      final refused = refusals().single;
      expect(refused.level, LogLevel.warn);
      expect(refused.area, 'hub');
      expect(refused.fields, {'device': 'thermostat', 'kind': 'thermostat'});
    });

    test('toggle on an id the House does not contain refuses the same way',
        () async {
      await world.seed();
      final changes = <String>[];
      final sub = world.hub.stateChanges.listen(changes.add);
      addTearDown(sub.cancel);

      await world.hub.toggle('no-such-device');
      await pumpEventQueue();

      expect(changes, isEmpty);
      final refused = refusals().single;
      expect(refused.level, LogLevel.warn);
      expect(refused.fields, {'device': 'no-such-device', 'kind': null});
    });

    test('a state the world reports lands in states and emits its Device id',
        () async {
      await world.seed();
      final changes = <String>[];
      final sub = world.hub.stateChanges.listen(changes.add);
      addTearDown(sub.cancel);

      await world.push(const SwitchState('light-hall', on: true));
      await pumpEventQueue();

      expect((world.hub.states['light-hall'] as SwitchState).on, isTrue);
      expect(changes, ['light-hall']);
    });

    test('a Device the world loses leaves states and emits its Device id',
        () async {
      await world.seed();
      final changes = <String>[];
      final sub = world.hub.stateChanges.listen(changes.add);
      addTearDown(sub.cancel);

      await world.makeUnknown('light-hall');
      await pumpEventQueue();

      // Unknown, not stale: a frozen reading nobody announced is the one
      // thing a wall Panel must never show.
      expect(world.hub.states.containsKey('light-hall'), isFalse);
      expect(changes, ['light-hall']);
    });

    test('status falls to retrying when the Hub goes away and rises when it '
        'returns', () async {
      await world.seed();
      expect(world.hub.status.value, HubStatus.up);

      await world.dropHub();
      // Retrying, not gaveUp: an absent Hub is the case that fixes itself,
      // and the adapter must keep trying without being asked.
      expect(world.hub.status.value, HubStatus.retrying);

      await world.returnHub();
      expect(world.hub.status.value, HubStatus.up);
    });
  });
}

/// The in-process world: the driving surface *is* the staging.
Future<HubWorld> _fakeWorld() async {
  final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
  return (
    hub: hub,
    seed: () async {
      // FakeHub seeds every Device already; this only pins the two the
      // contract talks about (lights are seeded randomly).
      hub.pushState(const SwitchState('light-hall', on: false));
      hub.pushState(
          const ThermostatState('thermostat', currentC: 21.4, targetC: 21.0));
    },
    push: (state) async => hub.pushState(state),
    makeUnknown: (deviceId) async => hub.dropDevice(deviceId),
    dropHub: () async => hub.setStatus(HubStatus.retrying),
    returnHub: () async => hub.setStatus(HubStatus.up),
    dispose: () async => hub.dispose(),
  );
}

/// The production world, spoken to in Home Assistant's own frames: the
/// contract's scenarios have to survive the translation to and from the
/// wire, which is exactly the part the fake cannot vouch for.
Future<HubWorld> _haWorld() async {
  late FakeChannel channel;
  final hub = HaHubClient(
    house: loadTestHouse(),
    url: Uri.parse('ws://test/api/websocket'),
    token: 'test-token',
    // A fresh channel per attempt: the Hub coming back is a new socket, not
    // the old one resurrected.
    connect: (_) => channel = FakeChannel(),
    retryFloor: const Duration(milliseconds: 1),
    retryCeiling: const Duration(milliseconds: 2),
  );

  const entityOf = {
    'light-hall': 'input_boolean.light_hall',
    'thermostat': 'climate.ecobee',
  };

  /// The fixture's Device states, back in the entity shape the Hub reports.
  Map<String, dynamic> frameFor(DeviceState state) => switch (state) {
        SwitchState s =>
          entityFrame(entityOf[s.deviceId]!, s.on ? 'on' : 'off'),
        ThermostatState t => entityFrame(entityOf[t.deviceId]!, 'heat',
            {'current_temperature': t.currentC, 'temperature': t.targetC}),
        _ => throw UnsupportedError('the contract fixture reports only '
            'switches and thermostats; ${state.runtimeType} needs a frame'),
      };

  return (
    hub: hub,
    seed: () => connectAndSeed(channel, [
      entityFrame('input_boolean.light_hall', 'off'),
      entityFrame('climate.ecobee', 'heat',
          {'current_temperature': 21.4, 'temperature': 21.0}),
    ]),
    push: (state) async {
      channel.serverSays(stateChangedFrame(frameFor(state)));
      await pumpEventQueue();
    },
    makeUnknown: (deviceId) async {
      channel.serverSays(
          stateChangedFrame(entityFrame(entityOf[deviceId]!, 'unavailable')));
      await pumpEventQueue();
    },
    dropHub: () async {
      channel.serverDrops();
      // Long enough for the socket's onDone to reach the reconnect loop and
      // for its 1 ms retry to reopen — on the fresh channel returnHub speaks.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
    returnHub: () => connectAndSeed(channel, const []),
    dispose: () async => hub.dispose(),
  );
}
