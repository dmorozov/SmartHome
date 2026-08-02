import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/device_state.dart';

import 'support/fake_channel.dart';
import 'test_house.dart';

void main() {
  late FakeChannel channel;
  late HaHubClient hub;

  setUp(() {
    channel = FakeChannel();
    hub = HaHubClient(
      house: loadTestHouse(),
      url: Uri.parse('ws://test/api/websocket'),
      token: 'test-token',
      connect: (_) => channel,
      retryFloor: const Duration(milliseconds: 1),
      retryCeiling: const Duration(milliseconds: 2),
    );
  });

  tearDown(() => hub.dispose());

  test('authenticates, then asks for the snapshot and the subscription',
      () async {
    channel.serverSays({'type': 'auth_required', 'ha_version': '2026.7'});
    await pumpEventQueue();
    expect(channel.sent.single,
        {'type': 'auth', 'access_token': 'test-token'});

    channel.serverSays({'type': 'auth_ok', 'ha_version': '2026.7'});
    await pumpEventQueue();
    expect(channel.sent[1]['type'], 'get_states');
    expect(channel.sent[2]['type'], 'subscribe_events');
    expect(channel.sent[2]['event_type'], 'state_changed');
    expect(hub.status.value, HubStatus.up);
  });

  test('folds entity states down to Device states by kind', () async {
    await connectAndSeed(channel, [
      entityFrame('input_boolean.light_hall', 'on'),
      entityFrame('climate.ecobee', 'heat',
          {'current_temperature': 21.4, 'temperature': 21.0}),
      entityFrame('sensor.emporia_vue', '812.5'),
      entityFrame('sensor.lg_washer', 'Idle'),
      entityFrame('input_boolean.garage_door', 'off'),
    ]);

    expect((hub.states['light-hall'] as SwitchState).on, isTrue);
    final thermostat = hub.states['thermostat'] as ThermostatState;
    expect(thermostat.currentC, 21.4);
    expect(thermostat.targetC, 21.0);
    expect((hub.states['energy-monitor'] as PowerState).watts, 812.5);
    expect((hub.states['washer'] as StatusState).status, 'Idle');
    expect((hub.states['garage-door'] as GarageDoorState).open, isFalse);
  });

  test('ignores entities no Device binds to', () async {
    await connectAndSeed(channel, [entityFrame('light.someone_elses_lamp', 'on')]);
    expect(hub.states, isEmpty);
  });

  test('state_changed events update state and reach the stream', () async {
    await connectAndSeed(channel, [entityFrame('input_boolean.light_hall', 'off')]);
    final changes = <String>[];
    hub.stateChanges.listen(changes.add);

    channel.serverSays(
        stateChangedFrame(entityFrame('input_boolean.light_hall', 'on')));
    await pumpEventQueue();

    expect((hub.states['light-hall'] as SwitchState).on, isTrue);
    expect(changes.single, 'light-hall');
  });

  test('unavailable drops the Device back to unknown, not a stale value',
      () async {
    await connectAndSeed(channel, [entityFrame('sensor.emporia_vue', '812')]);
    expect(hub.states.containsKey('energy-monitor'), isTrue);
    final changes = <String>[];
    hub.stateChanges.listen(changes.add);

    channel.serverSays(
        stateChangedFrame(entityFrame('sensor.emporia_vue', 'unavailable')));
    await pumpEventQueue();

    expect(hub.states.containsKey('energy-monitor'), isFalse);
    // The drop has to be announced like any other change, or the pin keeps
    // its stale reading until some unrelated Device repaints the Dollhouse.
    expect(changes.single, 'energy-monitor');
  });

  test('toggle calls the domain-agnostic homeassistant.toggle service',
      () async {
    await connectAndSeed(channel, [entityFrame('input_boolean.light_hall', 'off')]);
    channel.sent.clear();

    await hub.toggle('light-hall');

    expect(channel.sent.single['type'], 'call_service');
    expect(channel.sent.single['domain'], 'homeassistant');
    expect(channel.sent.single['service'], 'toggle');
    expect(channel.sent.single['target'],
        {'entity_id': 'input_boolean.light_hall'});
  });

  test('refuses to toggle the thermostat — nothing reaches the Hub',
      () async {
    final records = <LogRecord>[];
    Log.sink = records.add;
    addTearDown(() => Log.sink = Log.printRecord);

    await connectAndSeed(channel, [
      entityFrame('climate.ecobee', 'heat',
          {'current_temperature': 21.4, 'temperature': 21.0}),
    ]);
    channel.sent.clear();

    await hub.toggle('thermostat');

    // `homeassistant.toggle` delegates per domain, and on `climate.*` that
    // is `climate.toggle` — it would flip the real HVAC. Nothing but the
    // seam's refusal stands between a mis-tap and a cold house.
    expect(channel.sent, isEmpty);
    final refused = records.singleWhere((r) => r.event == 'toggle_refused');
    expect(refused.level, LogLevel.warn);
    expect(refused.area, 'hub');
    expect(refused.fields, {'device': 'thermostat', 'kind': 'thermostat'});
  });

  test('reports how much of the House the snapshot actually covered',
      () async {
    final records = <LogRecord>[];
    Log.sink = records.add;
    Log.level = LogLevel.info;
    addTearDown(() {
      Log.sink = Log.printRecord;
      Log.level = LogLevel.warn;
    });

    await connectAndSeed(channel, [entityFrame('input_boolean.light_hall', 'on')]);

    final snapshot = records.firstWhere((r) => r.event == 'snapshot').fields!;
    expect(snapshot['entities'], 1);
    expect(snapshot['bound'], 1);
    // Every other Device in bindings.yaml names an entity the Hub did not
    // report. Without this line that failure — a typo in bindings.yaml, an
    // integration not set up — shows only as a pin that never fills in.
    expect(snapshot['missing'], greaterThan(0));
    expect(records.map((r) => r.event), contains('missing_entities'));
  });

  // Reconnection lives in ha_hub_recovery_test.dart, where a fake clock and
  // a fresh socket per attempt let it assert what actually happens. The
  // wall-clock test that used to sit here counted connect attempts against
  // one single-subscription channel, so every retry crashed in listen() and
  // was swallowed — it never replayed a handshake, and passed anyway.
}
