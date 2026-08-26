import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../diagnostics/log.dart';
import '../../diagnostics/url_redaction.dart';
import 'live_video.dart';

/// True: this build has a player compiled into it. See the note on the
/// appliance branch's copy — both branches answer true since 2026-08-04, and
/// the constant is what a future third branch would answer false to.
const liveVideoIsAvailable = true;

/// How long go2rtc has to answer the codec offer with a picture.
///
/// The socket itself connects in milliseconds on a LAN; what takes time is
/// go2rtc starting the producer — a slow start must read as
/// [LiveVideoPhase.connecting] and not as a failure somebody goes looking for
/// a cause of.
///
/// **Twenty-five seconds since 2026-08-15, and it was fifteen until real
/// cameras arrived.** Fifteen was sized against the `selftest` pattern —
/// 2.10 s warm, 4.10 s cold — which turned out to be nothing like a camera.
/// Measured cold time to first frame on the Wyze fleet:
///
/// * Family Room, Living Room, Back Yard Door — **4.6 – 5.2 s**
/// * Garage Door, Back Yard (floodlight units) — **17.0 – 17.9 s**
///
/// So the old value failed the two floodlights by about three seconds, every
/// time, on a camera that was working perfectly: the wall said `Live view
/// failed` while go2rtc was still dutifully starting the producer. That is
/// the exact failure ADR-0007 exists to forbid — a fault reported for
/// something that is not faulty.
///
/// Twenty-five is chosen against the *measured* worst case plus ~40% head,
/// not doubled for luck, and it stays under [kDoorbellPopupDeadline]'s 30 s so
/// the Popup's own deadline is still the outer bound rather than a race.
/// If a future camera is slower than this, raise it against a measurement and
/// move the Popup deadline with it.
const kMseOpenTimeout = Duration(seconds: 25);

/// How long a playing stream may go silent before it is failed.
///
/// **Measured: there are no keepalives in either direction**, so this is the
/// only liveness signal that exists. It is also the only thing that ever ends
/// a session go2rtc has abandoned — an error frame leaves the socket open
/// with no close frame (measured: still open at 30 s), and a dead producer
/// sends nothing at all.
const kMseStallTimeout = Duration(seconds: 15);

