import 'package:flutter/foundation.dart';

import '../../domain/device_state.dart';
import '../../domain/house.dart';
import '../hub_controller.dart';
import 'stream_director.dart';

/// Camera Health (phase-8, CONTEXT.md), read off the Hub seam the Panel
/// already has: each camera Device's `entity:` is its RTSP daemon probe —
/// `binary_sensor.wyze_*_rtsp`, a once-a-minute TCP connect the Hub runs
/// against the camera's port 322 — and the Hub folds it like any status
/// entity. `on` means the daemon answers; `off` means it died (measured
/// 2026-08-25: four of five dead while pinging fine, which is why this
/// module exists); an absent state means nobody knows.
///
/// Why this is the Hub's probe and not the Panel's: it needs to run whether
/// or not anybody is watching (the uptime history is what the preload-scope
/// and `wyze://` decisions wait on, phase-8 §D), it must work on the web
/// build (no raw sockets in a browser), and the one thing it may never be
/// is a go2rtc `/api/streams` poll — those responses embed producer URLs,
/// credentials included.
///
/// Deliberately three-valued through [Reachability.unknown]: the dev Hub
/// has no probe entities, a fresh boot has no states yet, and a probe
/// entity can itself go unavailable. None of those may cost a picture —
/// the Stream Director gates dials only on an explicit
/// [Reachability.unreachable].
class HubCameraHealth implements CameraHealthSource {
  HubCameraHealth({required this.controller}) {
    for (final floor in controller.house.floors) {
      for (final device in floor.devices) {
        // Cameras only, NOT every video kind: the doorbell's `entity:` is
        // its ding event, not a daemon probe, and a doorbell integration
        // that reported in the binary word shape would read `off` at rest —
        // folding a resting bell into "unreachable" and gating a dial that
        // would have worked (found in review, 2026-08-25). If a second
        // probed kind ever exists, this becomes a KindSpec fact or a
        // `probe:` binding key, not a wider filter here.
        if (device.kind == DeviceKind.camera) _devices[device.id] = device;
      }
    }
    controller.addListener(_refresh);
  }

  final HubController controller;

  final _devices = <String, Device>{};
  final _verdicts = <String, ValueNotifier<Reachability>>{};

  /// The stable-identity contract [CameraHealthSource] states: one
  /// listenable per id, forever — the Director add/removes listeners
  /// against it by identity.
  @override
  ValueListenable<Reachability> reachableOf(String deviceId) =>
      _verdictOf(deviceId);

  ValueNotifier<Reachability> _verdictOf(String deviceId) =>
      _verdicts.putIfAbsent(
          deviceId, () => ValueNotifier(_read(deviceId)));

  /// Dial outcomes are accepted and deliberately dropped for now: the probe
  /// is the primary adapter (it answers *before* a dial, which outcomes by
  /// definition cannot), and folding outcomes in is a later refinement that
  /// needs its own decay rules — a single failed dial during a Wi-Fi blip
  /// must not mark a camera offline for a minute. The sink exists so the
  /// Director's side of the contract is already whole.
  @override
  void dialOutcome(String deviceId, {required bool connected}) {}

  void _refresh() {
    for (final entry in _verdicts.entries) {
      // ValueNotifier only notifies on a changed value, so this loop is a
      // cheap no-op on the Hub's usual traffic.
      entry.value.value = _read(entry.key);
    }
  }

  Reachability _read(String deviceId) {
    final device = _devices[deviceId];
    if (device == null) return Reachability.unknown;
    final state = controller.presentationOf(device).state;
    // Absence is the Hub seam's own vocabulary for unknown/unavailable —
    // including a probe entity that does not exist on this Hub (the dev
    // one), which is exactly the case that may not gate anything.
    if (state is! StatusState) return Reachability.unknown;
    return switch (state.status) {
      'on' => Reachability.reachable,
      'off' => Reachability.unreachable,
      // A stand-in seed ('Live'), or a state some future integration
      // reports in its own words: not a verdict, so not a gate.
      _ => Reachability.unknown,
    };
  }

  /// Tests only — the wall's instance lives as long as the process, like
  /// the pool and the Director it feeds.
  void dispose() => controller.removeListener(_refresh);
}
