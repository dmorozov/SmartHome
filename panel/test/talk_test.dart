import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/audio/talk.dart';

/// The two URLs ADR-0011 decided, and the set of addresses this seam refuses.
///
/// A sibling of `live_video_test.dart`'s `urlFor` group and held to the same
/// standard, because the failure modes are the same ones: a wrong address must
/// cost only the talkback, and a bad one must be refused above the seam rather
/// than by whichever HTTP stack this build happens to carry.
void main() {
  group('the two calls', () {
    const talk = TalkConfig(go2rtcUrl: 'http://hub:1984');

    test('START pushes the mic into the talk stream, RTSP-encoded', () {
      // Verbatim from ADR-0011. The RTSP form is not incidental: the `mic`
      // stream already produces opus/48000/2 and Ring negotiates
      // opus/48000/2, so this is a passthrough with no re-encode. A bare
      // `src=mic` is HTTP 500 (`unsupported scheme`).
      expect(
        talk.startUrl('ring').toString(),
        'http://hub:1984/api/streams'
        '?dst=ring&src=rtsp%3A%2F%2F127.0.0.1%3A8554%2Fmic',
      );
    });

    test('STOP is the same call with an empty src', () {
      expect(
        talk.stopUrl('ring').toString(),
        'http://hub:1984/api/streams?dst=ring&src=',
      );
    });

    test('the talk stream is the dst, and nothing derives it from the video '
        'stream', () {
      // The Front Door carries both names and only one has a backchannel.
      // Posting to `ring_doorbell` would reach ring-mqtt's RTSP restream,
      // which cannot carry talk at all — which is the whole of ADR-0011.
      expect(talk.startUrl('ring')!.queryParameters['dst'], 'ring');
      expect(
        talk.startUrl('ring_doorbell')!.queryParameters['dst'],
        'ring_doorbell',
      );
    });

    test('a go2rtc behind TLS is not downgraded to plain HTTP', () {
      expect(
        const TalkConfig(go2rtcUrl: 'https://hub:1984')
            .startUrl('ring')
            .toString(),
        startsWith('https://hub:1984/api/streams'),
      );
    });
  });

  group('what it refuses, instead of throwing out of a gesture callback', () {
    test('no address named', () {
      expect(const TalkConfig().startUrl('ring'), isNull);
      expect(const TalkConfig().stopUrl('ring'), isNull);
    });

    test('no talk stream on the Device', () {
      const talk = TalkConfig(go2rtcUrl: 'http://hub:1984');
      expect(talk.startUrl(null), isNull);
      expect(talk.startUrl(''), isNull);
      expect(talk.stopUrl(null), isNull);
    });

    test('an address that will not parse as one', () {
      // `Uri.tryParse` is generous: `localhost:1984` parses happily, as a URI
      // with scheme `localhost` and no host at all. Requiring a host is what
      // separates an address from a typo — the same guard `VideoConfig` uses,
      // checked here independently so the two cannot drift.
      for (final garbled in ['localhost:1984', 'hub:1984', '::::']) {
        expect(
          TalkConfig(go2rtcUrl: garbled).startUrl('ring'),
          isNull,
          reason: garbled,
        );
      }
    });

    test('an empty mic source refuses to START but still lets go2rtc STOP', () {
      // Not symmetric on purpose. An empty `src` IS the stop, so a blank mic
      // source would turn every press into a stop that reported itself as a
      // successful start — the one confusion in this seam that could leave a
      // person at the wall talking to nobody and being told it worked.
      const talk = TalkConfig(go2rtcUrl: 'http://hub:1984', micSource: '');
      expect(talk.startUrl('ring'), isNull);
      expect(talk.stopUrl('ring'), isNotNull);
    });
  });

  /// The appliance poster against a real socket — the same split
  /// `snapshot_test.dart` uses for the sibling seam, and for the same reason:
  /// everything above this line is platform-independent, and everything below
  /// it is `dart:io` and cannot be asserted on a web build.
  group('postTalk (appliance branch, real socket)', () {
    late HttpServer server;

    tearDown(() async => server.close(force: true));

    Future<Uri> serve(void Function(HttpRequest request) handler) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(handler);
      return Uri.parse(
        'http://127.0.0.1:${server.port}/api/streams?dst=ring&src=',
      );
    }

    test('POSTs, with the query intact and an empty body', () async {
      String? method;
      String? query;
      int? length;
      final url = await serve((request) {
        method = request.method;
        query = request.uri.query;
        length = request.contentLength;
        request.response.close();
      });

      final result = await postTalk(url);

      expect(result.ok, isTrue);
      expect(result.status, 'ok');
      expect(method, 'POST');
      // `src=` survives the round trip — the reason `_urlFor` spells the
      // query out instead of using `queryParameters:`.
      expect(query, 'dst=ring&src=');
      expect(length, 0);
    });

    test('a refusal is the status code, and the call does not throw', () async {
      final url = await serve((request) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('unsupported scheme')
          ..close();
      });

      final result = await postTalk(url);

      expect(result.ok, isFalse);
      expect(result.status, '500');
    });

    test('a go2rtc that is not listening costs the talkback and nothing '
        'else — and names no URL doing it', () async {
      // The seam's hard rule: a gesture callback has nowhere to put an
      // exception, and `HttpException` appends `, uri = …` to its message
      // while a fat-fingered GO2RTC_URL can carry a password (log.dart:
      // Never log a secret). So a dead server is a status, not a throw.
      final url = await serve((request) => request.response.close());
      await server.close(force: true);

      final result = await postTalk(url);

      expect(result.ok, isFalse);
      expect(result.status, isNot(contains('127.0.0.1')));
      expect(result.status, isNot(contains('http')));
      // The bare exception type, which is all `talk.dart` permits.
      expect(result.status, matches(RegExp(r'^[A-Za-z_$][\w$]*$')));
    });
  });
}
