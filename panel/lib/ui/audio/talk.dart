import 'package:flutter/foundation.dart';

// Both, not just the export — the same shape as `video/snapshot.dart` and for
// the same reason: the export gives the rest of the Panel `postTalk`, and the
// import is what lets [TalkConfig] name it as its default.
//
// Two branches, two HTTP stacks — `dart:io` on the appliance, the browser's own
// `fetch` on web — because there is no HTTP client both builds can compile.
// This is a third sibling beside `VideoConfig` and `SnapshotConfig`, injected
// the same way and faked the same way.
import 'talk_io.dart' if (dart.library.js_interop) 'talk_web.dart';

export 'talk_io.dart' if (dart.library.js_interop) 'talk_web.dart';

/// What the push-to-talk button can honestly say.
///
/// Five, for [LiveVideoPhase]'s reason at a control's scale: "nobody told the
/// Panel where go2rtc is" is a config fact knowable at open, and it is a
/// different thing from "go2rtc answered and refused", which is different
/// again from "the microphone is open". Collapsing them would put one grey
/// caption under three problems with three different fixes.
enum TalkPhase {
  /// No go2rtc address, or no `talk:` stream on this Device. Nothing was
  /// dialled and nothing is wrong — the Panel simply has not been told.
  unconfigured,

  /// Configured, and nobody is holding the button.
  idle,

  /// The START call is in flight. A distinct phase because it is not
  /// instantaneous — go2rtc has to dial Ring's backchannel — and a button
  /// that looked live during it would be claiming a microphone that is not
  /// open yet.
  opening,

  /// go2rtc accepted the microphone as a producer on the talk stream.
  ///
  /// Precisely that, and the caption says no more: a `200` means the API took
  /// the producer, not that a person at the door heard anything. That is the
  /// strongest claim this API affords, and ADR-0007's rule — a thing that is
  /// not happening may not look like it is — is what keeps the wording down
  /// to what the status code actually backs.
  open,

  /// go2rtc was reachable and refused, or could not be reached at all.
  /// Deliberately sticky until the next press: a release is quick, and a
  /// failure the operator never gets to read is a failure reported to nobody.
  failed,
}

/// What one talk call came back with.
///
/// [status] is **an HTTP status code or an exception's type name — never a
/// message**, for the rule `snapshot.dart` states: `dart:io`'s `HttpException`
/// appends `, uri = …`, the browser's `TypeError` quotes the URL it refused,
/// and a fat-fingered `GO2RTC_URL` can carry a password. The one place this
/// goes is a `popup.talk_failed` log line (`diagnostics/log.dart`: **Never log
/// a secret**).
@immutable
class TalkResult {
  const TalkResult.ok() : ok = true, status = 'ok';

  const TalkResult.refused(this.status) : ok = false;

  final bool ok;
  final String status;
}

/// Posts one talk call. [url] is already complete — see [TalkConfig.startUrl].
///
/// An implementation may not throw: the callers are a gesture callback and
/// [State.dispose], and neither has anywhere to put an exception. The way to
/// say no is a [TalkResult.refused].
typedef TalkPoster = Future<TalkResult> Function(Uri url);

/// go2rtc's own view of its RTSP listener, which is what `src=` names.
///
/// Unlike `GO2RTC_URL` this earns a built-in default, and the difference is
/// worth being precise about: `GO2RTC_URL` is the address *this Panel* dials,
/// so it is site-specific and a default would be a localhost the Panel
/// invented. This string is never dialled by the Panel at all — it is handed
/// to go2rtc, which resolves it against **its own** loopback. Container-side
/// or host-side, dev or appliance, go2rtc's RTSP listener is on 127.0.0.1:8554
/// and the stream is called `mic`, because the same `go2rtc.yaml` ships with
/// both. So this is a constant of the deployment, not a fact about the house.
///
/// The RTSP form is ADR-0011's, deliberately: the `mic` stream already
/// produces `opus/48000/2` and Ring negotiates `opus/48000/2`, so this is a
/// passthrough with no re-encode. `ffmpeg:mic#audio=opus` also works and
/// transcodes; a bare `src=mic` does not (`HTTP 500 · unsupported scheme`).
const defaultTalkMicSource = 'rtsp://127.0.0.1:8554/mic';

