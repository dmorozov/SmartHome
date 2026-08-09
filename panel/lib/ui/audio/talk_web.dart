import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'talk.dart';

/// The same budget as the appliance branch, for the same reason.
const kTalkTimeout = Duration(seconds: 4);

/// The web poster: the browser's own `fetch`.
///
/// Unlike `snapshot_web.dart` this sends **no headers** — go2rtc's API has no
/// authentication, and the network boundary is the control (root README, E8).
/// That makes this a CORS *simple request*, so there is no preflight to fail;
/// go2rtc's `api: origin: "*"` is still what lets the response be read.
///
/// Never throws, and no failure carries the URL or an exception message — the
/// same rule as the `dart:io` branch, kept independently because a browser
/// `TypeError` quotes the URL it refused.
Future<TalkResult> postTalk(Uri url) async {
  try {
    return await _post(url).timeout(kTalkTimeout);
  } catch (error) {
    return TalkResult.refused(error.runtimeType.toString());
  }
}

Future<TalkResult> _post(Uri url) async {
  final response = await web.window
      .fetch(url.toString().toJS, web.RequestInit(method: 'POST'))
      .toDart;
  if (response.status != 200) {
    return TalkResult.refused('${response.status}');
  }
  return const TalkResult.ok();
}
