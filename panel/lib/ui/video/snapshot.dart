import 'package:flutter/foundation.dart';

import '../../config/go2rtc_address.dart';

// Same both-not-just-the-export shape as `live_video.dart`, for the same
// reason: the export gives the rest of the Panel `fetchSnapshot`, and the
// import lets [SnapshotConfig] name it as its default.
//
// Two branches, two HTTP stacks — `dart:io` on the appliance, the browser's
// own `fetch` on web — because there is no HTTP client both builds can
// compile. The seam mirrors `live_video.dart` deliberately: phase-7 §B4
// calls this "a sibling seam beside VideoConfig, injected the same way,
// faked the same way".
import 'snapshot_io.dart' if (dart.library.js_interop) 'snapshot_web.dart';

export 'snapshot_io.dart' if (dart.library.js_interop) 'snapshot_web.dart';

/// What one snapshot fetch came back with.
///
/// [bytes] is a decodable JPEG or null; [status] is **an HTTP status code or
/// an exception's type name — never a message**. `dart:io`'s `HttpException`
/// and the browser's `TypeError` both embed the request URL in their
/// messages, this request carries the Hub token in its headers, and the one
/// place [status] goes is a `cameras.snapshot_failed` log line
/// (`diagnostics/log.dart`: **Never log a secret**).
@immutable
class SnapshotResult {
  const SnapshotResult.ok(Uint8List this.bytes) : status = 'ok';

  const SnapshotResult.refused(this.status) : bytes = null;

  final Uint8List? bytes;
  final String status;
}

/// Fetches one still image, authenticating with [token].
///
/// The token travels **only as an `Authorization: Bearer` header** — never
/// as a query parameter or a signed path. HA offers both and its own
/// frontend uses the query form; a token in a URL reaches logs, history and
/// error text, which is the G3 leak class all over again (phase-7 §B4).
///
/// An implementation may not throw — the caller is a widget's refresh tick,
/// and the way to say "no" is a [SnapshotResult.refused].
typedef SnapshotFetcher = Future<SnapshotResult> Function(Uri url,
    {required String token});

/// Where the Hub's REST API is and how to authenticate — one value, so the
/// Cameras view takes one parameter and a test can stage every scene.
///
/// Passed in rather than read from dart-defines, exactly like [VideoConfig]
/// and for the same reason: the widget tree must know nothing about which
/// build it came from. Deliberately **not** part of `HubClient`: the
/// contract test keeps that seam video-free, and a still image is this
/// seam's business (phase-7 §C2.3).
@immutable
class SnapshotConfig {
  const SnapshotConfig({
    this.haUrl = '',
    this.token = '',
    this.fetch = fetchSnapshot,
  });

  /// Base address of the Hub's REST API, e.g. `http://192.168.68.81:8123`.
  /// Empty means nobody named one — absent, not a localhost the Panel
  /// invented.
  final String haUrl;

  /// The same long-lived token the Hub socket authenticates with. Held here
  /// so the fetcher can send it as a header; never rendered into a URL.
  final String token;

  final SnapshotFetcher fetch;

  /// `http://host:8123` + `camera.front_door_snapshot` ->
  /// `http://host:8123/api/camera_proxy/camera.front_door_snapshot`.
  ///
  /// HA's camera-proxy endpoint serves the entity's **current cached
  /// image** — for an MQTT camera the JPEG HA already holds, so fetching it
  /// costs no device session. That property is the whole reason the Ring
  /// tile's off state exists (phase-7 §B4): go2rtc's frame-grab would
  /// *start* a Ring live session, the exact thing the off state avoids.
  ///
  /// Null instead of throwing, mirroring [VideoConfig.urlFor] clause for
  /// clause: a bad address must only ever cost the picture.
  Uri? urlFor(String? entityId) {
    if (haUrl.isEmpty ||
        token.isEmpty ||
        entityId == null ||
        entityId.isEmpty) {
      return null;
    }
    final base = Uri.tryParse(haUrl);
    // The same generosity guard as `VideoConfig.urlFor`: `localhost:8123`
    // parses as scheme `localhost` with no host at all.
    if (base == null || base.host.isEmpty) return null;
    return base.replace(pathSegments: ['api', 'camera_proxy', entityId]);
  }
}

