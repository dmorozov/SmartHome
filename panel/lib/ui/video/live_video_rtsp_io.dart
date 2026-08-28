import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, TextureBox;
import 'package:flutter/scheduler.dart' show SchedulerBinding, Ticker;
import 'package:flutter/widgets.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player/video_player.dart';

import '../../diagnostics/log.dart';
// `kMjpegFirstFrameTimeout`/`kMjpegStallTimeout` arrive through
// `live_video.dart`'s own export of the platform branch.
import 'live_video.dart';

/// go2rtc's RTSP restream listener. A different port than the API's 1984 —
/// the adapter's own constant, exactly as the MJPEG path owns
/// `/api/stream.mjpeg`: which port a transport speaks is the transport's
/// business, not the seam's.
const kRtspRestreamPort = 8554;

/// The seam's deadlines, restated for this transport on the MJPEG file's
/// own argument: the branches "answer the same question about the same
/// producer, and a wall that gives up sooner than the browser — or later —
/// is a difference nobody would think to look for". 25 s to a first
/// picture (a cold floodlight main measured 3.9 s on this path, but the
/// margin is what keeps a slow start honest-connecting rather than
/// called a failure), 15 s of frozen picture before a playing stream is
/// failed.
const kRtspFirstFrameTimeout = kMjpegFirstFrameTimeout;
const kRtspStallTimeout = kMjpegStallTimeout;

/// The RTSP endpoint for the stream the seam named:
/// `ws://host:1984/api/ws?src=selftest` -> `rtsp://host:8554/selftest`.
///
/// The mapping lives here, inside the file that implements the transport,
/// for `mjpegEndpointFor`'s stated reason. Always plain `rtsp` — 8554 is
/// go2rtc's cleartext restream listener whatever scheme the API URL wore —
/// and **userInfo is stripped**: `GO2RTC_URL` is allowed to carry
/// credentials (`api.username`/`api.password` are real go2rtc settings),
/// they authenticate the API, not the restream, and this URL reaches a
/// native player whose error strings this file does not control.
@visibleForTesting
Uri rtspEndpointFor(Uri seamUrl) => Uri(
  scheme: 'rtsp',
  host: seamUrl.host,
  port: kRtspRestreamPort,
  path: '/${seamUrl.queryParameters['src'] ?? ''}',
);

var _fvpRegistered = false;

/// The decoder priority list handed to fvp, or null to keep fvp's own.
///
/// **Set this before the first [openRtspVideo], from `main()` and nowhere
/// else** — fvp is registered once per process, so a later change is
/// ignored. It is a variable rather than a constant for the reason
/// `VIDEO_TRANSPORT` is: which decoder a given wall can actually use is an
/// operational fact about that machine, not a property of the binary, and
/// finding out costs a person standing in front of the screen.
///
/// **The shipped default is software, and that is a precaution rather than
/// a proven fix — say so honestly.** fvp's own Linux list prefers hardware
/// (`['VAAPI', 'CUDA', 'VDPAU', 'hap', 'FFmpeg', 'dav1d']`), and pinning
/// `FFmpeg` was the first attempt at the broken wall of 2026-08-26. It did
/// not fix it. The two causes that did were [rtspLowLatency] (a dropped key
/// frame, which is what the macroblocks were) and [rtspFramePulse] (a
/// retained texture layer, which is what the frozen pictures were). Hardware
/// decoding was never actually convicted of anything.
///
/// It stays software for now because the one property worth having here is
/// that a broken *picture* is indistinguishable from a broken *camera* to
/// whoever is looking at the wall, and this house's cameras break often
/// enough on their own; software decode is the path with no driver roulette
/// across the dev box's Intel+NVIDIA and the appliance's AMD.
///
/// Affordable at this size: a tile is 640×360 and the grid is six of them —
/// the phase-8 prototype measured about half a core for six streams
/// *including* software GL rendering under Xvfb. **`VIDEO_DECODERS=auto` is
/// worth a run now that the real faults are fixed**: if the picture holds,
/// hardware decoding buys the appliance back a core it would rather spend on
/// something else.
List<String>? rtspVideoDecoders = const ['FFmpeg'];

