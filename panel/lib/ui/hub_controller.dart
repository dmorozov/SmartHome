import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/hub_client.dart';
import '../domain/device_state.dart';
import '../domain/house.dart';

/// Presentation state: the House structure plus live Device state from the
/// Hub, folded into one Listenable for the widget tree.
class HubController extends ChangeNotifier {
  HubController({required this.house, required HubClient hub}) : _hub = hub {
    _sub = hub.stateChanges.listen((_) => notifyListeners());
  }

  final House house;
  final HubClient _hub;
  late final StreamSubscription<DeviceState> _sub;

  DeviceState? stateOf(String deviceId) => _hub.states[deviceId];

  bool isOn(String deviceId) => switch (stateOf(deviceId)) {
        SwitchState s => s.on,
        _ => false,
      };

  /// A Room is lit when any light in it is on.
  bool isRoomLit(Room room) =>
      room.devices.any((d) => d.kind == DeviceKind.light && isOn(d.id));

  Future<void> toggle(String deviceId) => _hub.toggle(deviceId);

  /// Tapping a Room acts on it: all lights on if none is lit, all off
  /// otherwise.
  Future<void> toggleRoomLights(Room room) async {
    final lit = isRoomLit(room);
    for (final light
        in room.devices.where((d) => d.kind == DeviceKind.light)) {
      if (isOn(light.id) == lit) await _hub.toggle(light.id);
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _hub.dispose();
    super.dispose();
  }
}
