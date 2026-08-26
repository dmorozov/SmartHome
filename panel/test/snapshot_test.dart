import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/snapshot.dart';

/// The snapshot seam: the URL rule (platform-independent) and the appliance
/// fetcher against a real socket — the same split `live_video_test.dart` /
/// `live_video_mjpeg_test.dart` uses for the sibling seam.
void main() {
  group('SnapshotConfig.urlFor', () {
    const config = SnapshotConfig(
        haUrl: 'http://hub.local:8123', token: 'a-token', fetch: _never);

    test('builds the camera_proxy path, token nowhere in it', () {
      final url = config.urlFor('camera.front_door_snapshot');
      expect(url.toString(),
          'http://hub.local:8123/api/camera_proxy/camera.front_door_snapshot');
      // The leak rule, asserted at the seam: the token travels as a header
      // or not at all — never in the URL, which reaches logs and history.
      expect(url.toString().contains('a-token'), isFalse);
    });

    test('an empty base is absent, not a localhost the Panel invented', () {
      const unconfigured = SnapshotConfig(token: 'a-token', fetch: _never);
      expect(unconfigured.urlFor('camera.x'), isNull);
    });

    test('an empty token dials nothing rather than earning a 401 per tick',
        () {
      const tokenless =
          SnapshotConfig(haUrl: 'http://hub.local:8123', fetch: _never);
      expect(tokenless.urlFor('camera.x'), isNull);
    });

    test('no entity, no URL', () {
      expect(config.urlFor(null), isNull);
      expect(config.urlFor(''), isNull);
    });

    test('an address with no host is a typo, refused as one', () {
      // `Uri.tryParse('localhost:8123')` parses happily — scheme
      // `localhost`, no host. The same guard as `VideoConfig.urlFor`.
      const typo =
          SnapshotConfig(haUrl: 'localhost:8123', token: 't', fetch: _never);
      expect(typo.urlFor('camera.x'), isNull);
    });

    test('https is not downgraded', () {
      const tls = SnapshotConfig(
          haUrl: 'https://hub.local:8123', token: 't', fetch: _never);
      expect(tls.urlFor('camera.x')!.scheme, 'https');
    });
  });

  group('Go2rtcStillsConfig.urlFor', () {
    const config = Go2rtcStillsConfig(
        go2rtcUrl: 'http://hub.local:1984', fetch: _never);

    test('builds the frame grab with the cache window that bounds its cost',
        () {
      final url = config.urlFor('wyze_garage_door_sub')!;
      expect(url.path, '/api/frame.jpeg');
      expect(url.queryParameters,
          {'src': 'wyze_garage_door_sub', 'cache': '45s'});
    });

    test('an empty base is absent, not a localhost the Panel invented', () {
      expect(const Go2rtcStillsConfig(fetch: _never).urlFor('x'), isNull);
    });

    test('no stream, no URL', () {
      expect(config.urlFor(null), isNull);
      expect(config.urlFor(''), isNull);
    });

    test('an address with no host is a typo, refused as one', () {
      const typo =
          Go2rtcStillsConfig(go2rtcUrl: 'localhost:1984', fetch: _never);
      expect(typo.urlFor('x'), isNull);
    });

    test('https is not downgraded', () {
      const tls = Go2rtcStillsConfig(
          go2rtcUrl: 'https://hub.local:1984', fetch: _never);
      expect(tls.urlFor('x')!.scheme, 'https');
    });
  });

  group('fetchSnapshot (appliance branch, real socket)', () {
    late HttpServer server;

    tearDown(() async => server.close(force: true));

    Future<Uri> serve(
        void Function(HttpRequest request) handler) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(handler);
      return Uri.parse('http://127.0.0.1:${server.port}/api/camera_proxy/x');
    }

    test('sends the token as a Bearer header and returns the bytes', () async {
      String? auth;
      final url = await serve((request) {
        auth = request.headers.value(HttpHeaders.authorizationHeader);
        request.response
          ..headers.contentType = ContentType('image', 'jpeg')
          ..add([1, 2, 3])
          ..close();
      });
      final result = await fetchSnapshot(url, token: 'secret-token');
      expect(auth, 'Bearer secret-token');
      expect(result.status, 'ok');
      expect(result.bytes, [1, 2, 3]);
    });

    test('an empty token sends no Authorization header at all', () async {
      String? auth;
      final url = await serve((request) {
        auth = request.headers.value(HttpHeaders.authorizationHeader);
        request.response
          ..headers.contentType = ContentType('image', 'jpeg')
          ..add([1, 2, 3])
          ..close();
      });
      // The go2rtc source (`Go2rtcStillsConfig`) is tokenless by design;
      // a `Bearer ` with nothing after it would be a malformed credential,
      // not an absent one.
      final result = await fetchSnapshot(url, token: '');
      expect(auth, isNull);
      expect(result.status, 'ok');
    });

    test('a zero-byte 200 is a refusal, not an empty image', () async {
      // What go2rtc's `frame.jpeg` answers for a camera whose RTSP daemon
      // is dead (measured 2026-08-25) — and `Image.memory` over zero bytes
      // throws in the tile.
      final url = await serve((request) => request.response.close());
      final result = await fetchSnapshot(url, token: 't');
      expect(result.bytes, isNull);
      expect(result.status, 'empty');
    });

    test('a non-200 is the status code, drained and done', () async {
      final url = await serve((request) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
      });
      final result = await fetchSnapshot(url, token: 't');
      expect(result.bytes, isNull);
      expect(result.status, '404');
    });

    test('an unreachable Hub is a type name — never the URL', () async {
      final url = await serve((request) => request.response.close());
      await server.close(force: true);
      final result =
          await fetchSnapshot(url, token: 'token-that-must-not-leak');
      expect(result.bytes, isNull);
      // The exception's bare type: `SocketException`'s *message* carries
      // the address it failed to reach, and the headers carried the token.
      expect(result.status.contains(':'), isFalse,
          reason: 'a colon smells like a message, not a type name');
      expect(result.status.contains('127.0.0.1'), isFalse);
      expect(result.status.contains('token-that-must-not-leak'), isFalse);
    });
  });
}

Future<SnapshotResult> _never(Uri url, {required String token}) async =>
    throw StateError('this test never fetches');
