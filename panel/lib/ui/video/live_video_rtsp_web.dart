import '../../diagnostics/log.dart';
import 'live_video.dart';

var _warned = false;

/// The web branch of `live_video_rtsp.dart`: browsers do not speak RTSP,
/// so `VIDEO_TRANSPORT=rtsp` on a web build is a configuration slip — and
/// one that must cost nothing. This delegates to the platform's own player
/// (MSE, through `openLiveVideo`'s web branch) and says so once in the
/// log, rather than failing every stream on the wall over a dart-define.
LiveVideoSession openRtspVideo(Uri url, {required String name}) {
  if (!_warned) {
    _warned = true;
    Log.warn('panel', 'video_transport_fallback', {
      'asked': 'rtsp',
      'using': 'platform',
      'why': 'browsers do not speak RTSP',
    });
  }
  return openLiveVideo(url, name: name);
}