/// fvp's `lowLatency`, and **the shipped value is 0 — off — because 1
/// visibly corrupts this wall.**
///
/// Set alongside [rtspVideoDecoders], from `main()`, before the first open.
///
/// This was 1 from the day the transport landed, on the reasonable-sounding
/// argument that a live wall wants no buffering. What that actually buys is
/// spelled out in fvp's own source, one line above where it applies it:
///
/// ```dart
/// // +nobuffer: the 1st key-frame packet is dropped. -nobuffer: high latency
/// player.setProperty('avformat.fflags', '+nobuffer');
/// ```
///
/// **It drops the first key frame.** H.264 is differential, so a decoder
/// handed the packets after an IDR but not the IDR itself has nothing to
/// reference: it paints garbage and keeps painting garbage until the camera
/// sends another key frame, which on a long-GOP Wyze substream is a long
/// time and — with errors propagating — sometimes never resolves. That is
/// the wall of macroblocks seen on 2026-08-26, and it is why the identical
/// substreams decoded perfectly under plain `ffmpeg`, which drops nothing,
/// and why swapping decoders only changed what the mess looked like.
///
/// Every value above 0 sets that flag, so **0 is the only safe setting**;
/// `VIDEO_LOW_LATENCY=1` exists to reproduce the fault, not to tune it. The
/// price of 0 is mdk's ordinary network buffering — a slower first frame and
/// some delay behind real time — which is a trade this house can make
/// happily, a picture being worth more than a second.
int rtspLowLatency = 0;

/// Whether a playing stream keeps the engine drawing frames.
///
/// **This is a workaround for the embedder, not a feature**, and it is on by
/// default because without it the wall does not move. Measured 2026-08-26 on
/// the Hub (GNOME on **Wayland**, rendering on the Intel iGPU): the camera
/// grid updated its pictures *only while being scrolled*, and sat on a stale
/// frame the moment the finger stopped.
///
/// Not the decoder, not the stream and not the plugin. The same substreams
/// software-decoded flawlessly under `ffmpeg`, and the **web build plays
/// them perfectly** — a browser's `<video>` element paints itself, which is
/// what narrows this to the Linux texture path. fvp does its part too,
/// calling `fl_texture_registrar_mark_texture_frame_available()` from mdk's
/// render callback for every frame.
///
/// The mechanism is one line of Flutter's own rendering layer:
///
/// ```dart
/// class TextureBox extends RenderBox {
///   bool get isRepaintBoundary => true;   // its own retained layer
/// ```
///
/// **A `Texture` is its own repaint boundary.** Nothing above it can dirty
/// it, so its `TextureLayer` is retained across frames and the engine
/// re-uses the layer it already has. Drawing more frames does not help —
/// measured: an idle [Ticker] that merely asked for a frame every vsync
/// changed nothing at all, because every one of those frames re-used the
/// same retained layer. Scrolling works because it changes the transform
/// *above* the texture, which forces the scene to be rebuilt and the
/// texture resolved again.
///
/// So [_FramePulse] reaches the `TextureBox` itself and calls
/// `markNeedsPaint()` on it once per vsync, which rebuilds its layer and
/// re-resolves the texture. It costs one small repaint boundary per frame
/// for as long as a stream is on screen — which is what showing live video
/// costs anyway — and it stops when the session closes or `TickerMode` goes
/// false under a covering route.
///
/// `VIDEO_REPAINT_PULSE=off` turns it off, which is how to check whether a
/// given machine needs it: if the picture still moves, that embedder is
/// delivering texture frames on its own and this is dead weight there.
bool rtspFramePulse = true;

/// Whether the pulse also nudges the texture's *transform* each frame.
///
/// `VIDEO_REPAINT_PULSE=jiggle`. A sub-pixel vertical translate, alternating
/// between 0 and 0.01 logical pixels — invisible, and deliberately the one
/// thing that is known to work on this wall.
///
/// The evidence it is built on: with the pulse running properly, an idle
/// screen and a scrolled screen produce **numerically identical** debug
/// lines — `ticks≈60 frames≈60 pos≈+1000ms paint=clean` in both — yet the
/// picture moves only while scrolling. Nothing measurable from Dart
/// separates the two cases. What scrolling changes that a repaint does not
/// is the *geometry* of the layers above the texture, which is what this
/// reproduces on purpose.
///
/// If this works and [rtspFramePulse]'s `markNeedsPaint` does not, the fault
/// is a cached raster being reused for a subtree whose contents changed —
/// and this is a genuinely ugly workaround for it, kept only until the real
/// answer comes back from upstream.
bool rtspFrameJiggle = false;

