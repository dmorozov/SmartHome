import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/domain/device_state.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'test_house.dart';

/// A WebSocketChannel the test drives by hand: [fromServer] plays frames at
/// the client, [sent] records what the client wrote back.
class FakeChannel implements WebSocketChannel {
  final _fromServer = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  var closed = false;

  void serverSays(Map<String, dynamic> message) =>
      _fromServer.add(jsonEncode(message));

  void serverDrops() => _fromServer.close();

  @override
  Stream<dynamic> get stream => _fromServer.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this.channel);
  final FakeChannel channel;

  @override
  void add(dynamic data) =>
      channel.sent.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async =>
      channel.closed = true;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _entity(String id, String state,
        [Map<String, dynamic> attributes = const {}]) =>
    {'entity_id': id, 'state': state, 'attributes': attributes};

void main() {
  late FakeChannel channel;
  late HaHubClient hub;

  /// Runs the handshake up to the point HA has answered `get_states`.
  Future<void> connectAndSeed(List<Map<String, dynamic>> entities) async {
    channel.serverSays({'type': 'auth_required', 'ha_version': '2026.7'});
    await pumpEventQueue();
    channel.serverSays({'type': 'auth_ok', 'ha_version': '2026.7'});
    await pumpEventQueue();
    channel.serverSays({'id': 1, 'type': 'result', 'success': true, 'result': entities});
    await pumpEventQueue();
  }

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
    expect(hub.connected.value, isTrue);
  });

  test('folds entity states down to Device states by kind', () async {
    await connectAndSeed([
      _entity('input_boolean.light_hall', 'on'),
      _entity('climate.ecobee', 'heat',
          {'current_temperature': 21.4, 'temperature': 21.0}),
      _entity('sensor.emporia_vue', '812.5'),
      _entity('sensor.lg_washer', 'Idle'),
      _entity('input_boolean.garage_door', 'off'),
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
    await connectAndSeed([_entity('light.someone_elses_lamp', 'on')]);
    expect(hub.states, isEmpty);
  });

  test('state_changed events update state and reach the stream', () async {
    await connectAndSeed([_entity('input_boolean.light_hall', 'off')]);
    final changes = <DeviceState>[];
    hub.stateChanges.listen(changes.add);

    channel.serverSays({
      'type': 'event',
      'event': {
        'event_type': 'state_changed',
        'data': {
          'entity_id': 'input_boolean.light_hall',
          'new_state': _entity('input_boolean.light_hall', 'on'),
        },
      },
    });
    await pumpEventQueue();

    expect((hub.states['light-hall'] as SwitchState).on, isTrue);
    expect((changes.single as SwitchState).on, isTrue);
  });

  test('unavailable drops the Device back to unknown, not a stale value',
      () async {
    await connectAndSeed([_entity('sensor.emporia_vue', '812')]);
    expect(hub.states.containsKey('energy-monitor'), isTrue);

    channel.serverSays({
      'type': 'event',
      'event': {
        'event_type': 'state_changed',
        'data': {
          'entity_id': 'sensor.emporia_vue',
          'new_state': _entity('sensor.emporia_vue', 'unavailable'),
        },
      },
    });
    await pumpEventQueue();

    expect(hub.states.containsKey('energy-monitor'), isFalse);
  });

  test('toggle calls the domain-agnostic homeassistant.toggle service',
      () async {
    await connectAndSeed([_entity('input_boolean.light_hall', 'off')]);
    channel.sent.clear();

    await hub.toggle('light-hall');

    expect(channel.sent.single['type'], 'call_service');
    expect(channel.sent.single['domain'], 'homeassistant');
    expect(channel.sent.single['service'], 'toggle');
    expect(channel.sent.single['target'],
        {'entity_id': 'input_boolean.light_hall'});
  });

  test('a dropped connection is retried', () async {
    await connectAndSeed([_entity('input_boolean.light_hall', 'on')]);
    var connects = 1;
    // Re-point the factory at a fresh channel for the reconnect.
    final reconnected = FakeChannel();
    hub.dispose();
    hub = HaHubClient(
      house: loadTestHouse(),
      url: Uri.parse('ws://test/api/websocket'),
      token: 'test-token',
      connect: (_) {
        connects++;
        return reconnected;
      },
      retryFloor: const Duration(milliseconds: 1),
      retryCeiling: const Duration(milliseconds: 2),
    );
    reconnected.serverDrops();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(connects, greaterThan(1));
    expect(hub.connected.value, isFalse);
  });
}
