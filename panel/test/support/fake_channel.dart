import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A WebSocketChannel the test drives by hand: [serverSays] plays frames at
/// the client, [sent] records what the client wrote back.
///
/// Shared by every suite that drives HaHubClient — the adapter's own tests
/// and the HubClient contract suite — so the Hub's wire protocol is spoken
/// in one place rather than re-typed per file.
class FakeChannel implements WebSocketChannel {
  final _fromServer = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  var closed = false;

  void serverSays(Map<String, dynamic> message) =>
      _fromServer.add(jsonEncode(message));

  void serverDrops() => _fromServer.close();

  /// The socket failing rather than closing — what `WebSocketChannel` puts on
  /// the stream when the connection breaks. Separate from [serverDrops]
  /// because the client treats them differently: a drop is silent and a
  /// failure is logged, and it is the logged one that has to be checked for
  /// what it prints (`dart:io`'s `HttpException` appends `uri = …` to its own
  /// message, and that Uri is HA_URL).
  void serverFails(Object error) => _fromServer.addError(error);

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

/// The Hub's side of the socket across reconnects: a fresh [FakeChannel]
/// per connect attempt, the way a real server hands out a new socket every
/// time.
///
/// A [FakeChannel]'s stream is single-subscription, so handing the same one
/// back on every attempt turns each retry into a `listen()` crash that the
/// client's blanket handler swallows and retries — a connect-crash loop
/// that looks exactly like a working reconnect from the outside, and never
/// replays a handshake. Keeping the attempts is also how a test asserts
/// backoff: [attempts] grows once per attempt, at the moment it happens.
class FakeHubServer {
  final attempts = <FakeChannel>[];

  /// The socket of the latest connect attempt.
  FakeChannel get current => attempts.last;

  WebSocketChannel connect(Uri _) {
    final channel = FakeChannel();
    attempts.add(channel);
    return channel;
  }
}

/// One entity as the Hub reports it — the shape carried by both the
/// `get_states` snapshot and a `state_changed` event.
Map<String, dynamic> entityFrame(String id, String state,
        [Map<String, dynamic> attributes = const {}]) =>
    {'entity_id': id, 'state': state, 'attributes': attributes};

/// A `state_changed` event announcing [entity] as that entity's new state.
Map<String, dynamic> stateChangedFrame(Map<String, dynamic> entity) => {
      'type': 'event',
      'event': {
        'event_type': 'state_changed',
        'data': {'entity_id': entity['entity_id'], 'new_state': entity},
      },
    };

/// The `get_config` answer, trimmed to the one field the Panel reads.
/// [temperature] is the symbol HA puts in `unit_system.temperature` — the
/// house Hub says `°F`, the dev Hub `°C`, and a Hub that says something
/// else is a case the Panel has to survive.
Map<String, dynamic> configFrame(String temperature) => {
      'id': 1,
      'type': 'result',
      'success': true,
      'result': {
        'location_name': 'Home',
        'unit_system': {'temperature': temperature, 'length': 'km'},
      },
    };

/// Runs the handshake on [channel] up to the point the Hub has answered
/// `get_config` and `get_states` with [entities]. The result ids are
/// arbitrary: the Panel keys off the payload's shape, not off ids it sent.
///
/// [temperature] defaults to a Celsius Hub, which is what the dev Hub is —
/// so a suite that is not *about* units gets a Hub that answered, like
/// every real one does. Pass null for the Hub that never answers, and `°F`
/// for the house.
Future<void> connectAndSeed(
    FakeChannel channel, List<Map<String, dynamic>> entities,
    {String? temperature = '°C'}) async {
  channel.serverSays({'type': 'auth_required', 'ha_version': '2026.7'});
  await pumpEventQueue();
  channel.serverSays({'type': 'auth_ok', 'ha_version': '2026.7'});
  await pumpEventQueue();
  if (temperature != null) {
    channel.serverSays(configFrame(temperature));
    await pumpEventQueue();
  }
  channel.serverSays(
      {'id': 2, 'type': 'result', 'success': true, 'result': entities});
  await pumpEventQueue();
}
