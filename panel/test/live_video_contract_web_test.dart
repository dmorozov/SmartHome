// The web half of the video seam, held to the same contract as every other
// adapter:
//
//   cd panel && flutter test --platform chrome test/live_video_contract_web_test.dart
//
// `@TestOn('browser')` rather than a skip, for `live_video_mse_web_test.dart`'s
// reason: `live_video_mse.dart` is not compiled into a VM build at all — the
// conditional import in `live_video.dart` hands the VM the MJPEG player — so
// under plain `flutter test` this file is not skipped, it is *absent*.
//
// **This does not run in the devcontainer today.** `flutter test --platform
// chrome` hangs at "loading …" here; it passed 237 cases on Chrome 151 on
// 2026-08-07, and `hub/dev/go2rtc/DEBUGGING.md` records repairing the runner
// as worth more than any individual patch. So the MSE column of the contract
// is written and unexecuted, which is a gap — named here rather than papered
// over, because the alternative is a suite that claims six adapters and
// proves five.
//
// **What the browser world can and cannot stage.** Without a go2rtc to talk
// to, this world cannot reach `playing`: a MediaSource needs real fMP4
// segments, and inventing them here would test the fixture. So the MSE world
// declares `reachPlaying: null`, which leaves the picture-half of cases 2,
// 3 and 6 unstaged; all six cases still execute. Reaching playing on this
// transport stays a browser-driven procedure (`panel/README.md`, the
// Playwright shape) — the one that actually found the two 2026-08-06 bugs.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_mse.dart' show MseLiveVideoSession;

import 'support/session_world.dart';

void main() {
  runSessionContract('MseLiveVideoSession', _mseWorld,
      // The one adapter that walks from a live phase into a settled one: it
      // dials its socket before `sourceopen` tells it the browser decodes
      // none of go2rtc's codecs. The interface names the exception.
      settlesUnsupportedFromLive: true);
}

/// The web player, dialling a socket nothing will answer.
///
/// Port 9 is discard: nothing listens, so the browser answers the connection
/// attempt with an `error` event — the path `_onSocketError` covers, and the
/// only failure reachable without a server.
Future<SessionWorld> _mseWorld() async {
  MseLiveVideoSession? session;
  return (
    open: () async => session = MseLiveVideoSession(
      Uri.parse('ws://127.0.0.1:9/api/ws?src=porch'),
      openTimeout: const Duration(seconds: 5),
      decodeTimeout: const Duration(seconds: 5),
      stallTimeout: const Duration(seconds: 5),
    ),
    reachPlaying: null,
    // Already in flight: the constructor dialled port 9 and armed the open
    // watchdog, so a refusal is coming whichever path wins. The contract's
    // own wait is what meets it.
    fail: () async {},
    // The socket is the browser's; the session's own witness of having let
    // go is its phase, which the contract reads directly.
    connectionOpen: null,
    // Born muted is what the `<video>` autoplay policy requires, and the
    // element is the player's own — not reachable from here without the
    // platform view the harness does not create.
    muted: null,
    // The one opener on this branch that really does raise: a URL with a
    // fragment is refused outright by the WebSocket constructor, where a
    // wrong scheme is silently rewritten (measured 2026-08-07).
    openBroken: () =>
        openLiveVideo(Uri.parse('wss://example.invalid/ws#f'), name: 'porch'),
    // `_onSocketError` says the browser could not reach go2rtc and the
    // watchdog says go2rtc sent no picture — neither quotes the URL, and
    // this is the canary for the day one of them starts to (the same string
    // `live_video_mse_web_test.dart` measures).
    forbiddenInFailure: const <String>['127.0.0.1'],
    dispose: () async => session?.close(),
  );
}
