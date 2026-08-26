import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'live_video.dart';
import 'mjpeg_frames.dart';

/// True: this build has a player compiled into it.
///
/// It used to be `false` here, when everything that was not web showed a grey
/// box — and that was the wrong half of the seam to leave empty, because the
/// Flutter/cage kiosk **is** the wall (owner decision, 2026-08-04). Kept as a
/// const rather than deleted now that both branches answer true: it is the
/// one thing that tells a future third branch apart from these two, and the
/// seam test asserts it so that re-stubbing this file fails a test instead of
/// quietly costing the appliance its picture.
///
/// Whether the player can *run* is a separate, later question, and the answer
/// to it is [LiveVideoSession.phase], not this.
const liveVideoIsAvailable = true;

/// How long go2rtc has to produce a first picture.
///
/// Measured: go2rtc starts the ffmpeg transcode on demand, so time to first
/// byte is **2.10 s** warm and **4.10 s** cold, re-measured independently at
/// 2.096 / 2.110 / 2.145 s. Not the JPEG encode: `/api/stream.mp4`, which is
/// the untranscoded H.264 producer, costs the same 2.095–2.106 s over four
/// runs, one of them taken while an MSE session was already playing. The
/// browser's WebSocket path does not pay it (101 ms in real Chrome) and why
/// has not been measured, so nothing here is sized on an explanation.
///
/// **Twenty-five seconds since 2026-08-15, matching [kMseOpenTimeout], and
/// for the reason recorded there:** those numbers above are the `selftest`
/// pattern, and real cameras are slower by a lot. The Wyze fleet's cold time
/// to first frame is 4.6–5.2 s for the three plain v3s and **17.0–17.9 s**
/// for the two floodlight units, so fifteen failed working hardware by about
/// three seconds every time. The point of the margin is that a slow start
/// must show [LiveVideoPhase.connecting] honestly rather than be called a
/// failure.
///
/// The two branches are kept equal deliberately. They answer the same
/// question about the same producer, and a wall that gives up sooner than the
/// browser — or later — is a difference nobody would think to look for.
///
/// Note this deadline is not the floodlights' only problem on this transport:
/// a *cold* MJPEG request to one returns HTTP 200 and zero bytes because
/// go2rtc answers its own internal DESCRIBE before the upstream producer
/// knows its tracks. No timeout here can fix that; see Ch. 5 §2.2.1.
const kMjpegFirstFrameTimeout = Duration(seconds: 25);

/// How long a stream that *was* playing may go silent before it is failed.
///
/// The only liveness signal there is: HTTP multipart has no keepalive, so a
/// camera that stops and a network that dropped look identical until a
/// timeout says otherwise. Measured rate is **25 fps** — 25.1 fps over two
/// independent captures — so fifteen seconds is roughly 375 missing frames,
/// long past "a hiccup".
///
/// The 16.5 fps this arithmetic used to run on was retracted: it divided the
/// frame count by the whole request, idle transcode spin-up included, which
/// is the same error that produced the retracted ~124 kB/s figure (see
/// [MjpegLiveVideoSession] and `panel/README.md`). Steady-state rate is the
/// one that belongs here — the question this constant answers is what a
/// *playing* stream does when it goes quiet, and it is never asked before the
/// first picture, which [kMjpegFirstFrameTimeout] covers instead.
const kMjpegStallTimeout = Duration(seconds: 15);

/// How many parts in a row may fail to decode before the stream is failed.
///
/// Not one: a single corrupt JPEG in a stream that is otherwise fine should
/// cost one frame at 25 fps — 40 ms of picture — not the picture. Not
/// unbounded either, or a producer emitting something that is not JPEG at all
/// would leave the wall saying "Connecting to the camera…" forever, which is
/// the lie this whole phase enum exists to prevent.
const kMjpegUndecodableLimit = 10;

