import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_rtsp.dart';
import 'package:video_player/video_player.dart';

/// The RTSP adapter against the seam's obligations — the same split the
/// MJPEG player uses: the URL rule and the session contracts hermetically
/// here, the real player against a real go2rtc elsewhere. "Elsewhere" for
/// this transport is NOT an opt-in `flutter test` suite: fvp's native
/// library is not built for VM test runs (the MJPEG live suite gets away
/// with it by being pure `dart:io`), so the live proof is the N5 prototype
/// app (`rtsp_probe`, run 2026-08-26: 6 streams, 3.9–5.1 s to first frame,
/// teardown drained go2rtc to 0 consumers) and the wall itself under
/// `VIDEO_TRANSPORT=rtsp`.
void main() {
  group('rtspEndpointFor', () {
    test('maps the seam URL to the restream listener', () {
      final url =
          rtspEndpointFor(Uri.parse('ws://hub.local:1984/api/ws?src=selftest'));
      expect(url.toString(), 'rtsp://hub.local:8554/selftest');
    });

    test('TLS on the API does not invent TLS on the restream', () {
      // 8554 is go2rtc's cleartext RTSP listener whatever scheme the API
      // URL wore; an `rtsps://` here would dial a port nobody serves.
      final url =
          rtspEndpointFor(Uri.parse('wss://hub.local:1984/api/ws?src=x'));
      expect(url.scheme, 'rtsp');
      expect(url.port, 8554);
    });

    test('credentials in GO2RTC_URL never reach the player', () {
      // `api.username`/`api.password` make `http://user:pass@hub` a value an
      // operator can legitimately be given; they authenticate the API, not
      // the restream, and the native player's error strings are not ours to
      // redact.
      final url = rtspEndpointFor(
          Uri.parse('ws://user:secret@hub.local:1984/api/ws?src=x'));
      expect(url.userInfo, isEmpty);
      expect(url.toString().contains('secret'), isFalse);
    });

    test('the stream name is the path, the query does not survive', () {
      final url = rtspEndpointFor(
          Uri.parse('ws://hub:1984/api/ws?src=wyze_garage_door_sub'));
      expect(url.path, '/wyze_garage_door_sub');
      expect(url.query, isEmpty);
    });
  });

  group('the frame pulse', () {
    // A global, so every case here puts it back — a leaked `false` would
    // silently unpin the wall's only defence against a frozen picture.
    tearDown(() => rtspFramePulse = true);

    test(
      'a playing view carries the pulse by default — without it the '
      'GTK/Wayland embedder only re-samples the texture when something '
      'else makes the engine draw, and the wall updates on scroll alone',
      () {
        fakeAsync((async) {
          final session = RtspLiveVideoSession(
            _url,
            controllerFor: (_) => _FakeController(),
          );
          // Not a bare player: something wraps it to keep frames coming.
          expect(session.view, isNot(isA<VideoPlayer>()));
          session.close();
        });
      },
    );

    test('VIDEO_REPAINT_PULSE=off hands back the plain player', () {
      fakeAsync((async) {
        rtspFramePulse = false;
        final session = RtspLiveVideoSession(
          _url,
          controllerFor: (_) => _FakeController(),
        );
        expect(session.view, isA<VideoPlayer>());
        session.close();
      });
    });

    testWidgets(
      'the pulse actually ticks — a ticker that is never started repaints '
      'nothing, and reads exactly like a wall with no fix at all',
      (tester) async {
        final session = RtspLiveVideoSession(
          _url,
          controllerFor: (_) => _FakeController(),
        );
        final before = tester.binding.transientCallbackCount;
        await tester.pumpWidget(
          Directionality(textDirection: TextDirection.ltr, child: session.view),
        );
        // A running Ticker holds a transient frame callback. This was the
        // whole bug: `late final Ticker _ticker = createTicker(...)` is
        // initialised on first read, nothing read it, and the shipped
        // "fix" ticked zero times.
        expect(tester.binding.transientCallbackCount, greaterThan(before));

        // Unmount first so the ticker is disposed, then close so the open
        // watchdog does not outlive the case.
        await tester.pumpWidget(const SizedBox.shrink());
        session.close();
        await tester.pump();
      },
    );

    testWidgets('with the pulse off nothing is scheduled at all', (
      tester,
    ) async {
      rtspFramePulse = false;
      final session = RtspLiveVideoSession(
        _url,
        controllerFor: (_) => _FakeController(),
      );
      final before = tester.binding.transientCallbackCount;
      await tester.pumpWidget(
        Directionality(textDirection: TextDirection.ltr, child: session.view),
      );
      expect(tester.binding.transientCallbackCount, before);

      await tester.pumpWidget(const SizedBox.shrink());
      session.close();
      await tester.pump();
    });

    test('the view is still built once, pulse or no pulse', () {
      fakeAsync((async) {
        final session = RtspLiveVideoSession(
          _url,
          controllerFor: (_) => _FakeController(),
        );
        // The pinned invariant this must not break: a fresh widget on every
        // read would remount the texture on every phase change.
        expect(identical(session.view, session.view), isTrue);
        session.close();
      });
    });
  });

  group('RtspLiveVideoSession', () {
    test('born connecting; metadata alone is not a picture', () {
      fakeAsync((async) {
        final controller = _FakeController();
        final session =
            RtspLiveVideoSession(_url, controllerFor: (_) => controller);
        expect(session.phase.value, LiveVideoPhase.connecting);

        // Initialize completes — fvp's "metadata landed" — but the clock
        // has not advanced: still honestly connecting.
        controller.finishInitialize();
        async.flushMicrotasks();
        expect(controller.played, isTrue);
        expect(session.phase.value, LiveVideoPhase.connecting);

        // The clock advances: frames are flowing.
        controller.showPosition(const Duration(milliseconds: 120));
        expect(session.phase.value, LiveVideoPhase.playing);
        session.close();
      });
    });

    test('no picture within the open deadline is a failure that names it',
        () {
      fakeAsync((async) {
        final controller = _FakeController();
        final session =
            RtspLiveVideoSession(_url, controllerFor: (_) => controller);
        controller.finishInitialize();
        async.flushMicrotasks();
        async.elapse(kRtspFirstFrameTimeout + const Duration(seconds: 1));
        expect(session.phase.value, LiveVideoPhase.failed);
        expect(session.failure, contains('${kRtspFirstFrameTimeout.inSeconds}'));
        // A session nobody will watch is still a consumer until torn down.
        expect(controller.disposed, isTrue);
      });
    });

    test('a frozen clock is a stall, an advancing one is liveness', () {
      fakeAsync((async) {
        final controller = _FakeController();
        final session =
            RtspLiveVideoSession(_url, controllerFor: (_) => controller);
        controller.finishInitialize();
        async.flushMicrotasks();
        controller.showPosition(const Duration(milliseconds: 100));
        expect(session.phase.value, LiveVideoPhase.playing);

        // Advancing position keeps re-arming the watchdog far past the
        // stall deadline.
        for (var i = 1; i <= 4; i++) {
          async.elapse(const Duration(seconds: 10));
          controller.showPosition(Duration(seconds: i));
        }
        expect(session.phase.value, LiveVideoPhase.playing);

        // Then the picture freezes.
        async.elapse(kRtspStallTimeout + const Duration(seconds: 1));
        expect(session.phase.value, LiveVideoPhase.failed);
        expect(session.failure, contains('froze'));
        expect(controller.disposed, isTrue);
      });
    });

    test("the player's own error fails the session without quoting it", () {
      fakeAsync((async) {
        final controller = _FakeController();
        final session =
            RtspLiveVideoSession(_url, controllerFor: (_) => controller);
        controller.reportError('mdk said something quoting rtsp://x');
        expect(session.phase.value, LiveVideoPhase.failed);
        expect(session.failure, isNot(contains('rtsp://')),
            reason: 'the platform message is not ours to redact, so none '
                'of it is repeated');
      });
    });

    test('an initialize that throws is a typed failure, never an escape', () {
      fakeAsync((async) {
        final controller = _FakeController();
        final session =
            RtspLiveVideoSession(_url, controllerFor: (_) => controller);
        controller.failInitialize(StateError('uri = rtsp://secret'));
        async.flushMicrotasks();
        expect(session.phase.value, LiveVideoPhase.failed);
        expect(session.failure, contains('StateError'));
        expect(session.failure, isNot(contains('secret')));
      });
    });

    test('close is idempotent, tears the player down, and ends the story',
        () {
      fakeAsync((async) {
        final controller = _FakeController();
        final session =
            RtspLiveVideoSession(_url, controllerFor: (_) => controller);
        controller.finishInitialize();
        async.flushMicrotasks();
        controller.showPosition(const Duration(milliseconds: 100));

        session.close();
        session.close();
        expect(controller.disposed, isTrue);

        // No phase transition after close — the watchdog is cancelled and
        // the listener is off.
        async.elapse(const Duration(minutes: 2));
        expect(session.phase.value, LiveVideoPhase.playing);
        expect(async.pendingTimers, isEmpty,
            reason: 'no Timer outlives its owner');
      });
    });

    test('born muted, and the unmute that raced initialize still lands '
        'before a sample plays', () {
      fakeAsync((async) {
        final controller = _FakeController();
        final session =
            RtspLiveVideoSession(_url, controllerFor: (_) => controller);
        // The surface decides DURING the dial — the Popup unmutes right
        // after opening, while initialize is still in flight.
        session.setMuted(false);
        controller.finishInitialize();
        async.flushMicrotasks();
        expect(controller.volumes, [1.0],
            reason: 'the in-flight decision wins; nothing ever played at '
                'the default volume');
        expect(controller.played, isTrue);

        session.setMuted(true);
        expect(controller.volumes, [1.0, 0.0]);
        session.close();
      });
    });

    test('left alone, the player is silent — six tiles of pcm_mulaw is the '
        'measured alternative', () {
      fakeAsync((async) {
        final controller = _FakeController();
        final session =
            RtspLiveVideoSession(_url, controllerFor: (_) => controller);
        controller.finishInitialize();
        async.flushMicrotasks();
        expect(controller.volumes, [0.0]);
        session.close();
      });
    });

    test('the opener never throws', () {
      // With no native player in a VM test run, everything past the seam is
      // allowed to fail — as a settled session or a failing dial, never as
      // an exception out of the opener (the caller is a State.initState).
      expect(
          () => openRtspVideo(Uri.parse('ws://hub:1984/api/ws?src=x'),
              name: 'x'),
          returnsNormally);
    });
  });
}

