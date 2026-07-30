import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/demo_house.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/main.dart';
import 'package:panel/ui/hub_controller.dart';

void main() {
  (HubController, FakeHub) makeController() {
    final house = demoHouse();
    final hub = FakeHub(house, driftEvery: Duration.zero);
    return (HubController(house: house, hub: hub), hub);
  }

  testWidgets('renders with the ground floor expanded', (tester) async {
    final (controller, _) = makeController();
    await tester.pumpWidget(PanelApp(controller: controller));

    expect(find.text('Demo House'), findsOneWidget);
    // Ground-floor pins are live (the doorbell lives in the hall)…
    expect(find.byIcon(Icons.doorbell), findsOneWidget);
    // …while collapsed upstairs shows no pins.
    expect(find.byIcon(Icons.local_laundry_service), findsNothing);
  });

  testWidgets('tapping a collapsed floor expands it', (tester) async {
    final (controller, _) = makeController();
    await tester.pumpWidget(PanelApp(controller: controller));

    // Collapsed floors are scaled toward their top-center, so tap inside
    // the scaled slab rather than the full-size widget's center.
    final rect =
        tester.getRect(find.byKey(const ValueKey('floor-upstairs')));
    await tester.tapAt(rect.topCenter + Offset(0, rect.height * 0.2));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.local_laundry_service), findsOneWidget);
    expect(find.byIcon(Icons.doorbell), findsNothing);
  });

  testWidgets('tapping a light pin toggles it through the hub',
      (tester) async {
    final (controller, hub) = makeController();
    await tester.pumpWidget(PanelApp(controller: controller));

    final before = (hub.states['light-hall'] as SwitchState).on;
    await tester.tap(find.byKey(const ValueKey('pin-light-hall')));
    await tester.pumpAndSettle();

    expect((hub.states['light-hall'] as SwitchState).on, !before);
  });

  testWidgets('tapping the doorbell pin opens the live-view popup',
      (tester) async {
    final (controller, _) = makeController();
    await tester.pumpWidget(PanelApp(controller: controller));

    await tester.tap(find.byKey(const ValueKey('pin-doorbell')));
    await tester.pumpAndSettle();

    expect(find.text('Ring Doorbell'), findsOneWidget);
    expect(
        find.text('Live view placeholder — go2rtc stream'), findsOneWidget);
  });
}
