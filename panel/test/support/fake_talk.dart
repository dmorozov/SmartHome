import 'dart:async';

import 'package:panel/ui/audio/talk.dart';

/// A go2rtc talkback endpoint the test drives by hand: [posts] records every
/// URL the Panel called, in order, and the answer to each is the test's to
/// choose.
///
/// A sibling of `fake_go2rtc.dart` and faked at the same seam depth, for the
/// same reason: what the Popup's suites assert is *which calls it made and
/// when* — a START on press, a STOP on release, and one more from `dispose`
/// by every route out — and none of that needs an HTTP stack. The real
/// posters are two files behind a conditional import and neither compiles
/// into every test binary.
///
/// Hand-written because this repo has no mockito and no mocktail.
class FakeTalk {
  /// Every URL posted, in the order go2rtc would have seen them. Order is the
  /// property under test as much as content is: a STOP overtaking the START
  /// it undoes leaves the microphone open with nothing left to close it.
  final posts = <Uri>[];

  /// What the next call answers. `null` is 200; set it to refuse.
  TalkResult? answer;

  /// Held calls, when [holdNext] is on — how a test stages "the START is
  /// still in flight" without a timer.
  final _held = <Completer<TalkResult>>[];

  /// While true, calls do not answer until [releaseHeld]. The press/release
  /// race is only reachable with a call in flight across the release.
  var holdNext = false;

  /// Hand this to `TalkConfig(post: ...)`.
  Future<TalkResult> post(Uri url) {
    posts.add(url);
    final result = answer ?? const TalkResult.ok();
    if (!holdNext) return Future.value(result);
    final held = Completer<TalkResult>();
    _held.add(held);
    return held.future;
  }

  void releaseHeld() {
    for (final held in _held) {
      held.complete(answer ?? const TalkResult.ok());
    }
    _held.clear();
  }

  /// The `src=` of each call: the mic source on a START, empty on a STOP.
  /// What a test means by "it started then stopped", without spelling a whole
  /// URL twice.
  List<String> get sources => [
    for (final p in posts) p.queryParameters['src'] ?? '',
  ];

  /// The `dst=` of each call — the `talk:` stream, never the `stream:` one.
  List<String> get destinations => [
    for (final p in posts) p.queryParameters['dst'] ?? '',
  ];
}
