import 'package:flutter/foundation.dart';

/// How the RTSP transport is tuned on this machine — the four settings that
/// used to be process-wide mutable globals in `live_video_rtsp_io.dart`, with
/// four inert twins in `live_video_rtsp_web.dart` and a prose ordering rule
/// ("set before the first open, from `main()` and nowhere else") that nothing
/// enforced.
///
/// **Why a value and not four globals.** Every one of these is an operational
/// fact about the machine the Panel is running on, not a property of the
/// binary — which is the same argument `HubConfig` makes about addresses, and
/// the reason both resolve environment-first. As globals they were readable
/// and writable from anywhere, in any order, at any time; the invariant that
/// makes them correct is that they are settled once at the composition root
/// and never touched again, and a `final` field on a value handed to the
/// transport states that invariant instead of asking for it. A test that
/// wants a different tuning constructs one rather than mutating a global
/// under a `tearDown` — which `live_video_rtsp_test.dart` had to do.
///
/// **What is deliberately not here.** `VIDEO_TRANSPORT`. That names which
/// transport plays at all — `rtsp`, `mjpeg` or the web build's `mse` — and
/// folding a three-way choice between transports into a type called
/// *Rtsp*Tuning would be a category error: this describes how the RTSP
/// transport behaves once chosen, and means nothing to the other two.
/// `main()` keeps that choice, and hands this to the branch it picks.
///
/// **No `sources` map, unlike [HubConfig].** That type reports where each
/// address came from because "pointed at the wrong Hub" and "pointed at the
/// right Hub and it is down" look identical on the badge. Nothing here is an
/// address and nothing here has that ambiguity: a wrong decoder is a broken
/// picture, and what an operator needs on the boot line is the *value* that
/// was used. [logFields] carries those.
@immutable
class RtspTuning {
  const RtspTuning({
    this.decoders = const ['FFmpeg'],
    this.lowLatency = 0,
    this.framePulse = false,
    this.debug = false,
  });

  /// The decoder priority list handed to fvp, or null to keep fvp's own.
  ///
  /// **The shipped default is software, and that is a precaution rather than
  /// a proven fix — say so honestly.** fvp's own Linux list prefers hardware
  /// (`['VAAPI', 'CUDA', 'VDPAU', 'hap', 'FFmpeg', 'dav1d']`), and pinning
  /// `FFmpeg` was the first attempt at the broken wall of 2026-08-26. It did
  /// not fix it. The macroblocks were [lowLatency] dropping the first key
  /// frame; the frozen pictures were the Impeller renderer (ADR-0012).
  /// Hardware decoding was never actually convicted of anything.
  ///
  /// It stays software for now because the one property worth having here is
  /// that a broken *picture* is indistinguishable from a broken *camera* to
  /// whoever is looking at the wall, and this house's cameras break often
  /// enough on their own; software decode is the path with no driver roulette
  /// across the dev box's Intel+NVIDIA and the mini PC's AMD.
  ///
  /// Affordable at this size: a tile is 640×360 and the grid is six of them —
  /// the phase-8 prototype measured about half a core for six streams
  /// *including* software GL rendering under Xvfb.
  ///
  /// **`VIDEO_DECODERS=auto` was finally run on 2026-09-04, and the picture
  /// holds.** Eight freeze-probe arms, four each, CPU sampled over a 14 s
  /// window inside the warmup: `auto` 46.1 / 47.2 / 49.6 / 50.4 % (mean 48.3),
  /// `FFmpeg` 53.7 / 55.2 / 57.9 / 60.4 % (mean 56.8). No overlap between the
  /// arms — every `auto` run is cheaper than every software run, about 15 %
  /// less CPU. Grades were 5/6 three times each with one 4/6 apiece, and both
  /// 4/6s were hub-side: one camera on "Connecting…", one with a clock 18 s
  /// behind its neighbours. **No macroblocks in any `auto` grab**, which is
  /// what the 2026-08-26 fault looked like and further evidence that
  /// [lowLatency] was the whole of it.
  ///
  /// Two things that measurement does NOT establish, and they are why the
  /// default has not moved on it alone. Which engine did the work is unknown:
  /// `nvidia-smi` shows NVDEC essentially idle (4 % peak against a 0 %
  /// baseline), so it is not the dGPU — which is the reassuring answer, since
  /// the kiosk pins the i915 and never opens the NVIDIA card — but telling
  /// VAAPI from a different software path needs `vainfo` or
  /// `intel_gpu_top`, and neither is installed. And the software pin's stated
  /// purpose is portability to the AMD mini PC, which is still unpurchased,
  /// so `auto` there remains untested by construction. The failure it guards
  /// against is also the deceptive one: a corrupt picture under a LIVE badge
  /// reads as a working camera.
  final List<String>? decoders;

