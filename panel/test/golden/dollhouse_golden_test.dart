import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/main.dart';

import '../dollhouse_geometry.dart';
import '../fixtures.dart';
import 'golden_setup.dart';

/// Renders the Panel to PNGs, headlessly, with no browser and no server.
///
/// Two jobs. It fails when the dollhouse changes shape unintentionally —
/// and, on failure, writes `failures/*_isolatedDiff.png` showing exactly
/// what moved. And it is the cheapest way to *look* at the Panel while
/// working on it: `flutter test --update-goldens test/golden` regenerates
/// every scene in a couple of seconds.
///
/// Goldens are baked in the devcontainer — the canonical golden host
/// (ADR-0009) — and match exactly there; the tolerance knob in
/// golden_setup.dart exists only for genuine cross-rebuild drift inside
/// the container. Regenerate (in-container) and eyeball the diff rather
/// than rubber-stamping a failure.
void main() {
  setUpPanelGoldens();

  /// The two scenes about a Hub the Panel cannot reach: every Device
  /// dropped to unknown, and the badge in [status]. They render the
  /// production label, because a rejected token and an absent Hub are
  /// production events — a dev build's fake hub is in-process and does
  /// neither.
  Future<void> pumpHubFailure(WidgetTester tester, HubStatus status) async {
    final (controller, hub) = fakeHubRig();
    for (final device in controller.house.floors.expand((f) => f.devices)) {
      hub.dropDevice(device.id);
    }
    hub.setStatus(status);
    await pumpPanel(tester, controller, hubLabel: 'HUB');
  }

  goldenTest('ground floor selected', (tester) async {
    await pumpPanel(tester, fakeHubRig().$1);

    await expectLater(find.byType(PanelApp),
        matchesGoldenFile('goldens/ground_floor.png'));
  });

  goldenTest('upstairs selected', (tester) async {
    final (controller, _) = fakeHubRig();
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
    await pumpPanel(tester, fakeHubRig().$1);

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
    await pumpHubFailure(tester, HubStatus.retrying);

    await expectLater(find.byType(PanelApp),
        matchesGoldenFile('goldens/hub_offline.png'));
  });

  /// The same wall, one word different — and the difference is everything:
  /// the Hub above comes back on its own, this one never does until someone
  /// mints a new token. In real life it happens about once a decade, which
  /// is exactly why nobody would ever stage it by hand.
  goldenTest('hub gave up: token rejected', (tester) async {
    await pumpHubFailure(tester, HubStatus.gaveUp);

    await expectLater(find.byType(PanelApp),
        matchesGoldenFile('goldens/hub_gave_up.png'));
  });
}
