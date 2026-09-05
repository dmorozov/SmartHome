import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, TextureBox;
import 'package:flutter/scheduler.dart' show SchedulerBinding, Ticker;
import 'package:flutter/widgets.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player/video_player.dart';

import '../../config/video_tuning.dart';
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

/// Hands fvp the decoder settings, once per process, from `main()`.
///
/// **Called at the composition root and nowhere else**, which is where the
/// decision has always been described as living — `main()`'s own comment
/// beside the `VIDEO_DECODERS` read calls it "a composition-root decision
/// by construction" — but the call itself was made lazily, at the first
/// dial, until 2026-09-03. Doing it there was a live hazard in every test
/// binary: `registerWith` schedules its own setup on an unawaited
/// `Future.delayed` — fvp's own comment says the delay exists so the log
/// handler is installed inside `main()` — and that setup opens `libfvp.so`,
/// which no VM test run has. The `DynamicLibrary.open` failure therefore
/// surfaced as an **unhandled async error charged to whichever test happened
/// to be running** when the microtask drained, which no `try` around the
/// opener can catch and which failed a different innocent case each time
/// (seen twice: 2026-09-02 and 2026-09-03).
///
/// Registering from `main()` fixes it by construction rather than by a
/// test-only guard: a test binary never calls `main()`, so it never asks fvp
/// to load a library that is not there.
///
/// Not the first registration on the appliance, and deliberately so: fvp
/// declares `dartPluginClass: VideoPlayerRegistrant`, so Flutter's generated
/// plugin registrant has already swapped `video_player`'s platform and
/// loaded libmdk **before** `main()` runs — the fvp banner precedes
/// `panel.start` in the journal. That first registration passes no options;
/// this one is how [RtspTuning.decoders] and [RtspTuning.lowLatency] reach
/// the player at all. Idempotent, so a second call is a no-op — and the
/// second call's tuning is therefore ignored, which is not a bug to fix but
/// the fact fvp imposes: it registers once per process, so the first caller
/// wins. `main()` is the only caller.
void registerRtspPlayer(RtspTuning tuning) {
  if (_fvpRegistered) return;
  _fvpRegistered = true;
  // Swaps video_player's platform implementation for fvp (libmdk),
  // process-wide, once. RTSP-over-TCP is fvp's own default (it sets
  // `avformat.rtsp_transport: tcp` per player), which is also this house's
  // rule: RTSPS/TCP everywhere upstream.
  fvp.registerWith(
    options: {
      'lowLatency': tuning.lowLatency,
      // Omitted entirely when null, so "let fvp choose" stays reachable and
      // is not spelled as an empty list fvp would read as "nothing".
      'video.decoders': ?tuning.decoders,
    },
  );
  Log.info('panel', 'video_player', tuning.logFields);
}

/// The seam's opener for this transport, bound to the tuning `main()`
/// resolved.
///
/// A function that returns an opener rather than an opener that reads
/// globals: [RtspTuning] reaches the session — and through it the render
/// path — as an argument, so there is no moment at which it is half-set and
/// no way to change it after a stream is playing. `main()` picks the
/// transport and binds the tuning in the same expression; the seam
/// downstream sees a plain [LiveVideoOpener] and knows nothing about either.
LiveVideoOpener rtspOpener(RtspTuning tuning) =>
    (Uri url, {required String name}) {
      try {
        return RtspLiveVideoSession(rtspEndpointFor(url), tuning: tuning);
      } catch (error) {
        // The type, never the message — `mjpegEndpointFor`'s twin, same rule
        // (`diagnostics/log.dart`: **Never log a secret**).
        return SettledLiveVideoSession(
          LiveVideoPhase.failed,
          failure: 'the player would not start: ${error.runtimeType}',
        );
      }
    };

/// Frames the engine rasterised, counted for [RtspTuning.debug]. Global
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
    this.tuning = const RtspTuning(),
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

  /// How this machine is tuned. Only the render-path half is this class's
  /// business — [RtspTuning.decoders] and [RtspTuning.lowLatency] were spent
  /// at [registerRtspPlayer] long before any session existed. Defaulted, like
  /// the deadlines beside it, so a case that is not about tuning does not
  /// have to say anything about it.
  final RtspTuning tuning;

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
  late final Widget view = tuning.framePulse || tuning.debug
      ? _FramePulse(
          tuning: tuning,
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

/// Repaints the video texture under it once per vsync — see
/// [RtspTuning.framePulse] for the measurement and what to set it to.
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
    required this.tuning,
    required this.child,
    required this.label,
    required this.positionMs,
  });

  /// Both halves of why this widget exists at all: [RtspTuning.framePulse]
  /// makes it repaint, [RtspTuning.debug] makes it measure, and the session
  /// builds it when either is set. Held whole rather than as two booleans so
  /// a third render-path setting costs no re-threading.
  final RtspTuning tuning;

  final Widget child;

  /// The stream's name, for [RtspTuning.debug]'s lines. Never a URL.
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

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_pulse)..start();
    if (!widget.tuning.debug) return;
    _hookFrameTimings();
    _framesAtLastReport = _engineFrames;
    _positionAtLastReport = widget.positionMs();
    _report = Timer.periodic(const Duration(seconds: 1), (_) => _log());
  }

  void _pulse(Duration _) {
    if (!mounted) return;
    _ticks++;
    // A debug-only run: measure, change nothing.
    if (!widget.tuning.framePulse) return;
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
    // element is never rebuilt — and the one wrapper above it is constant
    // for the life of the session (the tuning is a value, fixed at
    // construction).
    if (!widget.tuning.debug) return widget.child;
    return RepaintBoundary(key: _boundaryKey, child: widget.child);
  }
}
