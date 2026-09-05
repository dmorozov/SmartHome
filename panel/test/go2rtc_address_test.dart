import 'package:flutter_test/flutter_test.dart';
import 'package:panel/config/go2rtc_address.dart';
import 'package:panel/ui/audio/talk.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/snapshot.dart';

/// Reading `GO2RTC_URL` for which of three things it is.
///
/// This rule used to exist four times — in `VideoConfig.urlFor`,
/// `Go2rtcStillsConfig.urlFor`, `TalkConfig._urlFor` and the Stream Director's
/// skip reason — and three of the four said in a comment that they were
/// copying the first. What was never asserted anywhere is the trap the
/// comments were about: `Uri.tryParse` accepts `localhost:1984` happily, as a
/// URI whose *scheme* is `localhost` and which has no host at all. That is the
/// difference between an address and a typo, and it is the whole content of
/// the guard.
///
/// The three consumers are exercised here too, against the same inputs, so
/// "all four refuse exactly the same set of addresses" is a fact rather than a
/// promise in four comments.
void main() {
  group('the three meanings of GO2RTC_URL', () {
    test('empty is absent — nobody named a go2rtc, which is a supported boot '
        'state and not a fault', () {
      expect(Go2rtcAddress.parse(''), isA<Go2rtcAbsent>());
    });

    test('an address is an address, and the base survives intact', () {
      final at = Go2rtcAddress.parse('http://192.168.68.81:1984');
      expect(at, isA<Go2rtcAt>());
      expect((at as Go2rtcAt).base.host, '192.168.68.81');
      expect(at.base.port, 1984);
      expect(at.base.scheme, 'http');
    });

    test('`localhost:1984` is UNUSABLE, not an address — the trap the four '
        'copied guards existed for', () {
      // `Uri.tryParse` reads this as scheme `localhost`, path `1984`, and no
      // host whatsoever. It is the single most likely thing for somebody to
      // type into GO2RTC_URL by hand, and it parses without complaint.
      expect(Uri.tryParse('localhost:1984')?.host, isEmpty,
          reason: 'if this ever fails, Dart changed and the guard is moot');
      expect(Go2rtcAddress.parse('localhost:1984'), isA<Go2rtcUnusable>());
    });

    test('every other way of naming nothing is unusable too', () {
      for (final raw in [
        'nonsense', // parses, no host
        'http://', // a scheme and nothing else
        'file:///tmp/x', // a real scheme, still no host
        '://x', // does not parse at all
        'h ttp://x', // nor this
        '   ', // somebody typed spaces
      ]) {
        expect(Go2rtcAddress.parse(raw), isA<Go2rtcUnusable>(),
            reason: 'GO2RTC_URL=$raw');
      }
    });

    test('whitespace is unusable rather than absent, and that is the honest '
        'answer', () {
      // Not trimmed into absence: somebody typed something, and the two
      // states earn different journal lines and different fixes.
      expect(Go2rtcAddress.parse(' '), isA<Go2rtcUnusable>());
      expect(Go2rtcAddress.parse(''), isA<Go2rtcAbsent>());
    });

    test('a scheme-less `//host/path` has a host, so it is an address — a '
        'known edge, unchanged by this refactor', () {
      expect(Go2rtcAddress.parse('//hub/x'), isA<Go2rtcAt>());
    });
  });

  group('all three consumers refuse the same set', () {
    // The property the four comments promised. Asserted against the consumers
    // rather than the parser, because what matters is that a bad address
    // costs the picture and nothing else.
    const usable = 'http://hub:1984';
    const refused = ['', 'localhost:1984', 'nonsense', 'http://', '://x'];

    test('the video seam', () {
      expect(const VideoConfig(go2rtcUrl: usable).urlFor('cam').toString(),
          'ws://hub:1984/api/ws?src=cam');
      for (final raw in refused) {
        expect(VideoConfig(go2rtcUrl: raw).urlFor('cam'), isNull,
            reason: 'GO2RTC_URL=$raw');
      }
    });

    test('the go2rtc still grab', () {
      expect(
          const Go2rtcStillsConfig(go2rtcUrl: usable).urlFor('cam')?.path,
          '/api/frame.jpeg');
      for (final raw in refused) {
        expect(Go2rtcStillsConfig(go2rtcUrl: raw).urlFor('cam'), isNull,
            reason: 'GO2RTC_URL=$raw');
      }
    });

    test('push-to-talk, both legs', () {
      const good = TalkConfig(go2rtcUrl: usable, micSource: 'rtsp://x/mic');
      expect(good.startUrl('ring')?.path, '/api/streams');
      expect(good.stopUrl('ring')?.path, '/api/streams');
      for (final raw in refused) {
        final talk = TalkConfig(go2rtcUrl: raw, micSource: 'rtsp://x/mic');
        expect(talk.startUrl('ring'), isNull, reason: 'GO2RTC_URL=$raw');
        expect(talk.stopUrl('ring'), isNull, reason: 'GO2RTC_URL=$raw');
      }
    });

    test('a missing stream name is refused whatever the address, and that is '
        'a separate question from the address being good', () {
      const video = VideoConfig(go2rtcUrl: usable);
      expect(video.urlFor(null), isNull);
      expect(video.urlFor(''), isNull);
      expect(video.address, isA<Go2rtcAt>(),
          reason: 'the address is fine; it is the name that is missing, and '
              'the Director tells those two apart in its skip line');
    });
  });

  group('https', () {
    test('a TLS go2rtc is not downgraded — wss for the socket, https for the '
        'still', () {
      expect(
          const VideoConfig(go2rtcUrl: 'https://hub:1984')
              .urlFor('cam')
              ?.scheme,
          'wss');
      expect(
          const Go2rtcStillsConfig(go2rtcUrl: 'https://hub:1984')
              .urlFor('cam')
              ?.scheme,
          'https');
    });
  });
}
