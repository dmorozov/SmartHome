import 'package:flutter/widgets.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/main.dart';
import 'package:panel/ui/hub_controller.dart';

import 'test_house.dart';

/// The standard rig for widget and golden tests: the shipped House Plan, a
/// drift-frozen fake hub, and the controller over both.
///
/// Assembled at the [HubController] seam rather than through `bootPanel` —
/// deliberately. Boot answers "which Hub did this build choose", which is
/// not a question these tests ask; they need the opposite, a Hub they
/// choose and then drive. Routing them through boot would mean growing it
/// adapter-injection and drift knobs, which is how a deep module turns
/// shallow.
(HubController, FakeHub) fakeHubRig() {
  final house = loadTestHouse();
  // Zero drift: readings must not wander between pumps, or a golden would
  // differ from itself.
  final hub = FakeHub(house, driftEvery: Duration.zero);
  return (HubController(house: house, hub: hub), hub);
}

/// The Panel as a test pumps it. The label defaults to the fake hub's,
/// which is what a dev build shows — a fact about fixtures, not about
/// [PanelApp], which is why it does not default in the widget itself. A
/// scene about the production Panel passes `hubLabel: 'HUB'`.
Widget panelApp(HubController controller, {String hubLabel = 'FAKE HUB'}) =>
    PanelApp(controller: controller, hubLabel: hubLabel);
