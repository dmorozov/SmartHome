import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../diagnostics/url_redaction.dart';
import 'live_video.dart';

/// True: this build has a player compiled into it. See the note on the
/// appliance branch's copy — both branches answer true since 2026-08-04, and
/// the constant is what a future third branch would answer false to.
const liveVideoIsAvailable = true;

/// How long go2rtc has to answer the codec offer with a picture.
///
/// The socket itself connects in milliseconds on a LAN; what takes time is
/// go2rtc starting the producer, measured at 2.10 s for the transcoding case
/// and 4.10 s cold. The same fifteen seconds the appliance branch allows, for
/// the same reason
/// — a slow start must read as [LiveVideoPhase.connecting] and not as a
/// failure somebody goes looking for a cause of.
const kMseOpenTimeout = Duration(seconds: 15);

/// How long a playing stream may go silent before it is failed.
///
/// **Measured: there are no keepalives in either direction**, so this is the
/// only liveness signal that exists. It is also the only thing that ever ends
/// a session go2rtc has abandoned — an error frame leaves the socket open
/// with no close frame (measured: still open at 30 s), and a dead producer
/// sends nothing at all.
const kMseStallTimeout = Duration(seconds: 15);

/// The staging buffer for segments that arrive while the [web.SourceBuffer]
/// is still busy with the previous append.
///
/// Mandatory, not an optimisation: `appendBuffer` throws if called while
/// `updating` is true, and moof/mdat pairs arrive back to back. 2 MB is the
/// size go2rtc's own reference player uses (`/video-rtc.js`).
const kMseStagingBytes = 2 * 1024 * 1024;

/// The codec candidates, cribbed verbatim from go2rtc's own reference player
/// at `http://<go2rtc>/video-rtc.js` rather than invented.
///
/// Read from the running server on 2026-08-04. Inventing a codec string here
/// would be guessing at what a server this file cannot test against will
/// accept; the list the server ships with its own player is the one answer
/// that is not a guess. Video only — the Popup's box has no audio element and
/// a doorbell Popup that started talking would be a surprise, so the
/// reference player's `mp4a`/`flac`/`opus` entries are deliberately absent.
const kMseCodecs = <String>[
  'avc1.640029', // H.264 high 4.1
  'avc1.64002A', // H.264 high 4.2
  'avc1.640033', // H.264 high 5.1
  'hvc1.1.6.L153.B0', // H.265 main 5.1
];

/// Opens go2rtc's MSE stream, or answers a session that is already settled.
///
/// Never throws: the caller is a `State.initState`, and `WebSocket`'s
/// constructor raises `SecurityError` for a `ws://` opened from an https page
/// and `SyntaxError` for a URL it will not have — the same fat-fingered
/// `GO2RTC_URL` that [VideoConfig.urlFor] answers null to, arriving one layer
/// further in.
LiveVideoSession openLiveVideo(Uri url, {required String name}) {
  if (!_mediaSourceExists) {
    // `unsupported`, not `failed`: nothing was dialled and go2rtc is not the
    // problem. Reporting this as a failure would send an operator to look at
    // a server that is healthy, for a browser that has no MSE in it.
    return SettledLiveVideoSession(LiveVideoPhase.unsupported);
  }
  try {
    // The seam's URL is already this transport's endpoint — `/api/ws` is
    // what [VideoConfig.urlFor] builds — so unlike the appliance branch
    // there is nothing to map. It is the appliance's `/api/stream.mjpeg`
    // that is derived, in the file that implements it.
    return MseLiveVideoSession(url);
  } catch (error) {
    // The type, never the message: `SyntaxError` quotes the URL it refused,
    // and that URL is the one string here that can be carrying a password
    // (`diagnostics/log.dart`: **Never log a secret**).
    return SettledLiveVideoSession(LiveVideoPhase.failed,
        failure: 'the socket would not open: ${error.runtimeType}');
  }
}

/// Feature detection rather than a browser check: iOS Safari has
/// `ManagedMediaSource` and not this, and a version test would have to be
/// rewritten every time either of them moves.
bool get _mediaSourceExists => web.window.has('MediaSource');

