import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'boot.dart';
import 'config/hub_config.dart';
import 'config/runtime_env.dart';
import 'data/hub_client.dart';
import 'diagnostics/log.dart';
import 'diagnostics/url_redaction.dart';
import 'domain/house.dart';
import 'ui/cameras/cameras_view.dart';
import 'ui/device_popup.dart';
import 'ui/dollhouse/dollhouse_view.dart';
import 'ui/doorbell_popup_host.dart';
import 'ui/edge_tab.dart';
import 'ui/hub_controller.dart';
import 'ui/theme.dart';
import 'ui/audio/talk.dart';
import 'ui/video/camera_health.dart';
import 'ui/video/live_video.dart';
import 'ui/video/live_video_keepalive.dart';
import 'ui/video/live_video_rtsp.dart';
import 'ui/video/snapshot.dart';
import 'ui/video/stream_director.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Log.installErrorHandlers();
  // Read once, handed to both resolvers: `main()` is the only thing in the
  // Panel that touches the process environment, which is what keeps
  // `bootPanel` and `Log` reachable from plain data in a test.
  final environment = runtimeEnvironment();
  // Before the first line is emitted, or `LOG=off` could not silence the
  // boot lines it is asked to silence. Environment first, like the Hub
  // settings below: turning the logs up on a Panel already on the wall must
  // not mean rebuilding it.
  final logFrom = Log.applyLevel(environment);
  // Runtime environment first, build defines second (config/hub_config.dart).
  // The Hub's address is an operational setting, not a property of the
  // binary: on the appliance systemd supplies it, so a Hub that moves costs
  // a restart rather than a Flutter rebuild.
  final config = resolveHubConfig(
    environment: environment,
    buildKind: _buildHubKind,
    buildUrl: _buildHaUrl,
    buildToken: _buildHaToken,
    buildGo2rtcUrl: _buildGo2rtcUrl,
  );
  Log.info('panel', 'start', {
    'hub': config.kind,
    'mode': kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    'log': Log.level.name,
    // Which origin set it — the same argument as `hub.config`: with two
    // possible origins, `log=info log_from=build` on a run that exported
    // LOG=debug is how a web build says the environment was discarded.
    'log_from': logFrom,
  });
  // Which origin won, per setting. With two possible origins, a Panel
  // pointed at a stale address and a Panel pointed at a dead Hub look the
  // same on the badge; this line is what separates them. Origins only — the
  // token's *value* never appears (log.dart: Never log a secret). `env=` says
  // whether a process environment existed at all, because on web it does not
  // and a discarded `HA_URL=…` otherwise looks like a healthy default.
  Log.info('hub', 'config', {
    ...config.logFields,
    'env': environmentIsAvailable ? 'available' : 'unavailable',
  });
  // An ambient variable beating the flag the operator typed is the one
  // genuinely surprising consequence of environment-first order. Warn, don't
  // fail: the environment is still the answer we want, just not silently.
  if (config.overridden.isNotEmpty) {
    Log.warn('hub', 'config_override', {
      'settings': config.overridden.join(','),
      'winner': 'environment',
    });
  }
  // Where go2rtc is, host and port in the clear, because "pointed at the
  // wrong go2rtc" is otherwise invisible until somebody taps a camera.
  // Everything a password can hide in is taken out first — see [urlForLog],
  // which used to be a `go2rtcForLog` private to this file and is now shared
  // with the Hub's own address lines, because two copies is exactly how
  // `GO2RTC_URL` came to be built up from named parts while `HA_URL`, one
  // field over in the same `HubConfig`, was still printed whole.
  //
  // The old justification for printing it whole ("go2rtc is unauthenticated
  // here") was a fact about this deployment's go2rtc.yaml, not about the URL
  // shape this setting accepts: go2rtc 1.9 has `api.username`/`api.password`,
  // so `GO2RTC_URL=http://user:pass@hub` is a value an operator can
  // legitimately be given. Rejected: `go2rtc=set` on `panel.start`, which
  // phase 4 asked for — it borrows the secret-withholding vocabulary for an
  // address and throws away the host, which is the one fact worth having.
  Log.info('popup', 'go2rtc', urlForLog(config.go2rtcUrl));
  // Which player the appliance dials with (phase-8 N5): `rtsp` plays
  // go2rtc's H.264 restream through fvp; anything else is the shipped
  // MJPEG default. Environment first, build define second, like every Hub
  // setting above and for the same reason — rolling the wall back from a
  // misbehaving transport must cost a restart, not a rebuild. On web the
  // rtsp opener falls through to the platform player and says so itself.
  final videoTransport =
      environment['VIDEO_TRANSPORT'] ?? _buildVideoTransport ?? 'mjpeg';
  if (videoTransport != 'mjpeg' && videoTransport != 'rtsp') {
    Log.warn('panel', 'video_transport_unknown',
        {'asked': videoTransport, 'using': 'mjpeg'});
  }
  final rawOpen = videoTransport == 'rtsp' ? openRtspVideo : openLiveVideo;
  Log.info('panel', 'video_transport', {'transport': videoTransport});
  // The House Plan (ADR-0005): everything drawn — geometry and Device
  // Placements — generated into house.yaml, joined with the hand-maintained
  // Hub bindings.
  final boot = bootPanel(
    hubKind: config.kind,
    hubUrl: config.url,
    hubToken: config.token,
    houseYaml: await rootBundle.loadString('assets/house/house.yaml'),
    bindingsYaml: await rootBundle.loadString('assets/house/bindings.yaml'),
  );
  // One pool for the whole process, never disposed — issue #1; the file says
  // what it is for. Here and not inside `VideoConfig`, whose `open` this
  // becomes: that class is `@immutable` and every hermetic test builds one,
  // while this holds live sessions and running Timers. Composed at the root
  // instead, so the widget tree is unchanged, both video surfaces get it
  // through the seam they already use, and `test/fixtures.dart` still
  // defaults to the raw opener.
  final keepAlive = LiveVideoKeepAlive(opener: rawOpen);
  // The Stream Director (phase-8), one per process like the pool and never
  // disposed here for the pool's reason: it holds admission and retry
  // Timers for as long as the Panel runs. Composed ABOVE the pool — it
  // dials through `keepAlive.open`, so a feed the Director stops is a
  // stream the pool may linger — and BELOW every surface: the Cameras view
  // attaches managed feeds, and the Popup path's `VideoConfig` below opens
  // through `director.open`, counted but not managed (its arbitration is
  // `doorbell_popup_host.dart`'s own).
  final director = StreamDirector(
    video: VideoConfig(go2rtcUrl: config.go2rtcUrl, open: keepAlive.open),
    // Camera Health off the Hub's own port-322 probes (phase-8 A2): the
    // Director will not dial a camera whose daemon the Hub says is dead —
    // each failed dial costs that camera two connections, and the recovery
    // dial rides the probe flipping back, not a timer.
    health: HubCameraHealth(controller: boot.controller),
  );
  // `video` travels beside `controller`/`hubLabel` and deliberately not
  // through `bootPanel`: boot's contract is that it fails "in exactly three
  // ways" and brings up two things, the House and the Hub adapter. go2rtc is
  // neither, and a field there would invite a fourth boot failure for the
  // one setting that must never stop the wall coming up.
  runApp(
    PanelApp(
      controller: boot.controller,
      hubLabel: boot.hubLabel,
      director: director,
      video: VideoConfig(go2rtcUrl: config.go2rtcUrl, open: director.open),
      // The Hub's own address and token, reused: a camera snapshot is an HA
      // REST fetch authenticated exactly like the socket. The token travels
      // in this object to become a header — never a URL part (snapshot.dart).
      snapshots: SnapshotConfig(haUrl: config.url, token: config.token),
      // The same go2rtc `video` dials, for the Wyze tiles' still faces
      // (phase-8 A7): a `frame.jpeg` grab off the substream, tokenless,
      // bounded by its `cache=45s`. The doorbell never uses this source —
      // its still stays HA-held through `snapshots` (#177014).
      stills: Go2rtcStillsConfig(go2rtcUrl: config.go2rtcUrl),
      // The same go2rtc, reached over the same address, for the other half of
      // the doorbell: `video` plays what the camera sees, `talk` pushes a
      // microphone back into it. Two configs and not one because every camera
      // Popup in the house carries the first and only a doorbell can use the
      // second (ADR-0011; `ui/audio/talk.dart`).
      talk: TalkConfig(go2rtcUrl: config.go2rtcUrl),
    ),
  );
}