/// Once-per-second instrumentation of the render path, `VIDEO_DEBUG=on`.
///
/// Off by default because it writes a line per second per playing stream.
/// Turn it on when the wall shows a picture that will not move, and read the
/// line as a chain — the first field that is wrong is where to look:
///
/// ```
/// I video.pulse name=wyze_back_yard_sub ticks=60 frames=60 pos=+1000ms
///                tex=id42 paint=clean
/// ```
///
/// * `ticks` — pulses in the last second. 0 means the [Ticker] is not
///   running (a muted `TickerMode`, or [rtspFramePulse] off).
/// * `frames` — frames the *engine* actually rasterised, counted through
///   `SchedulerBinding.addTimingsCallback`. 0 with non-zero ticks means the
///   scheduler is asking and the engine is not drawing.
/// * `pos` — how far the player's clock moved. 0 means no decoding, so the
///   problem is upstream of rendering entirely.
/// * `tex` — the `TextureBox` this pulse found, and its texture id, or
///   `none` if the walk found no texture to repaint.
/// * `paint` — whether that box was still marked dirty when the line was
///   written. `dirty` means `markNeedsPaint()` is being called and paint is
///   never running. Needs asserts, so a `--debug` run; otherwise `n/a`.
///
/// The honest reading: `ticks=60 frames=60 pos=+1000ms tex=id42 paint=clean`
/// and a frozen picture means every layer of Flutter did its job and the
/// texture still did not update — which puts it below Dart, in the embedder
/// or the plugin, and no amount of widget code will fix it.
bool rtspVideoDebug = false;

/// Frames the engine rasterised, counted for [rtspVideoDebug]. Global
/// because it is a property of the process, not of one stream.
var _engineFrames = 0;
var _timingsHooked = false;

void _hookFrameTimings() {
  if (_timingsHooked) return;
  _timingsHooked = true;
  SchedulerBinding.instance.addTimingsCallback(
    (timings) => _engineFrames += timings.length,
  );
}

/// Opens go2rtc's RTSP restream through fvp, or answers a session that is
/// already failed. Never throws — `openLiveVideo`'s contract, kept for its
/// stated reason (the caller is a `State.initState`).
LiveVideoSession openRtspVideo(Uri url, {required String name}) {
  try {
    if (!_fvpRegistered) {
      // Swaps video_player's platform implementation for fvp (libmdk),
      // process-wide, once. RTSP-over-TCP is fvp's own default (it sets
      // `avformat.rtsp_transport: tcp` per player), which is also this
      // house's rule: RTSPS/TCP everywhere upstream.
      _fvpRegistered = true;
      final decoders = rtspVideoDecoders;
      fvp.registerWith(
        options: {
          'lowLatency': rtspLowLatency,
          // Omitted entirely when null, so "let fvp choose" stays reachable
          // and is not spelled as an empty list fvp would read as "nothing".
          'video.decoders': ?decoders,
        },
      );
      Log.info('panel', 'video_player', {
        'decoders': decoders == null ? 'fvp_default' : decoders.join(','),
        'low_latency': rtspLowLatency,
        'repaint_pulse': rtspFramePulse ? 'on' : 'off',
      });
    }
    return RtspLiveVideoSession(rtspEndpointFor(url));
  } catch (error) {
    // The type, never the message — `mjpegEndpointFor`'s twin, same rule
    // (`diagnostics/log.dart`: **Never log a secret**).
    return SettledLiveVideoSession(
      LiveVideoPhase.failed,
      failure: 'the player would not start: ${error.runtimeType}',
    );
  }
}

