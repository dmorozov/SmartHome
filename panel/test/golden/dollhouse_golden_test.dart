import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/main.dart';
import 'package:panel/ui/hub_controller.dart';

import '../dollhouse_geometry.dart';
import '../test_house.dart';
import 'golden_setup.dart';

/// Renders the Panel to PNGs, headlessly, with no browser and no server.
///
/// Two jobs. It fails when the dollhouse changes shape unintentionally —
/// and, on failure, writes `failures/*_isolatedDiff.png` showing exactly
/// what moved. And it is the cheapest way to *look* at the Panel while
/// working on it: `flutter test --update-goldens test/golden` regenerates
/// every scene in a couple of seconds.
///
/// Goldens are host-rendered, so a small pixel tolerance is allowed (see
/// golden_setup.dart). Regenerate and eyeball the diff rather than
/// rubber-stamping a failure.
void main() {
  setUpPanelGoldens();

  // driftEvery: zero — the fake readings must not wander between runs.
  HubController fakeHub() {
    final house = loadTestHouse();
    return HubController(
        house: house, hub: FakeHub(house, driftEvery: Duration.zero));
  }

  goldenTest('ground floor selected', (tester) async {
    await pumpPanel(tester, fakeHub());

    await expectLater(find.byType(PanelApp),
        matchesGoldenFile('goldens/ground_floor.png'));
  });

  goldenTest('upstairs selected', (tester) async {
    final controller = fakeHub();
    await pumpPanel(tester, controller);

    await tester.tapAt(floorSlabCentre(tester,
        house: controller.house,
        selectedFloorId: 'ground-floor',
        floorId: 'upstairs'));
    await tester.pumpAndSettle();

    await expectLater(find.byType(PanelApp),
        matchesGoldenFile('goldens/upstairs_selected.png'));
  });

  goldenTest('device popup over the dollhouse', (tester) async {
    await pumpPanel(tester, fakeHub());

    await tester.tap(find.byKey(const ValueKey('pin-doorbell')));
    await tester.pumpAndSettle();

    await expectLater(find.byType(PanelApp),
        matchesGoldenFile('goldens/device_popup.png'));
  });

  /// What the wall shows on a cold start with the Hub down: red badge, and
  /// every Device unknown rather than frozen on its last reading. The most
  /// important scene to recognise at a glance, and the hardest to reach by
  /// hand — so it is scripted through the same adapter dev builds run,
  /// rather than through a stand-in that only this file knows about.
  goldenTest('hub unreachable', (tester) async {
    final house = loadTestHouse();
    final hub = FakeHub(house, driftEvery: Duration.zero);
    for (final device in house.floors.expand((f) => f.devices)) {
      hub.dropDevice(device.id);
    }
    hub.setReachable(false);
    await pumpPanel(tester, HubController(house: house, hub: hub));

    await expectLater(find.byType(PanelApp),
        matchesGoldenFile('goldens/hub_offline.png'));
  });
}
