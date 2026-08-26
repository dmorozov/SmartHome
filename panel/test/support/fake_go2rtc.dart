import 'package:flutter/widgets.dart';
import 'package:panel/ui/video/live_video.dart';

/// A go2rtc the test drives by hand: [opened] records every session the
/// Panel asked for, and each session's phase is moved by the test rather
/// than by a socket.
///
/// Shared by every suite that has an opinion about when a stream is opened
/// and closed — the Popup's own tests and the Dollhouse's — so the seam is
/// faked in one place rather than re-typed per file, exactly like
/// `support/fake_channel.dart` for the Hub's wire protocol.
///
/// Still a fake now that both branches of the seam carry a real player
/// (MJPEG on the appliance, MSE on web). The real ones are proved against a
/// real socket in `live_video_mjpeg_test.dart`; what the Popup's suites need
/// is a session whose phase moves when the *test* says so, because what they
/// assert is the Popup's lifecycle — one session per Popup, closed by every
/// route out — and a player that took 2.1 s to reach `playing` would make
/// every one of those cases a race.
///
/// Hand-written because this repo has no mockito and no mocktail; every
/// fake here is written out.
class FakeGo2rtc {
  final opened = <FakeLiveVideoSession>[];

  /// Hand this to `VideoConfig(open: ...)`.
  LiveVideoSession open(Uri url, {required String name}) {
    final session = FakeLiveVideoSession(url, name);
    opened.add(session);
    return session;
  }

  FakeLiveVideoSession get only => opened.single;
}

class FakeLiveVideoSession implements LiveVideoSession {
  FakeLiveVideoSession(this.url, this.name);

  final Uri url;
  final String name;

  /// How many times [close] was called. A count, not a bool: "closed once,
  /// by every route out" is the property the Popup owes go2rtc, and a bool
  /// cannot tell a double-close from a clean one.
  var closes = 0;

  /// The seam's born-muted default, and the history of every [setMuted]
  /// call — the ORDER is what the duck test reads (unmute on open, mute on
  /// press, unmute on release).
  var muted = true;
  final mutedChanges = <bool>[];

  @override
  final ValueNotifier<LiveVideoPhase> phase =
      ValueNotifier(LiveVideoPhase.connecting);

  @override
  String? failure;

  @override
  Widget get view => const Text('a moving picture');

  @override
  void setMuted(bool value) {
    muted = value;
    mutedChanges.add(value);
  }

  @override
  void close() => closes++;

  /// What the MSE player does when go2rtc's first text frame is an error, and
  /// what the MJPEG one does when go2rtc answers 404 or goes quiet.
  void fails(String reason) {
    failure = reason;
    phase.value = LiveVideoPhase.failed;
  }

  void plays() => phase.value = LiveVideoPhase.playing;
}
