import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_keepalive.dart';
import 'package:panel/ui/video/live_video_rtsp_io.dart';
import 'package:video_player/video_player.dart';

import 'support/fake_go2rtc.dart';
import 'support/session_world.dart';

/// The video seam's contract, run against every adapter this binary can
/// host.
///
/// `LiveVideoSession` has five adapters in `lib` and one in `test`, and until
/// 2026-09-03 its six invariants were pinned adapter-by-adapter across five
/// files — each in its own words, each covering a different subset, and the
/// fake that the Popup, doorbell, Director and Cameras suites all drive held
/// to none of them. This is where "the seam is real" is cashed out: each
/// invariant is stated once, in `live_video.dart`, and executed once per
/// world.
///
/// **Not here:** the MSE player, which no VM build compiles — the
/// conditional import hands the VM the MJPEG one. Its world lives in
/// `live_video_contract_web_test.dart` and runs only under
/// `flutter test --platform chrome`, which hangs in this devcontainer today
/// (`README.md`; `hub/dev/go2rtc/DEBUGGING.md` names repairing the runner as
/// worth more than any individual patch). That is a gap, and it is named
/// rather than papered over.
void main() {
  runSessionContract('SettledLiveVideoSession', _settledWorld,
      noFailureText: 'a settled session is handed its sentence at '
          'construction; it composes none',
      noOpener: 'constructed directly — it IS what an opener answers with');
  runSessionContract('FakeLiveVideoSession', _fakeWorld,
      noFailureText: 'the fake\'s failure words are the test\'s own, so '
          'there is nothing of the adapter\'s to check them against',
      noOpener: 'FakeGo2rtc.open cannot fail; there is no broken world');
  runSessionContract('MjpegLiveVideoSession', _mjpegWorld);
  runSessionContract('RtspLiveVideoSession', _rtspWorld,
      noOpener: '`rtspOpener` is safe to call here since 2026-09-03 (fvp '
          'registration moved to `main()`), but it still cannot satisfy this '
          'invariant: it hands back a live session whose dial fails '
          'asynchronously against an unimplemented platform, and what is '
          'asserted here is a session ALREADY failed when the opener '
          'returns. The no-throw half stays pinned in '
          '`live_video_rtsp_test.dart`');
  runSessionContract('LiveVideoKeepAlive lease', _leaseWorld,
      noFailureText: 'the lease passes the inner session\'s failure through '
          'verbatim; the words are the player\'s, checked in its own world');
}

/// A session that was over before it began — what both players answer
/// instead of throwing. It cannot reach playing and it composes no failure
/// text, so what it carries is what every adapter owes whatever else it
/// does: a stable view, a `setMuted` that no-ops in any phase, and a close
/// that can be called four times. Case 6 holds vacuously here — its phase
/// cannot change at all — and that is the honest shape of this adapter
/// rather than a gap to paper over.
Future<SessionWorld> _settledWorld() async {
  LiveVideoSession? session;
  return (
    open: () async =>
        session = SettledLiveVideoSession(LiveVideoPhase.failed,
            failure: 'go2rtc refused'),
    reachPlaying: null,
    fail: null,
    connectionOpen: null,
    muted: null,
    openBroken: null,
    forbiddenInFailure: const <String>[],
    dispose: () async => session?.close(),
  );
}

/// The fake four widget suites drive. It has no opener of its own and its
/// failure words are the test's, so it carries the four invariants that are
/// about *shape* — and carrying them is the point: a fake that drifts from
/// the players it stands in for makes every suite above it a lie.
Future<SessionWorld> _fakeWorld() async {
  final go2rtc = FakeGo2rtc();
  return (
    open: () async =>
        go2rtc.open(Uri.parse('ws://hub:1984/api/ws?src=porch'), name: 'porch'),
    reachPlaying: () async => go2rtc.only.plays(),
    // Words the test chose, which is why invariant 1 is exempt here — but a
    // real transition, which invariant 6 needs.
    fail: () async => go2rtc.only.fails('a staged refusal'),
    connectionOpen: () => go2rtc.only.closes == 0,
    muted: () => go2rtc.only.muted,
    openBroken: null,
    forbiddenInFailure: const <String>[],
    dispose: () async {},
  );
}

