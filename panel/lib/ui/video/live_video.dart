import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

// Both, not just the export: the export is what gives the rest of the Panel
// `openLiveVideo` and `liveVideoIsAvailable`, and the import is what lets
// [VideoConfig] name `openLiveVideo` and `liveVideoEndpoint` in its own body.
// Same shape as `config/runtime_env.dart`, which only needs the export because
// nothing in its own body mentions the symbols it re-exports.
//
// The two branches are two *transports*, not a player and a placeholder:
// `live_video_mjpeg.dart` plays multipart JPEG over HTTP on the appliance,
// `live_video_mse.dart` plays fMP4 over a WebSocket in a browser. The file
// was called `live_video_stub.dart` while the appliance had no player; the
// Flutter/cage kiosk is the primary target, so a stub there was the wrong
// half of the seam to leave empty and the name became a lie (owner decision,
// 2026-08-04).
import 'live_video_mjpeg.dart' if (dart.library.js_interop) 'live_video_mse.dart';

export 'live_video_mjpeg.dart' if (dart.library.js_interop) 'live_video_mse.dart';

/// What the Popup's video box can honestly say.
///
/// Five, not two. "Nobody told the Panel where go2rtc is" is a config fact
/// knowable at boot, and it is a different thing from "go2rtc answered and
/// refused", which is a different thing again from "this build cannot play
/// video at all". Collapsing them is the ADR-0007 mistake reproduced at
/// Device scale: the wall would show one grey rectangle for three problems
/// with three different fixes, and whoever is standing there would have no
/// way to tell a typo in a `--dart-define` from a camera that is unplugged.
enum LiveVideoPhase {
  /// No go2rtc address, or no stream name on this Device. Nothing was
  /// dialled, and nothing is wrong — the Panel simply has not been told.
  unconfigured,

  /// A connection is open and no picture has arrived yet.
  ///
  /// Measured, and the reason this phase has to be honest rather than
  /// cosmetic: go2rtc starts the ffmpeg transcode on demand, so the first
  /// byte of an MJPEG stream lands **2.1 s** after the request (4.1 s cold).
  /// A wall that flashed "unavailable" for those seconds would send whoever
  /// is standing there to debug a camera that is about to work.
  connecting,

  /// Frames are arriving; [LiveVideoSession.view] is worth rendering.
  playing,

  /// go2rtc was reachable and said no, or stopped answering.
  failed,

  /// This build, on this machine, has no way to play video.
  ///
  /// No longer a whole-platform verdict: both branches of the seam now carry
  /// a real player. What still reaches this is the browser that has no
  /// `MediaSource` at all — the web branch checks before it dials, because
  /// [failed] would send an operator to look at go2rtc for a fault that is
  /// in the browser. Distinct from [failed] because no amount of fixing the
  /// Hub will change it.
  unsupported,
}

/// One Popup's live view, from the moment it is opened to the moment the
/// Popup goes away.
///
/// An interface rather than a class because there are two real
/// implementations behind a conditional import and neither can be compiled
/// into every test binary — the MJPEG one needs `dart:io`, the MSE one needs
/// a browser. So every test that has an opinion about *when* a session is
/// opened and closed drives one of these by hand.
abstract interface class LiveVideoSession {
  ValueListenable<LiveVideoPhase> get phase;

  /// The last failure verbatim from go2rtc, for the log — never for the
  /// wall. It is a human sentence go2rtc is free to reword, so it is logged
  /// and never branched on.
  ///
  /// Both players are held to one rule when they fill this in: **it may not
  /// contain the URL**, because a fat-fingered `GO2RTC_URL` can carry a
  /// password and `dart:io`'s own `HttpException` appends `uri = …` to its
  /// message. Transport failures are reported by exception *type*; the only
  /// sentences reproduced here are go2rtc's own error frame — through
  /// `redactCredentials` in `diagnostics/url_redaction.dart`, which is
  /// best-effort over a string another process composed and says in its own
  /// docstring exactly where it stops — and strings the two players construct
  /// themselves out of counts. See `diagnostics/log.dart`: **Never log a
  /// secret**.
  String? get failure;

