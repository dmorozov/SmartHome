import 'package:flutter/foundation.dart';

import '../domain/device_state.dart';

/// How the Panel's link to the Hub stands.
///
/// A wall display has nobody watching a console, so "my readings are stale"
/// has to be visible — and so does whether waiting will fix it. Those are
/// different problems with different remedies, which is why this is not a
/// bool: [retrying] resolves itself, [gaveUp] never does.
enum HubStatus {
  /// Socket open, authenticated, subscribed: the readings are live.
  up,

  /// The Hub is unreachable and the client is backing off and retrying on
  /// its own, forever — also the state before the first connection ever
  /// succeeds. Waiting fixes it.
  retrying,

  /// The Hub rejected the token. Retrying cannot fix that, so the client
  /// has stopped: a human must mint a new long-lived token and restart the
  /// Panel with it (`HA_TOKEN` in the environment; `--dart-define=HA_TOKEN`
  /// for web builds, which have no environment — see hub/dev/README.md).
  gaveUp,
}

/// The Panel's window onto the Hub. The production implementation talks to
/// the Home Assistant WebSocket API; the fake hub serves development and,
/// scripted, the widget and golden tests.
abstract interface class HubClient {
  /// The link to the Hub, live. Never throws to report a link failure —
  /// every way the link can fail is one of these three values, because a
  /// wall display's only way to report anything is to render it.
  ValueListenable<HubStatus> get status;

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

  /// Command a thermostat's target temperature to the absolute value
  /// [target], **in whatever unit the Hub speaks**. The Panel never
  /// converts: the value a caller passes is stepped from a reading the Hub
  /// itself denominated ([ThermostatState.target]), and it travels back
  /// unconverted — so the command is unit-correct even while
  /// [ThermostatState.unit] is still null.
  ///
  /// Refuses — observably, with one `hub.set_target_refused` warn line,
  /// touching neither [states] nor the Hub — any Device that is not a
  /// thermostat, any id the House does not contain, and a non-finite
  /// [target] (which `jsonEncode` would throw on, one layer too late to be
  /// anyone's fault but ours).
  ///
  /// Deliberately no Panel-side min/max clamp: the Hub owns the thermostat's
  /// range, and a bound restated here is a bound that drifts. An
  /// out-of-range value is the Hub's to reject; the rejection is observable
  /// as `hub.command_failed`, and as the wall's dialled value reverting to
  /// the live one (see ThermostatControls).
  Future<void> setThermostatTarget(String deviceId, double target);

  void dispose();
}
