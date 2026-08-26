import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'snapshot.dart';

/// How long one still image gets before the fetch is called off — the same
/// budget as the appliance branch, for the same reason.
const kSnapshotTimeout = Duration(seconds: 10);

/// The web fetcher: the browser's own `fetch`, with the token as a header.
///
/// The `Authorization` header makes this a non-simple request, so the
/// browser preflights it — expected, and the reason the Hub needs
/// `http: cors_allowed_origins:` naming this build's origin before the tile
/// shows anything (phase-7 §B4). A CORS refusal surfaces here as a
/// `TypeError` with no detail, by the browser's design.
///
/// Never throws, and no failure carries the URL or an exception message —
/// the same rule as the `dart:io` branch, kept independently because a
/// browser `TypeError` quotes the URL it refused.
Future<SnapshotResult> fetchSnapshot(Uri url, {required String token}) async {
  try {
    return await _get(url, token).timeout(kSnapshotTimeout);
  } catch (error) {
    return SnapshotResult.refused(error.runtimeType.toString());
  }
}

Future<SnapshotResult> _get(Uri url, String token) async {
  // No token, no header — the go2rtc source (`Go2rtcStillsConfig`) is
  // tokenless by design, and here the absence buys more than hygiene: a
  // request without `Authorization` stays a *simple* CORS request, so the
  // browser never preflights go2rtc (whose `origin: "*"` answers the
  // response header, not an OPTIONS dance).
  final headers = web.Headers();
  if (token.isNotEmpty) headers.append('Authorization', 'Bearer $token');
  final response = await web.window
      .fetch(url.toString().toJS, web.RequestInit(headers: headers))
      .toDart;
  if (response.status != 200) {
    return SnapshotResult.refused('${response.status}');
  }
  final buffer = await response.arrayBuffer().toDart;
  // go2rtc answers a dead camera's `frame.jpeg` with a ZERO-BYTE 200
  // (measured 2026-08-25) — an empty body is a refusal, not a picture.
  final bytes = buffer.toDart.asUint8List();
  if (bytes.isEmpty) return SnapshotResult.refused('empty');
  return SnapshotResult.ok(bytes);
}
