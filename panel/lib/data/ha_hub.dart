import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../diagnostics/log.dart';
import '../diagnostics/url_redaction.dart';
import '../domain/device_state.dart';
import '../domain/device_traits.dart';
import '../domain/house.dart';
import 'hub_client.dart';

/// The real Hub: Home Assistant over its WebSocket API.
///
/// Folds the Hub's entity-shaped world down to the Panel's one-state-per-
/// Device model (see [DeviceState]). Each Device names the entity it comes
/// from in `bindings.yaml`; how that entity's state is read depends on the
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
      _byId[device.id] = device;
      final entityId = device.entityId;
      if (entityId != null) _byEntity[entityId] = device;
    }
    _open();
  }

  /// Builds the WebSocket URL from a Hub base URL: `http://host:8123` ->
  /// `ws://host:8123/api/websocket`.
  ///
  /// `replace` carries `userInfo` and the query through on purpose — a Hub
  /// behind a reverse proxy with basic auth, or an `?api_password=`, has to
  /// reach the socket or the handshake fails. What must not carry through is
  /// the *log*: everything below prints this Uri through [addressForLog], and
  /// the whole value used to go to journald twice per connect and again on
  /// every reconnect.
  ///
  /// `tryParse`, not `parse`, and the difference is a credential. `Uri.parse`
  /// throws a FormatException that reproduces the WHOLE source string with a
  /// caret under the offending character — and the shape that reaches it is
  /// the ordinary one: a password containing `@`, `!`, `|` or a space, none
  /// of which anyone percent-encodes when typing `Environment=HA_URL=`. That
  /// exception escaped `bootPanel` as an uncaught async error and printed
  /// `HA_URL` verbatim, one line after `hub.configured` had carefully
  /// answered `url=unusable` about the very same value. Naming the setting
  /// instead of echoing it is what makes those two lines agree.
  ///
  /// `log.dart` now also redacts `error=` as a backstop, so this is belt and
  /// braces — deliberately, because the backstop works on rendered text and
  /// this knows it is holding a URL.
  static Uri webSocketUrl(String baseUrl) {
    final base = Uri.tryParse(baseUrl);
    if (base == null || base.host.isEmpty) {
      throw ArgumentError('HA_URL is not a URL the Panel can dial: it needs a '
          'scheme and a host, like http://192.168.68.81:8123. Its value is not '
          'repeated here — it is read from the environment, a --dart-define or '
          'the appliance unit file, and a password pasted into it would end up '
          'in the log this message goes to.');
    }
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

  final _byId = <String, Device>{};
  final _byEntity = <String, Device>{};
  final _states = <String, DeviceState>{};

  /// Devices currently reporting an unusable state, so the warning is
  /// logged once per outage rather than once per message.
  final _unusable = <String>{};
  final _changes = StreamController<String>.broadcast();

  /// The unit this Hub states climate temperatures in, learned from
  /// `get_config` — null until it answers. Survives a reconnect: the last
  /// unit the Hub stated is a better guess than none while the socket is
  /// down.
  TemperatureUnit? _unit;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  Duration _retryIn = Duration.zero;
  var _nextId = 1;
  var _disposed = false;

  /// Up once the socket is open, authenticated and subscribed; retrying
  /// from construction until then and after every drop; gaveUp only when
  /// the Hub rejects the token.
  @override
  final ValueNotifier<HubStatus> status = ValueNotifier(HubStatus.retrying);

  @override
  Map<String, DeviceState> get states => Map.unmodifiable(_states);

  @override
  Stream<String> get stateChanges => _changes.stream;

  @override
  bool togglable(String deviceId) => _byId[deviceId]?.kind.toggles ?? false;

  @override
  Future<void> toggle(String deviceId) async {
    final device = _byId[deviceId];
    if (device == null || !device.kind.toggles) {
      // `homeassistant.toggle` delegates per domain, so on `climate.*` it
      // would flip the real HVAC. The Panel refuses rather than find out.
      Log.warn('hub', 'toggle_refused',
          {'device': deviceId, 'kind': device?.kind.name});
      return;
    }
    final entityId = device.entityId;
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
  Future<void> setThermostatTarget(String deviceId, double target) async {
    final device = _byId[deviceId];
    if (device == null ||
        specOf(device.kind).family != StateFamily.thermostat) {
      // The mirror of toggle's refusal, and for the mirror-image reason:
      // `climate.set_temperature` on anything else is a command the House
      // never meant, and the entity behind a Device is not the caller's to
      // know.
      Log.warn('hub', 'set_target_refused', {
        'device': deviceId,
        'kind': device?.kind.name,
        'reason': 'not_thermostat',
      });
      return;
    }
    if (!target.isFinite) {
      // jsonEncode throws on NaN/infinity — an uncaught async error one
      // layer down, blamed on the socket. Refused here, where the value is
      // still a value and the line can say so. `'$target'` because a
      // non-finite double is exactly the thing the fields map cannot carry
      // as a number.
      Log.warn('hub', 'set_target_refused', {
        'device': deviceId,
        'kind': device.kind.name,
        'reason': 'not_finite',
        'target': '$target',
      });
      return;
    }
    final entityId = device.entityId;
    if (entityId == null) {
      // toggle_unbound's twin: a setpoint row that does nothing, silently,
      // is the same worst bug to chase on a wall.
      Log.warn('hub', 'set_target_unbound', {'device': deviceId});
      return;
    }
    // The value is a room temperature, not a secret — and without it the
    // debug trail cannot answer "did the Panel command what the wall showed".
    Log.debug('hub', 'set_target',
        {'device': deviceId, 'entity': entityId, 'target': target});
    // Absolute and unconverted — hub_client.dart states why. Single-setpoint
    // only: a thermostat in heat/cool mode. In heat_cool the entity carries
    // no `temperature` attribute, so [_toDeviceState] already reports it
    // unusable and the wall never offers the controls that would call this.
    _send({
      'id': _nextId++,
      'type': 'call_service',
      'domain': 'climate',
      'service': 'set_temperature',
      'service_data': {'temperature': target},
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
    status.dispose();
  }

  void _open() {
    if (_disposed) return;
    // The address alone, and no `path=`/`auth=` beside it: this Uri's path is
    // `/api/websocket`, which the Panel appended itself, so `path=set` here
    // would appear on every Hub and mean nothing. `hub.configured` is the one
    // line that sees the operator's own value and characterises it; this one
    // answers "which Hub is being dialled", which is what tells a stale
    // address from a dead Hub and is `hub.config`'s stated job.
    Log.info('hub', 'connecting', {'url': addressForLog('$_url')});
    try {
      final channel = _connect(_url);
      _channel = channel;
      _subscription = channel.stream.listen(
        _onFrame,
        onError: (Object error) {
          // Through the redaction, because this is the exact shape it was
          // written for one layer up: `dart:io`'s `HttpException` appends
          // `uri = <the whole URL>` to its own message, so
          // `WebSocketChannelException: HttpException: …, uri =
          // http://admin:hunter2@ha.local:8123/api/websocket` was the failure
          // path's copy of the leak the two lines above just lost. Best-effort
          // over a string another library composed — url_redaction.dart says
          // where it stops.
          Log.warn('hub', 'socket_error',
              {'error': redactCredentials('$error')});
          _reconnect();
        },
        onDone: _reconnect,
        cancelOnError: true,
      );
    } on Object catch (error) {
      // Same channel, same treatment: `WebSocketChannel.connect` throws with
      // the Uri in the message too.
      Log.warn('hub', 'connect_failed',
          {'error': redactCredentials('$error')});
      _reconnect();
    }
  }

  void _reconnect() {
    if (_disposed || _retryTimer != null) return;
    final wasConnected = status.value == HubStatus.up;
    status.value = HubStatus.retrying;
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
        status.value = HubStatus.up;
        // Address only, for the reason `hub.connecting` states — and this one
        // is re-emitted on every reconnect, so a flapping Hub multiplied
        // whatever it printed.
        Log.info('hub', 'connected',
            {'url': addressForLog('$_url'), 'devices': _byEntity.length});
        // What unit does this Hub speak, snapshot, then the delta
        // subscription. All three ids are ours; HA echoes them back on the
        // results.
        //
        // The unit goes first so that on a well-behaved Hub it is known
        // before the first reading lands — but nothing here *depends* on
        // that, and it is asked again on every reconnect, because the unit
        // system is a setting the owner can change under us.
        _send({'id': _nextId++, 'type': 'get_config'});
        _send({'id': _nextId++, 'type': 'get_states'});
        _send({
          'id': _nextId++,
          'type': 'subscribe_events',
          'event_type': 'state_changed',
        });
      case 'auth_invalid':
        // A bad token is not worth retrying — it will not fix itself. Stop,
        // and say so where the wall can see it: a rejected token is a
        // different problem from a Hub reboot, and only a human with a new
        // token ends it. Setting _disposed halts the loop — the sink close
        // below fires onDone, and _reconnect returns immediately on it.
        //
        // `reason` is the Hub's own sentence and is **not** redacted, which is
        // a stated residual rather than an omission: a Hub that echoes the
        // rejected token back (`Invalid access token: <the token we sent>`)
        // publishes it here. Nothing this file can do reaches that — the value
        // is not a URL, so `redactCredentials` has no structure to find, and
        // guessing which words in a server's prose were the token is the
        // parameter-name guess that url_redaction.dart just stopped making.
        // It is also the token *we already had*, from a Hub that is refusing
        // it, on a terminal error rather than a healthy boot. `command_failed`
        // below is the same class. Rejected: dropping the field, which leaves
        // a Panel stuck on NEEDS NEW TOKEN with no way to tell a revoked token
        // from a clock skew.
        Log.error('hub', 'auth_invalid', fields: {'reason': message['message']});
        _disposed = true;
        status.value = HubStatus.gaveUp;
        _channel?.sink.close();
      case 'result':
        if (message['success'] == false) {
          // A rejected command would otherwise vanish: the Panel would show
          // the tap doing nothing and give no reason.
          Log.warn('hub', 'command_failed',
              {'id': message['id'], 'error': message['error']});
        }
        final result = message['result'];
        if (result is Map && result['unit_system'] is Map) {
          // The `get_config` answer, recognised by its shape rather than by
          // the id we sent — the same rule the snapshot below follows, and
          // the one thing that lets the two results arrive in either order.
          _adoptUnit((result['unit_system'] as Map)['temperature']);
        }
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
            // The Hub has never heard of these. Typo in bindings.yaml, or
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

  /// The Hub has said which unit its climate readings are in.
  ///
  /// Re-states every thermostat already folded, because the answer can
  /// arrive after the snapshot: those were labelled `null` and are on the
  /// wall as a bare `°`, and the next report that would fix them is
  /// whenever the room next moves — minutes, on a real thermostat. This is
  /// also what makes the send order above an optimisation rather than a
  /// correctness assumption.
  void _adoptUnit(Object? symbol) {
    final unit = TemperatureUnit.fromSymbol(symbol);
    if (unit == null) {
      // Not fatal — the readings still render, unitless, which is the
      // honest thing to show for a unit we cannot name. Worth a line
      // anyway: a wall of bare degrees has no other explanation, and
      // "unitless" is indistinguishable from "the Hub never answered".
      Log.warn('hub', 'temperature_unit_unknown', {'unit': symbol});
      return;
    }
    if (unit == _unit) return;
    Log.info('hub', 'temperature_unit', {'unit': unit.symbol});
    _unit = unit;
    for (final entry in _states.entries.toList()) {
      final state = entry.value;
      if (state is! ThermostatState) continue;
      _states[entry.key] = ThermostatState(entry.key,
          current: state.current, target: state.target, unit: unit);
      if (!_changes.isClosed) _changes.add(entry.key);
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
      final wasKnown = _states.remove(device.id) != null;
      // One line per *entry* into the unusable state. Logging every message
      // would put a permanently-unavailable entity into journald forever.
      if (_unusable.add(device.id)) {
        Log.warn('hub', 'state_unusable', {
          'device': device.id,
          'entity': entity['entity_id'],
          'state': entity['state'],
        });
      }
      // A drop is a change like any other — without this the pin keeps its
      // stale reading until some unrelated Device happens to repaint it.
      // Only when something actually left: a permanently-unavailable entity
      // reports on every message, and those repaints say nothing new.
      if (wasKnown && !_changes.isClosed) _changes.add(device.id);
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
    if (!_changes.isClosed) _changes.add(device.id);
    return true;
  }

  DeviceState? _toDeviceState(Device device, Map<dynamic, dynamic> entity) {
    final raw = entity['state'];
    if (raw is! String || raw == 'unavailable' || raw == 'unknown') return null;
    final attributes = entity['attributes'];
    final attrs = attributes is Map ? attributes : const {};

    // On the family, not the kind: how a reading is *read* follows the
    // shape of the state, and a washer behind a `sensor.*` folds exactly
    // like one behind a vendor integration. Fourteen arms became five, and
    // a new kind of hardware needs no arm here at all.
    switch (specOf(device.kind).family) {
      case StateFamily.toggle:
        return SwitchState(device.id, on: raw == 'on');
      case StateFamily.garageDoor:
        return GarageDoorState(device.id, open: raw == 'on' || raw == 'open');
      case StateFamily.thermostat:
        final current = _number(attrs['current_temperature']);
        final target = _number(attrs['temperature']);
        if (current == null || target == null) return null;
        // Straight through, unconverted, carrying the Hub's own unit.
        //
        // Normalising to Celsius here was the obvious alternative and is
        // rejected on three counts. It buys nothing: HA hands climate
        // temperatures over already converted and the entity never names
        // the unit, so converting needs the same `get_config` lookup this
        // does, plus arithmetic. It has no honest answer while that lookup
        // is outstanding — it would have to assume a source unit, which is
        // precisely the bug being fixed. And it would put `28.3 °C` on the
        // wall beside an Ecobee reading 83 °F, in a house where every other
        // Home Assistant surface is `us_customary`; setting the Hub metric
        // to make the Panel's assumption true is the same disagreement with
        // the owner, moved somewhere harder to see.
        return ThermostatState(device.id,
            current: current, target: target, unit: _unit);
      case StateFamily.power:
        final watts = _number(raw);
        return watts == null ? null : PowerState(device.id, watts: watts);
      case StateFamily.status:
        return StatusState(device.id, raw);
    }
  }

  static double? _number(dynamic value) => switch (value) {
        num n => n.toDouble(),
        String s => double.tryParse(s),
        _ => null,
      };
}