/// The second still source (phase-8 A7): go2rtc's own frame grab, for the
/// cameras HA holds no JPEG for — the Wyze fleet, whose `snapshot:` binding
/// does not exist and should not: an HA camera entity per Wyze would be a
/// heavier integration bought for a picture go2rtc already has.
///
/// A sibling of [SnapshotConfig], not a mode of it: the two sources differ
/// in every fact that matters. This one is **tokenless** — go2rtc is
/// unauthenticated on this LAN (owner decision, phase-4 §B0) — so callers
/// pass `token: ''` and the fetchers send no Authorization header at all
/// (which on web also keeps the request simple: no CORS preflight for
/// go2rtc to fail). And unlike `camera_proxy`, **a fetch here can wake a
/// device**: a cache-miss `frame.jpeg` on a stream with no running producer
/// dials the camera for one keyframe (~3 s, measured 2026-08-25). The
/// `cache=45s` parameter is what bounds that: within the window go2rtc
/// answers from cache — byte-identical, sub-millisecond, no dial (measured)
/// — so a remount storm after a zoom-and-back costs the camera nothing.
///
/// **The doorbell never reaches this class.** Any go2rtc consumer on the
/// Ring stream — a frame grab included — opens a real Ring cloud session
/// and suppresses dings (HA core #177014). The call site enforces it by
/// kind (`DeviceKind.camera` only) and the doorbell's still stays HA-held
/// through [SnapshotConfig].
/// The go2rtc frame-grab cache window — how long a repeat `frame.jpeg` is
/// answered from cache (byte-identical, sub-millisecond, no camera dial;
/// measured) before the next fetch dials for a fresh keyframe.
///
/// **Deliberately shorter than the tile's refresh cadence**
/// (`kCamerasSnapshotRefresh`, 60 s): each periodic tick lands past the
/// window and gets a fresh frame, while remount storms inside it — a
/// zoom-and-back, a view reopen — are free. Raise this past the cadence and
/// every tick silently returns the same cached bytes (a frozen face logging
/// `snapshot_ok`); lower the cadence below this and ticks silently
/// coalesce. The ordering is pinned by a test in `cameras_view_test.dart`.
const kGo2rtcStillCache = Duration(seconds: 45);

@immutable
class Go2rtcStillsConfig {
  const Go2rtcStillsConfig({this.go2rtcUrl = '', this.fetch = fetchSnapshot});

  /// Base address of go2rtc, e.g. `http://192.168.68.81:1984` — the same
  /// value `VideoConfig.go2rtcUrl` carries, spelled here again because this
  /// config travels to a surface (the still loop) that must not reach into
  /// the video seam for it. Empty means unconfigured: [urlFor] answers null
  /// and the tile simply has no go2rtc still face.
  final String go2rtcUrl;

  final SnapshotFetcher fetch;

  /// Where go2rtc is — see [Go2rtcAddress], and [VideoConfig.address] for why
  /// this is a getter.
  Go2rtcAddress get address => Go2rtcAddress.parse(go2rtcUrl);

  /// `http://host:1984` + `wyze_garage_door_sub` ->
  /// `http://host:1984/api/frame.jpeg?src=wyze_garage_door_sub&cache=45s`.
  ///
  /// Null instead of throwing, mirroring [SnapshotConfig.urlFor] and
  /// `VideoConfig.urlFor` clause for clause: a bad address must only ever
  /// cost the picture.
  Uri? urlFor(String? streamName) {
    if (streamName == null || streamName.isEmpty) return null;
    if (address case Go2rtcAt(:final base)) {
      return base.replace(
        path: '/api/frame.jpeg',
        queryParameters: {
          'src': streamName,
          'cache': '${kGo2rtcStillCache.inSeconds}s',
        },
      );
    }
    return null;
  }
}