final _url = Uri.parse('rtsp://hub:8554/selftest');

/// The player as the adapter assumes it: a [VideoPlayerController] whose
/// lifecycle the test drives by hand. Subclassing the real controller keeps
/// the adapter's type honest; nothing here touches a platform channel —
/// `initialize`/`play`/`dispose` are overridden whole.
class _FakeController extends VideoPlayerController {
  _FakeController() : super.networkUrl(Uri.parse('rtsp://fake:8554/x'));

  final _init = Completer<void>();
  var played = false;
  var disposed = false;

  /// Every volume the adapter set, in order — the mute contract's witness.
  final volumes = <double>[];

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> initialize() async {
    await _init.future;
    value = value.copyWith(isInitialized: true);
  }

  void finishInitialize() => _init.complete();

  void failInitialize(Object error) => _init.completeError(error);

  @override
  Future<void> play() async => played = true;

  void showPosition(Duration position) {
    value = value.copyWith(isInitialized: true, position: position);
  }

  void reportError(String description) {
    value = value.copyWith(errorDescription: description);
  }

  // The real dispose tears down a platform player this fake never
  // created; the notifier itself is deliberately left alive for the same
  // reason the sessions leave theirs (a listener may still be coming off
  // after close).
  @override
  // ignore: must_call_super
  Future<void> dispose() async => disposed = true;
}
