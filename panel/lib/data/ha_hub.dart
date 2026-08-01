import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../diagnostics/log.dart';
import '../domain/device_state.dart';
import '../domain/house.dart';
import 'hub_client.dart';

/// The real Hub: Home Assistant over its WebSocket API.
///
/// Folds the Hub's entity-shaped world down to the Panel's one-state-per-
/// Device model (see [DeviceState]). Each Device names the entity it comes
/// from in `devices.yaml`; how that entity's state is read depends on the
/// Device's kind, not on the entity's domain — a washer reported by a
/// `sensor.*` and one reported by a vendor integration both become a
/// [StatusState].
///
/// Connection handling is deliberately dumb and endless: the Panel is a
/// wall display that must recover on its own from a Hub restart, a network
/// blip, or the appliance rebooting, with nobody there to press anything.
class HaHubClient implements HubClient {
  HaHubClient({
    required House house,
    required Uri url,
    required String token,
    WebSocketChannel Function(Uri)? connect,
    this.retryFloor = const Duration(seconds: 1),
    this.retryCeiling = const Duration(seconds: 30),
    // Named parameters cannot be private, so these cannot be initializing
    // formals; the fields stay private because nothing outside needs them
    // (least of all the token).
    // ignore: prefer_initializing_formals
  })  : _url = url,
        // ignore: prefer_initializing_formals
        _token = token,
        _connect = connect ?? WebSocketChannel.connect {
    for (final device in house.floors.expand((f) => f.devices)) {
      final entityId = device.entityId;
      if (entityId != null) _byEntity[entityId] = device;
    }
    _open();
  }

