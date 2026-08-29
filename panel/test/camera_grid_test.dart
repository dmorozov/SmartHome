import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/cameras/camera_grid.dart';
import 'package:panel/ui/cameras/camera_order.dart';
import 'package:panel/ui/cameras/cameras_view.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/snapshot.dart';

import 'fixtures.dart';
import 'support/fake_go2rtc.dart';
import 'support/fake_snapshots.dart';
import 'test_house.dart';

/// Rearranging the Cameras grid: press and hold a tile, drag it onto
/// another, let go — and the order is still there next time.
///
/// Driven through the real view against the shipped House Plan, because the
/// two things worth pinning are both properties of the whole scene: that a
/// camera nobody wired up cannot get between somebody and the doorbell, and
/// that moving a tile does not cost the stream underneath it.
void main() {
  late FakeGo2rtc go2rtc;
  late FakeSnapshots snapshots;

  setUp(() {
    go2rtc = FakeGo2rtc();
    snapshots = FakeSnapshots();
    // The tiles' VisibilityDetector coalesces on a 500 ms timer by default;
    // zero is the package's own documented test setting, and without it
    // every case ends holding a pending Timer.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  /// Tall enough that the whole grid is *built* — [GridView] is lazy, and on
  /// the 800×600 default the unwired tail below the rule never exists, which
  /// is exactly what most of these cases are about.
  Future<void> openCameras(
    WidgetTester tester, {
    required CameraOrderStore order,
    House? house,
  }) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final (controller, _) = fakeHubRig(house: house ?? loadTestHouse());
    await tester.pumpWidget(
      panelApp(
        controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        snapshots: SnapshotConfig(
          haUrl: 'http://hub:8123',
          token: 'tok',
          fetch: snapshots.fetch,
        ),
        order: order,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CamerasTab));
    await tester.pumpAndSettle();
  }

  /// Unmounts everything, so tile `dispose()` runs and no timer outlives the
  /// case — the same discipline the view owes the wall.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// The tiles as drawn, top-left to bottom-right.
  List<String> tileOrder(WidgetTester tester) => [
    for (final tile in tester.widgetList<CameraTile>(find.byType(CameraTile)))
      tile.device.id,
  ];

  /// Press and hold [from], drag it onto [to], let go.
  ///
  /// Moves in small steps with a frame between each: a multi-drag recognizer
  /// tracks pointer *moves*, and one long jump from press to target is not
  /// how a finger arrives — nor how the recognizer sees it.
  Future<void> dragTileOnto(
    WidgetTester tester,
    String from,
    String to,
  ) async {
    final start = tester.getCenter(find.byKey(ValueKey('tile-$from')));
    final end = tester.getCenter(find.byKey(ValueKey('tile-$to')));
    final gesture = await tester.startGesture(start);
    // Past the lift delay (300 ms) with room to spare.
    await tester.pump(const Duration(milliseconds: 500));
    const steps = 12;
    for (var i = 1; i <= steps; i++) {
      await gesture.moveTo(start + (end - start) * (i / steps));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the camera nobody wired up is last, behind a rule that says why — '
    'plan order had it sitting in front of the doorbell',
    (tester) async {
      await openCameras(tester, order: CameraOrderStore());

      final order = tileOrder(tester);
      expect(order.last, 'cam-office', reason: 'the one camera with no feed');
      expect(
        order.indexOf('doorbell'),
        lessThan(order.indexOf('cam-office')),
        reason: 'the tile somebody actually comes to look at goes first',
      );
      expect(find.text('NOT SET UP'), findsOneWidget);

      // Where the rule *sits*, not merely that it exists. Without this the
      // rule could be hoisted to the top of the grid — captioning the set-up
      // cameras as the not-set-up ones — and every other case here, and the
      // whole 600-case suite, would stay green. Demonstrated, not imagined.
      final rule = tester.getRect(find.byType(NotSetUpRule));
      final lastWired = tester.getRect(
        find.byKey(ValueKey('tile-${order[order.length - 2]}')),
      );
      final firstUnwired = tester.getRect(
        find.byKey(const ValueKey('tile-cam-office')),
      );
      expect(rule.top, greaterThanOrEqualTo(lastWired.bottom));
      expect(rule.bottom, lessThanOrEqualTo(firstUnwired.top));
      await unmount(tester);
    },
  );

  testWidgets(
    'a tile lifted while the grid is torn out from under it does not throw '
    '— onDraggableCanceled is the one Draggable callback Flutter does NOT '
    'mounted-guard for you',
    (tester) async {
      final store = CameraOrderStore();
      await openCameras(tester, order: store);
      final before = tileOrder(tester);

      // One finger lifts a tile...
      final lift = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('tile-${before.first}'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await lift.moveBy(const Offset(0, 30));
      await tester.pump();

      // ...while a second finger taps another tile, which zooms and
      // replaces the whole grid. A wall panel is a multi-touch device.
      await tester.tap(find.byKey(ValueKey('tile-${before[1]}')));
      await tester.pumpAndSettle();
      expect(find.byType(ZoomedCamera), findsOneWidget);

      // Releasing over nothing cancels the drag against a defunct State.
      await lift.moveBy(const Offset(-600, -400));
      await tester.pump();
      await lift.up();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets(
    'at the wall real size the grid still scrolls after a brief rest — a '
    'look-then-flick must not rearrange the house',
    (tester) async {
      // 1280x800 is the wall, where the grid genuinely scrolls (687 px of
      // viewport against 887 px of content). Every other case here uses a
      // 1600-tall surface so the whole grid is built, which is exactly why
      // this conflict went unnoticed until it was measured.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final store = CameraOrderStore();
      final (controller, _) = fakeHubRig(house: loadTestHouse());
      await tester.pumpWidget(
        panelApp(
          controller,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          snapshots: SnapshotConfig(
            haUrl: 'http://hub:8123',
            token: 'tok',
            fetch: snapshots.fetch,
          ),
          order: store,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CamerasTab));
      await tester.pumpAndSettle();

      final scrollable = find.byType(Scrollable).last;
      final start = tester.getCenter(find.byType(CameraTile).first);
      final gesture = await tester.startGesture(start);
      // A rest a person takes while looking at the picture, then a flick.
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, -25));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester.widget<Scrollable>(scrollable).controller?.position.pixels ??
            Scrollable.of(
              tester.element(find.byType(CameraTile).first),
            ).position.pixels,
        greaterThan(0),
        reason: 'the flick scrolled the grid',
      );
      expect(
        store.value,
        isEmpty,
        reason: 'and rearranged nothing behind the person back',
      );
      await unmount(tester);
    },
  );

  testWidgets('holding a tile and dropping it on another moves it', (
    tester,
  ) async {
    final store = CameraOrderStore();
    await openCameras(tester, order: store);
    final before = tileOrder(tester);

    await dragTileOnto(tester, before[3], before[0]);

    expect(tileOrder(tester).first, before[3]);
    expect(store.value.first, before[3]);
    // The wall stays where it was, whatever moved above it.
    expect(store.value.last, 'cam-office');
    await unmount(tester);
  });

  testWidgets(
    'the order is still there next time the Cameras view is opened',
    (tester) async {
      final store = CameraOrderStore();
      await openCameras(tester, order: store);
      final before = tileOrder(tester);
      await dragTileOnto(tester, before[2], before[0]);
      expect(tileOrder(tester).first, before[2]);

      await tester.tap(find.byKey(const ValueKey('cameras-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CamerasTab));
      await tester.pumpAndSettle();

      expect(tileOrder(tester).first, before[2]);
      await unmount(tester);
    },
  );

  testWidgets(
    'a store handed a saved order draws it on the first frame — no grid in '
    'plan order that rearranges itself once storage answers',
    (tester) async {
      await openCameras(
        tester,
        order: CameraOrderStore(initial: const ['doorbell', 'cam-living']),
      );
      // Not pumpAndSettle-dependent: the first build already has it.
      expect(tileOrder(tester).take(2), ['doorbell', 'cam-living']);
      await unmount(tester);
    },
  );

  testWidgets(
    'a tap still zooms — the tile did not become a control that only '
    'rearranges',
    (tester) async {
      final store = CameraOrderStore();
      await openCameras(tester, order: store);
      final before = tileOrder(tester);

      await tester.tap(find.byKey(ValueKey('tile-${before.first}')));
      await tester.pumpAndSettle();

      expect(find.byType(ZoomedCamera), findsOneWidget);
      expect(store.value, isEmpty, reason: 'a tap arranges nothing');
      await unmount(tester);
    },
  );

  testWidgets(
    'nothing can be dropped onto the not-set-up tail, and nothing in it '
    'can be lifted',
    (tester) async {
      final store = CameraOrderStore();
      await openCameras(tester, order: store);
      final before = tileOrder(tester);

      // Onto the unwired tile...
      await dragTileOnto(tester, before.first, 'cam-office');
      expect(tileOrder(tester), before);
      expect(store.value, isEmpty);

      // ...and out of it.
      await dragTileOnto(tester, 'cam-office', before.first);
      expect(tileOrder(tester), before);
      expect(store.value, isEmpty);
      await unmount(tester);
    },
  );

  testWidgets(
    'moving a LIVE tile does not close its session — the lifted tile keeps '
    'playing in the hole it came from',
    (tester) async {
      final store = CameraOrderStore();
      await openCameras(
        tester,
        order: store,
        house: houseWithStream(
          houseWithoutCameraStreams(loadTestHouse()),
          'cam-living',
          'cam_living',
        ),
      );
      // Only cam-living has a feed in this scene: every other camera was
      // stripped, and the doorbell is wired but never auto-live (#177014).
      // So the single open session belongs to the tile about to be dragged.
      final session = go2rtc.only;
      expect(session.closes, 0);
      expect(tileOrder(tester).take(2), ['cam-living', 'doorbell']);

      // A real move, not a drop onto itself: the doorbell is the only other
      // tile above the rule.
      await dragTileOnto(tester, 'cam-living', 'doorbell');

      expect(tileOrder(tester).take(2), ['doorbell', 'cam-living']);
      expect(
        go2rtc.opened.length,
        1,
        reason: 'a drag must not dial the camera a second time',
      );
      expect(
        session.closes,
        0,
        reason: 'nor tear the first one down and lean on the keep-alive',
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'Reset order appears only once there is something to undo, and puts the '
    'grid back to plan order',
    (tester) async {
      final store = CameraOrderStore();
      await openCameras(tester, order: store);
      final plan = tileOrder(tester);
      const reset = ValueKey('cameras-reset-order');

      expect(
        find.byKey(reset),
        findsNothing,
        reason: 'a wall nobody rearranged carries no extra chrome',
      );

      await dragTileOnto(tester, plan[3], plan[0]);
      expect(tileOrder(tester), isNot(plan));
      expect(find.byKey(reset), findsOneWidget);

      await tester.tap(find.byKey(reset));
      await tester.pumpAndSettle();

      expect(tileOrder(tester), plan);
      expect(store.value, isEmpty, reason: 'forgotten, not inverted');
      expect(find.byKey(reset), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets('a house with every camera wired draws no rule at all', (
    tester,
  ) async {
    await openCameras(
      tester,
      order: CameraOrderStore(),
      house: houseWithStream(loadTestHouse(), 'cam-office', 'cam_office'),
    );
    expect(find.byType(NotSetUpRule), findsNothing);
    expect(find.text('NOT SET UP'), findsNothing);
    await unmount(tester);
  });
}