/// The appliance player, against a real socket on localhost writing go2rtc's
/// exact bytes — the rig `live_video_mjpeg_test.dart` proved the transport
/// with, driven here through the seam instead of through the multipart.
///
/// The URL carries a password on purpose: it is the canary for invariant 1,
/// and the fake server ignores credentials like the real one does.
Future<SessionWorld> _mjpegWorld() async {
  final server = await _StubGo2rtc.start();
  MjpegLiveVideoSession? session;
  return (
    open: () async {
      final opened = session = MjpegLiveVideoSession(
        server.url.replace(userInfo: 'admin:hunter2'),
        // Long enough that no case here can be decided by a deadline: what
        // is being pinned is the contract, not the watchdogs.
        firstFrameTimeout: const Duration(seconds: 20),
        stallTimeout: const Duration(seconds: 20),
      );
      await server.headersSent;
      return opened;
    },
    reachPlaying: () async {
      server.sendFrame();
      await _settle(() => session!.phase.value == LiveVideoPhase.playing);
    },
    // The far end vanishing mid-body, not a graceful end: `dart:io` reports
    // a truncated chunked body as an `HttpException` whose message carries
    // `uri = …` whole, userinfo included. That is the one staging in which
    // invariant 1's canary can sing — a clean end earns the player's own
    // string literal, which could never have held a URL.
    fail: () async => server.abort(),
    connectionOpen: () => !server.clientGone,
    muted: null, // multipart JPEG carries no audio at all.
    // A URL with no host at all: refused before the opener returns, which
    // is what invariant 5 reads. A dead port would not do — the request goes
    // out from an unawaited `_dial`, so the refusal lands long after.
    openBroken: () => openLiveVideo(Uri.parse('ws:'), name: 'porch'),
    forbiddenInFailure: [
      'hunter2',
      '127.0.0.1',
      '${server.url.port}',
    ],
    dispose: () async {
      session?.close();
      await server.stop();
    },
  );
}

/// The shipped appliance transport, over the controller the RTSP suite
/// drives by hand — fvp is not built for VM runs, and the seam's contract is
/// about the session, not about libmdk.
Future<SessionWorld> _rtspWorld() async {
  final controller = _FakeController();
  RtspLiveVideoSession? session;
  return (
    open: () async {
      final opened = session = RtspLiveVideoSession(
        Uri.parse('rtsp://admin:hunter2@127.0.0.1:8554/selftest'),
        firstFrameTimeout: const Duration(seconds: 20),
        stallTimeout: const Duration(seconds: 20),
        controllerFor: (_) => controller,
      );
      // Let initialize land here rather than at reachPlaying: the volume the
      // session chose for itself is only on the record afterwards, and the
      // birth witness has to be able to read it.
      controller.finishInitialize();
      await Future<void>.delayed(Duration.zero);
      return opened;
    },
    reachPlaying: () async {
      controller.showPosition(const Duration(milliseconds: 100));
      await _settle(() => session!.phase.value == LiveVideoPhase.playing);
    },
    // The player reporting an error is this transport's refusal: the
    // controller says so through its value, and the session composes the
    // sentence — which is what invariant 1 reads.
    fail: () async =>
        controller.reportError('rtsp://admin:hunter2@127.0.0.1:8554 refused'),
    connectionOpen: () => !controller.disposed,
    // An actual observation, not "never set": the empty list must not read
    // as silence, or a player that skipped the volume entirely would pass.
    muted: () => controller.volumes.isNotEmpty && controller.volumes.last == 0,
    openBroken: null,
    forbiddenInFailure: const ['hunter2', '127.0.0.1', '8554'],
    dispose: () async => session?.close(),
  );
}

/// The pool's lease — the adapter every surface on the wall actually holds,
/// because `main()` composes `VideoConfig.open` out of the keep-alive.
///
/// Exempt from one half of invariant 4 and from it alone: its close hands
/// the running session back for `kLiveVideoLinger` instead of dropping the
/// connection, which is the whole reason the class exists (issue #1) and
/// which `live_video.dart` names as the caller-visible exception. Everything
/// else it owes in full.
Future<SessionWorld> _leaseWorld() async {
  final go2rtc = FakeGo2rtc();
  final pool = LiveVideoKeepAlive(opener: go2rtc.open);
  LiveVideoSession? session;
  return (
    open: () async => session =
        pool.open(Uri.parse('ws://hub:1984/api/ws?src=porch'), name: 'porch'),
    reachPlaying: () async => go2rtc.only.plays(),
    // The inner session's words, passed through verbatim — which is why
    // invariant 1 is exempt here and lives in the player's own world.
    fail: () async => go2rtc.only.fails('a staged refusal'),
    connectionOpen: null,
    muted: () => go2rtc.only.muted,
    openBroken: () => LiveVideoKeepAlive(
            opener: (url, {required name}) => throw StateError('no socket'))
        .open(Uri.parse('ws://hub:1984/api/ws?src=x'), name: 'x'),
    forbiddenInFailure: const <String>[],
    dispose: () async {
      session?.close();
      pool.dispose();
    },
  );
}

