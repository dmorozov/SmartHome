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

  /// The probe reading a successful dial outranked, per Device — the mark
  /// that keeps [_refresh] from erasing dial evidence on the Hub's next
  /// unrelated push. Cleared the moment the probe folds to anything NEW —
  /// its own unavailability included: silence is the probe speaking too —
  /// or the moment a later dial FAILS ([dialOutcome]); either way the
  /// probe regains its authority without a clock.
  final _dialEvidence = <String, Reachability>{};

  /// The stable-identity contract [CameraHealthSource] states: one
  /// listenable per id, forever — the Director add/removes listeners
  /// against it by identity.
  @override
  ValueListenable<Reachability> reachableOf(String deviceId) =>
      _verdictOf(deviceId);

  ValueNotifier<Reachability> _verdictOf(String deviceId) =>
      _verdicts.putIfAbsent(
          deviceId, () => ValueNotifier(_read(deviceId)));

  /// Dial outcomes fold in as **positive evidence only** (ADR-0013): a dial
  /// that reached playing is frames on the wire — fresher truth than a
  /// once-a-minute port probe, and the stale-`off` window after a Wyze
  /// daemon restart is exactly when a parked tile should recover without
  /// waiting the probe out. A FAILED dial never overrules the probe: a
  /// single failure has too many non-camera causes (a daemon mid-death,
  /// go2rtc restarting, the two-connection contention a recovery storm
  /// invites), and negative authority stays the probe's alone — one bad
  /// dial must never blank a tile the probe still vouches for. What a
  /// failure MAY do is take back the word a success gave — withdraw held
  /// dial evidence, returning the verdict to the probe's own reading.
  ///
  /// Cameras only, like the probe map itself: the doorbell's outcomes are
  /// reported too (the popup role reports every dial) and dropped here —
  /// it was never probed, and its verdict stays [Reachability.unknown].
  @override
  void dialOutcome(String deviceId, {required bool connected}) {
    if (!_devices.containsKey(deviceId)) return;
    if (!connected) {
      // A failure may withdraw OUR OWN evidence — never the probe's
      // verdict. Where a success is on record, a failure says it has gone
      // stale, and the verdict falls back to whatever the probe was
      // already saying; without this, a camera that died again before the
      // probe ever saw it up wears `reachable` forever ('off'→'off' emits
      // nothing to clear it), and the grab loop and the ladder work a
      // dead daemon indefinitely (found in review, 2026-08-28). A failure
      // with no evidence on record stays what it always was: nothing.
      if (_dialEvidence.remove(deviceId) != null) {
        _verdictOf(deviceId).value = _read(deviceId);
      }
      return;
    }
    final probe = _read(deviceId);
    // Remember what the probe was saying only where the success outranks
    // it; evidence that merely agrees with the probe is not evidence worth
    // holding — and holding it would delay a genuine later flip to `off`.
    if (probe != Reachability.reachable) _dialEvidence[deviceId] = probe;
    _verdictOf(deviceId).value = Reachability.reachable;
  }

  void _refresh() {
    for (final entry in _verdicts.entries) {
      final probe = _read(entry.key);
      final outranked = _dialEvidence[entry.key];
      if (outranked != null) {
        // The probe has said nothing new since the dial succeeded — this
        // push is some other entity's traffic, and a reading the success
        // already outranked does not get to re-park the camera.
        if (probe == outranked) continue;
        _dialEvidence.remove(entry.key);
      }
      // ValueNotifier only notifies on a changed value, so this loop is a
      // cheap no-op on the Hub's usual traffic.
      entry.value.value = probe;
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