  /// What to render once [phase] is [LiveVideoPhase.playing].
  ///
  /// Never a spinner, in any phase: a [CircularProgressIndicator] never
  /// settles, so `pumpAndSettle` would hang every widget test that opens a
  /// camera — and a wall panel showing a spinner forever is the same lie as
  /// a stale reading.
  ///
  /// Stable across calls in both players. The Popup rebuilds this getter on
  /// every phase change, and the MSE one hands out a platform view that owns
  /// a `<video>` element — building a fresh one per rebuild would tear the
  /// picture down and put it back.
  ///
  /// **And since `live_video_keepalive.dart`, one of these is mounted more
  /// than once per session** — a Popup closes, the pool keeps the session, and
  /// the next Popup mounts this same widget again. A player holding platform
  /// state behind it owes that state a second start: issue #1's reused stream
  /// came back frozen because the MSE branch's `<video>` is paused by the HTML
  /// spec when the closing Popup takes it out of the document, and only
  /// `sourceopen` — which fires once per session — had ever called `play()`.
  /// See `MseLiveVideoSession._resume`. The appliance branch owes nothing here:
  /// its view is a `ValueListenableBuilder` over a frame notifier, and
  /// remounting it just rebuilds.
  Widget get view;

  /// Whether this session's sound — where the transport carries any —
  /// reaches the speakers. **Every session is born muted**, all four
  /// implementations: the web `<video>` needs it for autoplay, the RTSP
  /// player would otherwise play six camera audio tracks over each other
  /// the moment the grid opens (both Wyze stream tiers carry `pcm_mulaw`,
  /// probed 2026-08-26), and MJPEG carries no audio at all. Unmuting is a
  /// SURFACE decision, and only the person-opened surface — the Popup —
  /// makes it (the doorbell's LISTEN leg, ADR-0011; ducked back to muted
  /// while the talk button is held, half-duplex).
  ///
  /// Never throws, callable in any phase, idempotent; a transport with no
  /// audio (MJPEG) or no player (settled sessions) answers with a no-op.
  /// The keep-alive pool re-mutes every session it lingers, so audio can
  /// never outlive the surface that asked for it (`live_video_keepalive
  /// .dart` — the pool's own guarantee, not the Popup's diligence).
  void setMuted(bool muted);

  /// Idempotent: the Popup can be dismissed by three routes and the timer
  /// can fire during the fourth.
  ///
  /// And not merely bookkeeping — it must drop the socket or the HTTP
  /// connection, because go2rtc keeps the on-demand ffmpeg transcode running
  /// for as long as a consumer is attached.
  ///
  /// That is the contract a *player* keeps. It is not what the caller
  /// observes on the wall: `main()` composes `VideoConfig.open` out of
  /// `live_video_keepalive.dart`, whose sessions answer this by handing the
  /// running one back to the pool for `kLiveVideoLinger` before the player's
  /// own `close` is reached. Issue #1 — a reopen 1.1 s after a teardown
  /// relaunches ring-mqtt's producer and joins the new stream mid-GOP, with
  /// no later keyframe to heal with. Both callers are unchanged and both
  /// still owe this call by every route out; what changed is only how soon
  /// the socket behind it goes.
  ///
  /// Measured, and the earlier "returns `consumers` to `[]` immediately" was
  /// only half of it: from [LiveVideoPhase.playing] the count is back to `[]`
  /// inside a second, but a session closed during [LiveVideoPhase.connecting]
  /// sees `consumers` *rise after* the close and take 2–10 s to drain. Our own
  /// connection is gone at once (measured with a raw socket); what lingers is
  /// go2rtc's on-demand transcode, itself a consumer of the stream, finishing
  /// a spin-up nobody is waiting for any more. Attribution is inference; the
  /// timing is not. It costs a dismissed doorbell Popup a few seconds of
  /// transcode, and nothing else.
  void close();
}

/// Opens a session against the endpoint [VideoConfig.urlFor] built for this
/// build's transport — an `/api/ws` WebSocket on web, an `/api/stream.mjpeg`
/// HTTP request on the appliance.
///
/// [name] is passed separately so diagnostics can name the stream without
/// ever rendering the URL — see `diagnostics/log.dart`: a stream name is safe
/// to log, a URL that might have been fat-fingered into carrying credentials
/// is not.
///
/// An implementation may not throw. Reaching the network is allowed to fail;
/// the way to say so is a session already in [LiveVideoPhase.failed], because
/// a throw out of the Popup's `initState` costs the whole Dialog — the Device
/// name and the Close button with it.
typedef LiveVideoOpener = LiveVideoSession Function(Uri url,
    {required String name});