/// go2rtc's `/api/ws` MSE stream, played by a real `<video>` element.
///
/// The protocol, all of it measured:
///
/// 1. `binaryType = 'arraybuffer'` before the socket opens.
/// 2. **The client speaks first.** go2rtc sends nothing until it receives
///    `{"type":"mse","value":"<codec list>"}`.
/// 3. The first text frame back is a complete MIME type ready for
///    `addSourceBuffer`. The init segment follows ~0.1 ms later, so the
///    staging buffer has to exist before it arrives.
/// 4. A first text frame of `{"type":"error","value":"…"}` means failure —
///    **and the socket then stays open forever with no close frame**, so this
///    session closes it itself rather than waiting for one.
/// 5. No keepalives in either direction; [kMseStallTimeout] is the only
///    liveness signal.
///
/// Public for the same reason the appliance session is: this is where the
/// risk is, and a private class cannot be interrogated.
///
/// **What has actually been run**, in google-chrome via
/// `flutter test --platform chrome`, against the live go2rtc 1.9.10 on
/// 2026-08-04: the codec offer above was accepted and this reached
/// [LiveVideoPhase.playing] in ~100 ms; go2rtc's `consumers` gained one entry
/// while it played and was back to `[]` within a second of [close]; and
/// `?src=` a stream go2rtc does not have came back as
/// `failed / "go2rtc refused: mse: stream not found"` — the error-frame path,
/// parsed, redacted and with the socket closed from this side.
///
/// **What has not**: [view]. Those runs never mounted a widget tree, so the
/// `HtmlElementView` and the reparenting of the `<video>` element into it are
/// argued for below and unproven. Nor have [kMseStallTimeout] or [_trim] ever
/// fired. Those runs were throwaway probes and are deliberately not in the
/// suite: they need a go2rtc listening on 127.0.0.1:1984, and a test that
/// fails on every machine but one is a test nobody trusts.
class MseLiveVideoSession implements LiveVideoSession {
  MseLiveVideoSession(
    Uri url, {
    this.openTimeout = kMseOpenTimeout,
    this.stallTimeout = kMseStallTimeout,
  }) : _socket = web.WebSocket(url.toString()) {
    // First, before any DOM object exists, so that a constructor that throws
    // leaves nothing behind to leak. `binaryType` is set before the socket
    // can possibly have opened.
    _socket.binaryType = 'arraybuffer';
    _socket.addEventListener('open', _onOpen.toJS);
    _socket.addEventListener('message', _onMessage.toJS);
    _socket.addEventListener('error', _onSocketError.toJS);
    _socket.addEventListener('close', _onSocketClose.toJS);

    _video = web.HTMLVideoElement()
      // Before `play()`, not after: a doorbell Popup opens with no user
      // gesture behind it and every autoplay policy rejects unmuted playback
      // in that case. A muted picture is the product decision anyway — the
      // wall is in a hallway.
      ..muted = true
      ..autoplay = true
      ..controls = false;
    _video.setAttribute('playsinline', '');
    _video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain';

    _restartWatchdog(
        openTimeout, 'go2rtc sent no picture in ${openTimeout.inSeconds}s');
  }

  final Duration openTimeout;
  final Duration stallTimeout;

  final web.WebSocket _socket;
  late final web.HTMLVideoElement _video;

  web.MediaSource? _media;
  web.SourceBuffer? _buffer;
  String? _objectUrl;

  /// Segments that arrived while [_buffer] was still `updating`, and how much
  /// of it is live. A fixed array rather than a growing list: this is a live
  /// stream, so falling far enough behind to fill 2 MB is a reason to drop
  /// what is queued and resync, never a reason to allocate more.
  final _staging = Uint8List(kMseStagingBytes);
  var _staged = 0;

  final _phase = ValueNotifier(LiveVideoPhase.connecting);
  Timer? _watchdog;
  var _closed = false;

  @override
  ValueListenable<LiveVideoPhase> get phase => _phase;

  @override
  String? failure;

  /// Built once, and it hands over a `<video>` element that already exists.
  ///
  /// `HtmlElementView.fromTagName` creates the element itself, so the video
  /// element cannot be *the* view: MSE needs a media element attached before
  /// `sourceopen` will fire, and the Popup only renders [view] once the phase
  /// is [LiveVideoPhase.playing] — which would never arrive. So the session
  /// owns a detached `<video>` from the start (media elements load perfectly
  /// well outside the document) and the platform view is a plain `<div>` it
  /// gets moved into.
  ///
  /// `fromTagName` rather than `registerViewFactory`, which needs a
  /// globally-unique view type and offers no way to unregister one — on a
  /// panel that opens a Popup per ding, that is an unbounded registry.
  @override
  late final Widget view = HtmlElementView.fromTagName(
    tagName: 'div',
    onElementCreated: (Object element) {
      final host = element as web.HTMLElement;
      host.style
        ..width = '100%'
        ..height = '100%';
      host.appendChild(_video);
    },
  );

  void _onOpen(web.Event _) {
    if (_closed) return;
    // The MediaSource is built here rather than in the constructor because
    // the codec offer can only be sent once the socket is open, and
    // `sourceopen` is what says the MediaSource is ready to be asked. Same
    // order as go2rtc's own player.
    final media = _media = web.MediaSource();
    media.addEventListener('sourceopen', _onSourceOpen.toJS);
    final objectUrl = _objectUrl = web.URL.createObjectURL(media);
    _video.src = objectUrl;
  }

