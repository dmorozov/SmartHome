import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/hub_client.dart';
import '../diagnostics/log.dart';
import '../domain/device_state.dart';
import '../domain/house.dart';
import 'device_presentation.dart';

/// Presentation state: the House structure plus live Device state from the
/// Hub, folded into one Listenable for the widget tree.
class HubController extends ChangeNotifier {
  HubController({required this.house, required HubClient hub}) : _hub = hub {
    _sub = hub.stateChanges.listen((_) => notifyListeners());
    hub.connected.addListener(notifyListeners);
  }

  /// Whether the Panel currently has the Hub.
  bool get connected => _hub.connected.value;

  final House house;
  final HubClient _hub;
  late final StreamSubscription<DeviceState> _sub;

  /// Everything the Dollhouse and the Popup need to render and act on
  /// [device], derived from its kind and current live state.
  DevicePresentation presentationOf(Device device) =>
      DevicePresentation(device, _hub.states[device.id]);

  /// A Room is lit when any light in it is on.
  bool isRoomLit(Room room) => room.devices
      .any((d) => d.kind == DeviceKind.light && presentationOf(d).glows);

  Future<void> toggle(String deviceId) => _hub.toggle(deviceId);

  /// Tapping a Room acts on it: all lights on if none is lit, all off
  /// otherwise.
  Future<void> toggleRoomLights(Room room) async {
    final lit = isRoomLit(room);
    final lights =
        room.devices.where((d) => d.kind == DeviceKind.light).toList();
    Log.debug('ui', 'room_lights',
        {'room': room.id, 'was_lit': lit, 'lights': lights.length});
    for (final light in lights) {
      if (presentationOf(light).glows == lit) await _hub.toggle(light.id);
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _hub.connected.removeListener(notifyListeners);
    _hub.dispose();
    super.dispose();
  }
}
