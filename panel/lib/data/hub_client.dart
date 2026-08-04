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

  void dispose();
}
