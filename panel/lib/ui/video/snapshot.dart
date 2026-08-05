import 'package:flutter/foundation.dart';

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
