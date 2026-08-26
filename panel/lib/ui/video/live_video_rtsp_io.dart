import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player/video_player.dart';

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

/// Opens go2rtc's RTSP restream through fvp, or answers a session that is
/// already failed. Never throws — `openLiveVideo`'s contract, kept for its
/// stated reason (the caller is a `State.initState`).
LiveVideoSession openRtspVideo(Uri url, {required String name}) {
  try {
    if (!_fvpRegistered) {
      // Swaps video_player's platform implementation for fvp (libmdk),
      // process-wide, once. `lowLatency` trims mdk's network buffering —
      // this is a live wall, not a seekable file. RTSP-over-TCP is fvp's
      // own default (it sets `avformat.rtsp_transport: tcp` per player),
      // which is also this house's rule: RTSPS/TCP everywhere upstream.
      _fvpRegistered = true;
      fvp.registerWith(options: {'lowLatency': 1});
    }
    return RtspLiveVideoSession(rtspEndpointFor(url));
  } catch (error) {
    // The type, never the message — `mjpegEndpointFor`'s twin, same rule
    // (`diagnostics/log.dart`: **Never log a secret**).
    return SettledLiveVideoSession(LiveVideoPhase.failed,
        failure: 'the player would not start: ${error.runtimeType}');
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
  }) : _controller = (controllerFor ?? _networkController)(url) {
    _restartWatchdog(firstFrameTimeout,
        'the player drew no picture in ${firstFrameTimeout.inSeconds}s');
    _controller.addListener(_onValue);
    unawaited(_dial());
  }

  static VideoPlayerController _networkController(Uri url) =>
      VideoPlayerController.networkUrl(url);

  final Duration firstFrameTimeout;
  final Duration stallTimeout;

  final VideoPlayerController _controller;
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
  late final Widget view = VideoPlayer(_controller);

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
      unawaited(
          _controller.setVolume(muted ? 0 : 1).catchError((Object _) {}));
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
      _restartWatchdog(stallTimeout,
          'the picture froze for ${stallTimeout.inSeconds}s');
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