/// Where go2rtc is and how to reach it — one value, so the Popup takes one
/// parameter and a test can stage every scene without a `--dart-define`.
///
/// Passed in rather than read from the build's dart-defines, exactly like
/// [PanelApp.hubLabel] and for the same reason: the widget tree must know
/// nothing about which build it came from.
@immutable
class VideoConfig {
  const VideoConfig({this.go2rtcUrl = '', this.open = openLiveVideo});

  /// Base address of go2rtc, e.g. `http://192.168.68.81:1984`. Empty means
  /// nobody named one — `ConfigSource.absent`, not a localhost the Panel
  /// invented for itself.
  final String go2rtcUrl;

  final LiveVideoOpener open;

  /// `http://host:1984` + `ring_doorbell` ->
  /// `ws://host:1984/api/ws?src=ring_doorbell`.
  ///
  /// The seam's one spelling of "this go2rtc, this stream", and deliberately
  /// **not** per-transport even though the two players dial different paths.
  /// The Popup opens a stream and never reads a byte of one, so which
  /// transport this build speaks is not its business: `live_video_mjpeg.dart`
  /// maps this to `http://host:1984/api/stream.mjpeg?src=ring_doorbell`
  /// inside the file that implements MJPEG. Rejected: making this getter
  /// answer differently per platform — that lifts a transport detail above
  /// the seam, and every suite asserting what the Popup dialled would then
  /// have to assert two things and mean one.
  ///
  /// Mirrors [HaHubClient.webSocketUrl]'s http->ws transform. One stream name
  /// serves both transports: go2rtc's `selftest` carries an h264 producer and
  /// an mjpeg producer under a single name, verified on the live server, so
  /// `bindings.yaml` names it once. Rejected: a `_mjpeg` suffix convention,
  /// which would put a transport detail into the house's configuration and
  /// make every camera two entries that can drift apart.
  ///
  /// Returns null instead of throwing where [HaHubClient.webSocketUrl] would
  /// throw: a bad `HA_URL` stops the Hub and the badge says so across the
  /// room, while a bad `GO2RTC_URL` must only ever cost the video. A
  /// `FormatException` thrown out of the Popup's `initState` would take the
  /// whole Dialog — including the Device name and the Close button — down
  /// with it.
  Uri? urlFor(String? streamName) {
    if (go2rtcUrl.isEmpty || streamName == null || streamName.isEmpty) {
      return null;
    }
    final base = Uri.tryParse(go2rtcUrl);
    // `Uri.tryParse` is generous: `localhost:1984` parses happily, as a URI
    // with scheme `localhost` and no host at all. Requiring a host is what
    // separates an address from a typo — and it is checked here, once, above
    // the seam, so both players refuse exactly the same set of addresses.
    if (base == null || base.host.isEmpty) return null;
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/ws',
      queryParameters: {'src': streamName},
    );
  }
}

/// The H.264 level this Panel asks a browser decoder to be ready for: `0x33`,
/// level 5.1, which allows 36 864 macroblocks per frame.
///
/// Chosen as a ceiling rather than a fit. The level in a MIME type is a
/// *capability hint* — it tells the decoder what to be prepared for, and the
/// bitstream's own SPS still governs what is actually decoded — so declaring
/// more than a stream needs costs nothing, while declaring less is fatal.
const kMseH264Level = 0x33;

