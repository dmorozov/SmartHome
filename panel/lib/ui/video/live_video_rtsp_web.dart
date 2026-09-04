import '../../diagnostics/log.dart';
import 'live_video.dart';

var _warned = false;

/// The web branch's half of `live_video_rtsp_io.dart`'s decoder setting.
/// A browser picks its own decoder and offers no say in it, so this exists
/// only so `main()` compiles from one file — assigning it does nothing.
List<String>? rtspVideoDecoders;

/// The web branch's half of `live_video_rtsp_io.dart`'s low-latency knob,
/// here for `rtspVideoDecoders`' reason. Assigning it does nothing.
int rtspLowLatency = 0;

/// The web branch's half of the frame pulse. A browser drives its own
/// `<video>` element's painting, so there is nothing here to keep awake.
bool rtspFramePulse = true;

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

/// The web branch's half of the render-path instrumentation. A browser
/// paints its own `<video>`, so there is nothing here to measure.
bool rtspVideoDebug = false;

/// The web branch's half of `registerRtspPlayer`. A browser has no fvp and
/// no libmdk; it plays through MSE. Here so `main()` compiles from one file,
/// like the four inert knobs above — calling it does nothing.
void registerRtspPlayer() {}

