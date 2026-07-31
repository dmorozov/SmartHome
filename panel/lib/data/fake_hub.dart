import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/device_state.dart';
import '../domain/house.dart';
import 'hub_client.dart';

/// In-memory Hub for development: seeds plausible state for every Device in
/// the House, answers toggles instantly, and drifts thermostat/power
/// readings so the UI visibly lives. Pass [driftEvery] = [Duration.zero] to
/// disable the drift timer (deterministic tests).
class FakeHub implements HubClient {
  FakeHub(House house, {Duration driftEvery = const Duration(seconds: 3)}) {
    for (final device in house.floors.expand((f) => f.devices)) {
      _states[device.id] = _initialState(device);
    }
    if (driftEvery > Duration.zero) {
      _driftTimer = Timer.periodic(driftEvery, (_) => _drift());
    }
  }

  /// Always up: the fake Hub is in this process.
  @override
  final ValueNotifier<bool> connected = ValueNotifier(true);

  final _states = <String, DeviceState>{};
  final _changes = StreamController<DeviceState>.broadcast();
  final _random = Random(7);
  Timer? _driftTimer;

  @override
  Map<String, DeviceState> get states => Map.unmodifiable(_states);

  @override
  Stream<DeviceState> get stateChanges => _changes.stream;

  @override
  Future<void> toggle(String deviceId) async {
    final next = switch (_states[deviceId]) {
      SwitchState s => SwitchState(deviceId, on: !s.on),
      GarageDoorState g => GarageDoorState(deviceId, open: !g.open),
      _ => null,
    };
    if (next != null) _apply(next);
  }

  @override
  void dispose() {
    _driftTimer?.cancel();
    _changes.close();
    connected.dispose();
  }

  void _apply(DeviceState state) {
    _states[state.deviceId] = state;
    _changes.add(state);
  }

  void _drift() {
    for (final state in _states.values.toList()) {
      switch (state) {
        case ThermostatState t:
          _apply(ThermostatState(
            t.deviceId,
            currentC: t.currentC + (_random.nextDouble() - 0.5) * 0.2,
            targetC: t.targetC,
          ));
        case PowerState p:
          _apply(PowerState(
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