/// How long a stream that is *arriving* has to produce a frame the browser can
/// actually decode.
///
/// Separate from [kMseOpenTimeout] because it answers a different question.
/// That one covers go2rtc starting a producer, which is why it is fifteen
/// seconds; by the time bytes are on the wire the producer is up, and the only
/// thing still outstanding is whether they decode. Six seconds is generous
/// against a first frame that arrives ~100 ms after the first media segment
/// (measured on the live server, 2026-08-04), and it is the deadline that
/// stops issue #1's mid-GOP join from sitting on the wall as an empty box
/// claiming to play.
const kMseDecodeTimeout = Duration(seconds: 6);

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
/// **[view] and [_trim] were the unproven half, and on 2026-08-06 they were
/// driven** — google-chrome through the Playwright MCP, against the dev
/// sandbox's real `ring_doorbell`, mounting the real Popup. Both were wrong,
/// and both are fixed here: the re-parented `<video>` came back paused and was
/// never restarted ([_resume]), and [_trim] parked `currentTime` in the hole
/// its own `remove` had just made ([_seekNearLiveEdge]). The same session
/// showed [LiveVideoPhase.playing] standing over a box the browser had decoded
/// zero frames into, which is what [_onLoadedData] now answers.
///
/// **What still has not**: [kMseStallTimeout] has never fired. And none of this
/// is in the suite — the probes need a go2rtc, and a test that fails on every
/// machine but one is a test nobody trusts. `live_video_keepalive_live_test.dart`
/// is the opt-in that covers what can be covered, and it is a VM binary, so it
/// exercises the appliance branch; everything above was verified by driving a
/// browser and is recorded here because that is the only place it lives.
class MseLiveVideoSession implements LiveVideoSession {
  MseLiveVideoSession(
    Uri url, {
    this.openTimeout = kMseOpenTimeout,
    this.stallTimeout = kMseStallTimeout,
    this.decodeTimeout = kMseDecodeTimeout,
  })  : _url = url,
        _socket = web.WebSocket(url.toString()) {
    // First, before any DOM object exists, so that a constructor that throws
    // leaves nothing behind to leak. `binaryType` is set before the socket
    // can possibly have opened.
    _wireSocket();

    _video = web.HTMLVideoElement()
      // Before `play()`, not after: a doorbell Popup opens with no user
      // gesture behind it and every autoplay policy rejects unmuted playback
      // in that case. A muted picture is the product decision anyway — the
      // wall is in a hallway.
      ..muted = true
      ..autoplay = true
      ..controls = false;
    _video.setAttribute('playsinline', '');
    // The one event that says a frame exists. `readyState` reaching
    // HAVE_CURRENT_DATA is a statement about the decoder having produced a
    // picture for the current position, and it is what [LiveVideoPhase.playing]
    // now means — see [_onLoadedData].
    _video.addEventListener('loadeddata', _onLoadedData.toJS);
    // **The one event that says playback is over, and it was never listened
    // to.** A media element that errors sets `error`, and the MSE spec's
    // prepare-append algorithm then throws `InvalidStateError` on *every*
    // subsequent `appendBuffer`. So a decode failure was invisible here and
    // surfaced only as its own aftermath — a stream of append failures with a
    // healthy-looking MediaSource, measured on the live doorbell 2026-08-10 as
    // `media_state=open source_buffers=1 updating=false video_connected=true`,
    // every one of the spec's other throw conditions ruled out. Nothing in
    // this file could see the cause, only the symptom.
    _video.addEventListener('error', _onVideoError.toJS);
    _video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain'
      // The video must not eat the touch that lands on it.
      //
      // A platform view on web is a real DOM element composited ABOVE the
      // Flutter canvas, so a `<video>` filling a Cameras tile takes every
      // pointer event and the tile's own [GestureDetector] never sees one.
      // Measured 2026-08-15 on the wall: tapping a tile that was *playing*
      // did nothing, while a tile showing `Connecting…` or `Live view
      // failed` — Flutter-drawn text, no platform view — zoomed as intended.
      // That is a control that works only when it has nothing to show.
      //
      // `pointer-events: none` here rather than an invisible Flutter widget
      // stacked over the video: the element is ours, the rule is one line,
      // and an overlay would have to be maintained at every call site that
      // ever renders [view]. Nothing inside this element is interactive —
      // there are no native controls, `muted` is set for autoplay and the
      // Panel's own chrome is drawn by Flutter — so nothing is lost.
      ..pointerEvents = 'none';

    _restartWatchdog(
        openTimeout, 'go2rtc sent no picture in ${openTimeout.inSeconds}s');
  }

  final Duration openTimeout;
  final Duration stallTimeout;
  final Duration decodeTimeout;

  /// Kept so a session can dial again after the decoder gives up — see
  /// [_reconnect].
  final Uri _url;

  /// Replaced on every reconnect, so it cannot be final.
  web.WebSocket _socket;

  /// Reconnects spent on decoder failures, and the cap.
  ///
  /// Bounded because a stream the browser genuinely cannot play would
  /// otherwise reconnect for ever, and every attempt is another consumer on a
  /// doorbell (#177014). Three is enough to ride out the transient this exists
  /// for and few enough to give up honestly.
  var _reconnects = 0;
  static const _maxReconnects = 3;
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

  /// Segments lost, and appends refused. Both were silent until 2026-08-10,
  /// which is what made an intermittent half-green picture impossible to tell
  /// apart from a decoder fault: bytes kept arriving either way. Counted so
  /// the log can say so once rather than per segment.
  var _dropped = 0;
  var _appendFailures = 0;

  /// Whether the `<video>` has ever been in the document.
  ///
  /// Load-bearing for [_detached], which must not confuse "not attached yet"
  /// with "attached and then taken away". Before the first attach the element
  /// is *supposed* to be outside the document — the session owns a detached
  /// `<video>` from the start, because MSE needs a media element before
  /// `sourceopen` fires and the Popup only renders [view] once the phase is
  /// [LiveVideoPhase.playing]. Refusing to append then would be a deadlock:
  /// no append, no `loadeddata`, no `playing`, so the view never mounts and
  /// the element is never attached.
  var _wasConnected = false;

