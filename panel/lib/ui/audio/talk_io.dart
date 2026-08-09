import 'dart:async';
import 'dart:io';

import 'talk.dart';

/// How long one talk call gets before it is called off.
///
/// Shorter than `kSnapshotTimeout`: this one is in the hand-feel path. A
/// button that takes ten seconds to admit it could not open the microphone
/// has told the person at the wall nothing while they stood there talking.
const kTalkTimeout = Duration(seconds: 4);

/// The appliance's poster: one `dart:io` POST per call.
///
/// A client per call rather than a shared one, for `snapshot_io.dart`'s
/// reason: presses are seconds apart at best, so there is no connection worth
/// keeping warm, and a shared client is a shared lifetime nobody here owns.
///
/// Never throws, and no failure carries the URL or the exception message —
/// `HttpException` appends `, uri = …` and a fat-fingered `GO2RTC_URL` can
/// carry a password. The status is the HTTP code or the exception's bare type
/// name (`talk.dart`).
Future<TalkResult> postTalk(Uri url) async {
  final client = HttpClient();
  try {
    return await _post(client, url).timeout(kTalkTimeout);
  } catch (error) {
    return TalkResult.refused(error.runtimeType.toString());
  } finally {
    client.close(force: true);
  }
}

Future<TalkResult> _post(HttpClient client, Uri url) async {
  final request = await client.postUrl(url);
  // go2rtc reads this call entirely from the query string; the body is empty
  // and saying so explicitly is what stops `dart:io` from opening a chunked
  // request that go2rtc has no reason to wait for.
  request.contentLength = 0;
  final response = await request.close();
  // Drained either way: an undrained response holds the socket open until the
  // `close(force: true)` above tears it down, and on the success path that is
  // the difference between a clean release and a reset mid-press.
  await response.drain<void>();
  if (response.statusCode != HttpStatus.ok) {
    return TalkResult.refused('${response.statusCode}');
  }
  return const TalkResult.ok();
}