/// go2rtc's H.264 restream, played by fvp into a Flutter Texture.
///
/// What this transport buys over MJPEG, measured 2026-08-26 against the
/// live Hub: no per-stream ffmpeg transcode (go2rtc 35 % CPU / 117 MiB
/// serving six RTSP copies vs 52 % / 573 MiB for five MJPEG tiles), no
/// per-frame JPEG decode in the Panel, and a cold floodlight main that
/// simply waits out the producer start (1080p in 3.9 s — no zero-byte
/// race, which was an artifact of go2rtc answering an MJPEG GET before the
/// upstream producer knew its tracks).
///
/// Public with constructor-injectable deadlines and controller factory,
/// for `MjpegLiveVideoSession`'s stated reason: this is the part with real
/// risk in it, and a class that cannot be interrogated cannot be tested.
/// The hermetic suite drives a fake controller through every contract; the
/// opt-in live suite drives the real player against a real go2rtc.
class RtspLiveVideoSession implements LiveVideoSession {
  RtspLiveVideoSession(
    Uri url, {
    this.firstFrameTimeout = kRtspFirstFrameTimeout,
    this.stallTimeout = kRtspStallTimeout,
    VideoPlayerController Function(Uri url)? controllerFor,
  }) : _controller = (controllerFor ?? _networkController)(url),
       // The stream name, never the URL — `diagnostics/log.dart`'s rule
       // that the name is the safe half. Used only to label debug lines.
       _label = url.pathSegments.isEmpty ? url.host : url.pathSegments.last {
    _restartWatchdog(
      firstFrameTimeout,
      'the player drew no picture in ${firstFrameTimeout.inSeconds}s',
    );
    _controller.addListener(_onValue);
    unawaited(_dial());
  }

  static VideoPlayerController _networkController(Uri url) =>
      VideoPlayerController.networkUrl(url);

  final Duration firstFrameTimeout;
  final Duration stallTimeout;

  final VideoPlayerController _controller;
  final String _label;
  final _phase = ValueNotifier(LiveVideoPhase.connecting);

  Timer? _watchdog;
  var _closed = false;
  var _lastPosition = Duration.zero;

  /// Born muted — the seam's rule, and on THIS transport it is load-bearing:
  /// both Wyze stream tiers carry a `pcm_mulaw` track (probed 2026-08-26),
  /// so an unmuted default would play six camera audios over each other the
  /// moment the grid opens. The desired state is tracked here because
  /// [setMuted] can arrive before [_dial]'s initialize completes.
  var _muted = true;

  @override
  ValueListenable<LiveVideoPhase> get phase => _phase;

  @override
  String? failure;

  /// Built once — the Popup rebuilds this getter on every phase change, and
  /// a fresh widget each time would remount the texture for no reason
  /// (`MjpegLiveVideoSession.view`'s rule, and a pinned invariant: `view`
  /// identity is stable within one dial).
  @override
  late final Widget view = rtspFramePulse || rtspVideoDebug
      ? _FramePulse(
          label: _label,
          positionMs: () => _controller.value.position.inMilliseconds,
          child: VideoPlayer(_controller),
        )
      : VideoPlayer(_controller);

  Future<void> _dial() async {
    try {
      await _controller.initialize();
      if (_closed) return;
      // The muted-or-not decision may have landed while initialize was in
      // flight; apply whatever is current, before a single sample plays.
      await _controller.setVolume(_muted ? 0 : 1);
      if (_closed) return;
      await _controller.play();
    } catch (error) {
      // Type only: video_player wraps platform errors whose text quotes
      // the URL it failed to open.
      _fail('the player threw ${error.runtimeType}');
    }
  }

  @override
  void setMuted(bool muted) {
    if (_closed) return;
    _muted = muted;
    // Applied only once the player exists; before that, [_dial] reads
    // [_muted] itself. Fire-and-forget with the same swallow as dispose:
    // a volume call racing teardown is nothing a wall can act on.
    if (_controller.value.isInitialized) {
      unawaited(_controller.setVolume(muted ? 0 : 1).catchError((Object _) {}));
    }
  }