/// What this build was compiled with, or null where the define was omitted —
/// `bool.hasEnvironment` is what separates "not passed" from "passed the
/// same string the default would have used", which is what lets the boot log
/// name the real origin.
///
/// Defaults live in `config/hub_config.dart`, not here, so the environment
/// path and the build path cannot drift apart. Pass `--dart-define=HUB=ha`
/// (plus `HA_URL` and `HA_TOKEN`) for a real Home Assistant, or set the same
/// names in the environment — see hub/dev/README.md. `GO2RTC_URL` is the
/// same shape and is optional in every build: a Panel that was never told
/// where go2rtc is shows every Device it always showed, and says so on one
/// camera Popup rather than failing to start.
const String? _buildHubKind = bool.hasEnvironment('HUB')
    ? String.fromEnvironment('HUB')
    : null;
const String? _buildHaUrl = bool.hasEnvironment('HA_URL')
    ? String.fromEnvironment('HA_URL')
    : null;
const String? _buildHaToken = bool.hasEnvironment('HA_TOKEN')
    ? String.fromEnvironment('HA_TOKEN')
    : null;
const String? _buildGo2rtcUrl = bool.hasEnvironment('GO2RTC_URL')
    ? String.fromEnvironment('GO2RTC_URL')
    : null;
const String? _buildVideoTransport = bool.hasEnvironment('VIDEO_TRANSPORT')
    ? String.fromEnvironment('VIDEO_TRANSPORT')
    : null;