  /// True once the element has been attached and is *currently* out of the
  /// document — the window in which `appendBuffer` throws.
  ///
  /// **This is what the intermittent green picture actually was**, measured on
  /// the live doorbell 2026-08-10:
  ///
  /// ```text
  /// mse_append_failed error=InvalidStateError bytes=201169 buffered_s=0.3
  ///   updating=false media_state=open source_buffers=1
  ///   video_connected=false video_ready=4
  /// ```
  ///
  /// The MediaSource was open, the SourceBuffer attached, nothing updating —
  /// the *element* had left the document. `_LiveVideoBox` renders
  /// `session.view` only while the phase is [LiveVideoPhase.playing], so any
  /// flip away from it unmounts the platform view and takes the `<video>` with
  /// it. An HTML media element outside a document re-runs its load algorithm,
  /// which aborts the in-flight resource, and `appendBuffer` then throws.
  ///
  /// It is self-sustaining, which is why it looked random: the throw loses
  /// segments, lost segments stall decoding, a stalled decode knocks the phase
  /// off `playing`, and that unmounts the view again. Watched from the wall it
  /// is a picture that appears, greys out, and comes back.
  ///
  /// Staging through the gap rather than throwing costs nothing — the element
  /// is back within a frame or two, and [_resume] drains the backlog the
  /// moment it returns.
  bool get _detached => _wasConnected && !_video.isConnected;

  final _phase = ValueNotifier(LiveVideoPhase.connecting);
  Timer? _watchdog;
  var _closed = false;

