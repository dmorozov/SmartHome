import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/ui/cameras/cameras_view.dart';
import 'package:panel/ui/dollhouse/dollhouse_view.dart';
import 'package:panel/ui/edge_tab.dart';
import 'package:panel/ui/video/live_video.dart';

import 'dollhouse_geometry.dart';
import 'fixtures.dart';
import 'support/fake_go2rtc.dart';
import 'test_house.dart';

/// A Device glyph **on the Dollhouse**, which is not the same question as
/// "anywhere on the Panel": the doorbell's edge tab deliberately wears the
/// same icon as its pin (`edge_tab.dart` — so the tab and the pin cannot come
/// to disagree about what a doorbell looks like), and a bare `find.byIcon`
/// therefore counts a pin that is not there and a tab that always is.
///
/// The tests below are about **which Floor is expanded**, so the Dollhouse is
/// the subtree they mean.
Finder pinIcon(IconData icon) => find.descendant(
  of: find.byType(DollhouseView),
  matching: find.byIcon(icon),
);

/// The Dollhouse as the wall shows it. Every scene the Hub has a hand in is
/// staged through FakeHub's driving surface — the same adapter dev builds
/// run — rather than through a stand-in written for one test.
void main() {
  testWidgets('renders with the ground floor expanded', (tester) async {
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    expect(find.text('Demo House'), findsOneWidget);
    // Ground-floor pins are live (the doorbell lives in the hall)…
    expect(pinIcon(Icons.doorbell), findsOneWidget);
    // …while collapsed upstairs shows no pins (litter robot: landing).
    expect(pinIcon(Icons.pets), findsNothing);
  });

  testWidgets('tapping a collapsed floor expands it', (tester) async {
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    await tester.tapAt(
      floorSlabCentre(
        tester,
        house: controller.house,
        selectedFloorId: 'ground-floor',
        floorId: 'upstairs',
      ),
    );
    await tester.pumpAndSettle();

    expect(pinIcon(Icons.pets), findsOneWidget);
    expect(pinIcon(Icons.doorbell), findsNothing);
  });

  /// Selecting a Floor by dragging the stack up or down (owner, 2026-08-15).
  ///
  /// **Content follows the finger**: dragging *down* slides the stack down,
  /// bringing the Floor drawn above into the centre — and the Floor drawn
  /// above is the higher level. So a downward drag goes upstairs. Every
  /// direction assertion below is really that one sentence.
  ///
  /// The test house has two Floors, `ground-floor` (0) and `upstairs` (1),
  /// and starts on the ground.
  group('selecting a Floor by drag', () {
    /// Comfortably past the commit threshold at the default surface, and the
    /// wrong sign for going up — the drag goes *down* to reach the Floor
    /// above.
    const past = 220.0;
    const short = 20.0;

    Future<void> pumpDollhouse(WidgetTester tester) async {
      final (controller, _) = fakeHubRig();
      await tester.pumpWidget(panelApp(controller));
      await tester.pumpAndSettle();
    }

    /// Drags from the middle of the Dollhouse, deliberately not from a pin —
    /// the pin case is its own test below.
    Future<void> dragBy(WidgetTester tester, double dy) async {
      await tester.drag(find.byType(DollhouseView), Offset(0, dy));
      await tester.pumpAndSettle();
    }

    testWidgets('dragging down brings the Floor above into the centre', (
      tester,
    ) async {
      await pumpDollhouse(tester);
      expect(pinIcon(Icons.pets), findsNothing, reason: 'upstairs is not up');

      await dragBy(tester, past);

      expect(pinIcon(Icons.pets), findsOneWidget);
      expect(pinIcon(Icons.doorbell), findsNothing);
    });

    testWidgets('dragging up from the ground floor does nothing — there is no '
        'Floor below it, and the stack springs back', (tester) async {
      await pumpDollhouse(tester);

      await dragBy(tester, -past);

      expect(pinIcon(Icons.doorbell), findsOneWidget);
      expect(pinIcon(Icons.pets), findsNothing);
      // Sprung back: nothing is left leaning, so the next gesture starts from
      // a stack that is where the arrangement says it is.
      final transform = tester.widget<Transform>(
        find
            .descendant(
              of: find.byType(DollhouseView),
              matching: find.byType(Transform),
            )
            .first,
      );
      expect(transform.transform.getTranslation().y, 0);
    });

    testWidgets('a drag that does not cover the threshold selects nothing', (
      tester,
    ) async {
      await pumpDollhouse(tester);

      await dragBy(tester, short);

      expect(pinIcon(Icons.doorbell), findsOneWidget);
      expect(pinIcon(Icons.pets), findsNothing);
    });

    testWidgets('and back down again — the two directions are symmetrical', (
      tester,
    ) async {
      await pumpDollhouse(tester);
      await dragBy(tester, past);
      expect(pinIcon(Icons.pets), findsOneWidget);

      await dragBy(tester, -past);

      expect(pinIcon(Icons.doorbell), findsOneWidget);
      expect(pinIcon(Icons.pets), findsNothing);
    });

    testWidgets('a drag that begins on a Device pin scrolls the house instead '
        'of opening that Device — the regression this gesture most invites', (
      tester,
    ) async {
      final go2rtc = FakeGo2rtc();
      final (controller, _) = fakeHubRig();
      await tester.pumpWidget(
        panelApp(
          controller,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const ValueKey('pin-doorbell')),
        const Offset(0, past),
      );
      await tester.pumpAndSettle();

      // No Popup, and the Floor changed: the gesture arena gave the pointer
      // to the drag once it passed slop, exactly as it does in a ListView
      // full of buttons.
      expect(find.byType(Dialog), findsNothing);
      expect(go2rtc.opened, isEmpty);
      expect(pinIcon(Icons.pets), findsOneWidget);
    });

    testWidgets('a tap on a pin still opens it — a drag recogniser does not '
        'cost the taps that were there first', (tester) async {
      final go2rtc = FakeGo2rtc();
      final (controller, _) = fakeHubRig();
      await tester.pumpWidget(
        panelApp(
          controller,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('pin-doorbell')));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('popup-close')));
      await tester.pumpAndSettle();
    });
  });

  /// The handles on the Panel's right edge (owner-restacked 2026-08-15): the
  /// doorbell's Popup above, the Cameras view below, both flush to the glass.
  group('the edge tabs', () {
    testWidgets('both ride the screen edge, starting below the title — no '
        'gutter, because a tab inside the gutter is a button', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (controller, _) = fakeHubRig();
      await tester.pumpWidget(panelApp(controller));
      await tester.pumpAndSettle();

      final bell = tester.getRect(find.byType(DoorbellTab));
      final cameras = tester.getRect(find.byType(CamerasTab));

      // Flush: the 24 px gutter every other thing on the Panel sits inside
      // stops at these two.
      expect(bell.right, 1280);
      expect(cameras.right, 1280);
      expect(bell.top, kEdgeTabsTop);
      // The doorbell above the cameras, one gap apart, and the same width —
      // two handles have to read as a set.
      expect(cameras.top, kEdgeTabsTop + bell.height + kEdgeTabGap);
      expect(cameras.width, bell.width);
    });

    testWidgets('tapping the doorbell tab opens the same Popup a ding raises '
        '— reached without hunting for the pin', (tester) async {
      final go2rtc = FakeGo2rtc();
      final (controller, _) = fakeHubRig();
      await tester.pumpWidget(
        panelApp(
          controller,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.byType(DoorbellTab));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Ring Doorbell'), findsOneWidget);
      // A person tapped it, so it opened the doorbell's own stream and gets
      // no countdown (D14) — the tab is the pin's shortcut, not a new kind
      // of Popup.
      expect(go2rtc.only.name, 'ring_doorbell');
      expect(find.byKey(const ValueKey('push-to-talk')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('popup-close')));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('tapping a light pin toggles it through the hub', (tester) async {
    final (controller, hub) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    final before = (hub.states['light-hall'] as SwitchState).on;
    await tester.tap(find.byKey(const ValueKey('pin-light-hall')));
    await tester.pumpAndSettle();

    expect((hub.states['light-hall'] as SwitchState).on, !before);
  });

  testWidgets('tapping the doorbell pin opens the live-view popup', (
    tester,
  ) async {
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    await tester.tap(find.byKey(const ValueKey('pin-doorbell')));
    await tester.pumpAndSettle();

    expect(find.text('Ring Doorbell'), findsOneWidget);
    expect(find.text('Live view placeholder — go2rtc stream'), findsOneWidget);
  });

  testWidgets('a tapped camera pin plays the stream the House Plan named, '
      'from the go2rtc the Panel was configured with', (tester) async {
    // The wiring nothing else can see: DollhouseView carries the Panel's
    // VideoConfig to the Popup it pushes. Replace `widget.video` with a
    // fresh `VideoConfig()` there and every other test in this file still
    // passes — the Popup would simply, silently, never play anything.
    final (controller, _) = fakeHubRig(
      house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'),
    );
    final go2rtc = FakeGo2rtc();
    await tester.pumpWidget(
      panelApp(
        controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('pin-doorbell')));
    await tester.pumpAndSettle();

    expect(
      go2rtc.only.url.toString(),
      'ws://hub:1984/api/ws?src=ring_doorbell',
    );
  });

  testWidgets('tapping a light pin with unknown state attempts a toggle, '
      'not a popup', (tester) async {
    // Unknown state is normal: no entity bound yet, an unavailable entity,
    // or the window before the Hub's first snapshot (ADR-0004). The pin's
    // affordance follows the Device's kind, so it stays a light switch.
    final (controller, hub) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    hub.dropDevice('light-hall');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pin-light-hall')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect((hub.states['light-hall'] as SwitchState).on, isTrue);
  });

  testWidgets('the OFFLINE badge follows the Hub away and back', (
    tester,
  ) async {
    final (controller, hub) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    expect(find.text('FAKE HUB'), findsOneWidget);

    hub.setStatus(HubStatus.retrying);
    await tester.pump();

    expect(find.text('FAKE HUB OFFLINE'), findsOneWidget);

    hub.setStatus(HubStatus.up);
    await tester.pump();

    expect(find.text('FAKE HUB'), findsOneWidget);
  });

  testWidgets('a rejected token reads differently from an absent Hub', (
    tester,
  ) async {
    // The whole point of the three-state status: one of these is fixed by
    // waiting and the other by a person with a new token, and the badge is
    // the only place the Panel can say which.
    final (controller, hub) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    hub.setStatus(HubStatus.gaveUp);
    await tester.pump();

    expect(find.text('FAKE HUB NEEDS NEW TOKEN'), findsOneWidget);
    expect(find.text('FAKE HUB OFFLINE'), findsNothing);
  });

  testWidgets('a state the Hub reports re-renders its pin', (tester) async {
    final (controller, hub) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    expect(find.text('21.4°'), findsOneWidget);

    hub.pushState(
      const ThermostatState(
        'thermostat',
        current: 23.0,
        target: 21.0,
        unit: TemperatureUnit.celsius,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('23.0°'), findsOneWidget);
    expect(find.text('21.4°'), findsNothing);
  });

  testWidgets('a Device the Hub loses re-renders as unknown', (tester) async {
    final (controller, hub) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    // A pin with a reading wears it; with nothing to report it falls back
    // to its kind's icon — the difference between "812 W" and "who knows".
    expect(find.text('812W'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsNothing);

    hub.dropDevice('energy-monitor');
    await tester.pumpAndSettle();

    expect(find.text('812W'), findsNothing);
    expect(find.byIcon(Icons.bolt), findsOneWidget);
  });
}