Future<void> _settle(bool Function() done) async {
  for (var i = 0; i < 3000; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('the world never reached the state the contract staged');
}

/// go2rtc's response side, scripted by the case rather than by a fixture: the
/// contract needs a server it can hold open, feed one frame, and end on
/// demand, which the per-case scripts in `live_video_mjpeg_test.dart` cannot
/// express.
class _StubGo2rtc {
  _StubGo2rtc._(this._server, this.url);

  final ServerSocket _server;
  final Uri url;

  Socket? _socket;
  final _headers = Completer<void>();
  var clientGone = false;

  Future<void> get headersSent => _headers.future;

  static Future<_StubGo2rtc> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final stub = _StubGo2rtc._(
        server,
        Uri.parse(
            'http://127.0.0.1:${server.port}/api/stream.mjpeg?src=selftest'));
    server.listen((socket) {
      stub._socket = socket;
      socket.listen((_) {},
          onDone: () => stub.clientGone = true,
          onError: (Object _) => stub.clientGone = true,
          cancelOnError: true);
      unawaited(socket.done.catchError((Object _) {
        stub.clientGone = true;
        return socket;
      }));
      socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
          'Content-Type: multipart/x-mixed-replace; boundary=frame\r\n'
          'Transfer-Encoding: chunked\r\n\r\n'));
      unawaited(socket.flush().then((_) {
        if (!stub._headers.isCompleted) stub._headers.complete();
      }).catchError((Object _) {}));
    });
    return stub;
  }

  void sendFrame() {
    final body = <int>[
      ...ascii.encode('--frame\r\nContent-Type: image/jpeg\r\n'
          'Content-Length: ${_jpeg.length}\r\n\r\n'),
      ..._jpeg,
      ...ascii.encode('\r\n'),
    ];
    _chunk(body);
    unawaited(_socket?.flush().catchError((Object _) {}));
  }

  /// Hangs up mid-stream, leaving the chunked body truncated.
  void abort() => _socket?.destroy();

  void _chunk(List<int> bytes) => _socket
    ?..add(ascii.encode('${bytes.length.toRadixString(16)}\r\n'))
    ..add(bytes)
    ..add(const [13, 10]);

  Future<void> stop() async {
    _socket?.destroy();
    await _server.close();
  }
}

/// The smallest thing `ui.decodeImageFromList` accepts: a 1×1 JPEG.
final _jpeg = Uint8List.fromList(base64Decode(
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
    'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA'
    'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=='));

/// The player as the adapter assumes it, subclassed so the adapter's type
/// stays honest — a deliberate copy of `live_video_rtsp_test.dart`'s fake,
/// trimmed to the lifecycle the contract drives (no `failInitialize`, no
/// `played`). Sharing it would mean a `test/support` type carrying the union
/// of two suites' needs; the copy is the smaller lie, and CLAUDE.md's
/// same-shape-twice rule is the argument for revisiting that if a third
/// suite ever drives this transport.
class _FakeController extends VideoPlayerController {
  _FakeController() : super.networkUrl(Uri.parse('rtsp://fake:8554/x'));

  final _init = Completer<void>();
  final volumes = <double>[];
  var disposed = false;

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> initialize() async {
    await _init.future;
    value = value.copyWith(isInitialized: true);
  }

  void finishInitialize() => _init.complete();

  @override
  Future<void> play() async {}

  void showPosition(Duration position) =>
      value = value.copyWith(isInitialized: true, position: position);

  void reportError(String description) =>
      value = value.copyWith(errorDescription: description);

  @override
  // ignore: must_call_super
  Future<void> dispose() async => disposed = true;
}
