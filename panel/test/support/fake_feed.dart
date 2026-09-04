import 'package:flutter/widgets.dart';
import 'package:panel/ui/video/stream_director.dart';

/// A [CameraFeed] the test drives by hand: its phase and retry count move
/// when the case says so, and every call across the seam is recorded.
///
/// Shared by the suites that sit ABOVE the Director's seam — the decorator
/// (`timed_feed_test.dart`) and the face (`camera_face_test.dart`) — so the
/// feed is faked in one place, the `support/fake_go2rtc.dart` discipline
/// one seam up.
class FakeFeed implements CameraFeed {
  final calls = <String>[];
  var released = false;

  @override
  final ListenedNotifier<FeedPhase> phase =
      ListenedNotifier(FeedPhase.connecting);

  @override
  String? failure;

  @override
  Widget get view => const SizedBox.shrink();

  @override
  set visible(bool value) => calls.add('visible=$value');

  @override
  final ListenedNotifier<int> retryAttempt = ListenedNotifier(0);

  /// Settable, so a case can stage the Director's verdict either way.
  @override
  var stillGrabAllowed = true;

  @override
  void setMuted(bool muted) => calls.add('setMuted=$muted');

  @override
  void start() => calls.add('start');

  @override
  void release() {
    released = true;
    calls.add('release');
  }
}

/// A notifier that can say whether anyone is listening — `hasListeners` is
/// protected, and a listener nobody removed is exactly what a dispose test
/// pins (`support/fake_health.dart`'s `ProbeNotifier`, the same reason).
class ListenedNotifier<T> extends ValueNotifier<T> {
  ListenedNotifier(super.value);

  bool get listened => hasListeners;
}