  /// The one listener, and **position is the truth it reads**: fvp reports
  /// `isInitialized` when the stream's metadata lands, which is before any
  /// picture — "connecting until a real first frame" (the honest-phases
  /// rule) means waiting for the clock to actually advance. The same
  /// advance re-arms the stall watchdog, so a picture that freezes for
  /// [stallTimeout] while the session still claims to play is failed, the
  /// exact job the MJPEG branch gives byte arrival.
  void _onValue() {
    if (_closed || _phase.value == LiveVideoPhase.failed) return;
    final value = _controller.value;
    if (value.hasError) {
      // video_player folds the platform's message into `errorDescription`;
      // this file does not control what mdk puts there, so none of it is
      // repeated (`diagnostics/log.dart`: **Never log a secret**).
      _fail('the player reported an error');
      return;
    }
    if (!value.isInitialized || value.position <= Duration.zero) return;
    if (value.position != _lastPosition) {
      _lastPosition = value.position;
      _restartWatchdog(
        stallTimeout,
        'the picture froze for ${stallTimeout.inSeconds}s',
      );
    }
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
    // Before the notifier settles, as the MJPEG branch does: a session
    // nobody is going to watch is still a go2rtc consumer until the
    // player is torn down.
    _release();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _release();
    // The phase notifier is deliberately not disposed —
    // `MjpegLiveVideoSession.close`'s rule: the surface's
    // `ValueListenableBuilder` removes its listener from its own
    // `dispose`, which the framework may run after this call.
  }

  void _release() {
    _watchdog?.cancel();
    _watchdog = null;
    _controller.removeListener(_onValue);
    // Disposing tears the RTSP session down (fvp closes the socket), which
    // is what drains this consumer from go2rtc — asserted by the live
    // suite. Errors from a dispose that races the platform are nothing a
    // wall can act on.
    unawaited(_controller.dispose().catchError((Object _) {}));
  }
}

/// Repaints the video texture under it once per vsync — see [rtspFramePulse]
/// for the measurement and the mechanism.
///
/// **It has to reach the [TextureBox] itself.** That render object is a
/// repaint boundary, so marking this widget, or anything else above it,
/// dirties a layer the texture does not live in; only the box's own
/// `markNeedsPaint()` rebuilds the `TextureLayer` and makes the engine
/// resolve the texture again.
///
/// Nothing here rebuilds a widget. `build` returns the child untouched,
/// deliberately: a rebuild per frame would churn the `VideoPlayer` this
/// exists to keep steady, and `view` identity is a pinned invariant.
///
/// [TickerProviderStateMixin] supplies the two behaviours worth having for
/// free: `TickerMode` is false under a route something else covers, so a
/// Popup riding over the Cameras view stops the pulse for the grid beneath
/// it, and `dispose` stops it for good when the session closes.
class _FramePulse extends StatefulWidget {
  const _FramePulse({
    required this.child,
    required this.label,
    required this.positionMs,
  });

  final Widget child;

  /// The stream's name, for [rtspVideoDebug]'s lines. Never a URL.
  final String label;

  /// The player's clock, read once a second so a debug line can say whether
  /// anything is being decoded at all.
  final int Function() positionMs;

  @override
  State<_FramePulse> createState() => _FramePulseState();
}