class PanelApp extends StatelessWidget {
  const PanelApp({
    super.key,
    required this.controller,
    required this.hubLabel,
    required this.video,
    required this.snapshots,
    required this.stills,
    required this.talk,
    this.director,
  });

  final HubController controller;

  /// The process-wide Stream Director, when `main()` composed one. Null in
  /// every hermetic fixture — the Cameras view then builds its own over
  /// [video], which is the same policy over the same opener, minus the
  /// cross-surface census only the wall cares about.
  final StreamDirector? director;

  /// What the Hub badge calls the Hub. Passed in rather than read from the
  /// build's dart-defines, so this widget knows nothing about which Hub it
  /// was compiled against — and so a test can render the production scene.
  final String hubLabel;

  /// Where go2rtc is, for the Popup a camera pin opens. Passed in for the
  /// same reason [hubLabel] is, and required for the same reason: an
  /// unconfigured default here would be a fact about test fixtures wearing
  /// the costume of a fact about the Panel. `test/fixtures.dart` is where it
  /// defaults, and it defaults to unconfigured.
  final VideoConfig video;

  /// Where the Hub's REST API is, for the still faces in the Cameras view.
  /// Required for [video]'s reason: an unconfigured default here would be a
  /// test-fixture fact wearing a Panel costume — `test/fixtures.dart` is
  /// where it defaults, and it defaults to unconfigured.
  final SnapshotConfig snapshots;

  /// go2rtc's frame-grab source, for the Wyze tiles' still faces — the
  /// other half of the Cameras view's stills, beside [snapshots]. Required
  /// for [video]'s reason, and defaulted to unconfigured in the same place.
  final Go2rtcStillsConfig stills;

  /// Where the doorbell's push-to-talk pushes. Required for [video]'s reason:
  /// an unconfigured default here would be a fact about test fixtures wearing
  /// the costume of a fact about the Panel. `test/fixtures.dart` is where it
  /// defaults, and it defaults to unconfigured.
  final TalkConfig talk;

  /// Whether the House has anything the Cameras view could show. Decides
  /// the tab's existence, not its behaviour: a tab onto an empty grid is
  /// furniture.
  bool get _hasCameras => controller.house.floors
      .expand((f) => f.devices)
      .any((d) => specOf(d.kind).video);

