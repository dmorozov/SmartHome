import '../domain/device_state.dart';

/// The Panel's window onto the Hub. The production implementation talks to
/// the Home Assistant WebSocket API; the fake hub serves development.
abstract interface class HubClient {
  /// Current state of every known Device, keyed by Device id. A Device
  /// absent from the map has unknown state.
  Map<String, DeviceState> get states;

  /// Emits each state change after it has been applied to [states].
  Stream<DeviceState> get stateChanges;

  /// Flip a Device that has a binary state (light, outlet, TV, garage
  /// door). No-op for anything else.
  Future<void> toggle(String deviceId);

  void dispose();
}
