import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/ui/cameras/cameras_view.dart';
import 'package:panel/ui/dollhouse/dollhouse_view.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_keepalive.dart';
import 'package:panel/ui/video/snapshot.dart';

import 'fixtures.dart';
import 'support/fake_go2rtc.dart';
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
  });

  tearDown(() {
    Log.sink = Log.printRecord;
  });

  /// [opener] replaces the raw fake for the one case that needs something
  /// *between* the tiles and it — the keep-alive. Everything else drives
  /// [go2rtc] directly, because what it asserts is the tile's own lifecycle.
  Future<void> pumpPanel(WidgetTester tester,
      {String? autoLiveStream, LiveVideoOpener? opener}) async {
    var house = loadTestHouse();
    if (autoLiveStream != null) {
      house = houseWithStream(house, 'cam-living', autoLiveStream);
    }
    final (controller, _) = fakeHubRig(house: house);
    await tester.pumpWidget(panelApp(
      controller,
      video: VideoConfig(
          go2rtcUrl: 'http://hub:1984', open: opener ?? go2rtc.open),
      snapshots: SnapshotConfig(
          haUrl: 'http://hub:8123', token: 'tok', fetch: snapshots.fetch),
    ));
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

  testWidgets('the right-edge tab slides the view out, Close returns',
      (tester) async {
    await pumpPanel(tester);
    expect(find.byType(CamerasView), findsNothing);

    await openCameras(tester);
    expect(find.byType(CamerasView), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(CamerasView), findsNothing);
    await unmount(tester);
  });

  testWidgets(
      'the doorbell tile is off at entry, wears the snapshot, and no Ring '
      'session exists until a person asks', (tester) async {
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
  });

  testWidgets('a tile tap opens exactly that stream; a second tap closes it',
      (tester) async {
    await pumpPanel(tester);
    await openCameras(tester);

    await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
    await tester.pump();
    final session = go2rtc.only;
    expect(session.name, 'ring_doorbell');
    expect(session.url.queryParameters['src'], 'ring_doorbell');
    expect(find.text('LIVE'), findsOneWidget);

    session.plays();
    await tester.pump();
    expect(find.text('a moving picture'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
    await tester.pump();
    expect(session.closes, 1);
    expect(go2rtc.opened, hasLength(1), reason: 'toggle, not reopen');
    expect(find.text('LIVE'), findsNothing);
    await unmount(tester);
  });

  testWidgets(
      'a camera with a stream auto-lives on entry, and closing the view '
      'closes every session', (tester) async {
    await pumpPanel(tester, autoLiveStream: 'cam_living');
    await openCameras(tester);

    // The camera auto-lived; the doorbell did not.
    expect(go2rtc.opened.map((s) => s.name), ['cam_living']);

    await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
    await tester.pump();
    expect(go2rtc.opened, hasLength(2));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    for (final session in go2rtc.opened) {
      expect(session.closes, 1, reason: '${session.name} must die with '
          'the route, by every route out');
    }
    await unmount(tester);
  });

  testWidgets('a not-wired camera renders honestly and dials nothing',
      (tester) async {
    await pumpPanel(tester);
    await openCameras(tester);

    // Three placeholder cameras, no stream and no snapshot on any of them.
    expect(find.text('Not wired up yet'), findsNWidgets(3));
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
    expect(find.byType(CamerasView), findsOneWidget,
        reason: 'the prompt is a question, not the act');

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
    navigator.push(PageRouteBuilder<void>(
        opaque: false, pageBuilder: (_, _, _) => const Text('a ding popup')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pump(kCamerasIdleWarning);
    expect(find.text('a ding popup'), findsOneWidget,
        reason: 'the fire must never take somebody else\'s route');
    expect(find.byType(CamerasView), findsOneWidget);
    expect(go2rtc.only.closes, 0);
    expect(records.any((r) => r.event == 'idle_blocked'), isTrue);
    expect(records.any((r) => r.event == 'idle_return'), isFalse,
        reason: 'a view that stayed must not log that it left');

    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(kCamerasIdleWarning);
    await tester.pumpAndSettle();
    expect(find.byType(CamerasView), findsNothing);
    expect(go2rtc.only.closes, 1);
    await unmount(tester);
  });

  testWidgets(
      'a fire that finds its route already leaving does nothing — the '
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
    expect(find.byType(DollhouseView), findsOneWidget,
        reason: 'popping blind here used to leave an empty Navigator — '
            'a blank wall until restart');
    await unmount(tester);
  });

  testWidgets(
      'a session born failed still logs tile_failed, and a dead session '
      'wears no LIVE badge', (tester) async {
    // Both real openers answer a settled session for a constructor throw,
    // and a settled session's notifier never fires a listener.
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(panelApp(
      controller,
      video: VideoConfig(
          go2rtcUrl: 'http://hub:1984',
          open: (url, {required name}) => SettledLiveVideoSession(
              LiveVideoPhase.failed, failure: 'go2rtc refused: nope')),
      snapshots: SnapshotConfig(
          haUrl: 'http://hub:8123', token: 'tok', fetch: snapshots.fetch),
    ));
    await tester.pumpAndSettle();
    await openCameras(tester);

    await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
    await tester.pump();
    expect(records.any((r) => r.event == 'tile_failed'), isTrue,
        reason: 'a listener never fires for a settled session — the open '
            'path must report it itself');
    expect(find.text('Live view failed'), findsOneWidget);
    expect(find.text('LIVE'), findsNothing);
    await unmount(tester);
  });

  testWidgets(
      'a declined open hands the tile back to the still loop, and the '
      'badge never promises a tap that cannot deliver', (tester) async {
    // go2rtc unconfigured — the hermetic default — while the snapshot
    // face works. One tap used to freeze the still forever.
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(panelApp(
      controller,
      snapshots: SnapshotConfig(
          haUrl: 'http://hub:8123', token: 'tok', fetch: snapshots.fetch),
    ));
    await tester.pumpAndSettle();
    await openCameras(tester);
    await tester.pump();
    expect(find.text('Tap for live'), findsNothing);

    final before = snapshots.requests.length;
    await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
    await tester.pump();
    await tester.pump(kCamerasSnapshotRefresh);
    expect(snapshots.requests.length, greaterThan(before),
        reason: 'a tap whose open declined must not freeze the snapshot');
    await unmount(tester);
  });

  testWidgets('cameras.closed counts the sessions the teardown released',
      (tester) async {
    await pumpPanel(tester, autoLiveStream: 'cam_living');
    await openCameras(tester);
    await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    final closed = records.lastWhere(
        (r) => r.area == 'cameras' && r.event == 'closed');
    expect(closed.fields?['live'], 2,
        reason: 'children unmount first — a census drained by tile '
            'dispose always read 0 here');
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
    // view's tiles toggle their own sessions on tap and drop all of them
    // when the view closes — the same open→teardown→reopen cadence, on the
    // same ring-mqtt restream, with the same mid-GOP join waiting at the end
    // of it. `main()` puts one keep-alive in front of both surfaces; these
    // cases are the proof that a tile's lifecycle reaches it.
    testWidgets('a tile toggled off and straight back on re-attaches to the '
        'stream that is still running', (tester) async {
      final keepAlive = LiveVideoKeepAlive(opener: go2rtc.open);
      await pumpPanel(tester, opener: keepAlive.open);
      await openCameras(tester);

      await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
      await tester.pump();
      go2rtc.only.plays();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
      await tester.pump();
      expect(go2rtc.only.closes, 0, reason: 'kept, not killed');
      expect(find.text('LIVE'), findsNothing,
          reason: 'the tile is off however the stream is held');

      await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
      await tester.pump();

      expect(go2rtc.opened, hasLength(1),
          reason: 'a second dial is the relaunch that loses the IDR race');
      expect(find.text('LIVE'), findsOneWidget);
      // Already playing, so the picture is there on the first frame rather
      // than after another go2rtc spin-up.
      expect(find.text('a moving picture'), findsOneWidget);

      await unmount(tester);
      keepAlive.dispose();
    });

    testWidgets('closing the view still lets every stream go once nobody '
        'comes back', (tester) async {
      final keepAlive = LiveVideoKeepAlive(opener: go2rtc.open);
      await pumpPanel(tester, opener: keepAlive.open);
      await openCameras(tester);
      await tester.tap(find.byKey(const ValueKey('tile-doorbell')));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.close));
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
