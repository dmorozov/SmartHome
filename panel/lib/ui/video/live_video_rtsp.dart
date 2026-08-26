/// The RTSP/H.264 transport behind the seam (phase-8 N5) — selected at the
/// composition root by `--dart-define=VIDEO_TRANSPORT=rtsp`, never by the
/// widget tree.
///
/// The same both-branches shape as `live_video.dart`, for the same reason:
/// `main()` compiles for the appliance and for the web from one file, and
/// this export gives it one `openRtspVideo` name whose meaning is the real
/// fvp-backed player on the VM and an explicit fall-through to the
/// platform's own player (MSE) on web — where RTSP is not a thing a browser
/// can speak, and `VIDEO_TRANSPORT=rtsp` on a web build is a configuration
/// slip that must cost nothing.
library;

export 'live_video_rtsp_io.dart'
    if (dart.library.js_interop) 'live_video_rtsp_web.dart';
