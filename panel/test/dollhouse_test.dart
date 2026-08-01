import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/main.dart';
import 'package:panel/ui/hub_controller.dart';

import 'test_house.dart';

void main() {
  (HubController, FakeHub) makeController() {
    final house = loadTestHouse();
    final hub = FakeHub(house, driftEvery: Duration.zero);
    return (HubController(house: house, hub: hub), hub);
  }

  testWidgets('renders with the ground floor expanded', (tester) async {
    final (controller, _) = makeController();
    await tester.pumpWidget(PanelApp(controller: controller));

    expect(find.text('Demo House'), findsOneWidget);
    // Ground-floor pins are live (the doorbell lives in the hall)…
    expect(find.byIcon(Icons.doorbell), findsOneWidget);
    // …while collapsed upstairs shows no pins (litter robot: landing).
    expect(find.byIcon(Icons.pets), findsNothing);
  });

  testWidgets('tapping a collapsed floor expands it', (tester) async {
    final (controller, _) = makeController();
    await tester.pumpWidget(PanelApp(controller: controller));

    // The rect is the unscaled box; a neighbour is drawn at 0.32 about its
    // top centre, so the box centre maps to 0.16 of the height. Only the
    // slab itself takes taps — the rest of the box belongs to whichever
    // Floor is behind it.
    final rect =
        tester.getRect(find.byKey(const ValueKey('floor-upstairs')));
    await tester.tapAt(rect.topCenter + Offset(0, rect.height * 0.16));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.pets), findsOneWidget);
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

  testWidgets('tapping a light pin with unknown state attempts a toggle, '
      'not a popup', (tester) async {
    // Unknown state is normal: no entity bound yet, an unavailable entity,
    // or the window before the Hub's first snapshot (ADR-0004). The pin's
    // affordance follows the Device's kind, so it stays a light switch.
    final house = loadTestHouse();
    final hub = _UnknownStateHub();
    await tester.pumpWidget(
        PanelApp(controller: HubController(house: house, hub: hub)));

    await tester.tap(find.byKey(const ValueKey('pin-light-hall')));
    await tester.pumpAndSettle();

    expect(hub.toggled, ['light-hall']);
    expect(find.byType(Dialog), findsNothing);
  });
}

/// A Hub that is up but has nothing to say about any Device: every state is
/// unknown. Records the commands it is sent.
class _UnknownStateHub implements HubClient {
  final toggled = <String>[];

  @override
  final ValueNotifier<bool> connected = ValueNotifier(true);

  @override
  Map<String, DeviceState> get states => const {};

  @override
  Stream<DeviceState> get stateChanges => const Stream.empty();

  @override
  Future<void> toggle(String deviceId) async => toggled.add(deviceId);

  @override
  void dispose() => connected.dispose();
}