  void _onSourceOpen(web.Event _) {
    if (_closed) return;
    final objectUrl = _objectUrl;
    // Revoked as soon as the attachment exists: the URL is a handle the
    // document holds until the page unloads otherwise, and a panel that opens
    // a Popup per ding would accumulate one per camera view for months.
    if (objectUrl != null) {
      web.URL.revokeObjectURL(objectUrl);
      _objectUrl = null;
    }
    final offer = _offer();
    if (offer.isEmpty) {
      // `MediaSource` exists and this browser will decode none of go2rtc's
      // video codecs — a Chromium built without the proprietary ones, which
      // is what most Linux distributions ship. `unsupported` for the same
      // reason the `MediaSource` check answers it: the fault is in the
      // browser and go2rtc is healthy. Sending the empty offer instead would
      // earn an error frame and put the blame on the server in the log.
      _settleUnsupported();
      return;
    }
    // The client speaks first. Nothing at all comes back until this is sent.
    _socket.send(jsonEncode({'type': 'mse', 'value': offer}).toJS);
    // The promise is rejected rather than thrown when autoplay is refused,
    // and an unhandled rejection in a Flutter web app is a console error
    // nobody can act on. Muted playback should never hit it; if it does, the
    // watchdog is what notices, because a paused video still buffers.
    _video.play().toDart.catchError((Object _) => null);
  }

  /// The candidates this browser will actually accept, comma-joined — the
  /// filter go2rtc's own player applies, kept because go2rtc picks from what
  /// it is offered and offering a codec the browser cannot decode buys a
  /// stream that arrives and never renders.
  String _offer() => kMseCodecs
      .where((codec) => web.MediaSource.isTypeSupported('video/mp4; '
          'codecs="$codec"'))
      .join(',');

  void _onMessage(web.MessageEvent event) {
    if (_closed) return;
    final data = event.data;
    if (data.isA<JSString>()) {
      _onText((data as JSString).toDart);
    } else if (data.isA<JSArrayBuffer>()) {
      _onSegment(data as JSArrayBuffer);
    }
  }

  void _onText(String frame) {
    final Map<String, Object?> message;
    try {
      message = jsonDecode(frame) as Map<String, Object?>;
    } catch (_) {
      // Not fatal on its own: go2rtc multiplexes several transports over this
      // socket and a frame this player does not understand is not a frame it
      // needs. The watchdog is what decides nothing useful is coming.
      return;
    }
    final value = message['value'];
    if (message['type'] == 'error') {
      // Verbatim, through the redaction: go2rtc's error frames quote the
      // producer they failed to dial, and a producer URL carries a camera's
      // password. Never branched on — go2rtc is free to reword these.
      //
      // The redaction is best-effort and cannot be anything else: go2rtc
      // composes this sentence from *its* config, which the Panel has never
      // seen. It quotes whole URLs —
      // `mse: streams: Get "http://…/onvif?username=admin&password=hunter2":
      // dial tcp …` — and, for an `ffmpeg:` producer, hands back ffmpeg's own
      // multi-line stderr with the URL *unquoted*
      // (`Error opening input file http://…?loginpas=hunter2.`); both were
      // measured coming back from the live daemon and going straight to
      // `popup.stream_failed`. [redactCredentials] states which shapes it
      // reaches and where it stops. It is logged anyway because `mse: stream
      // not found` is the one sentence that tells an operator the fault is in
      // bindings.yaml and not in the camera.
      _fail('go2rtc refused: ${redactCredentials('$value')}');
      return;
    }
    if (message['type'] != 'mse' || value is! String || value.isEmpty) return;
    if (_buffer != null) return;
    final media = _media;
    if (media == null) return;
    try {
      final buffer = _buffer = media.addSourceBuffer(value);
      buffer.mode = 'segments';
      buffer.addEventListener('updateend', _onUpdateEnd.toJS);
    } catch (error) {
      // A MIME type the browser accepted in `isTypeSupported` and then
      // refused here. The type, not the message — a `NotSupportedError`
      // quotes what it was given, and what it was given came off the wire.
      _fail('the browser refused go2rtc\'s MIME type: ${error.runtimeType}');
    }
  }

  void _onSegment(JSArrayBuffer segment) {
    // Binary arrival is the liveness signal — there is nothing else.
    _restartWatchdog(
        stallTimeout, 'go2rtc went quiet for ${stallTimeout.inSeconds}s');
    final buffer = _buffer;
    if (buffer == null) return;
    final bytes = segment.toDart.asUint8List();
    if (buffer.updating || _staged > 0) {
      if (_staged + bytes.length > _staging.length) {
        // Dropped whole rather than truncated: half a moof is not a smaller
        // segment, it is a corrupt one, and `appendBuffer` would take the
        // SourceBuffer to an error state it never comes back from.
        _staged = 0;
        return;
      }
      _staging.setRange(_staged, _staged + bytes.length, bytes);
      _staged += bytes.length;
    } else {
      _append(buffer, bytes);
    }
    if (_phase.value == LiveVideoPhase.connecting) {
      _phase.value = LiveVideoPhase.playing;
    }
  }

