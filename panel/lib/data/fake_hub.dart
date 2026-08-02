import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';
import '../domain/device_state.dart';
import '../domain/device_traits.dart';
import '../domain/house.dart';
import 'hub_client.dart';

/// In-memory Hub for development: seeds plausible state for every Device in
/// the House, answers toggles instantly, and drifts thermostat/power
/// readings so the UI visibly lives. Pass [driftEvery] = [Duration.zero] to
/// disable the drift timer (deterministic tests).
///
/// Past [HubClient] it exposes a driving surface — [pushState],
/// [dropDevice], [setStatus] — so a test can stage any scene the wall
/// might show (a Hub outage, a rejected token, a Device dropping to
/// unknown, a reading arriving) without hand-rolling another adapter.
/// Seeding and drift are simply the two scripts that ship with it.
class FakeHub implements HubClient {
  FakeHub(House house, {Duration driftEvery = const Duration(seconds: 3)}) {
    for (final device in house.floors.expand((f) => f.devices)) {
      _byId[device.id] = device;
      pushState(_initialState(device));
    }
    if (driftEvery > Duration.zero) {
      _driftTimer = Timer.periodic(driftEvery, (_) => _drift());
    }
    // Says plainly which Hub the running build is on — the header badge can
    // be missed, a log line cannot.
    Log.info('hub', 'fake_ready',
        {'devices': _states.length, 'drift_ms': driftEvery.inMilliseconds});
  }

  /// In this process, so up unless a test says otherwise ([setStatus]).
  @override
  final ValueNotifier<HubStatus> status = ValueNotifier(HubStatus.up);

  final _byId = <String, Device>{};
  final _states = <String, DeviceState>{};
  final _changes = StreamController<String>.broadcast();
  final _random = Random(7);
  Timer? _driftTimer;

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
      Log.warn('hub', 'toggle_refused',
          {'device': deviceId, 'kind': device?.kind.name});
      return;
    }
    pushState(switch (_states[deviceId]) {
      SwitchState s => SwitchState(deviceId, on: !s.on),
      GarageDoorState g => GarageDoorState(deviceId, open: !g.open),
      // Unknown state (or one of the wrong shape): the real Hub knows the
      // Device even when the Panel's knowledge has lapsed, so model the
      // command landing — from off, the only starting point a tap can assume.
      _ => device.kind == DeviceKind.garageDoor
          ? GarageDoorState(deviceId, open: true)
          : SwitchState(deviceId, on: true),
    });
  }

  @override
  void dispose() {
    _driftTimer?.cancel();
    _changes.close();
    status.dispose();
  }

  // ── Driving surface: how a test (or a built-in script) moves the world ──

  /// The world reports [state]: applied to [states], its Device id emitted
  /// on [stateChanges]. Accepts any Device id — the fake never validates
  /// against the House, so a test can stage whatever it needs.
  void pushState(DeviceState state) {
    _states[state.deviceId] = state;
    _changes.add(state.deviceId);
  }

  /// The world loses a Device: removed from [states] (dropped back to
  /// unknown), its id emitted on [stateChanges]. No-op if already unknown.
  void dropDevice(String deviceId) {
    if (_states.remove(deviceId) != null) _changes.add(deviceId);
  }

  /// The world drops, returns, or permanently refuses the Panel — the whole
  /// story the badge tells, including the token no amount of waiting fixes.
  void setStatus(HubStatus value) => status.value = value;

  void _drift() {
    for (final state in _states.values.toList()) {
      switch (state) {
        case ThermostatState t:
          pushState(ThermostatState(
            t.deviceId,
            currentC: t.currentC + (_random.nextDouble() - 0.5) * 0.2,
            targetC: t.targetC,
          ));
        case PowerState p:
          pushState(PowerState(
            p.deviceId,
            watts: max(0, p.watts * (0.9 + _random.nextDouble() * 0.2)),
          ));
        case _:
          break;
      }
    }
  }

  DeviceState _initialState(Device device) => switch (device.kind) {
        DeviceKind.light => SwitchState(device.id, on: _random.nextBool()),
        DeviceKind.outlet => SwitchState(device.id, on: true),
        DeviceKind.tv => SwitchState(device.id, on: false),
        DeviceKind.garageDoor => GarageDoorState(device.id, open: false),
        DeviceKind.thermostat =>
          ThermostatState(device.id, currentC: 21.4, targetC: 21.0),
        DeviceKind.energyMonitor => PowerState(device.id, watts: 812),
        DeviceKind.evCharger => PowerState(device.id, watts: 0),
        DeviceKind.washer => StatusState(device.id, 'Idle'),
        DeviceKind.dryer => StatusState(device.id, 'Cycle · 32 min left'),
        DeviceKind.oven => StatusState(device.id, 'Off'),
        DeviceKind.litterRobot =>
          StatusState(device.id, 'Clean · cycled 2 h ago'),
        DeviceKind.feeder => StatusState(device.id, 'Next meal 5:00 pm'),
        DeviceKind.camera || DeviceKind.doorbell =>
          StatusState(device.id, 'Live'),
      };
}