  /// Whether [decodeTimeout] is already running. See [_noteBytesArrived]:
  /// the deadline is armed by the first segment and never restarted, so a
  /// stream of undecodable bytes cannot hold it open.
  var _awaitingDecode = false;

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
  ///
  /// Built once, but `onElementCreated` runs **every time this widget is
  /// mounted**, which since `live_video_keepalive.dart` is more than once per
  /// session — and that is why it now resumes as well as re-parents. See
  /// [_resume].
  @override
  late final Widget view = HtmlElementView.fromTagName(
    tagName: 'div',
    onElementCreated: (Object element) {
      final host = element as web.HTMLElement;
      host.style
        ..width = '100%'
        ..height = '100%'
        // Both, not just the video: this div is the platform view itself and
        // is composited above the Flutter canvas whether or not the `<video>`
        // inside it happens to fill it. See the note on `_video.style`.
        ..pointerEvents = 'none';
      host.appendChild(_video);
      // Post-frame, and not inline here. `onElementCreated` runs while `host`
      // is still detached, and the removing steps this very `appendChild`
      // queues — it moves `_video` out of the platform view that is going away
      // — run at the next stable state, which is *after* this callback and
      // still before `host` reaches the document. They pause any element that
      // is not in a document by then, so a `play()` from here is undone
      // milliseconds later: measured 2026-08-06, the element was found paused
      // at `readyState` 4 with `currentTime` marching forward only in the jumps
      // [_trim] gave it. A post-frame callback lands after Flutter has put the
      // platform view into the DOM, which is after that checkpoint.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _resume();
        _letTouchesThrough(host);
      });
    },
  );

  /// Makes Flutter's own platform-view wrapper transparent to pointers, so a
  /// tap on a playing tile reaches the widget underneath it.
  ///
  /// **Why this is not solved by `pointer-events: none` on our own elements.**
  /// It was tried first and it is necessary but not sufficient. Flutter wraps
  /// the element it hands us in an `<flt-platform-view>` of its own, and that
  /// wrapper carries `pointer-events: auto`. With the video and its host made
  /// transparent, `document.elementFromPoint` over a tile still answered
  /// `FLT-PLATFORM-VIEW#flt-pv-3` — measured 2026-08-15 — and that element is
  /// not `<flt-glass-pane>`, which is the only place Flutter listens. So the
  /// touch was swallowed one level above anything this file owned, and the
  /// Cameras view's tap-to-zoom worked on every tile that was *not* playing.
  ///
  /// Walks up at most a few levels and only ever touches an element whose tag
  /// is `FLT-PLATFORM-VIEW`, so a Flutter version that renames or restructures
  /// this leaves the tree alone rather than blanking pointers on something
  /// load-bearing. If that happens the failure is the old one — a tile that
  /// ignores taps while it plays — and this comment is where to start.
  ///
  /// Safe because nothing inside is interactive: no native controls, `muted`
  /// for autoplay, and every control the Panel draws is a Flutter widget.
  static void _letTouchesThrough(web.HTMLElement host) {
    web.Element? node = host;
    for (var i = 0; node != null && i < 4; i++) {
      if (node.tagName.toUpperCase() == 'FLT-PLATFORM-VIEW') {
        (node as web.HTMLElement).style.pointerEvents = 'none';
        return;
      }
      node = node.parentElement;
    }
  }

  /// Puts a re-parented `<video>` back on the live edge and starts it again.
  ///
  /// **The bug this exists for**, measured in google-chrome through the
  /// Playwright MCP on 2026-08-06, driving the real Popup against the dev
  /// sandbox's `ring_doorbell`:
  ///
  /// | moment | in document | `paused` | `readyState` |
  /// |---|---|---|---|
  /// | Popup open | yes | false | 4 |
  /// | Popup closed, session kept | **element gone** | — | — |
  /// | Popup reopened, session reused | yes | **true** | **1** |
  ///
  /// Closing the Popup destroys the platform view, which takes `_video` out of
  /// the document with it, and the HTML spec's media-element *removing steps*
  /// run the internal pause steps on an element that leaves its document. That
  /// was harmless while every open dialled a fresh session — `_onSourceOpen`
  /// called `play()` each time — and stopped being harmless the moment
  /// `live_video_keepalive.dart` began handing the same session to a second
  /// consumer, because `sourceopen` fires **once per session** and nothing else
  /// ever started the element again. The reused stream showed a frozen frame
  /// and then, once [_trim] had moved the window past where it was parked, an
  /// empty box.
  ///
  /// So the seam did not need a new method: re-parenting *is* the signal, it is
  /// already delivered here, and the appliance branch — whose `view` is a
  /// `ValueListenableBuilder` over a frame notifier, with no element and no
  /// autoplay state — needs nothing at all.
  ///
  /// Both halves are load-bearing. `play()` alone leaves `currentTime` where
  /// the element was paused, which by now is behind everything [_trim] has
  /// kept; the seek alone leaves it paused. Confirmed by hand in the same
  /// session: seeking to the live edge *and* calling `play()` took a stuck
  /// element from `readyState` 1 back to 4 and live.
  void _resume() {
    if (_closed) return;
    if (_video.isConnected) _wasConnected = true;
    final buffer = _buffer;
    // Null on the very first mount, where there is nothing to seek to and
    // `_onSourceOpen` is the one that will call `play()`.
    if (buffer != null) {
      _seekNearLiveEdge(buffer);
      // The element is back in the document, so whatever [_detached] made the
      // pump hold on to can go in now. Without this the backlog waits for the
      // next `updateend`, and there is no `updateend` coming while nothing is
      // being appended.
      if (!buffer.updating) _flushStaged(buffer);
    }
    if (_video.paused) {
      _video.play().toDart.catchError((Object _) => null);
    }
  }

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
    // go2rtc advertises a lower level than the stream really has — its
    // `GetProfileLevelID` whitelist drops anything above 4.0 and falls back to
    // 4.1 — and Chrome believes the advertisement. See [raiseH264Level], which
    // has the measured before/after and the bitstream that clears Ring. Applied here because this is the last point before the
    // decoder is built, and never blindly: the raised type has to be one the
    // browser actually claims, or a device with a genuinely limited decoder
    // would be handed a promise nothing can keep. If it is not supported, go
    // on with go2rtc's own answer and let the existing failure path speak.
    var mime = value;
    final raised = raiseH264Level(value);
    if (raised != null &&
        web.MediaSource.isTypeSupported(raised) &&
        raised != value) {
      Log.debug('popup', 'mse_level_raised', {'from': value, 'to': raised});
      mime = raised;
    }
    try {
      final buffer = _buffer = media.addSourceBuffer(mime);
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
    final buffer = _buffer;
    if (buffer == null) return;
    final bytes = segment.toDart.asUint8List();
    if (buffer.updating || _detached) {
      _stage(bytes);
    } else if (_staged > 0) {
      // Staged bytes with an *idle* buffer means the `updateend` that should
      // have flushed them never arrived, and nothing else drives this pump.
      // That is reachable: `appendBuffer` can throw, and a throw means no
      // update ever started, so no `updateend` is ever fired — [_onUpdateEnd]
      // is then never called again and every later segment piles into the
      // staging buffer until it overflows and starts dropping. The stream
      // keeps arriving the whole time, so every liveness signal still reads
      // healthy while the picture is frozen or half-decoded.
      //
      // Draining here rather than only on `updateend` is what makes the pump
      // self-healing: the next segment to arrive restarts it.
      _stage(bytes);
      _flushStaged(buffer);
    } else {
      _append(buffer, bytes);
    }
    // The init segment does not start the decode clock — it carries no
    // frames, so "6 s of video the browser could not decode" would be a
    // statement about a segment that contains no video.
    if (!_isInitSegment(bytes)) _noteBytesArrived();
  }

  /// Whether this is the `ftyp`+`moov` header rather than a media segment.
  ///
  /// **This is what made the two slow cameras unplayable.** go2rtc sends the
  /// init segment ~0.1 ms after the handshake, whatever the camera is doing;
  /// media segments wait for the producer. Arming [decodeTimeout] on the
  /// first *binary frame* therefore started a 6 s clock at t≈0 on a camera
  /// whose first frame was coming at t≈17 s, and the tile failed with
  /// `go2rtc sent 6s of video the browser could not decode` — about a
  /// stream that had sent no video at all yet. Measured on the wall
  /// 2026-08-15: the two Wyze floodlight units failed every single time and
  /// the three fast ones never did, which is exactly the shape of a deadline
  /// that starts before the thing it is timing.
  ///
  /// Checked by box type rather than by counting frames: "the first binary
  /// frame is the init segment" is true of the protocol as measured, but a
  /// reconnect or a codec change puts another one on the wire, and a counter
  /// would arm the clock on it.
  static bool _isInitSegment(Uint8List bytes) =>
      bytes.length >= 8 &&
      bytes[4] == 0x66 && // f
      bytes[5] == 0x74 && // t
      bytes[6] == 0x79 && // y
      bytes[7] == 0x70; //  p

  /// Copies [bytes] into the staging buffer, or drops the segment whole.
  ///
  /// Dropped whole rather than truncated: half a moof is not a smaller
  /// segment, it is a corrupt one, and `appendBuffer` would take the
  /// SourceBuffer to an error state it never comes back from.
  ///
  /// **Every drop is a hole in the picture** — a lost moof/mdat pair is
  /// macroblocks the decoder never receives, which is why a stream that drops
  /// renders as a part-decoded frame with the rest left at the uninitialised
  /// YUV value (green). This used to happen silently, which made an
  /// intermittent green picture undiagnosable from the log.
  void _stage(Uint8List bytes) {
    if (_staged + bytes.length > _staging.length) {
      _staged = 0;
      _dropped++;
      // Once, with a running total: one line per dropped segment on a stream
      // that is dropping steadily would bury everything else in the log.
      if (_dropped == 1) {
        Log.warn('video', 'mse_segment_dropped', {
          'reason': 'staging_full',
          'staging_bytes': _staging.length,
          'segment_bytes': bytes.length,
        });
      }
      return;
    }
    _staging.setRange(_staged, _staged + bytes.length, bytes);
    _staged += bytes.length;
  }

  void _flushStaged(web.SourceBuffer buffer) {
    // Nothing staged is reachable, not defensive: [_stage] resets the backlog
    // to zero when it drops a segment, so the drain path can arrive here with
    // an empty buffer. Appending zero bytes is at best a wasted update and at
    // worst a throw.
    if (_staged == 0) return;
    final queued =
        Uint8List.fromList(Uint8List.sublistView(_staging, 0, _staged));
    _staged = 0;
    _append(buffer, queued);
  }

  /// Bytes are the liveness signal — there is nothing else — but they are
  /// **not** the picture signal, and the difference is issue #1.
  ///
  /// This used to promote the phase to [LiveVideoPhase.playing] right here, on
  /// the first segment. Measured on 2026-08-06 against the dev sandbox, that is
  /// a lie the wall can be shown: a reopen that lands while ring-mqtt's
  /// restream is relaunching delivers a steady stream of segments the browser
  /// decodes **zero** frames from — `totalVideoFrames: 0`, `readyState: 1` —
  /// and the Popup rendered an empty box under a phase that read `playing`.
  /// That is ADR-0007's stale reading at Device scale: the one thing the Panel
  /// may not do is claim a picture it does not have.
  ///
  /// So arrival now only ever *arms a deadline*, and [_onLoadedData] is what
  /// promotes. Deliberately armed once and never restarted while no frame has
  /// decoded: more bytes the decoder cannot use are not progress, and
  /// restarting on each one is what would let a mid-GOP join hold the box
  /// forever.
  void _noteBytesArrived() {
    if (_phase.value != LiveVideoPhase.connecting) {
      _restartWatchdog(
          stallTimeout, 'go2rtc went quiet for ${stallTimeout.inSeconds}s');
      return;
    }
    if (_awaitingDecode) return;
    _awaitingDecode = true;
    _restartWatchdog(
        decodeTimeout,
        'go2rtc sent ${decodeTimeout.inSeconds}s of video the browser '
        'could not decode');
  }

  /// `readyState` reached HAVE_CURRENT_DATA: there is a decoded frame at the
  /// current position, so there is something honest to draw.
  ///
  /// The promotion to [LiveVideoPhase.playing], and the reason it is this event
  /// rather than a frame counter: `loadeddata` is a statement about the media
  /// pipeline, which runs whether or not the element is in the document — and
  /// it is not, at this point. The Popup renders [view] only once the phase is
  /// `playing`, so a signal that needed the element on screen first could never
  /// arrive.
  /// The media element gave up. Playback is over and cannot be resumed on this
  /// element — every later `appendBuffer` throws — so this is a real failure
  /// and is reported as one rather than left as a frozen picture.
  ///
  /// Failing here is also what puts the **still photo** back on the wall under
  /// its "Still" caption (`_LiveVideoBox`), which is a far better answer than
  /// half a decoded frame with the rest left at the uninitialised YUV value
  /// that renders as green. ADR-0007: a picture that is not live may not be
  /// dressed as one, and a dead decoder's last output is not live.
  void _onVideoError(web.Event _) {
    if (_closed) return;
    final error = _video.error;
    // The code carries no text at all — 1 aborted, 2 network, 3 decode,
    // 4 source not supported — so it is always safe. The message is Chrome's
    // pipeline detail, which is where the diagnosis actually lives, and it
    // goes through the same redaction go2rtc's own error frames get.
    final code = error?.code ?? 0;
    Log.warn('video', 'mse_media_error', {
      'code': code,
      'detail': redactCredentials(error?.message ?? ''),
      'buffered_s': _buffer == null
          ? '0.0'
          : _bufferedSeconds(_buffer!).toStringAsFixed(1),
      'appends_failed': _appendFailures,
      'segments_dropped': _dropped,
    });
    if (_reconnects < _maxReconnects) {
      _reconnect('media_error_$code');
      return;
    }
    _fail('the browser stopped decoding the stream (media error $code)');
  }

  void _onLoadedData(web.Event _) {
    if (_closed || _phase.value != LiveVideoPhase.connecting) return;
    _phase.value = LiveVideoPhase.playing;
    _restartWatchdog(
        stallTimeout, 'go2rtc went quiet for ${stallTimeout.inSeconds}s');
  }

  void _onUpdateEnd(web.Event _) {
    if (_closed) return;
    final buffer = _buffer;
    if (buffer == null || buffer.updating) return;
    // Nothing may touch the SourceBuffer while the element is out of the
    // document — `remove` throws for the same reason `appendBuffer` does, and
    // this path calls both. [_resume] restarts the pump when the element comes
    // back, so standing down here loses no data: it is already staged.
    if (_detached) return;
    // Trim BEFORE draining the backlog. This used to be the other way round —
    // a waiting backlog returned early and `_trim` never ran — which under
    // sustained load meant the SourceBuffer was never trimmed at all. It grows
    // until `appendBuffer` throws `QuotaExceededError`, and before [_onSegment]
    // learned to drain a backlog itself, that throw killed the pump for good.
    // Observed on the live doorbell 2026-08-10: `video.mse_append_failed` on a
    // 1278-byte P-frame, with an intermittent half-decoded picture.
    //
    // A removal is asynchronous and fires its own `updateend`, which re-enters
    // here with the backlog still waiting and the window back under budget —
    // so the two alternate rather than starving each other.
    if (_trim(buffer)) return;
    if (_staged > 0) _flushStaged(buffer);
  }

  void _append(web.SourceBuffer buffer, Uint8List bytes) {
    try {
      buffer.appendBuffer(bytes.toJS);
    } catch (error) {
      // Still swallowed, as in go2rtc's own player: `appendBuffer` throws for
      // a buffer that is full (`QuotaExceededError`) or has just been closed
      // underneath us, and the next segment recovers. A failure here is not
      // the stream's death — the watchdog is what decides that.
      //
      // What is new is that it is no longer *silent*, and that it no longer
      // wedges the pump. A throw means no update started, so no `updateend`
      // follows; before [_onSegment] learned to drain a staged backlog itself,
      // one of these stopped the player for good while every byte-level signal
      // still looked healthy. The type, never the message — see the class doc
      // on what a failure is allowed to say.
      _appendFailures++;
      if (_appendFailures == 1) {
        Log.warn('video', 'mse_append_failed', {
          'error': _jsErrorName(error),
          'bytes': bytes.length,
          // The numbers that separate "the buffer is full" from "the
          // MediaSource went away underneath us". `InvalidStateError` has
          // exactly two causes in the spec — `updating`, or a MediaSource that
          // is no longer `open` — and these tell them apart.
          'buffered_s': _bufferedSeconds(buffer).toStringAsFixed(1),
          'ranges': buffer.buffered.length,
          'updating': buffer.updating,
          'media_state': _media?.readyState ?? 'no_media',
          'source_buffers': _media?.sourceBuffers.length ?? -1,
          // The re-parent test: a `<video>` outside the document re-runs its
          // load algorithm, which detaches the MediaSource and drops every
          // SourceBuffer with it.
          'video_connected': _video.isConnected,
          'video_ready': _video.readyState,
          // The fourth and last of the spec's throw conditions, and the only
          // one the earlier fields could not rule out.
          'video_error': _video.error?.code ?? 0,
        });
      }
    }
  }

  /// A DOM exception's **name**, never its message.
  ///
  /// `error.runtimeType` is `JSObject` for everything thrown across the interop
  /// boundary, which is exactly as useful as no log line at all — measured on
  /// the live doorbell, where it hid a `QuotaExceededError`. The `name` is a
  /// fixed identifier (`QuotaExceededError`, `InvalidStateError`), so it says
  /// what happened without reproducing a `message` that can quote the URL —
  /// see the class doc on what a failure is allowed to say.
  String _jsErrorName(Object error) {
    try {
      // A cast rather than an `is` check: `is` against a JS interop type is
      // flagged as platform-inconsistent, and a failed cast lands in the same
      // catch as a property read that throws.
      final name =
          (error as JSObject).getProperty<JSString?>('name'.toJS)?.toDart;
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {
      // Not a JS object at all, or reading the property threw.
    }
    return error.runtimeType.toString();
  }

  double _bufferedSeconds(web.SourceBuffer buffer) {
    final ranges = buffer.buffered;
    if (ranges.length == 0) return 0;
    return ranges.end(ranges.length - 1) - ranges.start(0);
  }

  /// Keeps the last few seconds and drops the rest.
  ///
  /// Without it a wall panel accumulates every frame it has ever received in
  /// the SourceBuffer, and the picture drifts steadily further behind live —
  /// the two costs go2rtc's own player pays this same code to avoid. The
  /// playback-rate nudge is the reference player's: it catches a video up to
  /// the live edge without a visible seek.
  /// Returns true when it started an asynchronous `remove`, which means the
  /// caller must stand down until the resulting `updateend` re-enters.
  bool _trim(web.SourceBuffer buffer) {
    final buffered = buffer.buffered;
    if (buffered.length == 0) return false;
    final end = buffered.end(buffered.length - 1);
    final start = end - _liveWindowSeconds;
    final first = buffered.start(0);
    if (start > first) {
      buffer.remove(first, start);
      _media?.setLiveSeekableRange(start, end);
      // Nothing is seeked on this pass, and that is the fix rather than an
      // omission. `remove` is asynchronous and rounds *outwards* to a segment
      // boundary, so the ranges it leaves behind are not the ones computed
      // above — seeking to `start` here lands in the hole it is about to make.
      // Measured on a reused session, 2026-08-06: `currentTime 83.54` against
      // `buffered [[84.07, 88.54]]`, a third of a second past the edge, with
      // `readyState` stuck at HAVE_METADATA and nothing on the glass. The
      // removal fires its own `updateend`, which brings this method straight
      // back with ranges that are real.
      return true;
    }
    if (_video.currentTime < first || _video.currentTime > end) {
      _seekNearLiveEdge(buffer);
    }
    final gap = end - _video.currentTime;
    _video.playbackRate = gap > 0.1 ? gap : 0.1;
    return false;
  }

  /// Puts playback just behind the newest thing in the buffer.
  ///
  /// [_resyncBehindLiveSeconds] rather than the live edge itself: landing
  /// exactly on `end` leaves nothing to play and stalls at once. One second is
  /// also where [_trim]'s playback-rate nudge settles — it sets the rate to the
  /// gap in seconds, so a gap of one is the fixed point that loop converges on,
  /// and resyncing anywhere else just makes it work to get back here.
  void _seekNearLiveEdge(web.SourceBuffer buffer) {
    final buffered = buffer.buffered;
    if (buffered.length == 0) return;
    final end = buffered.end(buffered.length - 1);
    final first = buffered.start(0);
    final target = end - _resyncBehindLiveSeconds;
    _video.currentTime = target > first ? target : first;
  }

  static const _liveWindowSeconds = 5.0;
  static const _resyncBehindLiveSeconds = 1.0;

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

  /// The four handlers, converted **once**.
  ///
  /// `.toJS` mints a fresh `JSFunction` on every call, so a listener added
  /// with one and removed with another is never actually removed. These have
  /// to be stored for [_unwireSocket] to work at all — and it has to work, or
  /// the socket a reconnect just discarded still fires `close` into a session
  /// that has already moved on and fails it.
  late final JSFunction _onOpenJs = _onOpen.toJS;
  late final JSFunction _onMessageJs = _onMessage.toJS;
  late final JSFunction _onSocketErrorJs = _onSocketError.toJS;
  late final JSFunction _onSocketCloseJs = _onSocketClose.toJS;

  void _wireSocket() {
    _socket.binaryType = 'arraybuffer';
    _socket.addEventListener('open', _onOpenJs);
    _socket.addEventListener('message', _onMessageJs);
    _socket.addEventListener('error', _onSocketErrorJs);
    _socket.addEventListener('close', _onSocketCloseJs);
  }

  void _unwireSocket() {
    _socket.removeEventListener('open', _onOpenJs);
    _socket.removeEventListener('message', _onMessageJs);
    _socket.removeEventListener('error', _onSocketErrorJs);
    _socket.removeEventListener('close', _onSocketCloseJs);
  }

  /// Dials again after the decoder gave up, keeping the same `<video>`.
  ///
  /// **This is what go2rtc's own player does, and why it survives where this
  /// one did not.** The stream carries samples with sub-millisecond durations
  /// — measured repeatedly on the live doorbell as
  /// `duration=11` (one tick at 90 kHz) on a normal-sized P-frame — and
  /// Chrome's decoder rejects the frame that follows. go2rtc's reference
  /// client at `/stream.html` hits exactly the same failure on the same
  /// machine, which is how the fault was placed upstream rather than here; the
  /// difference is that it reconnects and this session used to stop for good.
  ///
  /// Not a fix for the malformed samples — nothing on this side can be. It
  /// re-rolls the dice with a fresh muxer, which is empirically enough,
  /// because the anomaly is in the first samples a consumer is given rather
  /// than in the stream as a whole.
  ///
  /// Drops to [LiveVideoPhase.connecting] rather than holding `playing` over a
  /// dead element: ADR-0007 again, and it is what puts the still photo back
  /// with an honest caption while the retry runs.
  void _reconnect(String because) {
    if (_closed || !_undecided) return;
    _reconnects++;
    Log.info('video', 'mse_reconnect', {
      'attempt': _reconnects,
      'of': _maxReconnects,
      'reason': because,
    });
    // Everything [_release] tears down except the verdict: the socket, the
    // object URL, the MediaSource and the element's source all go, and the
    // element itself stays exactly where it is in the document.
    _watchdog?.cancel();
    _watchdog = null;
    // Deaf before closed. This session stays [_undecided] across a reconnect —
    // that is the point of it — so the discarded socket's own `close` event
    // would otherwise reach `_onSocketClose` and settle the *new* attempt as
    // "go2rtc closed the socket", which is both wrong and unrecoverable.
    _unwireSocket();
    _socket.close();
    final objectUrl = _objectUrl;
    if (objectUrl != null) {
      web.URL.revokeObjectURL(objectUrl);
      _objectUrl = null;
    }
    _buffer = null;
    _media = null;
    _staged = 0;
    _video.pause();
    _video.removeAttribute('src');
    _video.load();
    // `load()` clears `error`, which is what makes the element usable again —
    // without it every later `appendBuffer` would keep throwing
    // `InvalidStateError` against the corpse of the last attempt.
    _phase.value = LiveVideoPhase.connecting;
    _socket = web.WebSocket(_url.toString());
    _wireSocket();
    _restartWatchdog(
        openTimeout, 'go2rtc sent no picture in ${openTimeout.inSeconds}s');
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
