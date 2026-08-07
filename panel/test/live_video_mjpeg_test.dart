import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// Through the seam, not around it: on the VM the conditional export *is*
// `live_video_mjpeg.dart`, so importing that file here would assert nothing
// this import does not, and would hide the day the seam stops selecting it.
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/mjpeg_frames.dart';

/// The appliance's player, proved on the VM.
///
/// The Flutter/cage kiosk is the wall, so this transport is the one that has
/// to work — and all of it except the pixels is testable here: the framing is
/// byte arithmetic, and `flutter test` can drive a real socket on localhost
/// that speaks go2rtc's exact multipart dialect. What is *not* proved here is
/// that a Linux build compiles and paints — but no longer for the reason this
/// comment used to give. It said "this host has no clang/cmake/ninja/gtk
/// (TODO G4)", and that is stale twice over: **G4 is done** (the Hub host got
/// the toolchain 2026-08-04, and `flutter build linux --release` has since
/// produced a bundle that rendered live video), and the devcontainer this
/// suite actually runs in ships clang, cmake, ninja and gtk+-3.0 as well
/// (ADR-0009, re-checked 2026-08-07). Compiling is not the gap.
///
/// The gap is what it always really was: **pixels, under the real
/// compositor.** No VM test paints, and the kiosk the Panel ships into is
/// `cage`, which is still not installed (**G6**) on a host with no
/// touchscreen attached (**A7**). `panel/README.md`'s "Not finished" section
/// keeps the current version of that list.
///
/// Every wire shape below was measured against go2rtc 1.9.10 on 2026-08-04:
/// `--frame\r\nContent-Type: image/jpeg\r\nContent-Length: n\r\n\r\n<n
/// bytes>\r\n`, chunked, at 25.1 fps and a 7.2 kB mean frame.
void main() {
  // `ui.instantiateImageCodec` needs the engine up; nothing here needs a
  // widget tree, so the binding is initialised by hand rather than by
  // wrapping every case in `testWidgets`.
  TestWidgetsFlutterBinding.ensureInitialized();
  // …and then undone, for HTTP only. The binding installs an `HttpOverrides`
  // whose `HttpClient` answers **400 to everything and opens no socket** —
  // sensible for a widget test that wanders onto the network, fatal for the
  // one suite whose whole subject is what comes back over one. Every case
  // below reported `go2rtc answered HTTP 400` until this line existed.
  //
  // Rejected: injecting an `HttpClient` into the session. The framing faults
  // this suite exists to catch — a part split across two socket reads, a
  // boundary token inside the entropy data — only happen when a real kernel
  // decides where the reads land, and a hand-written fake would decide that
  // itself and always be right.
  setUpAll(() => HttpOverrides.global = null);

  group('framing', () {
    test('a boundary token inside a JPEG does not cut the frame in half: the '
        'part is cut out by its declared length', () async {
      // The reason this parser counts bytes instead of scanning. JPEG
      // entropy-coded data is effectively random, so `--frame` will
      // eventually appear inside a picture; a scanner would hand the decoder
      // the first half of it and call the rest a new frame.
      final body = Uint8List.fromList([
        ...List.filled(64, 0x5a),
        ...ascii.encode('\r\n--frame\r\nContent-Length: 9\r\n\r\n'),
        ...List.filled(64, 0x5a),
      ]);

      final frames = await mjpegFrames(_packets([_part(body)])).toList();

      expect(frames, hasLength(1));
      expect(frames.single, body);
    });

    test('a part split across packets arrives whole, so a slow socket cannot '
        'corrupt a picture', () async {
      final body = Uint8List.fromList(List.generate(300, (i) => i % 256));
      final whole = _part(body);
      // Split inside the header, inside the body and inside the trailer —
      // `HttpClient` de-chunks the transfer encoding and then hands over
      // whatever the socket read returned, which respects nothing.
      final packets = [
        whole.sublist(0, 20),
        whole.sublist(20, 61),
        whole.sublist(61, 300),
        whole.sublist(300),
      ];

      final frames = await mjpegFrames(_packets(packets)).toList();

      expect(frames.single, body);
    });

    test('one packet carrying three parts yields three frames, so a burst is '
        'not silently collapsed to one', () async {
      final bodies = [
        Uint8List.fromList(List.filled(10, 1)),
        Uint8List.fromList(List.filled(20, 2)),
        Uint8List.fromList(List.filled(30, 3)),
      ];

      final frames =
          await mjpegFrames(_packets([bodies.expand(_part).toList()])).toList();

      expect(frames.map((f) => f.length), [10, 20, 30]);
      expect(frames[2].every((b) => b == 3), isTrue);
    });

    test('a part with no Content-Length is refused rather than guessed at, '
        'because guessing means scanning for the boundary', () async {
      final bytes = [
        ...ascii.encode('--frame\r\nContent-Type: image/jpeg\r\n\r\n'),
        ...List.filled(40, 0),
      ];

      await expectLater(mjpegFrames(_packets([bytes])),
          emitsError(isA<MjpegFormatException>()));
    });

    test('a header that never ends is refused instead of buffered forever, so '
        'a wall panel cannot be talked into holding a megabyte', () async {
      final endless = ascii.encode('--frame\r\nX: ${'y' * 5000}');

      await expectLater(mjpegFrames(_packets([endless]), maxHeaderBytes: 128),
          emitsError(isA<MjpegFormatException>()));
    });

    test('a header past the cap is refused however the kernel split the '
        'reads, so a server cannot buy its way in with one big write',
        () async {
      // The gap: the cap was consulted only while the blank line had *not*
      // yet arrived, so a 100 kB header block in one packet was accepted and
      // the identical bytes in 4 kB packets were refused. Where a socket read
      // lands is not a property of the stream, so it cannot decide what the
      // stream is.
      final huge = [
        ...ascii.encode('--frame\r\nX: ${'y' * 100000}\r\n'
            'Content-Length: 4\r\n\r\n'),
        ...List.filled(4, 0),
      ];

      await expectLater(mjpegFrames(_packets([huge]), maxHeaderBytes: 4096),
          emitsError(isA<MjpegFormatException>()));
      // And in pieces, which was already refused and must stay refused.
      final pieces = [
        for (var at = 0; at < huge.length; at += 4096)
          huge.sublist(at, at + 4096 > huge.length ? huge.length : at + 4096),
      ];
      await expectLater(mjpegFrames(_packets(pieces), maxHeaderBytes: 4096),
          emitsError(isA<MjpegFormatException>()));
    });

    test('a body that was never multipart says so, instead of being reported '
        'as a stream that ended', () async {
      // A 200 carrying an error page produced no exception at all, so the
      // player said "go2rtc ended the stream" — which sends an operator to
      // look at a camera when what answered was a proxy's HTML.
      await expectLater(
          mjpegFrames(_packets([ascii.encode('<html>hello</html>')])),
          emitsError(isA<MjpegFormatException>()));
    });

    test('a body of nothing but blank lines stays quiet: that is an idle '
        'server, not a wrong one', () async {
      final frames =
          await mjpegFrames(_packets([ascii.encode('\r\n' * 2000)])).toList();

      expect(frames, isEmpty);
    });

    test('a part declaring more than the ceiling is refused before the bytes '
        'are allocated', () async {
      final bytes = ascii.encode('--frame\r\nContent-Type: image/jpeg\r\n'
          'Content-Length: 999999999\r\n\r\n');

      await expectLater(mjpegFrames(_packets([bytes]), maxFrameBytes: 4096),
          emitsError(isA<MjpegFormatException>()));
    });

    test('a Content-Length longer than an int is refused as too large rather '
        'than crashing the parser', () async {
      final bytes = ascii.encode('--frame\r\nContent-Length: '
          '99999999999999999999999\r\n\r\n');

      await expectLater(mjpegFrames(_packets([bytes])),
          emitsError(isA<MjpegFormatException>()));
    });

    test('a stream that stops mid-part ends quietly: a dropped connection is '
        'the player\'s event to name, not a framing fault', () async {
      final whole = _part(Uint8List.fromList(List.filled(100, 7)));

      final frames =
          await mjpegFrames(_packets([whole.sublist(0, 80)])).toList();

      expect(frames, isEmpty);
    });

    test('a blank line between parts is skipped, so a server more '
        'conventional than go2rtc is not called malformed', () async {
      final body = Uint8List.fromList(List.filled(16, 9));
      final doubled = [
        ..._part(body),
        ...ascii.encode('\r\n'), // a second trailer go2rtc does not send
        ..._part(body),
      ];

      final frames = await mjpegFrames(_packets([doubled])).toList();

      expect(frames, hasLength(2));
    });
  });

  group('the player against a real socket', () {
    test('frames off the wire become a picture: the phase reaches playing and '
        'a decoded image is on offer', () async {
      final go2rtc = await _FakeGo2rtc.start(_frames(forever: true));
      final session = _open(go2rtc.url);

      await _reaches(session, LiveVideoPhase.playing);

      expect(session.frame.value, isNotNull);
      expect(session.failure, isNull);
    });

    test('go2rtc answering 404 for an unknown stream is reported as a status, '
        'never as a black rectangle nobody can explain', () async {
      final go2rtc = await _FakeGo2rtc.start((wire) async {
        wire.head(404, 'Not Found');
        wire.send(ascii.encode('stream not found'));
        await wire.end();
      });
      final session = _open(go2rtc.url);

      await _reaches(session, LiveVideoPhase.failed);

      expect(session.failure, 'go2rtc answered HTTP 404');
    });

    test('the server ending the body is said at once, instead of leaving the '
        'wall on "Connecting…" until the watchdog expires', () async {
      final go2rtc = await _FakeGo2rtc.start(_frames(forever: false));
      // A first-frame deadline long enough that expiring would take the test
      // with it: what is asserted here is that `onDone` is what answered.
      final session = _open(go2rtc.url, firstFrame: const Duration(seconds: 20));

      await _reaches(session, LiveVideoPhase.failed);

      expect(session.failure, 'go2rtc ended the stream');
    });

    test('a server that sends headers and no picture stays honestly on '
        'connecting, then fails at the first-frame deadline', () async {
      // go2rtc starts its ffmpeg transcode on demand and the first byte was
      // measured 2.10 s after the request (4.10 s cold), so "no picture yet"
      // has to read as a phase and not as a failure for at least that long.
      final go2rtc = await _FakeGo2rtc.start((wire) async {
        wire.head();
        await wire.flush();
      });
      final session = _open(go2rtc.url, firstFrame: const Duration(seconds: 1));

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(session.phase.value, LiveVideoPhase.connecting,
          reason: 'a slow start is not a failure');

      await _reaches(session, LiveVideoPhase.failed);
      expect(session.failure, 'go2rtc sent no picture in 1s');
    });

    test('a stream that goes silent after playing is failed by the watchdog, '
        'because multipart has no keepalive to miss', () async {
      final go2rtc = await _FakeGo2rtc.start((wire) async {
        wire.head();
        wire.send(_part(_jpeg));
        await wire.flush();
      });
      final session = _open(go2rtc.url,
          firstFrame: const Duration(seconds: 20),
          stall: const Duration(seconds: 1));

      await _reaches(session, LiveVideoPhase.playing);
      await _reaches(session, LiveVideoPhase.failed);

      expect(session.failure, 'go2rtc went quiet for 1s');
    });

    test('a malformed stream names the framing fault, so an operator is not '
        'left to guess between a bad camera and a bad parser', () async {
      final go2rtc = await _FakeGo2rtc.start((wire) async {
        wire.head();
        wire.send(ascii.encode('--frame\r\nContent-Type: image/jpeg\r\n\r\n'));
        wire.send(List.filled(64, 0));
        await wire.flush();
      });
      final session = _open(go2rtc.url, firstFrame: const Duration(seconds: 20));

      await _reaches(session, LiveVideoPhase.failed);

      expect(session.failure, startsWith('malformed multipart: '));
      expect(session.failure, contains('no Content-Length'));
    });
  });

  group('the picture on the wall', () {
    testWidgets('the view paints the frame that arrived, and keeps painting '
        'across the swap that disposes the one before it', (tester) async {
      // The one case that exercises the painter, and the one that would catch
      // the disposal order being wrong: drawing a `ui.Image` whose handle has
      // been disposed raises, and `takeException` is where that lands.
      late MjpegLiveVideoSession session;
      // `runAsync`, because inside `testWidgets` the zone's Timers are fake
      // and a real socket's bytes never arrive without it.
      await tester.runAsync(() async {
        final go2rtc = await _FakeGo2rtc.start(_frames(forever: true));
        session = _open(go2rtc.url);
        await _reaches(session, LiveVideoPhase.playing);
      });

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(width: 320, height: 180, child: session.view),
        ),
      ));

      expect(find.byType(CustomPaint), findsWidgets);
      final first = session.frame.value!;
      await tester.runAsync(
          () => _until(() => !identical(session.frame.value, first)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(first.debugDisposed, isTrue);
    });

    testWidgets('a session with no frame yet paints nothing rather than a '
        'stale picture or a spinner', (tester) async {
      // A spinner would never settle, so `pumpAndSettle` would hang every
      // widget test that opens a camera. The Popup's "Connecting to the
      // camera…" is a different widget entirely, and it is the Popup's.
      late MjpegLiveVideoSession session;
      await tester.runAsync(() async {
        final go2rtc = await _FakeGo2rtc.start((wire) async {
          wire.head();
          await wire.flush();
        });
        session = _open(go2rtc.url, firstFrame: const Duration(seconds: 20));
        // Let the connection actually establish. The subject here is a
        // *connected* stream that has sent no picture — go2rtc's 2.10 s of
        // ffmpeg startup — and tearing down a TCP connect that is still in
        // flight surfaces inside `dart:io` as a late `SocketException` that
        // fails the test after it has already passed.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 320, height: 180, child: session.view),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(CustomPaint), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('what a failure is allowed to say', () {
    test('a password pasted into GO2RTC_URL never reaches the failure text: '
        'the transport is reported by exception type', () async {
      // `SocketException`'s own message carries `address = …, port = …` and
      // `HttpException`'s carries `uri = …` whole — userinfo and all — which
      // is why nothing but the type is reproduced. This feature has leaked a
      // credential into a log three times; diagnostics/log.dart: **Never log
      // a secret**.
      final closed = await _closedPort();
      final session = MjpegLiveVideoSession(
          Uri.parse('http://admin:hunter2@127.0.0.1:$closed'
              '/api/stream.mjpeg?src=porch'),
          firstFrameTimeout: const Duration(seconds: 20));
      addTearDown(session.close);

      await _reaches(session, LiveVideoPhase.failed);

      expect(session.failure, 'the transport threw SocketException');
      expect(session.failure, isNot(contains('hunter2')));
      expect(session.failure, isNot(contains('127.0.0.1')));
      expect(session.failure, isNot(contains('$closed')));
    });

    test('a URL carrying a password still dials, and the failure it earns is '
        'still nameless', () async {
      // The same rule on the path where the server does answer: the URL
      // reaches the socket and nothing else.
      final go2rtc = await _FakeGo2rtc.start((wire) async {
        wire.head(401, 'Unauthorized');
        await wire.end();
      });
      final session = _open(go2rtc.url.replace(userInfo: 'admin:hunter2'));

      await _reaches(session, LiveVideoPhase.failed);

      expect(session.failure, 'go2rtc answered HTTP 401');
    });
  });

  group('holding on to nothing', () {
    test('the frame it replaces is disposed, so months on a wall do not leak '
        'one decoded picture every 60 ms', () async {
      final go2rtc = await _FakeGo2rtc.start(_frames(forever: true));
      final session = _open(go2rtc.url);

      await _reaches(session, LiveVideoPhase.playing);
      final first = session.frame.value!;
      await _until(() => !identical(session.frame.value, first),
          because: 'a second frame never arrived');

      expect(first.debugDisposed, isTrue);
      expect(session.frame.value!.debugDisposed, isFalse);
    });

    test('closing disposes the picture still on screen', () async {
      final go2rtc = await _FakeGo2rtc.start(_frames(forever: true));
      final session = _open(go2rtc.url);

      await _reaches(session, LiveVideoPhase.playing);
      final showing = session.frame.value!;
      session.close();

      expect(showing.debugDisposed, isTrue);
      expect(session.frame.value, isNull);
    });

    test('closing drops the connection, so go2rtc stops its on-demand '
        'transcode instead of feeding a Popup that is gone', () async {
      final go2rtc = await _FakeGo2rtc.start(_frames(forever: true));
      final session = _open(go2rtc.url);

      await _reaches(session, LiveVideoPhase.playing);
      expect(go2rtc.clientGone, isFalse, reason: 'still watching');
      session.close();

      await _until(() => go2rtc.clientGone,
          because: 'the far end never saw the connection go away — go2rtc '
              'would still be running ffmpeg for a Popup that is gone');
    });

    test('close is idempotent: the Popup can be dismissed by three routes and '
        'the deadline can fire during the fourth', () async {
      final go2rtc = await _FakeGo2rtc.start(_frames(forever: true));
      final session = _open(go2rtc.url);

      await _reaches(session, LiveVideoPhase.playing);
      session.close();
      session.close();
      session.close();

      expect(session.frame.value, isNull);
    });

    test('closing before the server ever answers leaves no phase change '
        'behind for a torn-down builder to receive', () async {
      final go2rtc = await _FakeGo2rtc.start((wire) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        wire.head();
        await wire.end();
      });
      final session =
          _open(go2rtc.url, firstFrame: const Duration(milliseconds: 100));

      session.close();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // Not `failed`: nothing failed, the Popup went away. A phase change
      // after `close` would reach a `ValueListenableBuilder` the framework
      // has already disposed.
      expect(session.phase.value, LiveVideoPhase.connecting);
      expect(session.failure, isNull);
    });
  });

  group('the endpoint', () {
    test('the seam\'s URL becomes this transport\'s path, and one stream name '
        'still serves both: no _mjpeg suffix reaches bindings.yaml', () {
      // go2rtc's `selftest` carries an h264 producer for MSE and an mjpeg
      // producer for this player under a single name — verified on the live
      // server — so the house's configuration names the stream once and the
      // player changes only the scheme and the path.
      const video = VideoConfig(go2rtcUrl: 'http://h:1984');

      expect(mjpegEndpointFor(video.urlFor('ring_doorbell')!).toString(),
          'http://h:1984/api/stream.mjpeg?src=ring_doorbell');
    });

    test('a go2rtc behind TLS is not downgraded to plain HTTP', () {
      const video = VideoConfig(go2rtcUrl: 'https://h:1984');

      expect(mjpegEndpointFor(video.urlFor('selftest')!).toString(),
          'https://h:1984/api/stream.mjpeg?src=selftest');
    });
  });
}

// ---------------------------------------------------------------------------

/// A 16x12 JPEG, 312 bytes.
///
/// Small enough to read as a literal and a real JPEG rather than a PNG
/// smuggled past a parser that does not look at content: half of what these
/// cases assert is that the *decoder* accepts what the framing handed it.
final _jpeg = base64Decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABQODxIPDRQSEBIXFR'
    'QYHjIhHhwcHj0sLiQySUBMS0dARkVQWnNiUFVtVkVGZIhlbXd7gYKBTmCNl4x9lnN+gXz/2w'
    'BDARUXFx4aHjshITt8U0ZTfHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fH'
    'x8fHx8fHx8fHx8fHz/wAARCAAMABADASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAABQ'
    'T/xAAZEAACAwEAAAAAAAAAAAAAAAAAAwIEUWH/xAAVAQEBAAAAAAAAAAAAAAAAAAAAAv/EAB'
    'kRAAIDAQAAAAAAAAAAAAAAAAAEAQIDIf/aAAwDAQACEQMRAD8AJTR4Xpo8EEphgglMMGjEkJ'
    'NW4f/Z');

/// One multipart part, byte for byte what go2rtc 1.9.10 sends.
List<int> _part(List<int> body) => [
      ...ascii.encode('--frame\r\n'
          'Content-Type: image/jpeg\r\n'
          'Content-Length: ${body.length}\r\n\r\n'),
      ...body,
      ...ascii.encode('\r\n'),
    ];

Stream<List<int>> _packets(List<List<int>> chunks) =>
    Stream.fromIterable(chunks);

/// A script that sends [_jpeg] as go2rtc would.
Future<void> Function(_Wire) _frames({required bool forever}) => (wire) async {
      wire.head();
      var sent = 0;
      while (forever || sent < 2) {
        if (wire.gone) return;
        wire.send(_part(_jpeg));
        await wire.flush();
        sent++;
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      await wire.end();
    };

/// A localhost server that writes go2rtc's bytes by hand.
///
/// A raw [ServerSocket] rather than an [HttpServer], for two things measured
/// on this host:
///
/// * `HttpResponse` buffers ~8 kB before anything reaches the wire and
///   `flush()` does not bypass it, so a fixture that sends one frame and then
///   waits — which is the whole of the stall and malformed-stream cases —
///   sends nothing at all and the player correctly reports silence.
/// * `HttpServer` swallows the write failure when the client hangs up, which
///   is the one signal the teardown case exists to observe. On a raw socket
///   the client's FIN arrives as `onDone`, immediately.
///
/// Writing the chunked framing by hand is a bonus rather than a cost: go2rtc
/// sends `Transfer-Encoding: chunked`, and this is what proves the player
/// leaves de-chunking to `HttpClient` instead of parsing chunk sizes itself.
class _FakeGo2rtc {
  _FakeGo2rtc._(this.url);

  final Uri url;

  /// Set the moment the far end closes or resets the connection — the local
  /// stand-in for go2rtc's `consumers` returning to `[]`.
  var clientGone = false;

  static Future<_FakeGo2rtc> start(Future<void> Function(_Wire) script) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeGo2rtc._(Uri.parse(
        'http://127.0.0.1:${server.port}/api/stream.mjpeg?src=selftest'));
    final live = <Socket>[];
    addTearDown(() async {
      for (final socket in live) {
        socket.destroy();
      }
      await server.close();
    });
    server.listen((socket) {
      live.add(socket);
      // The request itself is read and thrown away: what this fixture is for
      // is the response, and every case sends the same GET.
      socket.listen((_) {},
          onDone: () => fake.clientGone = true,
          onError: (Object _) => fake.clientGone = true,
          cancelOnError: true);
      // A write to a socket the client has abandoned surfaces here, and an
      // unhandled one takes down the whole test file.
      unawaited(socket.done.catchError((Object _) {
        fake.clientGone = true;
        return socket;
      }));
      unawaited(Future(() => script(_Wire(socket, fake))).catchError((_) {}));
    });
    return fake;
  }
}

/// The response side of one connection, in chunked encoding.
class _Wire {
  _Wire(this._socket, this._fake);

  final Socket _socket;
  final _FakeGo2rtc _fake;

  bool get gone => _fake.clientGone;

  void head([int status = 200, String reason = 'OK']) {
    _socket.add(ascii.encode('HTTP/1.1 $status $reason\r\n'
        'Content-Type: multipart/x-mixed-replace; boundary=frame\r\n'
        'Transfer-Encoding: chunked\r\n'
        'Cache-Control: no-cache\r\n'
        'Access-Control-Allow-Origin: *\r\n\r\n'));
  }

  void send(List<int> bytes) {
    _socket
      ..add(ascii.encode('${bytes.length.toRadixString(16)}\r\n'))
      ..add(bytes)
      ..add(const [13, 10]);
  }

  Future<void> flush() => _socket.flush();

  Future<void> end() async {
    _socket.add(ascii.encode('0\r\n\r\n'));
    await _socket.flush();
    await _socket.close();
  }
}

/// A port with nothing on it: bound to learn the number, then released.
Future<int> _closedPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

MjpegLiveVideoSession _open(Uri url,
    {Duration firstFrame = const Duration(seconds: 10),
    Duration stall = const Duration(seconds: 10)}) {
  final session = MjpegLiveVideoSession(url,
      firstFrameTimeout: firstFrame, stallTimeout: stall);
  addTearDown(session.close);
  return session;
}

Future<void> _reaches(LiveVideoSession session, LiveVideoPhase phase) =>
    _until(() => session.phase.value == phase,
        because: 'the phase never reached $phase '
            '(it is ${session.phase.value}, failure=${session.failure})');

/// Polls rather than listens, so one helper serves both a notifier and a flag
/// the fake server sets.
Future<void> _until(bool Function() done,
    {String because = 'the condition never held',
    Duration within = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail(because);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
