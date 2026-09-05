import '../../config/video_tuning.dart';
import '../../diagnostics/log.dart';
import 'live_video.dart';

var _warned = false;

/// The web branch of `live_video_rtsp.dart`: browsers do not speak RTSP,
/// so `VIDEO_TRANSPORT=rtsp` on a web build is a configuration slip — and
/// one that must cost nothing. This delegates to the platform's own player
/// (MSE, through `openLiveVideo`'s web branch) and says so once in the
/// log, rather than failing every stream on the wall over a dart-define.
///
/// The [RtspTuning] is discarded, and that is the whole of what this branch
/// has to say about it: a browser picks its own decoder, does its own
/// buffering, and paints its own `<video>` element, so there is nothing here
/// any of those four settings could reach. Taking the argument and ignoring
/// it is what lets `main()` resolve the tuning from one file for both
/// builds — the same bargain the four inert globals used to strike, at one
/// declaration instead of four.
LiveVideoOpener rtspOpener(RtspTuning _) =>
    (Uri url, {required String name}) {
      if (!_warned) {
        _warned = true;
        Log.warn('panel', 'video_transport_fallback', {
          'asked': 'rtsp',
          'using': 'platform',
          'why': 'browsers do not speak RTSP',
        });
      }
      return openLiveVideo(url, name: name);
    };

/// The web branch's half of `registerRtspPlayer`. A browser has no fvp and
/// no libmdk; it plays through MSE. Here so `main()` compiles from one file,
/// like [rtspOpener]'s ignored argument — calling it does nothing.
void registerRtspPlayer(RtspTuning _) {}