class _FramePulseState extends State<_FramePulse>
    with SingleTickerProviderStateMixin {
  /// Started in [initState] and **not written as `late final`**. A `late`
  /// field initialises on first *read*, and nothing here ever reads this one
  /// — so written that way the ticker was never created, never started, and
  /// never repainted anything. It shipped like that, and the wall stayed
  /// frozen with `VIDEO_REPAINT_PULSE` on and off alike, because both did
  /// the same nothing. Caught by the instrumentation below reporting
  /// `ticks=0` on every line.
  Ticker? _ticker;

  /// Found by walking, then held: the subtree is a handful of nodes, but
  /// this runs every vsync and the answer only changes when the player
  /// remounts its texture.
  TextureBox? _texture;

  Timer? _report;
  var _ticks = 0;
  var _framesAtLastReport = 0;
  var _positionAtLastReport = 0;

  /// [_samplePixels]'s boundary and its last verdict — debug-run only.
  final _boundaryKey = GlobalKey();
  int? _lastPixelHash;

  /// Alternates with [rtspFrameJiggle], moving the texture half a hundredth
  /// of a pixel so the layer above it is never the same two frames running.
  var _nudged = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_pulse)..start();
    if (!rtspVideoDebug) return;
    _hookFrameTimings();
    _framesAtLastReport = _engineFrames;
    _positionAtLastReport = widget.positionMs();
    _report = Timer.periodic(const Duration(seconds: 1), (_) => _log());
  }

  void _pulse(Duration _) {
    if (!mounted) return;
    _ticks++;
    if (rtspFrameJiggle) setState(() => _nudged = !_nudged);
    if (!rtspFramePulse) return; // debug-only run: measure, change nothing
    final held = _texture;
    if (held != null && held.attached) {
      held.markNeedsPaint();
      return;
    }
    // Absent until the controller finishes initialising — `VideoPlayer`
    // draws nothing before it has a texture id — so keep looking rather
    // than resolving once and giving up.
    _texture = _findTexture(context.findRenderObject());
    _texture?.markNeedsPaint();
  }

  void _log() {
    final texture = _texture ?? _findTexture(context.findRenderObject());
    final frames = _engineFrames - _framesAtLastReport;
    final position = widget.positionMs();
    Log.info('video', 'pulse', {
      'name': widget.label,
      'ticks': _ticks,
      'frames': frames,
      'pos': '+${position - _positionAtLastReport}ms',
      'tex': texture == null ? 'none' : 'id${texture.textureId}',
      'paint': _paintState(texture),
    });
    _ticks = 0;
    _framesAtLastReport = _engineFrames;
    _positionAtLastReport = position;
    unawaited(_samplePixels());
  }

  /// What the RASTER holds, versus what the glass shows. The freeze's
  /// signature so far is "decode advances, engine draws, picture stale" —
  /// this line says which side of the raster the staleness lives on:
  /// `changed` every second while the glass is frozen means the layer
  /// content advances and the staleness is in compositing/present;
  /// `SAME` means the texture sample itself is stale; `blank` means
  /// `toImage` cannot see external textures at all on this stack, and the
  /// line is measuring nothing (an honest answer too — say so, drop it).
  Future<void> _samplePixels() async {
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    try {
      // Quarter resolution: the question is "did anything move", and a
      // 160×90 readback answers it for a fraction of the cost.
      final image = await boundary.toImage(pixelRatio: 0.25);
      final data = await image.toByteData();
      image.dispose();
      if (data == null) return;
      final bytes = data.buffer.asUint8List();
      var hash = 0x811c9dc5;
      var allZero = true;
      for (var i = 0; i < bytes.length; i += 97) {
        final b = bytes[i];
        if (b != 0) allZero = false;
        hash = ((hash ^ b) * 0x01000193) & 0xFFFFFFFF;
      }
      final last = _lastPixelHash;
      _lastPixelHash = hash;
      Log.info('video', 'pixels', {
        'name': widget.label,
        'state': allZero
            ? 'blank'
            : last == null
                ? 'first'
                : last == hash
                    ? 'SAME'
                    : 'changed',
      });
    } catch (error) {
      // "Needs paint" races and unattached boundaries are expected noise;
      // the type alone says which without quoting a message that is not
      // ours (log.dart: Never log a secret).
      Log.info('video', 'pixels', {
        'name': widget.label,
        'state': 'error:${error.runtimeType}',
      });
    }
  }

  /// Whether the texture was still marked dirty when the line was written —
  /// `dirty` every second means `markNeedsPaint()` is landing and paint is
  /// never running. `debugNeedsPaint` is assert-guarded, so this can only
  /// answer in a `--debug` run.
  static String _paintState(TextureBox? box) {
    if (box == null) return 'n/a';
    var state = 'n/a';
    assert(() {
      state = box.debugNeedsPaint ? 'dirty' : 'clean';
      return true;
    }());
    return state;
  }

  static TextureBox? _findTexture(RenderObject? node) {
    if (node == null) return null;
    if (node is TextureBox) return node;
    TextureBox? found;
    node.visitChildren((child) => found ??= _findTexture(child));
    return found;
  }

  @override
  void dispose() {
    _report?.cancel();
    _ticker?.dispose();
    _texture = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `widget.child` is the same instance every build, so the player's
    // element is never rebuilt — only the wrappers above it change, and
    // each wrapper is constant for a whole run (both globals are set once
    // in `main()`).
    Widget child = widget.child;
    if (rtspVideoDebug) {
      child = RepaintBoundary(key: _boundaryKey, child: child);
    }
    if (!rtspFrameJiggle) return child;
    return Transform.translate(
      offset: Offset(0, _nudged ? 0.01 : 0),
      transformHitTests: false,
      child: child,
    );
  }
}