  /// The doorbell the edge tab opens, or null in a House that has none —
  /// which decides that tab's existence for [_hasCameras]'s reason.
  ///
  /// The first, in House order, and this house has exactly one. A second
  /// doorbell would want a tab each, and that is a decision about what the
  /// edge looks like with three handles on it, not something to guess at now.
  Device? get _doorbell {
    for (final device in controller.house.floors.expand((f) => f.devices)) {
      if (device.kind == DeviceKind.doorbell) return device;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Panel',
      debugShowCheckedModeBanner: false,
      // How the Cameras route hears a Popup ride over it — `didPushNext`
      // into `StreamDirector.overlaid`. An observer, not a visibility
      // callback: visibility is blind to routes pushed on top.
      navigatorObservers: [camerasRouteObserver],
      theme: PanelTheme.data(),
      home: Scaffold(
        // Inside MaterialApp, so the host has a Navigator to push onto; and
        // outside both ListenableBuilders below, so the widget that owns a
        // live subscription and an open-Popup flag is not rebuilt every time
        // a reading moves.
        body: DoorbellPopupHost(
          controller: controller,
          video: video,
          snapshots: snapshots,
          talk: talk,
          child: SafeArea(
            // The edge tabs ride flush against the right of this Stack, which
            // is why the gutter below is a Padding *inside* it rather than
            // around it: everything else on the Panel keeps its 24 px, and
            // the tabs keep the screen edge. Inside the SafeArea, not around
            // it — the wall has no notch, but a tab under one would be a tab
            // nobody can press.
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            controller.house.name,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: PanelTheme.ink,
                            ),
                          ),
                          const Spacer(),
                          ListenableBuilder(
                            listenable: controller,
                            builder: (context, _) => _HubBadge(
                              label: hubLabel,
                              status: controller.status,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Tap a floor to expand · tap a room to toggle its lights · tap a device to act',
                        style: TextStyle(
                          fontSize: 12,
                          color: PanelTheme.inkFaint,
                        ),
                      ),
                      Expanded(
                        child: ListenableBuilder(
                          listenable: controller,
                          builder: (context, _) => DollhouseView(
                            controller: controller,
                            video: video,
                            snapshots: snapshots,
                            talk: talk,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // The edge tabs (phase-7 §B2, restacked 2026-08-15). Outside the
                // gutter so they touch the screen edge, and outside the
                // ListenableBuilder because their *existence* depends on the
                // House, which never changes after boot — only what they open
                // ever moves.
                Positioned(
                  top: kEdgeTabsTop,
                  right: 0,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (_doorbell case final doorbell?)
                        Builder(
                          builder: (context) => DoorbellTab(
                            onTap: () => showDevicePopup(
                              context,
                              presentation: controller.presentationOf(doorbell),
                              video: video,
                              talk: talk,
                              controller: controller,
                              snapshots: snapshots,
                            ),
                          ),
                        ),
                      if (_doorbell != null && _hasCameras)
                        const SizedBox(height: kEdgeTabGap),
                      if (_hasCameras)
                        Builder(
                          builder: (context) => CamerasTab(
                            onTap: () => showCamerasView(
                              context,
                              controller: controller,
                              video: video,
                              snapshots: snapshots,
                              stills: stills,
                              director: director,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hub reachability, always visible: a wall display has nobody watching a
/// console, so "these readings are frozen" must be legible from across the
/// room — and so must the difference between a Hub that will come back on
/// its own and a token only a human can replace.
class _HubBadge extends StatelessWidget {
  const _HubBadge({required this.label, required this.status});

  final String label;
  final HubStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: PanelTheme.surfaceRaised,
        borderRadius: BorderRadius.circular(20),
        boxShadow: PanelTheme.raised(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // One dot colour per severity, so the across-the-room read
              // stays binary: green = live, red = stale. Which kind of
              // stale is what the text is for.
              color: status == HubStatus.up
                  ? const Color(0xFF4CAF50)
                  : const Color(0xFFE05A5A),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            switch (status) {
              HubStatus.up => label,
              HubStatus.retrying => '$label OFFLINE',
              // Names the action, not the diagnosis: whoever is standing
              // there needs to know what to do, and nothing else will.
              HubStatus.gaveUp => '$label NEEDS NEW TOKEN',
            },
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: PanelTheme.inkFaint,
            ),
          ),
        ],
      ),
    );
  }
}