  void _onUpdateEnd(web.Event _) {
    if (_closed) return;
    final buffer = _buffer;
    if (buffer == null || buffer.updating) return;
    if (_staged > 0) {
      final queued = Uint8List.fromList(
          Uint8List.sublistView(_staging, 0, _staged));
      _staged = 0;
      _append(buffer, queued);
      return;
    }
    _trim(buffer);
  }

  void _append(web.SourceBuffer buffer, Uint8List bytes) {
    try {
      buffer.appendBuffer(bytes.toJS);
    } catch (_) {
      // Swallowed, as in go2rtc's own player: `appendBuffer` throws for a
      // buffer that is full or has just been closed underneath us, and the
      // next segment recovers. A failure here is not the stream's death — the
      // watchdog is what decides that.
    }
  }

  /// Keeps the last few seconds and drops the rest.
  ///
  /// Without it a wall panel accumulates every frame it has ever received in
  /// the SourceBuffer, and the picture drifts steadily further behind live —
  /// the two costs go2rtc's own player pays this same code to avoid. The
  /// playback-rate nudge is the reference player's: it catches a video up to
  /// the live edge without a visible seek.
  void _trim(web.SourceBuffer buffer) {
    final buffered = buffer.buffered;
    if (buffered.length == 0) return;
    final end = buffered.end(buffered.length - 1);
    final start = end - _liveWindowSeconds;
    final first = buffered.start(0);
    if (start > first) {
      buffer.remove(first, start);
      _media?.setLiveSeekableRange(start, end);
    }
    if (_video.currentTime < start) _video.currentTime = start;
    final gap = end - _video.currentTime;
    _video.playbackRate = gap > 0.1 ? gap : 0.1;
  }

  static const _liveWindowSeconds = 5.0;

  void _onSocketError(web.Event _) =>
      // No detail is available: the browser deliberately withholds why a
      // WebSocket failed, so there is nothing here to quote even if it were
      // safe to.
      _fail('the browser could not reach go2rtc');

  void _onSocketClose(web.CloseEvent event) {
    // The code, never `event.reason`: the reason is a server-supplied string
    // and this player has no way to know go2rtc will not have put a producer
    // URL in it.
    _fail('go2rtc closed the socket (${event.code})');
  }

  void _restartWatchdog(Duration after, String reason) {
    _watchdog?.cancel();
    _watchdog = Timer(after, () => _fail(reason));
  }

  void _fail(String reason) {
    if (!_undecided) return;
    failure = reason;
    _phase.value = LiveVideoPhase.failed;
    _release();
  }

  void _settleUnsupported() {
    if (!_undecided) return;
    _phase.value = LiveVideoPhase.unsupported;
    _release();
  }

  /// Whether this session has yet to reach a verdict.
  ///
  /// Guards both settling methods, and it has to name [LiveVideoPhase.failed]
  /// *and* [LiveVideoPhase.unsupported]: [_release] closes the socket, the
  /// browser answers that with a `close` event, and `_onSocketClose` would
  /// otherwise overwrite an honest "this browser cannot decode it" with
  /// "go2rtc closed the socket (1000)" — sending an operator to look at the
  /// server for a fault that is on the glass.
  bool get _undecided =>
      !_closed &&
      (_phase.value == LiveVideoPhase.connecting ||
          _phase.value == LiveVideoPhase.playing);

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _release();
    // The notifier is deliberately not disposed: the Popup's
    // `ValueListenableBuilder` removes its listener from its own `dispose`,
    // which the framework may run after this call.
  }

  void _release() {
    _watchdog?.cancel();
    _watchdog = null;
    // Closed by us, always. Measured: after an error frame go2rtc leaves the
    // socket open with no close frame — still open at 30 s — so waiting for
    // one means holding a consumer on the stream for as long as the panel
    // runs.
    _socket.close();
    final objectUrl = _objectUrl;
    if (objectUrl != null) {
      web.URL.revokeObjectURL(objectUrl);
      _objectUrl = null;
    }
    _buffer = null;
    _media = null;
    // `removeAttribute` then `load()`: detaching the MediaSource is what
    // actually frees the decoded buffers. Setting `src = ''` instead makes
    // the element re-resolve the empty string against the page URL and fetch
    // the document as if it were a video.
    _video.pause();
    _video.removeAttribute('src');
    _video.load();
  }
}