/// Raises the H.264 level in a `video/mp4; codecs="avc1.…"` MIME type, or
/// returns null when it is already high enough (or is not H.264 at all).
///
/// Works around go2rtc advertising a level below the stream's real one.
///
/// **This exists because of a go2rtc bug, and it was measured.** The first
/// diagnosis here blamed Ring's encoder for declaring a level its own frames
/// exceed. That was **wrong**, and the bitstream disproves it — read off the
/// live init segment on 2026-08-10:
///
/// | source | level |
/// |---|---|
/// | SPS in the bitstream | **50 (0x32) — Level 5.0** |
/// | `avcC` box in the init segment | **50 (0x32) — Level 5.0** |
/// | go2rtc's MIME answer | **41 (0x29) — Level 4.1** |
///
/// Ring is conformant: Level 5.0 permits 22 080 macroblocks and a 1536×1536
/// frame is 9216. **go2rtc understates it.** `pkg/h264/h264.go`'s
/// `GetProfileLevelID` sanitises the level it parses against a whitelist:
///
/// ```go
/// level := byte(41)                 // default
/// switch conf[2] {
/// case 30, 31, 40:                  // 3.0, 3.1, 4.0 only
///     level = conf[2]
/// }
/// ```
///
/// 50 is not in that list, so the real level is discarded and the default 41
/// stands. Every stream above Level 4.0 is advertised as 4.1 — which is below
/// what this frame size needs (9216 > 4.1's 8192), so a decoder that believes
/// the MIME cannot allocate for the picture it is about to receive.
///
/// Chrome does believe it. `MediaSource.isTypeSupported` returns **true**,
/// because all it does is parse the string; the decoder is then configured for
/// level 4.1 and rejects the first keyframe outright:
///
/// ```text
/// PIPELINE_ERROR_DECODE: Failed to send video packet for decoding:
///   {timestamp=0 duration=1011 size=93997 is_key_frame=1 encrypted=0}
/// ```
///
/// Measured against the live doorbell, same stream, same socket, one byte
/// different:
///
/// | declared | totalVideoFrames | readyState | error |
/// |---|---|---|---|
/// | `avc1.640029` (4.1) | **0** | 1 | `PIPELINE_ERROR_DECODE` |
/// | `avc1.640033` (5.1) | **180+** | 4 | none, full picture decoded |
///
/// **The fault is not in this Panel** — go2rtc's own reference player at
/// `/stream.html` fails identically on the same stream, which is how it was
/// localised. This is a client-side workaround for an upstream defect, applied
/// at the one place that can see the MIME before the decoder is built, and it
/// is worth filing: the reproduction is one `GET` and four bytes.
///
/// Only `avc1` is touched. H.265 (`hvc1.…`) uses a different string grammar and
/// no Ring stream produces it, so guessing at it would be inventing a rule for
/// a case nobody has seen.
String? raiseH264Level(String mime) {
  // `avc1.PPCCLL` — profile_idc, constraint flags, level_idc, each one hex
  // byte. Only the last is rewritten; the profile must survive untouched or
  // the decoder is told to expect the wrong syntax entirely.
  final match = RegExp(r'avc1\.([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})').firstMatch(mime);
  if (match == null) return null;
  final level = int.parse(match.group(2)!, radix: 16);
  if (level >= kMseH264Level) return null;
  final raised = kMseH264Level.toRadixString(16).padLeft(2, '0');
  return mime.replaceRange(
    match.start,
    match.end,
    'avc1.${match.group(1)}$raised',
  );
}

/// A session that was over before it began: one phase, forever, and closing
/// it does nothing.
///
/// What both players answer instead of throwing — a browser with no
/// `MediaSource` ([LiveVideoPhase.unsupported]), a `WebSocket` constructor
/// that raised, an `HttpClient` that would not take the URL. Shared rather
/// than written twice so the two halves of the seam cannot drift into
/// disagreeing about what a session that never opens looks like.
@immutable
class SettledLiveVideoSession implements LiveVideoSession {
  SettledLiveVideoSession(LiveVideoPhase phase, {this.failure})
      : phase = _Unchanging(phase);

  @override
  final ValueListenable<LiveVideoPhase> phase;

  @override
  final String? failure;

  /// Never asked for: the Popup renders [view] only in
  /// [LiveVideoPhase.playing], and a settled session is never in it.
  @override
  Widget get view => const SizedBox.shrink();

  @override
  void setMuted(bool muted) {} // Nothing was dialled; there is no sound.

  @override
  void close() {}
}

/// A [ValueListenable] that cannot change, so it needs no listener list.
///
/// Rejected: a shared `ValueNotifier` constant — that is mutable state with
/// a listener list at library scope, and one Popup disposing it would break
/// every Popup after it.
@immutable
class _Unchanging<T> implements ValueListenable<T> {
  const _Unchanging(this.value);

  @override
  final T value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
