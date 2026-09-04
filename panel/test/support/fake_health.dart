import 'package:flutter/foundation.dart';
import 'package:panel/ui/video/stream_director.dart';

/// Camera Health as the Director assumes it: a listenable verdict per
/// Device, and a sink recording what the Director reported back.
///
/// In `support/` rather than beside the Director's suite because more than
/// one suite stages health: the Director's (gating, recovery, listener
/// hygiene, and the still-grab verdict `CameraFeed.stillGrabAllowed` reads
/// live), the Cameras view's (the tile's still loop declines through that
/// verdict), and the Dollhouse's (a pin's Popup outcome landing in the
/// Panel's Camera Health — the outcome sink, proving the Popup rides the
/// Panel's Director).
class FakeHealth implements CameraHealthSource {
  final _verdicts = <String, ProbeNotifier>{};
  final outcomes = <(String, bool)>[];

  ProbeNotifier of(String id) =>
      _verdicts.putIfAbsent(id, () => ProbeNotifier(Reachability.unknown));

  @override
  ValueListenable<Reachability> reachableOf(String deviceId) => of(deviceId);

  @override
  void dialOutcome(String deviceId, {required bool connected}) =>
      outcomes.add((deviceId, connected));
}

/// A verdict notifier that can say whether anyone is listening —
/// `hasListeners` is protected, and the leak the Director's suite pins is
/// exactly a listener nobody could remove.
class ProbeNotifier extends ValueNotifier<Reachability> {
  ProbeNotifier(super.value);

  bool get listened => hasListeners;
}
