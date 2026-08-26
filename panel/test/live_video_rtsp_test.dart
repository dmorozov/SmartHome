import 'dart:async';

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
