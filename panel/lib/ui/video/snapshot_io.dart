import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'snapshot.dart';

/// How long one still image gets before the fetch is called off. Generous
/// for a LAN JPEG; the point is that a wedged Hub costs one refresh tick,
/// not a connection held forever.
const kSnapshotTimeout = Duration(seconds: 10);

/// The appliance's fetcher: one `dart:io` GET per call.
///
/// A client per call rather than a shared one: snapshots refresh on the
/// order of a minute, so there is no connection worth keeping warm, and a
/// shared client is a shared lifetime nobody here owns. `close(force:)` in
/// `finally` is what guarantees no socket outlives the tick.
///
/// Never throws, and — the rule this file exists to keep — **no failure
/// carries the URL or the exception message**: `HttpException` appends
/// `, uri = …` to its message, and this request's headers carry the Hub
/// token. The status is the HTTP code or the exception's bare type name.
Future<SnapshotResult> fetchSnapshot(Uri url, {required String token}) async {
  final client = HttpClient();
  try {
    return await _get(client, url, token).timeout(kSnapshotTimeout);
  } catch (error) {
    return SnapshotResult.refused(error.runtimeType.toString());
  } finally {
    client.close(force: true);
  }
}

Future<SnapshotResult> _get(HttpClient client, Uri url, String token) async {
  final request = await client.getUrl(url);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    return SnapshotResult.refused('${response.statusCode}');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return SnapshotResult.ok(builder.takeBytes());
}