  /// Builds the WebSocket URL from a Hub base URL: `http://host:8123` ->
  /// `ws://host:8123/api/websocket`.
  static Uri webSocketUrl(String baseUrl) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/websocket',
    );
  }

  final Uri _url;
  final String _token;
  final WebSocketChannel Function(Uri) _connect;
  final Duration retryFloor;
  final Duration retryCeiling;

  final _byEntity = <String, Device>{};
  final _states = <String, DeviceState>{};

  /// Devices currently reporting an unusable state, so the warning is
  /// logged once per outage rather than once per message.
  final _unusable = <String>{};
  final _changes = StreamController<DeviceState>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  Duration _retryIn = Duration.zero;
  var _nextId = 1;
  var _disposed = false;

  /// Up once the socket is open, authenticated and subscribed.
  @override
  final ValueNotifier<bool> connected = ValueNotifier(false);

  @override
  Map<String, DeviceState> get states => Map.unmodifiable(_states);

  @override
  Stream<DeviceState> get stateChanges => _changes.stream;

  @override
  Future<void> toggle(String deviceId) async {
    final device = _byEntity.values.where((d) => d.id == deviceId).firstOrNull;
    final entityId = device?.entityId;
    if (entityId == null) {
      // A pin that does nothing when tapped, silently, is the worst kind of
      // bug to chase on a wall panel.
      Log.warn('hub', 'toggle_unbound', {'device': deviceId});
      return;
    }
    Log.debug('hub', 'toggle', {'device': deviceId, 'entity': entityId});
    // `homeassistant.toggle` spans domains (light, switch, input_boolean,
    // cover…), so the Panel does not have to know which one backs a Device.
    _send({
      'id': _nextId++,
      'type': 'call_service',
      'domain': 'homeassistant',
      'service': 'toggle',
      'target': {'entity_id': entityId},
    });
  }

  @override
  void dispose() {
    Log.info('hub', 'closed');
    _disposed = true;
    _retryTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _changes.close();
    connected.dispose();
  }

  void _open() {
    if (_disposed) return;
    Log.info('hub', 'connecting', {'url': _url});
    try {
      final channel = _connect(_url);
      _channel = channel;
      _subscription = channel.stream.listen(
        _onFrame,
        onError: (Object error) {
          Log.warn('hub', 'socket_error', {'error': error});
          _reconnect();
        },
        onDone: _reconnect,
        cancelOnError: true,
      );
    } on Object catch (error) {
      Log.warn('hub', 'connect_failed', {'error': error});
      _reconnect();
    }
  }

  void _reconnect() {
    if (_disposed || _retryTimer != null) return;
    final wasConnected = connected.value;
    connected.value = false;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    // Back off to the ceiling, then keep trying there forever.
    _retryIn = _retryIn == Duration.zero
        ? retryFloor
        : Duration(
            microseconds:
                (_retryIn.inMicroseconds * 2).clamp(0, retryCeiling.inMicroseconds));
    // `was_connected` separates "the Hub went away" from "it was never
    // there" — different problems, and the retry loop looks identical.
    Log.warn('hub', 'reconnecting', {
      'in_ms': _retryIn.inMilliseconds,
      'was_connected': wasConnected,
    });
    _retryTimer = Timer(_retryIn, () {
      _retryTimer = null;
      _open();
    });
  }

  void _send(Map<String, dynamic> message) =>
      _channel?.sink.add(jsonEncode(message));

  void _onFrame(dynamic frame) {
    final message = jsonDecode(frame as String);
    if (message is! Map) return;
    switch (message['type']) {
      // Handshake: HA speaks first, then wants the long-lived token.
      case 'auth_required':
        _send({'type': 'auth', 'access_token': _token});
      case 'auth_ok':
        _retryIn = Duration.zero;
        connected.value = true;
        Log.info('hub', 'connected', {'url': _url, 'devices': _byEntity.length});
        // Snapshot first, then the delta subscription. Both ids are ours;
        // HA echoes them back on the results.
        _send({'id': _nextId++, 'type': 'get_states'});
        _send({
          'id': _nextId++,
          'type': 'subscribe_events',
          'event_type': 'state_changed',
        });
      case 'auth_invalid':
        // A bad token is not worth retrying — it will not fix itself.
        Log.error('hub', 'auth_invalid', fields: {'reason': message['message']});
        connected.value = false;
        _disposed = true;
        _channel?.sink.close();
        throw StateError(
            'Home Assistant rejected the token: ${message['message']}. '
            'Create a new long-lived token and rebuild with --dart-define.');
      case 'result':
        if (message['success'] == false) {
          // A rejected command would otherwise vanish: the Panel would show
          // the tap doing nothing and give no reason.
          Log.warn('hub', 'command_failed',
              {'id': message['id'], 'error': message['error']});
        }
        final result = message['result'];
        if (result is List) {
          // The only List result the Panel asks for is the get_states
          // snapshot.
          final bound = <String>{};
          for (final entity in result) {
            if (entity is Map && _applyEntity(entity)) {
              bound.add('${entity['entity_id']}');
            }
          }
          final missing =
              _byEntity.keys.where((e) => !bound.contains(e)).toList();
          Log.info('hub', 'snapshot', {
            'entities': result.length,
            'bound': bound.length,
            'missing': missing.length,
          });
          if (missing.isNotEmpty) {
            // The Hub has never heard of these. Typo in devices.yaml, or an
            // integration not set up yet — either way those pins stay blank
            // forever and nothing else says so. Capped because thirty-odd
            // ids on one line is unreadable, and the first few identify the
            // pattern; `snapshot` above carries the true count.
            const shown = 8;
            Log.warn('hub', 'missing_entities', {
              'ids': missing.take(shown).join(','),
              if (missing.length > shown) 'more': missing.length - shown,
            });
          }
        }
      case 'event':
        final event = message['event'];
        if (event is Map && event['event_type'] == 'state_changed') {
          final newState = event['data']?['new_state'];
          if (newState is Map) _applyEntity(newState);
        }
    }
  }

  /// Returns whether the entity belongs to a Device at all — the caller
  /// counts that to report how much of the House the Hub actually covers.
  bool _applyEntity(Map<dynamic, dynamic> entity) {
    final device = _byEntity[entity['entity_id']];
    if (device == null) return false;
    final state = _toDeviceState(device, entity);
    if (state == null) {
      // 'unavailable'/'unknown', or a reading we could not parse: drop the
      // Device back to unknown rather than showing a stale value.
      _states.remove(device.id);
      // One line per *entry* into the unusable state. Logging every message
      // would put a permanently-unavailable entity into journald forever.
      if (_unusable.add(device.id)) {
        Log.warn('hub', 'state_unusable', {
          'device': device.id,
          'entity': entity['entity_id'],
          'state': entity['state'],
        });
      }
      return true;
    }
    if (_unusable.remove(device.id)) {
      Log.info('hub', 'state_recovered',
          {'device': device.id, 'entity': entity['entity_id']});
    }
    _states[device.id] = state;
    if (Log.isDebug) {
      Log.debug('hub', 'state', {
        'device': device.id,
        'entity': entity['entity_id'],
        'state': entity['state'],
      });
    }
    if (!_changes.isClosed) _changes.add(state);
    return true;
  }

  DeviceState? _toDeviceState(Device device, Map<dynamic, dynamic> entity) {
    final raw = entity['state'];
    if (raw is! String || raw == 'unavailable' || raw == 'unknown') return null;
    final attributes = entity['attributes'];
    final attrs = attributes is Map ? attributes : const {};

    switch (device.kind) {
      case DeviceKind.light:
      case DeviceKind.outlet:
      case DeviceKind.tv:
        return SwitchState(device.id, on: raw == 'on');
      case DeviceKind.garageDoor:
        return GarageDoorState(device.id, open: raw == 'on' || raw == 'open');
      case DeviceKind.thermostat:
        final current = _number(attrs['current_temperature']);
        final target = _number(attrs['temperature']);
        if (current == null || target == null) return null;
        return ThermostatState(device.id, currentC: current, targetC: target);
      case DeviceKind.energyMonitor:
      case DeviceKind.evCharger:
        final watts = _number(raw);
        return watts == null ? null : PowerState(device.id, watts: watts);
      case DeviceKind.camera:
      case DeviceKind.doorbell:
      case DeviceKind.oven:
      case DeviceKind.washer:
      case DeviceKind.dryer:
      case DeviceKind.litterRobot:
      case DeviceKind.feeder:
        return StatusState(device.id, raw);
    }
  }

  static double? _number(dynamic value) => switch (value) {
        num n => n.toDouble(),
        String s => double.tryParse(s),
        _ => null,
      };
}