/// Where go2rtc is and what to push into it when the button is held — one
/// value, so the Popup takes one parameter and a test can stage every scene
/// without a `--dart-define`.
///
/// A sibling of [VideoConfig], not a part of it, even though both hold
/// `go2rtcUrl`: the Popup can play video on a Device that has no talkback, and
/// every non-doorbell Popup in the house is exactly that. Folding talk into
/// [VideoConfig] would put a doorbell-only concern in the type every camera
/// tile passes around.
@immutable
class TalkConfig {
  const TalkConfig({
    this.go2rtcUrl = '',
    this.micSource = defaultTalkMicSource,
    this.post = postTalk,
  });

  /// Base address of go2rtc, e.g. `http://192.168.68.81:1984`. Empty means
  /// nobody named one — [ConfigSource.absent], not a localhost the Panel
  /// invented for itself. The same string [VideoConfig.go2rtcUrl] carries;
  /// `main()` resolves it once and hands it to both.
  final String go2rtcUrl;

  /// What `src=` names on the START call. See [defaultTalkMicSource].
  final String micSource;

  final TalkPoster post;

  /// `http://host:1984` + `ring` ->
  /// `http://host:1984/api/streams?dst=ring&src=rtsp%3A%2F%2F127.0.0.1%3A8554%2Fmic`
  ///
  /// [talkStream] is the Device's `talk:` binding — **not** its `stream:`. The
  /// two are different go2rtc streams and neither derives from the other: the
  /// Front Door plays `ring_doorbell` (ring-mqtt's RTSP restream, video) and
  /// talks into `ring` (go2rtc's native `ring:` source, which is the only one
  /// of the two with a backchannel). Deriving one from the other by suffix
  /// would be a convention the house's configuration does not have.
  ///
  /// Null instead of throwing, for [VideoConfig.urlFor]'s reason clause for
  /// clause: a bad address must only ever cost the talkback. A
  /// `FormatException` out of a gesture callback would take the frame down.
  Uri? startUrl(String? talkStream) =>
      micSource.isEmpty ? null : _urlFor(talkStream, micSource);

  /// The same URL with an empty `src`, which is go2rtc's stop.
  ///
  /// Idempotent — verified 40/40 returning 200 across 20 press/release cycles
  /// with zero leaked ffmpeg processes (ADR-0011) — which is why it is fired
  /// liberally rather than carefully: on release, on a failed start, and again
  /// from [State.dispose].
  Uri? stopUrl(String? talkStream) => _urlFor(talkStream, '');

  Uri? _urlFor(String? talkStream, String src) {
    if (go2rtcUrl.isEmpty || talkStream == null || talkStream.isEmpty) {
      return null;
    }
    final base = Uri.tryParse(go2rtcUrl);
    // The same generosity guard as [VideoConfig.urlFor]: `localhost:1984`
    // parses happily, as a URI with scheme `localhost` and no host at all.
    if (base == null || base.host.isEmpty) return null;
    // The query is spelled out rather than handed to `queryParameters:`,
    // and the reason is the stop call. `Uri.replace(queryParameters: {'src':
    // ''})` renders the empty value as a bare `src`, with no `=` — which is
    // *probably* fine, since Go's `net/url` reads `src` and `src=` alike, but
    // "probably" is the wrong standard for the one call that closes a live
    // microphone. ADR-0011's `src=` is what was verified 40/40 against the
    // real server, and this keeps the bytes identical to it.
    final query = 'dst=${Uri.encodeQueryComponent(talkStream)}'
        '&src=${Uri.encodeQueryComponent(src)}';
    return base.replace(path: '/api/streams', query: query);
  }
}