/// The MJPEG endpoint for the stream the seam named:
/// `ws://host:1984/api/ws?src=selftest` ->
/// `http://host:1984/api/stream.mjpeg?src=selftest`.
///
/// The mapping lives here, inside the file that implements the transport,
/// rather than in [VideoConfig.urlFor]. The Popup opens a stream and never
/// reads a byte of one, so which transport this build speaks is not its
/// business — and a per-platform `urlFor` would make every suite that asserts
/// what the Popup dialled assert two things and mean one.
///
/// The stream name is carried through untouched. go2rtc serves one stream
/// from two producers — `ffmpeg:virtual?video&size=640x480#video=h264` for
/// MSE and `ffmpeg:selftest#video=mjpeg` for this, verified on the live
/// server — so `bindings.yaml` names it once and no `_mjpeg` suffix
/// convention exists.
@visibleForTesting
Uri mjpegEndpointFor(Uri seamUrl) => seamUrl.replace(
      // `wss` is the only one that must become `https`; everything else this
      // can be handed — `ws`, or an `http` URL from a caller that skipped the
      // seam — is plain HTTP.
      scheme: seamUrl.scheme == 'wss' ? 'https' : 'http',
      path: '/api/stream.mjpeg',
    );

/// Opens go2rtc's MJPEG stream, or answers a session that is already failed.
///
/// Never throws, which is the whole reason for the `try`: the caller is a
/// `State.initState`, and an exception out of there costs the entire Dialog —
/// the Device name and the Close button with it — and leaves that State
/// half-built, so never disposed and never deregistered.
LiveVideoSession openLiveVideo(Uri url, {required String name}) {
  try {
    return MjpegLiveVideoSession(mjpegEndpointFor(url));
  } catch (error) {
    // The type, never the message. `ArgumentError` out of `HttpClient.getUrl`
    // quotes the URI it refused, and that URI is the one string here that a
    // fat-fingered `GO2RTC_URL` can have put a password into
    // (`diagnostics/log.dart`: **Never log a secret**).
    return SettledLiveVideoSession(LiveVideoPhase.failed,
        failure: 'the player would not start: ${error.runtimeType}');
  }
}

/// go2rtc's `multipart/x-mixed-replace` stream, decoded frame by frame.
///
/// MJPEG rather than MSE on the appliance because MSE is a browser API and
/// this build has no browser in it; rejected alternatives were an embedded
/// webview (a second rendering engine on a wall panel, for one rectangle) and
/// go2rtc's WebRTC (a whole ICE stack for a stream that never leaves the
/// LAN). What MJPEG costs is bandwidth — **~186 kB/s** measured at 640x480
/// (184.9 kB/s, 25.1 fps, 7.2 kB a frame, re-measured independently), on a
/// wire that is one box wide. That is ~1.5 Mbit on a LAN, and roughly seven
/// times what the H.264 producer behind MSE costs.
///
/// This used to say 124 kB/s. That figure was bytes divided by the whole
/// request including the ~2.1 s idle transcode spin-up, so it understated the
/// rate a network has to carry once frames are actually arriving; it is
/// retracted here, in `mjpeg_frames.dart` and in `panel/README.md`, and the
/// steady-state number is the one to size a wire against.
///
/// Public, and the timeouts are constructor parameters, because this is the
/// part of the feature with real risk in it and a private class can be
/// reasoned about but not interrogated. `test/live_video_mjpeg_test.dart`
/// drives it against a real socket on localhost that writes go2rtc's exact
/// bytes — and the whole of it has been run against the live go2rtc too.
class MjpegLiveVideoSession implements LiveVideoSession {
  MjpegLiveVideoSession(
    this._url, {
    this.firstFrameTimeout = kMjpegFirstFrameTimeout,
    this.stallTimeout = kMjpegStallTimeout,
  }) {
    _restartWatchdog(firstFrameTimeout,
        'go2rtc sent no picture in ${firstFrameTimeout.inSeconds}s');
    unawaited(_dial());
  }

  /// Read by exactly one line of code — the request. Never logged, never put
  /// in [failure], never rendered: this is the value `GO2RTC_URL` was pasted
  /// into and it is allowed to carry credentials.
  final Uri _url;

  final Duration firstFrameTimeout;
  final Duration stallTimeout;

  final _phase = ValueNotifier(LiveVideoPhase.connecting);
  final _frame = ValueNotifier<ui.Image?>(null);
  final _client = HttpClient();

  StreamSubscription<Uint8List>? _frames;
  Timer? _watchdog;
  var _closed = false;
  var _decoding = false;
  var _undecodable = 0;

