// Talks to a REAL go2rtc and opens a REAL stream, so running it has to be
// something you asked for on purpose:
//
//   cd panel && PANEL_LIVE_GO2RTC=1 GO2RTC_URL=http://192.168.68.81:1984 \
//       flutter test test/live_video_keepalive_live_test.dart
//
// PANEL_LIVE_GO2RTC is the opt-in, and it is the reason bare `flutter test`
// is still hermetic — the same gate and the same argument as
// `ha_hub_live_test.dart`'s PANEL_LIVE_HUB: a `GO2RTC_URL` that merely
// happens to be exported in somebody's shell is an ordinary thing to have,
// and it must not be enough to make a test reach out to a real house.
//
// **It plays `selftest` by default, not `ring_doorbell`, and that is
// deliberate.** The property under test is "does go2rtc's producer stay up
// across a close and a reopen", which is the same for every source, while
// pointing it at the doorbell would open a real Ring session — and #177014
// says an open Ring session can suppress the next real ding. Override with
// PANEL_LIVE_STREAM only if you mean it.
//
// This is the file that closes the gap issue #1's fix otherwise leaves open.
// Everything else about the keep-alive is hermetic
// (`live_video_keepalive_test.dart`), which proves the pooling logic and
// nothing about whether go2rtc agrees. What is proved here, measured against
// go2rtc 1.9.10 on 2026-08-06:
//
//   BASELINE consumers=0
//   OPENED   phase=playing consumers=2 dials=1
//   CLOSED   +3s consumers=2          <-- 0 before the fix
//   REOPENED phase=playing consumers=2 dials=1
//   DROPPED  after linger consumers=0
//
// `consumers=2` is our connection *plus* go2rtc's own on-demand
// `ffmpeg:…#video=mjpeg` producer, which is itself counted as a consumer of
// the stream — see `live_video_mjpeg.dart`, which measured the same thing.
//
// Only the MJPEG player is exercised: this is a VM binary, so the conditional
// import gives it the appliance branch. The MSE branch's own `<video>`
// re-parenting stays unproven, as its class says.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/config/runtime_env.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_keepalive.dart';

final _env = runtimeEnvironment();

final _go2rtcUrl = _env['GO2RTC_URL'] ?? '';

/// `selftest` unless somebody deliberately names another — see the header.
final _stream = (_env['PANEL_LIVE_STREAM'] ?? '').isNotEmpty
    ? _env['PANEL_LIVE_STREAM']!
    : 'selftest';

bool get _optedIn => (_env['PANEL_LIVE_GO2RTC'] ?? '').isNotEmpty;

String? get _skipReason {
  if (!_optedIn) {
    return 'live go2rtc test: run it on purpose with '
        'PANEL_LIVE_GO2RTC=1 and GO2RTC_URL in the environment';
  }
  if (_go2rtcUrl.isEmpty) {
    return 'PANEL_LIVE_GO2RTC is set but GO2RTC_URL is not';
  }
  return null;
}

/// How many consumers go2rtc reports on [_stream] — the independent witness.
/// The Panel's own log saying it kept a session proves only that the Panel
/// believes it; this is the server agreeing.
Future<int> _consumers() async {
  final client = HttpClient();
  try {
    final response = await (await client
            .getUrl(Uri.parse('$_go2rtcUrl/api/streams')))
        .close();
    final data = jsonDecode(await response.transform(utf8.decoder).join())
        as Map<String, Object?>;
    final entry = data[_stream] as Map<String, Object?>?;
    final list = entry?['consumers'];
    return list is List ? list.length : 0;
  } finally {
    client.close(force: true);
  }
}

Future<void> _settle(int seconds) =>
    Future<void>.delayed(Duration(seconds: seconds));

void main() {
  test('the producer survives a close and a reopen, and is let go when '
      'nobody comes back', () async {
    var dials = 0;
    final keep = LiveVideoKeepAlive(opener: (url, {required name}) {
      dials++;
      return openLiveVideo(url, name: name);
    });
    final url = VideoConfig(go2rtcUrl: _go2rtcUrl).urlFor(_stream)!;

    // 1. Open, and wait for a real picture rather than assuming one.
    final first = keep.open(url, name: _stream);
    for (var i = 0;
        i < 30 && first.phase.value != LiveVideoPhase.playing;
        i++) {
      await _settle(1);
    }
    expect(first.phase.value, LiveVideoPhase.playing,
        reason: 'go2rtc never produced a picture: ${first.failure}');
    expect(await _consumers(), greaterThanOrEqualTo(1));

    // 2. Let go. THE FIX: go2rtc's producer must still be running.
    first.close();
    await _settle(3);
    expect(await _consumers(), greaterThanOrEqualTo(1),
        reason: 'before the fix this had already fallen to 0, and the next '
            'open would have raced a fresh producer');

    // 3. Reopen inside the window: no second dial, and a picture that is
    // already there rather than 2.1 s away.
    final second = keep.open(url, name: _stream);
    expect(dials, 1,
        reason: 'a second dial is the relaunch that loses the IDR race');
    expect(second.phase.value, LiveVideoPhase.playing,
        reason: 'no spin-up — this is the whole product effect');

    // 4. Let go for real: #177014 says the session has to end on its own.
    second.close();
    await _settle(kLiveVideoLinger.inSeconds + 4);
    expect(await _consumers(), 0,
        reason: 'a kept session must end without anyone asking it to');

    keep.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)), skip: _skipReason ?? false);
}
