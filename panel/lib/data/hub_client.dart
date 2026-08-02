import 'package:flutter/foundation.dart';

import '../domain/device_state.dart';

/// The Panel's window onto the Hub. The production implementation talks to
/// the Home Assistant WebSocket API; the fake hub serves development and,
/// scripted, the widget and golden tests.
abstract interface class HubClient {
  /// Whether the Panel currently has the Hub. A wall display has nobody
  /// watching a console, so "my readings are stale" has to be visible.
  ValueListenable<bool> get connected;

  /// Current state of every known Device, keyed by Device id. A Device
  /// absent from the map has unknown state.
  Map<String, DeviceState> get states;

  /// Emits the id of each Device whose entry in [states] just changed —
  /// including a drop to unknown, where the id is no longer in the map.
  /// Emitted after [states] already reflects the change.
  Stream<String> get stateChanges;

  /// Whether [toggle] would act on this Device: true exactly for Device
  /// kinds that declare `DeviceKind.toggles`, false for an id the House does
  /// not contain. Answered from the House, never from live state — a light
  /// whose state is unknown still toggles.
  bool togglable(String deviceId);

  /// Flip a Device with a binary state. Refuses — observably, with one
  /// `hub.toggle_refused` warn line, touching neither [states] nor the Hub —
  /// any Device for which [togglable] is false. Nothing else protects the
  /// thermostat: the Hub's own toggle service would flip the real HVAC.
  Future<void> toggle(String deviceId);

  void dispose();
}