  @override
  ValueListenable<LiveVideoPhase> get phase => _phase;

  @override
  String? failure;

  /// Built once. The Popup rebuilds this getter on every phase change, and a
  /// fresh widget each time would drop the [ValueListenableBuilder]'s
  /// subscription and remount the painter for no reason.
  @override
  late final Widget view = _MjpegView(frame: _frame);

  /// The picture currently on screen — owned by this session, which disposes
  /// it the moment the next one lands.
  ///
  /// Exposed, rather than left private behind [view], so that the disposal
  /// can be *asserted*: "one decoded frame leaked per 60 ms" is invisible
  /// from outside for exactly as long as the panel takes to run out of
  /// memory, which on a wall is weeks. `ui.Image.debugDisposed` is the only
  /// witness there is, and it needs a handle on the image to ask.
  ValueListenable<ui.Image?> get frame => _frame;

  Future<void> _dial() async {
    try {
      final response = await (await _client.getUrl(_url)).close();
      if (_closed) return;
      if (response.statusCode != HttpStatus.ok) {
        // go2rtc answers 404 for a name it does not have. The number, not the
        // body: the body is go2rtc's prose and this is one place it is not
        // needed to say what went wrong.
        await response.drain<void>();
        _fail('go2rtc answered HTTP ${response.statusCode}');
        return;
      }
      _frames = mjpegFrames(response).listen(
        _onFrame,
        onError: (Object error) => _fail(_describe(error)),
        // Not silence: go2rtc closing the body is the shape a stream that
        // died takes, and a wall left on "Connecting to the camera…" until
        // the watchdog expires would be fifteen seconds of not saying so.
        onDone: () => _fail('go2rtc ended the stream'),
        cancelOnError: true,
      );
    } catch (error) {
      _fail(_describe(error));
    }
  }

  /// A failure sentence that cannot contain the URL.
  ///
  /// [MjpegFormatException] has its own type precisely so its message — which
  /// `mjpeg_frames.dart` builds out of counts and nothing else — can be
  /// reproduced while no other exception's can. `dart:io` appends
  /// `uri = <the URL>` to `HttpException` and `SocketException` messages, and
  /// `ArgumentError` quotes it too, so everything else is reported by type
  /// alone (`diagnostics/log.dart`: **Never log a secret**).
  String _describe(Object error) => error is MjpegFormatException
      ? 'malformed multipart: ${error.message}'
      : 'the transport threw ${error.runtimeType}';

  void _onFrame(Uint8List jpeg) {
    if (_closed) return;
    // Arrival, not decode, is the liveness signal: bytes are what prove the
    // far end is alive, and a stream of parts this build cannot decode is a
    // different fault with a different message (see [_undecodable]).
    _restartWatchdog(
        stallTimeout, 'go2rtc went quiet for ${stallTimeout.inSeconds}s');
    // Dropped, not queued. Decoding is asynchronous and go2rtc does not wait:
    // a panel that fell behind at 25 fps would grow an unbounded queue of
    // pictures that are already stale by the time they are drawn, which is
    // both a leak and the wrong image. The newest frame is the only one worth
    // having.
    if (_decoding) return;
    _decoding = true;
    unawaited(_decode(jpeg));
  }

