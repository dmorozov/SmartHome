import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_keepalive.dart';

import 'support/fake_go2rtc.dart';

/// The keep-alive: what happens to a go2rtc session between one consumer
/// letting go and the next one asking for the same stream.
///
/// Issue #1. Tapping the doorbell pin three times gave a good picture, then
/// half a green frame, then nothing at all for 2 m 22 s; three plain
/// `ffmpeg -frames:v 1` pulls a second apart, with no Panel in the loop, all
/// decoded corrupt frames. So the corruption was in the elementary stream, not
/// in either player. **Measured**: the correlation with the reconnect gap —
/// 1.0-1.1 s between teardown and relaunch lost every time, ~40 s came back
/// half corrupt, minutes came back clean. **Inferred**, and filed by the issue
/// under "Mechanism hypothesis": that the cause is a mid-GOP join on a WebRTC
/// stream with no later keyframe to heal with.
///
/// The fix is sized on the measurement, not the hypothesis: the thing to stop
/// doing is relaunching. Every property below is about one question — was the
/// producer still running when the reopen arrived — and none of them is about
/// picture quality, which the Panel cannot judge and does not try to (a corrupt
/// frame is a delivered frame; see the issue's note that the Panel "painted
/// what arrived").
///
/// Driven through [FakeGo2rtc] rather than a real player: what is under test is
/// the pooling, and both real players are proved elsewhere (the MJPEG one
/// against a real socket in `live_video_mjpeg_test.dart`). `fakeAsync` because
/// every deadline here is minutes long and a suite that slept them would take
/// longer than the Panel's boot.
void main() {
  final doorbell = Uri.parse('ws://hub:1984/api/ws?src=ring_doorbell');
  final garage = Uri.parse('ws://hub:1984/api/ws?src=garage');

  /// The rig, torn down the way the test always wants it: no kept session
  /// and no pending Timer outliving the `fakeAsync` zone.
  void withKeepAlive(
    void Function(FakeAsync async, FakeGo2rtc go2rtc, LiveVideoKeepAlive keep)
        body, {
    Duration linger = kLiveVideoLinger,
    Duration maxHeld = kLiveVideoMaxHeld,
  }) {
    fakeAsync((async) {
      final go2rtc = FakeGo2rtc();
      final keep = LiveVideoKeepAlive(
          opener: go2rtc.open, linger: linger, maxHeld: maxHeld);
      try {
        body(async, go2rtc, keep);
      } finally {
        keep.dispose();
      }
    });
  }

  group('the grace window', () {
    test('a lingered session is SILENT — the pool re-mutes what the closing '
        'surface unmuted, so sound cannot outlive a Popup', () {
      withKeepAlive((async, go2rtc, keep) {
        final lease = keep.open(doorbell, name: 'ring_doorbell');
        go2rtc.only.plays();
        // The Popup, being the person-opened surface, turned the sound on.
        lease.setMuted(false);
        expect(go2rtc.only.muted, isFalse);

        lease.close();
        expect(go2rtc.only.closes, 0,
            reason: 'kept for the linger — which is exactly why the mute '
                'must not wait for the real close');
        expect(go2rtc.only.muted, isTrue);
      });
    });

    test('a reopen inside it re-attaches to the producer that is already '
        'running, instead of racing a new one', () {
      withKeepAlive((async, go2rtc, keep) {
        final first = keep.open(doorbell, name: 'ring_doorbell');
        go2rtc.only.plays();
        first.close();

        // The measured losing gap from the issue: teardown to relaunch in
        // 1.1 s. Nothing is relaunched here.
        async.elapse(const Duration(milliseconds: 1100));
        final second = keep.open(doorbell, name: 'ring_doorbell');

        expect(go2rtc.opened, hasLength(1),
            reason: 'a second dial is the race this exists to avoid');
        expect(go2rtc.only.closes, 0);
        // And the reopen starts where the first one left off: playing, with a
        // picture already on the wire. That is the whole product effect —
        // no spin-up, no mid-GOP join, no green half-frame.
        expect(second.phase.value, LiveVideoPhase.playing);
      });
    });

    test('a session still connecting is kept too: the producer it started is '
        'the thing worth keeping, not the picture it has not sent yet', () {
      withKeepAlive((async, go2rtc, keep) {
        // The issue's worst cases are exactly here. go2rtc's on-demand
        // transcode is itself a consumer and finishes spinning up regardless
        // (see `LiveVideoSession.close`), so a Popup dismissed after a second
        // has already paid for a producer nobody is now waiting for.
        final first = keep.open(doorbell, name: 'ring_doorbell');
        expect(first.phase.value, LiveVideoPhase.connecting);
        first.close();
        async.elapse(const Duration(seconds: 1));

        keep.open(doorbell, name: 'ring_doorbell');

        expect(go2rtc.opened, hasLength(1));
        expect(go2rtc.only.closes, 0);
      });
    });

    test('nobody comes back: the window expires and the stream is really '
        'closed', () {
      withKeepAlive((async, go2rtc, keep) {
        keep.open(doorbell, name: 'ring_doorbell').close();
        expect(go2rtc.only.closes, 0, reason: 'kept, not closed');

        async.elapse(kLiveVideoLinger + const Duration(seconds: 1));

        // #177014: a held Ring session suppresses the next real ding, so
        // "held for a while" has to become "let go" without anyone asking.
        expect(go2rtc.only.closes, 1);
      });
    });

    test('a reopen after the window dials again, because there is nothing '
        'left to re-attach to', () {
      withKeepAlive((async, go2rtc, keep) {
        keep.open(doorbell, name: 'ring_doorbell').close();
        async.elapse(kLiveVideoLinger + const Duration(seconds: 1));

        keep.open(doorbell, name: 'ring_doorbell');

        expect(go2rtc.opened, hasLength(2));
      });
    });

    test('the window is shorter than the deadline an *attended* doorbell '
        'Popup gets', () {
      // Not arithmetic for its own sake: this is the whole #177014 argument.
      // A kept session is a Ring session with nobody watching it, so it may
      // not be allowed to live longer than one somebody *is* watching —
      // `kDoorbellPopupDeadline`, 30 s, in `ui/doorbell_popup_host.dart`.
      // Named there and only compared here: the video layer must not import
      // the Popup's, and a keep-alive that silently outgrew that deadline
      // would be invisible until a doorbell went deaf.
      expect(kLiveVideoLinger, lessThan(const Duration(seconds: 30)));
    });
  });

  group('what is not worth keeping', () {
    test('a session that failed is closed on the spot: re-attaching to it '
        'would hand the next Popup a stream that is already dead', () {
      withKeepAlive((async, go2rtc, keep) {
        final session = keep.open(doorbell, name: 'ring_doorbell');
        go2rtc.only.fails('go2rtc refused: mse: stream not found');
        session.close();

        expect(go2rtc.only.closes, 1);

        keep.open(doorbell, name: 'ring_doorbell');
        expect(go2rtc.opened, hasLength(2));
      });
    });

    test('a session that fails *while* kept is dropped, not handed to the '
        'next opener', () {
      withKeepAlive((async, go2rtc, keep) {
        keep.open(doorbell, name: 'ring_doorbell').close();
        // Both real players can fail with nobody listening: the MJPEG one on
        // `onDone`, the MSE one on a close frame, and both have watchdogs
        // running that keeping a session does not stop.
        go2rtc.only.fails('go2rtc ended the stream');
        async.elapse(const Duration(milliseconds: 1));

        keep.open(doorbell, name: 'ring_doorbell');

        expect(go2rtc.opened, hasLength(2));
        expect(go2rtc.opened.first.closes, 1);
      });
    });

    test('a build with no player keeps nothing: an unsupported session never '
        'dialled, so there is no producer to hold', () {
      fakeAsync((async) {
        var dials = 0;
        final keep = LiveVideoKeepAlive(opener: (url, {required name}) {
          dials++;
          return SettledLiveVideoSession(LiveVideoPhase.unsupported);
        });
        keep.open(doorbell, name: 'ring_doorbell').close();
        keep.open(doorbell, name: 'ring_doorbell').close();

        // Twice, not once: pooling a session that answers `unsupported`
        // without touching the network would turn `cameras.popup_unsupported`
        // into a line that appears for the first Popup and never again.
        expect(dials, 2);
        keep.dispose();
      });
    });
  });

  group('the age cap', () {
    test('no session is re-attached to past it, however often it is '
        'reopened', () {
      withKeepAlive((async, go2rtc, keep) {
        var session = keep.open(doorbell, name: 'ring_doorbell');
        go2rtc.opened.first.plays();

        // The Popup's own cadence, sped up: let go, come straight back. Six
        // seconds a round, thirty rounds — three minutes, comfortably past
        // the two-minute cap, so the chain has to break somewhere in the
        // middle rather than at the last step.
        for (var i = 0; i < 30; i++) {
          session.close();
          async.elapse(const Duration(seconds: 1));
          session = keep.open(doorbell, name: 'ring_doorbell');
          async.elapse(const Duration(seconds: 5));
        }
        session.close();

        // The chain broke: one session did not serve three minutes of
        // reopens, which is the guarantee the cap is for.
        expect(go2rtc.opened.length, greaterThan(1));
        expect(go2rtc.opened.first.closes, 1);
      });
    });

    test('the honest worst case: a reopen landing just under the cap still '
        'runs its consumer\'s own full lifetime on top of it', () {
      withKeepAlive((async, go2rtc, keep) {
        // The number an earlier draft of `kLiveVideoMaxHeld` got wrong. It
        // claimed "no Ring session is ever older than two minutes"; it cannot,
        // because a consumer is never interrupted (closing the player under a
        // live one leaves `playing` over an empty box, which is the stale
        // picture ADR-0007 forbids). Pinned here so the trade cannot drift
        // without somebody having to edit this number and notice.
        var session = keep.open(doorbell, name: 'ring_doorbell');
        go2rtc.only.plays();

        // Carrying one session up to the cap takes a *chain* — each reopen
        // has to land inside the 20 s window, or the session is dropped and
        // the next one dials fresh. Eleven rounds ten seconds apart: t=110 s.
        for (var i = 0; i < 11; i++) {
          session.close();
          async.elapse(const Duration(seconds: 5));
          session = keep.open(doorbell, name: 'ring_doorbell');
          async.elapse(const Duration(seconds: 5));
        }
        expect(go2rtc.opened, hasLength(1), reason: 'one producer so far');

        // The last reopen lands at t=115 s, five seconds under the cap, so it
        // re-attaches...
        session.close();
        async.elapse(const Duration(seconds: 5));
        session = keep.open(doorbell, name: 'ring_doorbell');
        expect(go2rtc.opened, hasLength(1), reason: 're-attached, not dialled');

        // ...and then holds it for as long as *it* is entitled to. For a
        // doorbell Popup that is `kDoorbellPopupCeiling`, another two minutes.
        // The cap fires at t=120 s and does nothing, because somebody is
        // watching.
        async.elapse(const Duration(minutes: 2));
        expect(go2rtc.only.closes, 0,
            reason: 'still watched, so still not interrupted');

        session.close();
        expect(go2rtc.only.closes, 1);
        // Total: one Ring session, ~3 m 55 s old. Not 2 minutes. Stated in
        // `kLiveVideoMaxHeld`, and the Cameras tile's five-minute idle return
        // makes the same sum 7.
      });
    });

    test('it never takes a picture off the screen: a session somebody is '
        'watching outlives it and is closed when its consumer lets go', () {
      withKeepAlive((async, go2rtc, keep) {
        final session = keep.open(doorbell, name: 'ring_doorbell');
        go2rtc.only.plays();

        // The Cameras view holds a tile live for up to `kCamerasIdleReturn`
        // — five minutes — on purpose. A cap that closed the session under it
        // would blank a camera somebody chose to watch, which is a worse lie
        // than the one this whole fix is about.
        async.elapse(kLiveVideoMaxHeld + const Duration(seconds: 30));
        expect(go2rtc.only.closes, 0);
        expect(session.phase.value, LiveVideoPhase.playing);

        // And when they do let go it is closed rather than kept: it is
        // already older than anything may be reused.
        session.close();
        expect(go2rtc.only.closes, 1);
      });
    });
  });

  group('one stream, one consumer at a time', () {
    test('two Popups open on one stream at once are two sessions: a running '
        'stream is lent, not shared', () {
      withKeepAlive((async, go2rtc, keep) {
        // Reachable: `device_popup.dart` keeps a *list* per Device, because
        // two Popups for one Device are a stack. Handing both the same
        // session would mean the first to close took the picture away from
        // the one still on screen.
        final first = keep.open(doorbell, name: 'ring_doorbell');
        final second = keep.open(doorbell, name: 'ring_doorbell');

        expect(go2rtc.opened, hasLength(2));

        first.close();
        expect(go2rtc.opened[1].closes, 0,
            reason: "the other consumer's session is untouched");
        expect(second.phase.value, isNot(LiveVideoPhase.failed));
      });
    });

    test('a consumer that closes twice closes once', () {
      withKeepAlive((async, go2rtc, keep) {
        // The Popup can be dismissed by three routes and the deadline can
        // fire during the fourth — the same idempotence both real players
        // promise, which a wrapper must not lose.
        final session = keep.open(doorbell, name: 'ring_doorbell');
        session.close();
        session.close();
        async.elapse(kLiveVideoLinger + const Duration(seconds: 1));

        expect(go2rtc.only.closes, 1);
      });
    });

    test('a stale close from a consumer that already let go does not evict '
        'the one now holding the stream', () {
      withKeepAlive((async, go2rtc, keep) {
        final first = keep.open(doorbell, name: 'ring_doorbell');
        first.close();
        final second = keep.open(doorbell, name: 'ring_doorbell');

        first.close();

        expect(go2rtc.only.closes, 0);
        second.close();
        async.elapse(kLiveVideoLinger + const Duration(seconds: 1));
        expect(go2rtc.only.closes, 1);
      });
    });

    test('streams are kept apart: reopening the doorbell does not hand back '
        "the garage's picture", () {
      withKeepAlive((async, go2rtc, keep) {
        keep.open(doorbell, name: 'ring_doorbell').close();
        keep.open(garage, name: 'garage').close();

        final again = keep.open(doorbell, name: 'ring_doorbell');

        expect(go2rtc.opened, hasLength(2));
        expect(again.phase, same(go2rtc.opened.first.phase));
      });
    });
  });

  group('what a re-attached consumer is handed', () {
    test("the running session's own phase and view, not a copy", () {
      withKeepAlive((async, go2rtc, keep) {
        final first = keep.open(doorbell, name: 'ring_doorbell');
        first.close();
        final second = keep.open(doorbell, name: 'ring_doorbell');

        // `view` is `late final` in both real players and hands over a
        // long-lived thing — a detached `<video>` element on web, a painter
        // bound to the session's frame notifier on the appliance. Rebuilding
        // it per consumer would tear the picture down and put it back, which
        // is the cost this whole file exists to avoid.
        expect(second.phase, same(go2rtc.only.phase));
        expect(second.view, same(go2rtc.only.view));
        expect(first.view, same(second.view));
      });
    });

    test('the failure text is the running session\'s, so the log still says '
        'what go2rtc said', () {
      withKeepAlive((async, go2rtc, keep) {
        final session = keep.open(doorbell, name: 'ring_doorbell');
        go2rtc.only.fails('go2rtc refused: mse: stream not found');

        expect(session.failure, 'go2rtc refused: mse: stream not found');
      });
    });
  });

  group('the log', () {
    late List<LogRecord> records;

    setUp(() {
      records = [];
      Log.level = LogLevel.debug;
      Log.sink = records.add;
    });

    tearDown(() {
      Log.sink = Log.printRecord;
      Log.level = LogLevel.debug;
    });

    test('says when a stream was kept, re-attached to and let go — the '
        'three facts issue #1 had to be inferred from timings', () {
      withKeepAlive((async, go2rtc, keep) {
        final first = keep.open(doorbell, name: 'ring_doorbell');
        first.close();
        keep.open(doorbell, name: 'ring_doorbell').close();
        async.elapse(kLiveVideoLinger + const Duration(seconds: 1));

        expect(records.map((r) => '${r.area}.${r.event}'),
            containsAllInOrder(
                ['video.stream_kept', 'video.stream_reused', 'video.stream_dropped']));
      });
    });

    test('names the stream and never the URL', () {
      withKeepAlive((async, go2rtc, keep) {
        // A `GO2RTC_URL` is allowed to carry credentials and this class holds
        // whole URLs as its pool keys — `diagnostics/log.dart`: **Never log a
        // secret**. The stream name is the safe half, and it is the half
        // worth grepping for.
        keep.open(doorbell, name: 'ring_doorbell').close();
        keep.open(doorbell, name: 'ring_doorbell').close();
        async.elapse(kLiveVideoLinger + const Duration(seconds: 1));

        expect(records, isNotEmpty);
        for (final record in records) {
          expect(record.toString(), contains('ring_doorbell'));
          expect(record.toString(), isNot(contains('hub:1984')));
          expect(record.toString(), isNot(contains('api/ws')));
        }
      });
    });
  });

  group('shutdown', () {
    test('dispose closes what is kept and cancels what is pending', () {
      fakeAsync((async) {
        final go2rtc = FakeGo2rtc();
        final keep = LiveVideoKeepAlive(opener: go2rtc.open);
        keep.open(doorbell, name: 'ring_doorbell').close();
        keep.open(garage, name: 'garage').close();

        keep.dispose();

        expect(go2rtc.opened.map((s) => s.closes), everyElement(1));
        // Nothing left to fire: a pending Timer outliving the tree is a
        // widget-test failure by itself, and on the wall it is a Panel
        // shutdown still holding a Ring session.
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('an open after dispose is dialled but not pooled, so it arms no '
        'Timer nothing will cancel', () {
      fakeAsync((async) {
        final go2rtc = FakeGo2rtc();
        final keep = LiveVideoKeepAlive(opener: go2rtc.open);
        keep.dispose();

        final session = keep.open(doorbell, name: 'ring_doorbell');
        session.close();

        // Straight through to the player, both ways: dialled, and closed for
        // real rather than kept by a pool that has shut down.
        expect(go2rtc.opened, hasLength(1));
        expect(go2rtc.only.closes, 1);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('dispose does not close a session somebody is still holding', () {
      fakeAsync((async) {
        final go2rtc = FakeGo2rtc();
        final keep = LiveVideoKeepAlive(opener: go2rtc.open);
        keep.open(doorbell, name: 'ring_doorbell');

        keep.dispose();

        // The consumer closes its own session; this class only ever closes
        // what nobody is holding. Closing a live one from here would blank a
        // camera that is on screen.
        expect(go2rtc.only.closes, 0);
      });
    });

    test('an opener that throws is answered with a settled session, because '
        'this wrapper may not throw either', () {
      fakeAsync((async) {
        // `LiveVideoOpener`'s contract, which a wrapper cannot quietly
        // relax: an implementation may not throw. `device_popup.dart` does
        // catch — but `cameras/cameras_view.dart` calls `video.open` bare, so
        // a throw let out of here would take the whole Cameras view down for
        // one tile that could not dial.
        final keep = LiveVideoKeepAlive(
            opener: (url, {required name}) => throw StateError('no socket'));

        final session = keep.open(doorbell, name: 'ring_doorbell');

        expect(session.phase.value, LiveVideoPhase.failed);
        // The type, never the message: a `SyntaxError` quotes the URL it
        // refused, and that URL may carry a password.
        expect(session.failure, 'the opener threw StateError');
        expect(session.failure, isNot(contains('hub:1984')));
        // Unpooled: nothing was dialled, so a reopen must dial rather than
        // find a dead session waiting for it.
        expect(keep.open(doorbell, name: 'ring_doorbell').phase.value,
            LiveVideoPhase.failed);
        keep.dispose();
      });
    });
  });
}
