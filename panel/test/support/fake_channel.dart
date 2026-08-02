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

/// Runs the handshake on [channel] up to the point the Hub has answered
/// `get_states` with [entities]. The result id is arbitrary: the Panel keys
/// off the payload's shape, not off ids it sent.
Future<void> connectAndSeed(
    FakeChannel channel, List<Map<String, dynamic>> entities) async {
  channel.serverSays({'type': 'auth_required', 'ha_version': '2026.7'});
  await pumpEventQueue();
  channel.serverSays({'type': 'auth_ok', 'ha_version': '2026.7'});
  await pumpEventQueue();
  channel.serverSays(
      {'id': 1, 'type': 'result', 'success': true, 'result': entities});
  await pumpEventQueue();
}
