import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/live_video.dart';

/// The seam itself: what both players owe the Popup, and what each build's
/// URL rule is.
///
/// The one file in this feature that runs **both** ways —
/// `flutter test test/live_video_test.dart` checks the appliance branch and
/// `flutter test --platform chrome test/live_video_test.dart` checks the web
/// one. The transports themselves are proved elsewhere: the MJPEG player
/// against a real socket in `live_video_mjpeg_test.dart`, and the MSE player
/// nowhere in this repo, because there is no browser on this host and an
/// assertion nobody can run is worse than an admitted gap.
///
/// Imports nothing from `fixtures.dart` on purpose: that reaches
/// `test_house.dart`, which imports `dart:io`, which would stop this file
/// running under `--platform chrome` — and the web half of the split is only
/// checked there.
///
/// What a `failure` string is allowed to say moved to
/// `test/url_redaction_test.dart` with `redactCredentials` itself: the rule
/// stopped being the video seam's private business the moment the Hub's own
/// socket errors — which append `uri = …` to their message the same way —
/// started going through it.
void main() {
  group('the endpoint', () {
    test('a base URL and a stream name become one endpoint on every platform, '
        'not two', () {
      // The same value on web and on the appliance, on purpose: the Popup
      // opens a stream and never reads a byte of one, so the transport is
      // chosen inside the player. `live_video_mjpeg.dart` maps this to
      // `http://h:1984/api/stream.mjpeg?src=ring_doorbell` and asserts that
      // there.
      //
      // Two transports, one stream name. go2rtc serves `selftest` from two
      // producers — `ffmpeg:virtual?video&size=640x480#video=h264` for MSE
      // and `ffmpeg:selftest#video=mjpeg` for MJPEG — so `bindings.yaml`
      // names the stream once and no `_mjpeg` suffix convention exists.
      const video = VideoConfig(go2rtcUrl: 'http://h:1984');

      expect(video.urlFor('ring_doorbell').toString(),
          'ws://h:1984/api/ws?src=ring_doorbell');
    });

    test('https becomes wss, exactly as the Hub\'s own socket does', () {
      const video = VideoConfig(go2rtcUrl: 'https://h:1984');

      expect(video.urlFor('selftest').toString(),
          'wss://h:1984/api/ws?src=selftest');
    });

    test('no base URL is no URL: unconfigured is an answer, not a localhost '
        'the Panel invented', () {
      const video = VideoConfig();

      expect(video.urlFor('selftest'), isNull);
    });

    test('no stream name is no URL, even when go2rtc is configured', () {
      const video = VideoConfig(go2rtcUrl: 'http://h:1984');

      expect(video.urlFor(null), isNull);
      expect(video.urlFor(''), isNull);
    });

    test('a garbled base URL costs the video and nothing else', () {
      // Returns null rather than throwing: HaHubClient.webSocketUrl may
      // throw because a bad HA_URL stops the Hub and the badge says so
      // across the room, while a bad GO2RTC_URL must only ever cost the
      // picture — a FormatException out of the Popup's initState would take
      // the Device name and the Close button down with it.
      //
      // Validated once, above the seam, so both transports refuse the same
      // set instead of each growing its own idea of a usable address.
      for (final garbled in ['h:1984', 'localhost:1984', '::::', 'nonsense']) {
        expect(VideoConfig(go2rtcUrl: garbled).urlFor('selftest'), isNull,
            reason: garbled);
      }
    });
  });

  group('the seam', () {
    test('both branches carry a real player: neither platform is a stub', () {
      // This was `expect(liveVideoIsAvailable, isFalse)` on everything that
      // is not web, back when the appliance showed a grey box. The
      // Flutter/cage kiosk *is* the wall, so that was the wrong half of the
      // seam to leave empty (owner decision, 2026-08-04). The assertion is
      // kept, inverted, so that re-stubbing a branch fails a test instead of
      // quietly costing the appliance its picture.
      expect(liveVideoIsAvailable, isTrue);
    });

    test('opening never throws, whatever the URL: a throw here would take the '
        'whole Dialog down with it', () {
      // The Popup calls this from `initState`, and a `State` whose
      // `initState` threw is never disposed — so it is never deregistered
      // either, and that Device's doorbell goes permanently deaf. Both
      // players answer a settled `failed` session instead.
      //
      // Through `urlFor`, so each platform's player is handed the shape it
      // actually expects and this exercises real construction rather than an
      // early refusal. `h` does not resolve on either platform, so what is
      // being driven is the failing path.
      final url = const VideoConfig(go2rtcUrl: 'http://h:1984').urlFor('x')!;
      final session = openLiveVideo(url, name: 'x');

      expect(session.phase.value, isNot(LiveVideoPhase.unconfigured));
      // Idempotent, and harmless before the Popup ever renders — the Popup
      // can be dismissed by three routes and the deadline can fire during the
      // fourth.
      session.close();
      session.close();
    });

    test('a settled session never changes, so nothing can be left listening '
        'to it', () {
      final session = SettledLiveVideoSession(LiveVideoPhase.failed,
          failure: 'mse: stream not found');
      var notified = 0;

      session.phase.addListener(() => notified++);
      session.close();

      expect(notified, 0);
      expect(session.failure, 'mse: stream not found');
    });
  });
}
