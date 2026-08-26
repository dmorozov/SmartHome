import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/data/house_loader.dart';
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
    // The unit system is asked for first, so that on a Hub that answers in
    // order no reading is ever folded before the Panel knows what unit it
    // is in. (Correctness does not rest on that — see the out-of-order test
    // below — but the wall should not flicker unitless for no reason.)
    expect(channel.sent.map((m) => m['type']),
        ['auth', 'get_config', 'get_states', 'subscribe_events']);
    expect(channel.sent[3]['event_type'], 'state_changed');
    expect(hub.status.value, HubStatus.up);
  });

  test('folds entity states down to Device states by kind', () async {
    await connectAndSeed(channel, [
      entityFrame('input_boolean.light_hall', 'on'),
      entityFrame('climate.main_floor', 'heat',
          {'current_temperature': 21.4, 'temperature': 21.0}),
      entityFrame('sensor.emporia_vue', '812.5'),
      entityFrame('sensor.lg_washer', 'Idle'),
      entityFrame('input_boolean.garage_door', 'off'),
    ]);

    expect((hub.states['light-hall'] as SwitchState).on, isTrue);
    final thermostat = hub.states['thermostat'] as ThermostatState;
    expect(thermostat.current, 21.4);
    expect(thermostat.target, 21.0);
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
      entityFrame('climate.main_floor', 'heat',
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

  test('setThermostatTarget calls climate.set_temperature with the absolute '
      'value', () async {
    await connectAndSeed(channel, [
      entityFrame('climate.main_floor', 'heat',
          {'current_temperature': 21.4, 'temperature': 21.0}),
    ]);
    channel.sent.clear();

    await hub.setThermostatTarget('thermostat', 22.5);

    final sent = channel.sent.single;
    expect(sent['type'], 'call_service');
    expect(sent['domain'], 'climate');
    expect(sent['service'], 'set_temperature');
    // Absolute and unconverted: the value is denominated by the Hub itself
    // (hub_client.dart), so nothing on the way out may translate it.
    expect(sent['service_data'], {'temperature': 22.5});
    expect(sent['target'], {'entity_id': 'climate.main_floor'});
  });

  test('refuses setThermostatTarget on a light — nothing reaches the Hub',
      () async {
    final records = <LogRecord>[];
    Log.sink = records.add;
    addTearDown(() => Log.sink = Log.printRecord);

    await connectAndSeed(channel, [entityFrame('input_boolean.light_hall', 'off')]);
    channel.sent.clear();

    await hub.setThermostatTarget('light-hall', 22.0);

    // The contract suite proves the log line and the silent states map; only
    // this seam's own test can see the channel, and "refused but sent
    // anyway" is precisely the regression the channel is needed to catch.
    expect(channel.sent, isEmpty);
    final refused =
        records.singleWhere((r) => r.event == 'set_target_refused');
    expect(refused.level, LogLevel.warn);
    expect(refused.fields, {
      'device': 'light-hall',
      'kind': 'light',
      'reason': 'not_thermostat',
    });
  });

  test('setThermostatTarget on an unbound thermostat sends nothing and says '
      'so', () async {
    final records = <LogRecord>[];
    Log.sink = records.add;
    addTearDown(() => Log.sink = Log.printRecord);

    // A House whose thermostat has no `entity:` yet — ADR-0004 says it
    // still renders, so its Popup's controls can still be tapped.
    final unboundChannel = FakeChannel();
    final unbound = HaHubClient(
      house: loadHouse(houseYaml: '''
name: "Unbound"
floors:
  - id: g
    name: "Ground"
    level: 0
    rooms:
      - id: den
        name: "Den"
        footprint: [[0, 0], [4, 0], [4, 3], [0, 3]]
    walls:
      - [[0, 0], [4, 0]]
devices:
  - key: thermostat
    name: "Ecobee"
    kind: thermostat
    room: den
    position: [2, 1.5]
''', bindingsYaml: '''
bindings:
  thermostat:
    connectivity: local
'''),
      url: Uri.parse('ws://test/api/websocket'),
      token: 'test-token',
      connect: (_) => unboundChannel,
      retryFloor: const Duration(milliseconds: 1),
      retryCeiling: const Duration(milliseconds: 2),
    );
    addTearDown(unbound.dispose);

    await unbound.setThermostatTarget('thermostat', 22.0);

    // A setpoint row that does nothing, silently, is the worst kind of bug
    // to chase on a wall panel — toggle_unbound's argument, same seam.
    expect(unboundChannel.sent.where((m) => m['type'] == 'call_service'),
        isEmpty);
    final line = records.singleWhere((r) => r.event == 'set_target_unbound');
    expect(line.level, LogLevel.warn);
    expect(line.fields, {'device': 'thermostat'});
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

  /// Home Assistant converts climate temperatures into the Hub's own unit
  /// system before they reach the API, and the entity payload never names
  /// the unit — measured on the house Hub, whose `climate.main_floor`
  /// reports `current_temperature: 83` with `unit_system.temperature: °F`
  /// and nothing else. So the unit is a fact about the *Hub*, learned once
  /// from `get_config`, and every reading has to carry it.
  group('temperature unit', () {
    /// The thermostat as the Hub reports it after [connectAndSeed].
    Future<ThermostatState> thermostat({String? temperature}) async {
      await connectAndSeed(channel, [
        entityFrame('climate.main_floor', 'cool',
            {'current_temperature': 83.0, 'temperature': 72.0}),
      ], temperature: temperature);
      return hub.states['thermostat'] as ThermostatState;
    }

    test('a °F Hub reading is labelled °F and left alone', () async {
      final state = await thermostat(temperature: '°F');

      // Unconverted: 83 is what the Ecobee's own display says, what the HA
      // app says, and what the wall must say. The bug this replaced named
      // this same 83 `currentC` and rendered "83.0 °C".
      expect(state.current, 83.0);
      expect(state.target, 72.0);
      expect(state.unit, TemperatureUnit.fahrenheit);
    });

    test('a °C Hub reading is labelled °C and left alone', () async {
      final state = await thermostat(temperature: '°C');

      expect(state.current, 83.0);
      expect(state.unit, TemperatureUnit.celsius);
    });

    test('a Hub that never answers get_config leaves the unit unstated',
        () async {
      final state = await thermostat(temperature: null);

      // Null, not a default. Defaulting is what put a Fahrenheit number
      // behind a °C suffix; unknown renders as a bare `°` instead.
      expect(state.unit, isNull);
      expect(state.current, 83.0);
    });

    test('a unit symbol the Panel cannot name is unknown, and says so',
        () async {
      final records = <LogRecord>[];
      Log.sink = records.add;
      addTearDown(() => Log.sink = Log.printRecord);

      final state = await thermostat(temperature: 'K');

      expect(state.unit, isNull);
      // Otherwise a wall of unitless degrees has no explanation anywhere.
      final unknown =
          records.singleWhere((r) => r.event == 'temperature_unit_unknown');
      expect(unknown.level, LogLevel.warn);
      expect(unknown.fields, {'unit': 'K'});
    });

    test('a unit that lands after the snapshot re-labels what is already on '
        'the wall', () async {
      // The Hub answers get_states first. Nothing forbids it, and the pin
      // is already showing a number by then — the next report that would
      // fix it is whenever the room moves, which on a real thermostat is
      // minutes.
      await thermostat(temperature: null);
      final changes = <String>[];
      hub.stateChanges.listen(changes.add);

      channel.serverSays(configFrame('°F'));
      await pumpEventQueue();

      final state = hub.states['thermostat'] as ThermostatState;
      expect(state.unit, TemperatureUnit.fahrenheit);
      expect(state.current, 83.0, reason: 'the reading itself must not move');
      // A relabel is a change like any other: without the emit the pin
      // keeps its unitless face until something unrelated repaints.
      expect(changes, ['thermostat']);
    });
  });

  group('what the log is allowed to say about the Hub address', () {
    // Its own hub, because these cases are about a URL with a credential in
    // it, and the shared one is a bare `ws://test/api/websocket`.
    const password = 'hunter2';
    late List<LogRecord> records;

    /// A client dialling [url], with the handshake left to the caller.
    HaHubClient dial(String url, {FakeChannel? socket}) {
      final client = HaHubClient(
        house: loadTestHouse(),
        url: HaHubClient.webSocketUrl(url),
        token: 'test-token',
        connect: (_) => socket ?? FakeChannel(),
        retryFloor: const Duration(milliseconds: 1),
        retryCeiling: const Duration(milliseconds: 2),
      );
      addTearDown(client.dispose);
      return client;
    }

    String lineFor(String event) =>
        records.singleWhere((r) => r.event == event).toString();

    setUp(() {
      records = <LogRecord>[];
      Log.sink = records.add;
      Log.level = LogLevel.debug;
      addTearDown(() {
        Log.sink = Log.printRecord;
        Log.level = LogLevel.warn;
      });
    });

    test('the address is dialled with its credential and logged without one, '
        'on connect and again on every reconnect', () async {
      // Measured, on a healthy boot and then forever:
      //
      //   I hub.connecting url=ws://admin:hunter2@ha.local:8123/api/websocket
      //   I hub.connected  url=ws://admin:hunter2@ha.local:8123/api/websocket
      //
      // `hub.connected` is re-emitted on every reconnect, so a flapping Hub
      // multiplied it. The credential still has to reach the socket — a Hub
      // behind a reverse proxy with basic auth needs it — so what changes is
      // the log and not `webSocketUrl`.
      final socket = FakeChannel();
      final client =
          dial('http://admin:$password@ha.local:8123', socket: socket);

      socket.serverSays({'type': 'auth_required'});
      await pumpEventQueue();
      socket.serverSays({'type': 'auth_ok'});
      await pumpEventQueue();

      expect(client.status.value, HubStatus.up);
      // The address survives whole: telling a stale address from a dead Hub
      // is what these lines are for, and neither is legible without it.
      expect(lineFor('connecting'), '[panel] I hub.connecting '
          'url=ws://ha.local:8123');
      expect(lineFor('connected'), '[panel] I hub.connected '
          'url=ws://ha.local:8123 devices=36');
    });

    test('no path=set on a path the Panel appended itself, or the word would '
        'be on every Hub forever', () {
      // `webSocketUrl` replaces the path with `/api/websocket`, so reporting a
      // path here would report the Panel's own constant. `hub.configured` in
      // boot.dart is the line that sees the operator's value and
      // characterises it — one fact, reported once.
      dial('http://ha.local:8123');

      expect(lineFor('connecting'), '[panel] I hub.connecting '
          'url=ws://ha.local:8123');
    });

    test('a query credential does not survive the http->ws transform into the '
        'log, though it does survive it into the socket', () async {
      // `base.replace(scheme:, path:)` carries the query through — deliberate,
      // because `?api_password=` is a real Home Assistant credential and the
      // handshake needs it — and that is exactly why the line printing this
      // Uri had to stop printing it whole.
      final socket = FakeChannel();
      final client =
          dial('http://ha.local:8123/?api_password=$password', socket: socket);

      expect(client.status.value, HubStatus.retrying);
      expect(records.map((r) => r.toString()).join('\n'),
          isNot(contains(password)));
      expect(lineFor('connecting'), '[panel] I hub.connecting '
          'url=ws://ha.local:8123');
    });

    test('a socket failure reproduces the library\'s message and not the URL '
        'that library appended to it', () async {
      // The failure path's copy of the same leak, and the shape
      // `redactCredentials` was written for one layer up: `dart:io`'s
      // `HttpException` appends `uri = <the whole URL>` to its own message,
      // measured against a real ServerSocket as
      //
      //   W hub.socket_error error="WebSocketChannelException: HttpException:
      //   …, uri = http://admin:hunter2@127.0.0.1:43159/api/websocket"
      final socket = FakeChannel();
      dial('http://admin:$password@ha.local:8123', socket: socket);

      socket.serverFails('WebSocketChannelException: HttpException: '
          'Connection closed before full header was received, uri = '
          'http://admin:$password@127.0.0.1:43159/api/websocket');
      await pumpEventQueue();

      // Which host refused, and why, both survive; the credential and the
      // path do not.
      expect(lineFor('socket_error'), '[panel] W hub.socket_error '
          'error="WebSocketChannelException: HttpException: Connection closed '
          'before full header was received, uri = http://127.0.0.1:43159 '
          '<redacted>"');
    });
  });

  // Reconnection lives in ha_hub_recovery_test.dart, where a fake clock and
  // a fresh socket per attempt let it assert what actually happens. The
  // wall-clock test that used to sit here counted connect attempts against
  // one single-subscription channel, so every retry crashed in listen() and
  // was swallowed — it never replayed a handshake, and passed anyway.
}