  /// fvp's `lowLatency`, and **the shipped value is 0 — off — because 1
  /// visibly corrupts this wall.**
  ///
  /// This was 1 from the day the transport landed, on the reasonable-sounding
  /// argument that a live wall wants no buffering. What that actually buys is
  /// spelled out in fvp's own source, one line above where it applies it:
  ///
  /// ```dart
  /// // +nobuffer: the 1st key-frame packet is dropped. -nobuffer: high latency
  /// player.setProperty('avformat.fflags', '+nobuffer');
  /// ```
  ///
  /// **It drops the first key frame.** H.264 is differential, so a decoder
  /// handed the packets after an IDR but not the IDR itself has nothing to
  /// reference: it paints garbage and keeps painting garbage until the camera
  /// sends another key frame, which on a long-GOP Wyze substream is a long
  /// time and — with errors propagating — sometimes never resolves. That is
  /// the wall of macroblocks seen on 2026-08-26, and it is why the identical
  /// substreams decoded perfectly under plain `ffmpeg`, which drops nothing,
  /// and why swapping decoders only changed what the mess looked like.
  ///
  /// Every value above 0 sets that flag, so **0 is the only safe setting**;
  /// `VIDEO_LOW_LATENCY=1` exists to reproduce the fault, not to tune it. The
  /// price of 0 is mdk's ordinary network buffering — a slower first frame
  /// and some delay behind real time — which is a trade this house can make
  /// happily, a picture being worth more than a second.
  final int lowLatency;

  /// Whether a playing stream keeps the engine drawing frames.
  ///
  /// **A workaround for the embedder, not a feature, and OFF since
  /// 2026-09-04** (owner decision). `VIDEO_REPAINT_PULSE=on` turns it back
  /// on, no rebuild, and that direction is the point — see below. What it
  /// does and why it has to reach the `TextureBox` itself is `_FramePulse`'s
  /// doc; what to set it to is this one's.
  ///
  /// Built 2026-08-26, when the wall updated its pictures *only while being
  /// scrolled* and sat on a stale frame the moment the finger stopped. That
  /// symptom turned out to be Impeller's, and the wall now pins Skia
  /// (ADR-0012) — so the fault it was built for is fixed somewhere else, and
  /// what remained was a per-vsync repaint nobody had proved was doing
  /// anything.
  ///
  /// Its cost while on is not nothing: one `Ticker` per playing session,
  /// firing every vsync, each forcing a repaint of a texture layer that may
  /// have no new frame in it — six of those on a full grid, on a wall that is
  /// meant to sit still for hours.
  ///
  /// **Why the default flipped.** Measured through `tool/freeze_probe.sh`
  /// with the pulse off: 3 runs of 3 on 2026-08-28, and 2 of 2 again on
  /// 2026-09-04 against the current build (one of those graded 4/6, and
  /// looking at the grab said why — the sixth cell was a camera still saying
  /// "Connecting…" in both, not a texture that stopped). And the reason it
  /// had stayed on turned out to be about a machine that does not exist: the
  /// old wording was "the evidence is from the dev box's Intel/NVIDIA stack,
  /// the appliance is different silicon", but that mini PC has not been
  /// purchased (`appliance/ansible/inventory.yml` —
  /// `minipc.placeholder.invalid`), so the only real appliance is the Legion,
  /// whose kiosk is pinned to the same i915 the probe measures.
  ///
  /// **What is still unmeasured, and why off is nevertheless the right
  /// default.** The probe runs under XWayland on GNOME; the kiosk runs under
  /// cage/wlroots, and the embedder's frame-available path is exactly the
  /// layer that differs between them. Only the wall settles that — and with
  /// the default on, it never would: `VIDEO_REPAINT_PULSE=off` had never been
  /// set there once (the unit templates `HUB`, `HA_URL`, `GO2RTC_URL` and
  /// `LOG`, and nothing else), so the week of production evidence this
  /// setting's own deletion note asks for could not start until somebody
  /// remembered to start it. Off by default starts it at the next deploy, and
  /// the cost of being wrong is one `Environment=VIDEO_REPAINT_PULSE=on` line
  /// and a restart. **Delete this and `_FramePulse` once a week on the wall
  /// says nothing was lost.**
  final bool framePulse;

