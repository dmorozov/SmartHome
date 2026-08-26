import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/close_button.dart';
import 'package:panel/ui/cameras/cameras_view.dart';
import 'package:panel/ui/dollhouse/dollhouse_view.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_keepalive.dart';
import 'package:panel/ui/video/snapshot.dart';
import 'package:panel/ui/video/stream_director.dart';

import 'fixtures.dart';
import 'support/fake_go2rtc.dart';
import 'support/fake_health.dart';
import 'support/fake_snapshots.dart';
import 'test_house.dart';

/// The Cameras view (phase-7 §B): the owner-specified tab/slide/grid/close
/// shape, tap-to-toggle tile sessions, the doorbell's default-off snapshot
/// face, and the idle return that asks before it acts.
///
/// Driven entirely through [FakeGo2rtc] and [FakeSnapshots]: what these
/// cases assert is lifecycle — which sessions exist when, and that closing
/// the view closes all of them — and a real 2.1 s player would make every
/// one a race.
void main() {
  late FakeGo2rtc go2rtc;
  late FakeSnapshots snapshots;
  late List<LogRecord> records;

  setUp(() {
    go2rtc = FakeGo2rtc();
    snapshots = FakeSnapshots();
    records = <LogRecord>[];
    Log.sink = records.add;
    Log.level = LogLevel.debug;
    // The tiles' VisibilityDetector coalesces callbacks on a 500 ms timer by
    // default; zero makes them fire at the end of every frame, which is the
    // package's own documented setting for tests — without it every case
    // ends with a pending Timer the framework calls a failure.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    Log.sink = Log.printRecord;
  });

  /// A surface tall enough that the whole grid is *built*.
  ///
  /// [GridView] is lazy, so on the 800×600 default the third row of tiles
  /// never exists — and a case that counts tiles, or expects the doorbell to
  /// have asked for its snapshot, then measures the viewport rather than the
  /// view. That was invisible while the house had three cameras and every
  /// tile fitted; the Wyze fleet took it to seven and four of them built.
  ///
  /// 1280 wide is the Panel's real width and puts the grid in its 3-column
  /// layout (the `> 900` branch). The height is deliberately not realistic:
  /// on the wall this grid scrolls, and these cases are not about scrolling.
  Future<void> useFullGridSurface(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// [opener] replaces the raw fake for the one case that needs something
  /// *between* the tiles and it — the keep-alive. Everything else drives
  /// [go2rtc] directly, because what it asserts is the tile's own lifecycle.
  Future<void> pumpPanel(
    WidgetTester tester, {
    String? autoLiveStream,
    LiveVideoOpener? opener,
    VideoConfig? video,
    Go2rtcStillsConfig? stills,
    StreamDirector? director,
    House Function(House house)? stage,
  }) async {
    await useFullGridSurface(tester);
    // Start from a house whose cameras are unwired and add back exactly
    // what the case is about. Without this, every scene here inherits
    // whatever `bindings.yaml` ships — which since 2026-08-15 is two live
    // Wyze cameras — and cases about *one* session start counting three.
    var house = houseWithoutCameraStreams(loadTestHouse());
    if (autoLiveStream != null) {
      house = houseWithStream(house, 'cam-living', autoLiveStream);
    }
    // For scenes [autoLiveStream] cannot spell — a substream, a rewired
    // doorbell — staged by the case itself, on the same blank sheet.
    if (stage != null) house = stage(house);
    final (controller, _) = fakeHubRig(house: house);
    await tester.pumpWidget(
      panelApp(
        controller,
        video: video ??
            VideoConfig(
              go2rtcUrl: 'http://hub:1984',
              open: opener ?? go2rtc.open,
            ),
        snapshots: SnapshotConfig(
          haUrl: 'http://hub:8123',
          token: 'tok',
          fetch: snapshots.fetch,
        ),
        stills: stills ?? const Go2rtcStillsConfig(),
        director: director,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openCameras(WidgetTester tester) async {
    await tester.tap(find.byType(CamerasTab));
    await tester.pumpAndSettle();
  }

  /// Unmounts everything, so tile `dispose()` runs and no timer outlives
  /// the test — the same discipline the view owes the wall.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('the way out is the same puck every Popup wears — one idiom on '
      'a screen with no Escape key', (tester) async {
    await pumpPanel(tester);
    await openCameras(tester);

    // The widget, not the glyph: a bare Material IconButton also draws an X,
    // and that is exactly what this view had until 2026-08-15.
    expect(find.byType(PanelCloseButton), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('the right-edge tab slides the view out, Close returns', (
    tester,
  ) async {
    await pumpPanel(tester);
    expect(find.byType(CamerasView), findsNothing);

    await openCameras(tester);
    expect(find.byType(CamerasView), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cameras-close')));
    await tester.pumpAndSettle();
    expect(find.byType(CamerasView), findsNothing);
    await unmount(tester);
  });

  testWidgets(
    'the doorbell tile is off at entry, wears the snapshot, and no Ring '
    'session exists until a person asks',
    (tester) async {
      await pumpPanel(tester);
      await openCameras(tester);

      // The safety half of `autoLive`: entering the view opened NOTHING —
      // the doorbell's stream is wired and still not dialled (#177014).
      expect(go2rtc.opened, isEmpty);

      // The still face came from HA's camera_proxy, token as a header value
      // handed to the fetcher — and never in the URL.
      final request = snapshots.requests.first;
      expect(request.path, '/api/camera_proxy/camera.front_door_snapshot');
      expect(request.toString().contains('tok'), isFalse);
      expect(snapshots.tokens.first, 'tok');
      await tester.pump();
      expect(find.text('Tap for live'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    "a Wyze tile with no HA snapshot wears go2rtc's frame grab — the "
    'substream is billed, tokenless, on the snapshot cadence',
    (tester) async {
      final stills = FakeSnapshots();
      await pumpPanel(
        tester,
        // go2rtc-for-video unconfigured: the feed settles `unconfigured`,
        // a still-wearing face — the grab source is its own config and
        // works even where the video seam has nothing to dial.
        video: const VideoConfig(),
        stills: Go2rtcStillsConfig(
          go2rtcUrl: 'http://hub:1984',
          fetch: stills.fetch,
        ),
        stage: (house) => houseWithStream(house, 'cam-living',
            'wyze_living_room',
            substream: 'wyze_living_room_sub'),
      );
      await openCameras(tester);

      final request = stills.requests.single;
      expect(request.path, '/api/frame.jpeg');
      expect(request.queryParameters['src'], 'wyze_living_room_sub',
          reason: 'the grab bills the substream when one is offered — the '
              'offer rule; a main-only camera is grabbed on its main');
      expect(request.queryParameters['cache'], '45s',
          reason: 'the cache window is what makes a remount storm free');
      expect(stills.tokens.single, isEmpty,
          reason: 'go2rtc is tokenless — there is no bearer to send');

      // The tile actually paints it.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tile-cam-living')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );

      // And refreshes on the same cadence as the HA-held face.
      await tester.pump(kCamerasSnapshotRefresh + const Duration(seconds: 1));
      expect(stills.requests.length, 2);
      await unmount(tester);
    },
  );

  testWidgets(
    'the doorbell never reaches frame.jpeg — wired for video with no '
    'snapshot face, its kind is the wall (#177014)',
    (tester) async {
      final stills = FakeSnapshots();
      await pumpPanel(
        tester,
        video: const VideoConfig(),
        stills: Go2rtcStillsConfig(
          go2rtcUrl: 'http://hub:1984',
          fetch: stills.fetch,
        ),
        // A doorbell with a wired stream and NO snapshot binding: its idle
        // face is grab-allowed and the go2rtc source is configured, so the
        // kind check is the only thing between it and a frame grab — which
        // on the Ring stream would open a real cloud session and suppress
        // dings. This is the canary for exactly that check.
        stage: (house) => houseWithStream(house, 'doorbell', 'ring_doorbell',
            clearSnapshot: true),
      );
      await openCameras(tester);
      await tester.pump(kCamerasSnapshotRefresh + const Duration(seconds: 1));

      expect(stills.requests, isEmpty,
          reason: 'a frame grab on the Ring stream is a real Ring session');
      expect(snapshots.requests, isEmpty,
          reason: 'no snapshot binding, nothing to ask HA for');
      await unmount(tester);
    },
  );

  testWidgets(
    'a tile the Director is pursuing never grabs frames — not while live, '
    'not while the retry ladder owns the camera',
    (tester) async {
      final stills = FakeSnapshots();
      await pumpPanel(
        tester,
        stills: Go2rtcStillsConfig(
          go2rtcUrl: 'http://hub:1984',
          fetch: stills.fetch,
        ),
        stage: (house) => houseWithStream(house, 'cam-living',
            'wyze_living_room',
            substream: 'wyze_living_room_sub'),
      );
      await openCameras(tester);

      // Auto-live: the tile dialled at attach and is `connecting` — the
      // initState fetch already declined to bill the camera a second time.
      expect(stills.requests, isEmpty);

      go2rtc.only.plays();
      await tester.pump();
      await tester.pump(kCamerasSnapshotRefresh + const Duration(seconds: 1));
      expect(stills.requests, isEmpty,
          reason: 'the video is on screen — a grab buys nobody anything');

      // The stream dies and the ladder takes over (5 s → 15 s → 60 s):
      // every later tick lands on a pursued phase — retrying or a fresh
      // dial's connecting — and the grab stays declined either way.
      go2rtc.opened.first.fails('gone');
      await tester.pump();
      await tester.pump(kCamerasSnapshotRefresh + const Duration(seconds: 1));
      expect(stills.requests, isEmpty,
          reason: 'the retry ladder owns this camera\'s dial budget');
      await unmount(tester);
    },
  );

  testWidgets(
    'a main-only camera is grabbed on its main — a substream is an offer, '
    'not a requirement',
    (tester) async {
      final stills = FakeSnapshots();
      await pumpPanel(
        tester,
        video: const VideoConfig(),
        stills: Go2rtcStillsConfig(
          go2rtcUrl: 'http://hub:1984',
          fetch: stills.fetch,
        ),
        // No substream: the fallback arm. Tightening _grabStream to the
        // substream alone would silently revert this camera to the
        // pre-N6 icon — this case is what resists that.
        stage: (house) =>
            houseWithStream(house, 'cam-living', 'wyze_living_room'),
      );
      await openCameras(tester);

      expect(stills.requests.single.queryParameters['src'],
          'wyze_living_room');
      await unmount(tester);
    },
  );

  testWidgets(
    'the grab gate reads Camera Health live — a dead camera is not knocked '
    'once a minute by a feed parked in a phase health never moves',
    (tester) async {
      final stills = FakeSnapshots();
      final health = FakeHealth();
      final director =
          StreamDirector(video: const VideoConfig(), health: health);
      addTearDown(director.dispose);
      await pumpPanel(
        tester,
        director: director,
        stills: Go2rtcStillsConfig(
          go2rtcUrl: 'http://hub:1984',
          fetch: stills.fetch,
        ),
        stage: (house) => houseWithStream(house, 'cam-living',
            'wyze_living_room',
            substream: 'wyze_living_room_sub'),
      );
      await openCameras(tester);

      // Unknown never gates (absence of evidence): the settled feed
      // grabbed at entry.
      expect(stills.requests.length, 1);

      // The daemon dies. The feed sits in a settled phase health never
      // transitions — exactly the hole the phase-only gate had — and the
      // next tick must read the verdict itself and stand down.
      health.of('cam-living').value = Reachability.unreachable;
      await tester.pump(kCamerasSnapshotRefresh + const Duration(seconds: 1));
      expect(stills.requests.length, 1,
          reason: 'a frame grab IS a dial — health-gated like every dial');

      // Recovery needs no listener: the next tick reads the flip.
      health.of('cam-living').value = Reachability.reachable;
      await tester.pump(kCamerasSnapshotRefresh + const Duration(seconds: 1));
      expect(stills.requests.length, 2);
      await unmount(tester);
    },
  );

  testWidgets(
    'a covering overlay pauses the grabs — the same didPushNext fact that '
    'pauses the streams',
    (tester) async {
      final stills = FakeSnapshots();
      final director = StreamDirector(video: const VideoConfig());
      addTearDown(director.dispose);
      await pumpPanel(
        tester,
        director: director,
        stills: Go2rtcStillsConfig(
          go2rtcUrl: 'http://hub:1984',
          fetch: stills.fetch,
        ),
        stage: (house) => houseWithStream(house, 'cam-living',
            'wyze_living_room',
            substream: 'wyze_living_room_sub'),
      );
      await openCameras(tester);
      expect(stills.requests.length, 1);

      director.overlaid = true;
      await tester.pump(kCamerasSnapshotRefresh + const Duration(seconds: 1));
      expect(stills.requests.length, 1,
          reason: 'a face nobody can see is not worth a camera dial');

      director.overlaid = false;
      await tester.pump(kCamerasSnapshotRefresh + const Duration(seconds: 1));
      expect(stills.requests.length, 2);
      await unmount(tester);
    },
  );

  testWidgets(
    'view-open fires no grab burst: tiles queued behind the admission gate '
    'do not dial the fleet through frame.jpeg instead',
    (tester) async {
      final stills = FakeSnapshots();
      await pumpPanel(
        tester,
        stills: Go2rtcStillsConfig(
          go2rtcUrl: 'http://hub:1984',
          fetch: stills.fetch,
        ),
        // Two auto-live cameras: at open the first dials (connecting), the
        // second parks at queued behind the 400 ms gate. Before the queued
        // arm was closed, the second tile's initState grab went out in the
        // same frame — the exact unspaced burst admission exists to stop.
        stage: (house) => houseWithStream(
            houseWithStream(house, 'cam-living', 'wyze_living_room',
                substream: 'wyze_living_room_sub'),
            'cam-garage',
            'wyze_garage_door',
            substream: 'wyze_garage_door_sub'),
      );
      await openCameras(tester);

      expect(stills.requests, isEmpty,
          reason: 'queued means a live dial is milliseconds away — grabbing '
              'now would burst the air the gate is spacing');
      await unmount(tester);
    },
  );

  testWidgets(
    'undecodable still bytes fall back to the icon — no error spam, no '
    'blank face',
    (tester) async {
      final stills = FakeSnapshots()
        // Non-empty and not an image: what a truncated grab (or a proxy's
        // HTML under a 200 on the web build) actually delivers. The
        // fetchers refuse only the measured zero-byte shape; this is the
        // shape they cannot vet.
        ..next = SnapshotResult.ok(Uint8List.fromList('not a jpeg'.codeUnits));
      await pumpPanel(
        tester,
        video: const VideoConfig(),
        stills: Go2rtcStillsConfig(
          go2rtcUrl: 'http://hub:1984',
          fetch: stills.fetch,
        ),
        stage: (house) => houseWithStream(house, 'cam-living',
            'wyze_living_room',
            substream: 'wyze_living_room_sub'),
      );
      await openCameras(tester);
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'a bad frame costs the picture, never an error cascade');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tile-cam-living')),
          matching: find.byType(Icon),
        ),
        findsWidgets,
      );
      await unmount(tester);
    },
  );

  test('the grab cache window stays inside the refresh cadence — each tick '
      'a fresh frame, remounts free', () {
    expect(kGo2rtcStillCache < kCamerasSnapshotRefresh, isTrue,
        reason: 'cache >= cadence silently freezes every still face at the '
            'cached frame while logging snapshot_ok');
  });

  testWidgets(
    'a tile tap fills the screen with that camera at FULL size, and closing '
    'the zoom returns to the grid',
    (tester) async {
      await pumpPanel(tester, autoLiveStream: 'cam_living');
      await openCameras(tester);
      // The grid was playing the doorbell's tile-sized stream — or in the
      // doorbell's case, nothing at all until asked (#177014).
      expect(go2rtc.opened.map((s) => s.name), ['cam_living']);

      await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
      await tester.pumpAndSettle();

      // Zoomed: the doorbell's own stream, and the grid is gone — which is
      // the whole point, because the tiles' bandwidth is what this one is
      // about to spend. On a Wi-Fi-only house that is not an optimisation.
      expect(find.byType(ZoomedCamera), findsOneWidget);
      expect(find.byType(CameraTile), findsNothing);
      final zoom = go2rtc.opened.last;
      expect(zoom.name, 'ring_doorbell');
      expect(zoom.url.queryParameters['src'], 'ring_doorbell');
      expect(find.text('Ring Doorbell'), findsOneWidget,
          reason: 'the header names the camera being watched');

      zoom.plays();
      await tester.pump();
      expect(find.text('a moving picture'), findsOneWidget);

      // The same puck steps back to the grid rather than leaving the view.
      await tester.tap(find.byKey(const ValueKey('cameras-close')));
      await tester.pumpAndSettle();
      expect(zoom.closes, 1, reason: 'the full-size stream is not left running');
      expect(find.byType(ZoomedCamera), findsNothing);
      expect(find.byType(CameraTile), findsWidgets);
      expect(find.byType(CamerasView), findsOneWidget,
          reason: 'close from a zoom goes back to the grid, not to the '
              'Dollhouse — one X, and the first press must not throw away '
              'more than was asked');
      await unmount(tester);
    },
  );

  testWidgets(
    'a tile with no feed still zooms, and says why at a size somebody can '
    'read',
    (tester) async {
      // A tap that appears to do nothing is worse than a tap that explains.
      await pumpPanel(tester);
      await openCameras(tester);
      await tester.tap(find.byKey(const ValueKey('tile-cam-office')));
      await tester.pumpAndSettle();

      expect(find.byType(ZoomedCamera), findsOneWidget);
      expect(find.text('Not wired up yet'), findsOneWidget);
      expect(go2rtc.opened, isEmpty, reason: 'nothing to dial, so nothing was');
      await unmount(tester);
    },
  );

  testWidgets(
    'a tile plays the substream where the camera offers one — the grid gets '
    'the small picture and the Popup keeps the big one',
    (tester) async {
      // Measured 2026-08-15 and the reason this field exists: five 1080p
      // tiles at once knocked cameras off the air with `Host is unreachable`,
      // five substreams at once did not. A ~400 px tile has no use for
      // 1920×1080 either way.
      var house = houseWithoutCameraStreams(loadTestHouse());
      house = houseWithStream(house, 'cam-living', 'cam_living',
          substream: 'cam_living_sub');
      await useFullGridSurface(tester);
      final (controller, _) = fakeHubRig(house: house);
      await tester.pumpWidget(
        panelApp(
          controller,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          snapshots: SnapshotConfig(
            haUrl: 'http://hub:8123',
            token: 'tok',
            fetch: snapshots.fetch,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openCameras(tester);

      expect(go2rtc.opened.map((s) => s.name), ['cam_living_sub'],
          reason: 'the tile dials the substream, never the full-size stream');
      expect(go2rtc.only.url.queryParameters['src'], 'cam_living_sub');
      await unmount(tester);
    },
  );

  testWidgets(
    'a camera with only one stream still plays it — a substream is an '
    'offer, not a requirement',
    (tester) async {
      await pumpPanel(tester, autoLiveStream: 'cam_living');
      await openCameras(tester);
      expect(go2rtc.opened.map((s) => s.name), ['cam_living']);
      await unmount(tester);
    },
  );

  testWidgets(
    'a camera with a stream auto-lives on entry, and closing the view '
    'closes every session',
    (tester) async {
      await pumpPanel(tester, autoLiveStream: 'cam_living');
      await openCameras(tester);

      // The camera auto-lived; the doorbell did not.
      expect(go2rtc.opened.map((s) => s.name), ['cam_living']);

      // A zoom and back adds a second session, so the teardown below is
      // proving something about more than one — including one the grid no
      // longer owns by the time the route leaves.
      await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
      await tester.pumpAndSettle();
      expect(go2rtc.opened, hasLength(2));

      await tester.tap(find.byKey(const ValueKey('cameras-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cameras-close')));
      await tester.pumpAndSettle();
      for (final session in go2rtc.opened) {
        expect(
          session.closes,
          1,
          reason:
              '${session.name} must die with '
              'the route, by every route out',
        );
      }
      await unmount(tester);
    },
  );

  testWidgets('a not-wired camera renders honestly and dials nothing', (
    tester,
  ) async {
    await pumpPanel(tester);
    await openCameras(tester);

    // Every camera in the house, stripped of its stream by `pumpPanel` and
    // with no snapshot entity: six of them since the Wyze fleet's other
    // three Keys were drawn. The doorbell is the seventh tile and is not
    // counted here — it has both a stream and a snapshot face, which is the
    // next case.
    expect(find.text('Not wired up yet'), findsNWidgets(6));
    expect(go2rtc.opened, isEmpty);
    await unmount(tester);
  });

  testWidgets('the idle return asks first; unanswered, it goes and takes '
      'every session with it', (tester) async {
    await pumpPanel(tester, autoLiveStream: 'cam_living');
    await openCameras(tester);
    final session = go2rtc.only;

    await tester.pump(kCamerasIdleReturn - kCamerasIdleWarning);
    expect(find.textContaining('Still watching?'), findsOneWidget);
    expect(
      find.byType(CamerasView),
      findsOneWidget,
      reason: 'the prompt is a question, not the act',
    );

    await tester.pump(kCamerasIdleWarning);
    await tester.pumpAndSettle();
    expect(find.byType(CamerasView), findsNothing);
    expect(session.closes, 1);
    await unmount(tester);
  });

  testWidgets(
    'the idle fire refuses to pop a route that is not its own — a ding '
    'Popup on top survives, and the retry lands once it leaves',
    (tester) async {
      await pumpPanel(tester, autoLiveStream: 'cam_living');
      await openCameras(tester);
      await tester.pump(kCamerasIdleReturn - kCamerasIdleWarning);
      expect(find.textContaining('Still watching?'), findsOneWidget);

      // A ding is not a pointer event, so nothing re-arms: push an overlay
      // the way DoorbellPopupHost would.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (_, _, _) => const Text('a ding popup'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.pump(kCamerasIdleWarning);
      expect(
        find.text('a ding popup'),
        findsOneWidget,
        reason: 'the fire must never take somebody else\'s route',
      );
      expect(find.byType(CamerasView), findsOneWidget);
      expect(go2rtc.only.closes, 0);
      expect(records.any((r) => r.event == 'idle_blocked'), isTrue);
      expect(
        records.any((r) => r.event == 'idle_return'),
        isFalse,
        reason: 'a view that stayed must not log that it left',
      );

      navigator.pop();
      await tester.pumpAndSettle();
      await tester.pump(kCamerasIdleWarning);
      await tester.pumpAndSettle();
      expect(find.byType(CamerasView), findsNothing);
      expect(go2rtc.only.closes, 1);
      await unmount(tester);
    },
  );

  testWidgets('a fire that finds its route already leaving does nothing — the '
      'Dollhouse survives the race', (tester) async {
    await pumpPanel(tester);
    await openCameras(tester);
    await tester.pump(kCamerasIdleReturn - kCamerasIdleWarning);

    // A non-tap pop (system back, escape): nothing re-arms, and the fire
    // lands mid reverse-transition, while this State is still mounted.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(kCamerasIdleWarning);
    await tester.pumpAndSettle();
    expect(find.byType(CamerasView), findsNothing);
    expect(
      find.byType(DollhouseView),
      findsOneWidget,
      reason:
          'popping blind here used to leave an empty Navigator — '
          'a blank wall until restart',
    );
    await unmount(tester);
  });

  testWidgets(
    'a session born failed still logs tile_failed, and a dead session '
    'wears no LIVE badge',
    (tester) async {
      // Both real openers answer a settled session for a constructor throw,
      // and a settled session's notifier never fires a listener.
      //
      // Builds its own rig rather than going through `pumpPanel`, because
      // the opener is the subject here — so it has to do `pumpPanel`'s two
      // jobs itself: unwire the shipped cameras, or the Wyze units fail
      // alongside the doorbell and "exactly one failure" counts several; and
      // take a surface the whole grid builds on, or the doorbell tile it
      // taps is in a row [GridView] never made.
      await useFullGridSurface(tester);
      // A camera that auto-lives, so the failure lands on the TILE — the
      // doorbell would only fail inside a zoom now, which is a different
      // code path with its own `zoom_failed` line.
      final (controller, _) = fakeHubRig(
        house: houseWithStream(
          houseWithoutCameraStreams(loadTestHouse()),
          'cam-living',
          'cam_living',
        ),
      );
      await tester.pumpWidget(
        panelApp(
          controller,
          video: VideoConfig(
            go2rtcUrl: 'http://hub:1984',
            open: (url, {required name}) => SettledLiveVideoSession(
              LiveVideoPhase.failed,
              failure: 'go2rtc refused: nope',
            ),
          ),
          snapshots: SnapshotConfig(
            haUrl: 'http://hub:8123',
            token: 'tok',
            fetch: snapshots.fetch,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openCameras(tester);

      expect(
        records.any((r) => r.event == 'tile_failed'),
        isTrue,
        reason:
            'a listener never fires for a settled session — the open '
            'path must report it itself',
      );
      expect(find.text('Live view failed'), findsOneWidget);
      expect(find.text('LIVE'), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets('with no go2rtc the badge promises nothing, and a zoom says so '
      'rather than showing a black rectangle', (tester) async {
    // go2rtc unconfigured — the hermetic default — while the snapshot face
    // works. The badge must not offer live video this build cannot fetch,
    // and the zoom behind it must explain itself: `unconfigured` is decided
    // before anything is dialled, so there is no failure to report, only a
    // Panel that was never told where go2rtc is.
    //
    // Own rig, so it needs the full-grid surface itself: the doorbell tile
    // is the seventh and [GridView] does not build a row nobody can see.
    await useFullGridSurface(tester);
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(
      panelApp(
        controller,
        snapshots: SnapshotConfig(
          haUrl: 'http://hub:8123',
          token: 'tok',
          fetch: snapshots.fetch,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openCameras(tester);
    await tester.pump();
    expect(find.text('Tap for live'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
    await tester.pumpAndSettle();
    expect(find.byType(ZoomedCamera), findsOneWidget);
    expect(find.text('Live view unavailable'), findsOneWidget);

    // And back: the still loop the tile was running is picked up again,
    // rather than the tile returning frozen on whatever frame it last had.
    await tester.tap(find.byKey(const ValueKey('cameras-close')));
    await tester.pumpAndSettle();
    final before = snapshots.requests.length;
    await tester.pump(kCamerasSnapshotRefresh);
    expect(
      snapshots.requests.length,
      greaterThan(before),
      reason: 'a tile that came back from a zoom must not freeze its snapshot',
    );
    await unmount(tester);
  });

  testWidgets('cameras.closed counts the sessions the teardown released', (
    tester,
  ) async {
    await pumpPanel(tester, autoLiveStream: 'cam_living');
    await openCameras(tester);

    await tester.tap(find.byKey(const ValueKey('cameras-close')));
    await tester.pumpAndSettle();
    final closed = records.lastWhere(
      (r) => r.area == 'cameras' && r.event == 'closed',
    );
    expect(
      closed.fields?['live'],
      1,
      reason:
          'children unmount first — a census drained by tile '
          'dispose always read 0 here, and 0 is what this guards against',
    );
    await unmount(tester);
  });

  testWidgets('a view closed FROM a zoom counts the zoom, not the ghost of '
      'the grid it replaced', (tester) async {
    await pumpPanel(tester, autoLiveStream: 'cam_living');
    await openCameras(tester);

    // Zoom into a camera with nothing to dial: the grid (one live tile) is
    // unmounted, and the zoom feed itself never goes active.
    await tester.tap(find.byKey(const ValueKey('tile-cam-office')));
    await tester.pumpAndSettle();

    // A non-tap pop takes the whole view down mid-zoom.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    final closed = records.lastWhere(
      (r) => r.area == 'cameras' && r.event == 'closed',
    );
    expect(
      closed.fields?['live'],
      0,
      reason: 'the live tile died at zoom-in; carrying its census entry '
          'through the zoom logged a stream the teardown never released',
    );
    await unmount(tester);
  });

  testWidgets('a touch answers the prompt and the view stays', (tester) async {
    await pumpPanel(tester);
    await openCameras(tester);

    await tester.pump(kCamerasIdleReturn - kCamerasIdleWarning);
    expect(find.textContaining('Still watching?'), findsOneWidget);

    await tester.tapAt(const Offset(30, 30));
    await tester.pump();
    expect(find.textContaining('Still watching?'), findsNothing);

    // A fresh full period has to elapse before it asks again.
    await tester.pump(kCamerasIdleReturn - kCamerasIdleWarning);
    expect(find.byType(CamerasView), findsOneWidget);
    expect(find.textContaining('Still watching?'), findsOneWidget);
    await unmount(tester);
  });

  group('through the keep-alive', () {
    // Issue #1 was reported against the doorbell Popup, but the Cameras
    // view drops every tile session when somebody zooms and dials them all
    // again on the way back — the same open→teardown→reopen cadence, on the
    // same ring-mqtt restream, with the same mid-GOP join waiting at the end
    // of it. `main()` puts one keep-alive in front of both surfaces; these
    // cases are the proof that a tile's lifecycle reaches it.
    testWidgets('a zoom and back re-attaches the grid to the streams that '
        'are still running — which is what makes zooming cheap', (tester) async {
      // The load-bearing claim behind `_CamerasViewState._zoomed`: replacing
      // the grid unmounts every tile, and that would be an expensive way to
      // glance at one camera — 5 s a tile, 17 s on a floodlight — if the
      // keep-alive were not holding them.
      final keepAlive = LiveVideoKeepAlive(opener: go2rtc.open);
      await pumpPanel(tester,
          autoLiveStream: 'cam_living', opener: keepAlive.open);
      await openCameras(tester);
      go2rtc.only.plays();
      await tester.pump();
      expect(find.text('a moving picture'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tile-cam-living')));
      await tester.pumpAndSettle();
      expect(find.byType(ZoomedCamera), findsOneWidget);
      expect(
        go2rtc.opened.first.closes,
        0,
        reason: 'the tile stream is kept, not killed, while the zoom is up',
      );
      final dialsWhileZoomed = go2rtc.opened.length;

      await tester.tap(find.byKey(const ValueKey('cameras-close')));
      await tester.pumpAndSettle();

      // The claim `_zoomed` rests on: coming back re-attaches rather than
      // re-dialling. A fresh dial is a go2rtc spin-up the person waits
      // through — 5 s here, 17 s on a floodlight — and on the doorbell it is
      // also the relaunch that loses the IDR race of issue #1.
      expect(
        go2rtc.opened,
        hasLength(dialsWhileZoomed),
        reason: 'returning to the grid dialled go2rtc again',
      );
      // Already playing, so the grid has its picture back on the first frame.
      expect(find.text('a moving picture'), findsOneWidget);

      await unmount(tester);
      keepAlive.dispose();
    });

    testWidgets('closing the view still lets every stream go once nobody '
        'comes back', (tester) async {
      final keepAlive = LiveVideoKeepAlive(opener: go2rtc.open);
      await pumpPanel(tester,
          autoLiveStream: 'cam_living', opener: keepAlive.open);
      await openCameras(tester);

      await tester.tap(find.byKey(const ValueKey('cameras-close')));
      await tester.pumpAndSettle();
      await tester.pump(kLiveVideoLinger + const Duration(seconds: 1));

      // #177014 again: the view's promise is that its streams die with it,
      // and a grace period may delay that, never repeal it.
      expect(go2rtc.only.closes, 1);
      await unmount(tester);
      keepAlive.dispose();
    });
  });
}