  Future<void> _decode(Uint8List jpeg) async {
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      try {
        _show((await codec.getNextFrame()).image);
      } finally {
        codec.dispose();
      }
      _undecodable = 0;
    } catch (_) {
      // Deliberately not reported per frame: the message would be the image
      // decoder's, once every 60 ms, into journald on a box with no operator
      // in front of it. The count is what turns "one bad frame" into a fault.
      if (++_undecodable >= kMjpegUndecodableLimit) {
        _fail('$kMjpegUndecodableLimit parts in a row were not decodable '
            'images');
      }
    } finally {
      _decoding = false;
    }
  }

  void _show(ui.Image image) {
    if (_closed) {
      image.dispose();
      return;
    }
    final previous = _frame.value;
    _frame.value = image;
    // Disposed the instant it is replaced, not at teardown: a wall panel runs
    // for months and this arrives ~25 times a second, so holding even one
    // extra decoded frame per swap is a real leak rather than a theoretical
    // one. Safe in this order for the reason `ImageStreamCompleter.setImage`
    // is — the engine keeps its own reference to anything already drawn into
    // a Picture, and the swap above happens between frames, so no painter
    // that still names [previous] can run after this line.
    previous?.dispose();
    if (_phase.value == LiveVideoPhase.connecting) {
      _phase.value = LiveVideoPhase.playing;
    }
  }

  void _restartWatchdog(Duration after, String reason) {
    _watchdog?.cancel();
    _watchdog = Timer(after, () => _fail(reason));
  }

  void _fail(String reason) {
    if (_closed || _phase.value == LiveVideoPhase.failed) return;
    failure = reason;
    _phase.value = LiveVideoPhase.failed;
    // Before the notifier settles: go2rtc keeps the on-demand ffmpeg
    // transcode running for as long as a consumer is attached, and a session
    // nobody is going to watch is still a consumer.
    _release();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _release();
    final image = _frame.value;
    _frame.value = null;
    image?.dispose();
    // The two notifiers are deliberately not disposed. The Popup's
    // `ValueListenableBuilder` removes its listener from its own `dispose`,
    // which the framework may run after this call, and a disposed
    // `ChangeNotifier` throws on `removeListener`.
  }

  void _release() {
    _watchdog?.cancel();
    _watchdog = null;
    final frames = _frames;
    _frames = null;
    // Cancelling a subscription whose connection is being torn out from under
    // it can complete with an error there is nothing to do about, and an
    // unhandled one would surface as a test failure in an unrelated suite.
    if (frames != null) unawaited(frames.cancel().catchError((Object _) {}));
    // `force`, because a graceful close waits for the response to end and
    // this response never ends. A raw-socket probe shows our own connection
    // gone at once from every state, so this is the whole of what the Panel
    // can do — but "the stream's `consumers` returns to `[]` immediately",
    // which this comment used to claim, is only true of a session that
    // reached [LiveVideoPhase.playing]: measured, that is under a second.
    //
    // Closing *during* the ~2 s connect measures differently. go2rtc's
    // on-demand `ffmpeg:selftest#video=mjpeg` producer is itself counted as a
    // consumer of the stream, and it finishes spinning up regardless, so
    // `consumers` **rises after** this call and takes 2–10 s to reach `[]`
    // (0 ms close: 1 consumer at +1 s and +2 s, 0 at +3 s; 50 ms close: still
    // 1 at +5 s, 0 at +10 s). The attribution to the transcode is inference;
    // the timings are measured against the live server.
    //
    // Nothing is done about it here, deliberately: the residue is a producer
    // this process does not own and cannot cancel, and go2rtc idles it out on
    // its own. What it costs is a few seconds of transcode after a Popup that
    // was dismissed before it ever showed a picture — see
    // `kDoorbellPopupCeiling` in `ui/doorbell_popup_host.dart`, whose #177014
    // argument is about how old a *Ring* session may get and is untouched by
    // a few seconds of local transcode, but which a reader may otherwise
    // expect to bound this too. "The session is torn down" there means the
    // Panel's end of it, which is what that argument needs and all this can
    // promise.
    _client.close(force: true);
  }
}

/// Paints whatever frame arrived last, and nothing at all before the first.
class _MjpegView extends StatelessWidget {
  const _MjpegView({required this.frame});

  final ValueListenable<ui.Image?> frame;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ui.Image?>(
        valueListenable: frame,
        builder: (context, image, _) => image == null
            ? const SizedBox.expand()
            : CustomPaint(size: Size.infinite, painter: _FramePainter(image)),
      );
}

/// A [CustomPainter] rather than a [RawImage] on purpose.
///
/// `RenderImage` takes ownership of the [ui.Image] handed to it and disposes
/// the one it replaces — so with `RawImage` the session and the render object
/// would both dispose every frame, and a double dispose is an assertion, not
/// a leak. Painting it here leaves ownership entirely with the session, which
/// is the object that knows when the next frame arrived.
class _FramePainter extends CustomPainter {
  const _FramePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    // `contain`, so a 640x480 camera in the Popup's 16:9 box is letterboxed
    // rather than cropped: what a doorbell is for is the edges of its field
    // of view, and `cover` would cut exactly those off.
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      !identical(oldDelegate.image, image);
}
