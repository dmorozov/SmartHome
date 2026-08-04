import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/domain/device_state.dart';

import 'dollhouse_geometry.dart';
import 'fixtures.dart';

/// The Dollhouse as the wall shows it. Every scene the Hub has a hand in is
/// staged through FakeHub's driving surface — the same adapter dev builds
/// run — rather than through a stand-in written for one test.
void main() {
  testWidgets('renders with the ground floor expanded', (tester) async {
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    expect(find.text('Demo House'), findsOneWidget);
    // Ground-floor pins are live (the doorbell lives in the hall)…
    expect(find.byIcon(Icons.doorbell), findsOneWidget);
    // …while collapsed upstairs shows no pins (litter robot: landing).
    expect(find.byIcon(Icons.pets), findsNothing);
  });

  testWidgets('tapping a collapsed floor expands it', (tester) async {
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    await tester.tapAt(floorSlabCentre(tester,
        house: controller.house,
        selectedFloorId: 'ground-floor',
        floorId: 'upstairs'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.pets), findsOneWidget);
    expect(find.byIcon(Icons.doorbell), findsNothing);
  });

  testWidgets('tapping a light pin toggles it through the hub',
      (tester) async {
    final (controller, hub) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    final before = (hub.states['light-hall'] as SwitchState).on;
    await tester.tap(find.byKey(const ValueKey('pin-light-hall')));
    await tester.pumpAndSettle();

    expect((hub.states['light-hall'] as SwitchState).on, !before);
  });

  testWidgets('tapping the doorbell pin opens the live-view popup',
      (tester) async {
    final (controller, _) = fakeHubRig();
    await tester.pumpWidget(panelApp(controller));

    await tester.tap(find.byKey(const ValueKey('pin-doorbell')));
    await tester.pumpAndSettle();

    expect(find.text('Ring Doorbell'), findsOneWidget);
    expect(
        find.text('Live view placeholder — go2rtc stream'), findsOneWidget);
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

  testWidgets('the OFFLINE badge follows the Hub away and back',
      (tester) async {
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

  testWidgets('a rejected token reads differently from an absent Hub',
      (tester) async {
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

    hub.pushState(const ThermostatState('thermostat',
        current: 23.0, target: 21.0, unit: TemperatureUnit.celsius));
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