  /// Once-per-second instrumentation of the render path, `VIDEO_DEBUG=on`.
  ///
  /// Off by default because it writes a line per second per playing stream.
  /// Turn it on when the wall shows a picture that will not move, and read
  /// the line as a chain — the first field that is wrong is where to look:
  ///
  /// ```
  /// I video.pulse name=wyze_back_yard_sub ticks=60 frames=60 pos=+1000ms
  ///                tex=id42 paint=clean
  /// ```
  ///
  /// * `ticks` — pulses in the last second. 0 means the `Ticker` is not
  ///   running (a muted `TickerMode`, or [framePulse] off).
  /// * `frames` — frames the *engine* actually rasterised, counted through
  ///   `SchedulerBinding.addTimingsCallback`. 0 with non-zero ticks means the
  ///   scheduler is asking and the engine is not drawing.
  /// * `pos` — how far the player's clock moved. 0 means no decoding, so the
  ///   problem is upstream of rendering entirely.
  /// * `tex` — the `TextureBox` this pulse found, and its texture id, or
  ///   `none` if the walk found no texture to repaint.
  /// * `paint` — whether that box was still marked dirty when the line was
  ///   written. `dirty` means `markNeedsPaint()` is being called and paint is
  ///   never running. Needs asserts, so a `--debug` run; otherwise `n/a`.
  ///
  /// The honest reading: `ticks=60 frames=60 pos=+1000ms tex=id42 paint=clean`
  /// and a frozen picture means every layer of Flutter did its job and the
  /// texture still did not update — which puts it below Dart, in the embedder
  /// or the plugin, and no amount of widget code will fix it.
  ///
  /// Caveat from the rig: the pixel sampler this turns on segfaults release
  /// GLES runs, so `tool/freeze_probe.sh` leaves it off and trusts its
  /// screenshots. Use it in log-only sessions.
  final bool debug;

  /// The `panel.video_player` boot line. Values, not origins — see the class
  /// doc. `debug` is absent deliberately: it is not a tuning of the player,
  /// it is whether this run is instrumented, and its own lines say so once a
  /// second and much louder.
  Map<String, Object> get logFields => {
    'decoders': decoders == null ? 'fvp_default' : decoders!.join(','),
    'low_latency': lowLatency,
    'repaint_pulse': framePulse ? 'on' : 'off',
  };
}

/// Resolves [RtspTuning] from the runtime [environment] and the build's
/// dart-defines, **runtime first** — `resolveHubConfig`'s order, for
/// `resolveHubConfig`'s reason: which decoder a given wall can actually use
/// is something you find out with a person standing in front of the screen,
/// and a setting that needs a rebuild to change is a setting nobody changes.
///
/// Pure: reads nothing itself, so every precedence case is reachable from a
/// test. Before this existed the same four rules lived as ~50 lines inside
/// `main()`, which no test runs.
///
/// An environment variable that is present but **empty** counts as absent,
/// as it does for every Hub setting: a blank value exported by a shell should
/// not silently defeat a value compiled into the build.
///
/// Nothing here rejects a bad value, and that is deliberate — each setting
/// degrades to its default in the way that is safe for it. An unparseable
/// `VIDEO_LOW_LATENCY` becomes 0, which is the only safe value anyway; a
/// decoder name fvp does not know is fvp's to ignore, and this file has no
/// list of what a given fvp build supports; and both booleans are "the magic
/// word or the default", so a typo leaves the shipped behaviour. Compare
/// `VIDEO_TRANSPORT`, which `main()` *does* warn about: naming a transport
/// that does not exist means the operator gets a different player than they
/// asked for, which is worth a line.
RtspTuning resolveRtspTuning({
  required Map<String, String> environment,
  String? buildDecoders,
  String? buildLowLatency,
  String? buildFramePulse,
  String? buildDebug,
}) {
  String? pick(String name, String? fromBuild) {
    final fromEnv = environment[name];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    if (fromBuild != null && fromBuild.isNotEmpty) return fromBuild;
    return null;
  }

  // `auto` and a list that names nothing — `VIDEO_DECODERS=,` — are one
  // instruction: keep fvp's own hardware-first list. Spelled as null rather
  // than as the empty list they parse to, because fvp reads an empty list as
  // "use no decoder at all", which is a black wall.
  final askedDecoders = pick('VIDEO_DECODERS', buildDecoders) ?? 'FFmpeg';
  final named = askedDecoders.trim().toLowerCase() == 'auto'
      ? const <String>[]
      : [
          for (final name in askedDecoders.split(','))
            if (name.trim().isNotEmpty) name.trim(),
        ];

  return RtspTuning(
    decoders: named.isEmpty ? null : named,
    lowLatency: int.tryParse(pick('VIDEO_LOW_LATENCY', buildLowLatency) ?? '') ?? 0,
    framePulse:
        (pick('VIDEO_REPAINT_PULSE', buildFramePulse) ?? '')
            .trim()
            .toLowerCase() ==
        'on',
    debug:
        (pick('VIDEO_DEBUG', buildDebug) ?? '').trim().toLowerCase() == 'on',
  );
}
