// The web half of the video seam, run in a real browser:
//
//   cd panel && flutter test --platform chrome test/live_video_mse_web_test.dart
//
// `@TestOn('browser')` rather than a skip: `live_video_mse.dart` is not
// compiled into a VM build at all — the conditional import in
// `live_video.dart` hands the VM the MJPEG player — so on `flutter test` this
// file is not skipped, it is *absent*, which is the honest state of affairs.
// Its VM-side counterpart is `live_video_mjpeg_test.dart`, which drives the
// appliance player against a real socket.
//
// **What this file deliberately does NOT test, and the measurement that
// settled it.** Phase 4's open item 3 asks for `MseLiveVideoSession.view` to
// be mounted by something automated. It cannot be, here. Measured 2026-08-07
// under `flutter test --platform chrome` (Chrome 151): mounting an
// `HtmlElementView.fromTagName` in a `testWidgets` pump never fires
// `onElementCreated` — the platform-view registry is stubbed in the test
// harness, so no DOM element is created and nothing is re-parented. A test
// asserting the view here would pass while exercising none of it, which is
// worse than no test.
//
// So the `view`/`_resume` path stays browser-driven, and the procedure that
// *did* find its two bugs is written down instead: panel/README.md, "The web
// build must not need the internet" has the Playwright shape, and
// `live_video_mse.dart`'s class docstring records what was driven on
// 2026-08-06 and what it found. What this file guards is everything up to
// that boundary — the part that is reachable without a platform view, and
// that had no automated coverage on any machine before today.
@TestOn('browser')
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_mse.dart' show MseLiveVideoSession;

void main() {
  test('this build says it can play video, because it can', () {
    // The seam's constant, asserted on the branch that answers true. A future
    // third branch answering false is what this exists to catch.
    expect(liveVideoIsAvailable, isTrue);
  });

  test('a URL no WebSocket will accept is a settled failure, not a throw', () {
    // `openLiveVideo`'s stated contract: "An implementation may not throw",
    // because the caller is a `State.initState` and a throw out of it costs
    // the whole Dialog — the Device name and the Close button with it. On web
    // the constructor really does raise, and only the web branch can be made
    // to, so only here can the promise be checked.
    //
    // A **fragment** is the trigger, and picking it took a measurement. The
    // obvious candidate — a wrong scheme — does not throw: the WebSocket spec
    // rewrites `http:`->`ws:` and `https:`->`wss:` before it validates, so
    // `https://…` is a legal argument that merely fails to connect later
    // (measured 2026-08-07: phase stayed `connecting`). A fragment is refused
    // outright, by that same step of the spec.
    late final LiveVideoSession session;
    expect(
        () => session = openLiveVideo(Uri.parse('wss://example.invalid/ws#f'),
            name: 'porch'),
        returnsNormally);
    expect(session.phase.value, LiveVideoPhase.failed);
    expect(session.view, isA<Widget>());
    session.close();
  });

  test('the failure text for a refused URL names a type, never the URL',
      () {
    // `diagnostics/log.dart`: **Never log a secret**. A `SyntaxError` quotes
    // the URL it refused, and that URL is the one string here a fat-fingered
    // GO2RTC_URL can have put a password into. The host below is the canary:
    // if it ever appears in `failure`, the quoting came back.
    final session = openLiveVideo(
        Uri.parse('wss://user:hunter2@example.invalid/api/ws#frag'),
        name: 'porch');
    addTearDown(session.close);

    expect(session.phase.value, LiveVideoPhase.failed);
    expect(session.failure, isNotNull);
    expect(session.failure, isNot(contains('hunter2')));
    expect(session.failure, isNot(contains('example.invalid')));
  });

  test('a socket that will not connect ends as failed, and says nothing about '
      'where it dialled', () async {
    // Port 9 is discard; nothing listens, so the browser answers the
    // connection attempt with an `error` event. That is the path
    // `_onSocketError` covers, and its message is deliberately contentless —
    // the browser withholds *why* a WebSocket failed, so there is nothing to
    // quote even if it were safe to.
    final session = MseLiveVideoSession(
      Uri.parse('ws://127.0.0.1:9/api/ws?src=porch'),
      openTimeout: const Duration(seconds: 5),
      decodeTimeout: const Duration(seconds: 5),
      stallTimeout: const Duration(seconds: 5),
    );
    addTearDown(session.close);

    // Starts honest: nothing has arrived, so nothing is claimed.
    expect(session.phase.value, LiveVideoPhase.connecting);

    for (var i = 0; i < 100; i++) {
      if (session.phase.value != LiveVideoPhase.connecting) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(session.phase.value, LiveVideoPhase.failed,
        reason: 'a refused socket must not sit on `connecting` forever — the '
            'watchdog is the only thing that ends a session go2rtc abandoned');
    expect(session.failure, isNot(contains('127.0.0.1')));
  });

  test('closing is idempotent, because the Popup has four ways out', () {
    final session = MseLiveVideoSession(Uri.parse('ws://127.0.0.1:9/'));
    session.close();
    expect(session.close, returnsNormally);
  });
}
