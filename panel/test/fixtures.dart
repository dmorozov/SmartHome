import 'package:flutter/widgets.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/main.dart';
import 'package:panel/ui/hub_controller.dart';
import 'package:panel/ui/audio/talk.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/snapshot.dart';

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
///
/// [house] overrides the shipped Plan for the one kind of scene the assets
/// cannot stage — see [houseWithStream].
(HubController, FakeHub) fakeHubRig({House? house}) {
  final plan = house ?? loadTestHouse();
  // Zero drift: readings must not wander between pumps, or a golden would
  // differ from itself.
  final hub = FakeHub(plan, driftEvery: Duration.zero);
  return (HubController(house: plan, hub: hub), hub);
}

/// [house] with one Device given a go2rtc stream name.
///
/// The shipped `bindings.yaml` names no stream on any placeholder *camera*:
/// no go2rtc feed exists for them, and a `stream:` pointing at nothing
/// would be a confident wrong answer in the one file a human hand-edits.
/// (The doorbell is the exception since 2026-08-05 — it is real hardware
/// with a real `ring_doorbell` stream and a snapshot face.) So a test about
/// camera video states the fact itself, here, rather than teaching the
/// assets something for a test's benefit.
///
/// Rebuilds the House rather than mutating it: [Device] is immutable and
/// [House] is a tree of `const` values, which is exactly the property that
/// makes a golden reproducible.
House houseWithStream(House house, String deviceId, String streamName,
    {String? snapshotEntity}) {
  Device retarget(Device device) => device.id == deviceId
      ? Device(
          id: device.id,
          name: device.name,
          kind: device.kind,
          connectivity: device.connectivity,
          position: device.position,
          entityId: device.entityId,
          streamName: streamName,
          snapshotEntityId: snapshotEntity ?? device.snapshotEntityId,
        )
      : device;
  return House(
    name: house.name,
    floors: [
      for (final floor in house.floors)
        Floor(
          id: floor.id,
          name: floor.name,
          level: floor.level,
          walls: floor.walls,
          rooms: [
            for (final room in floor.rooms)
              Room(
                id: room.id,
                name: room.name,
                footprint: room.footprint,
                devices: room.devices.map(retarget).toList(),
              ),
          ],
        ),
    ],
  );
}

/// The Panel as a test pumps it. The label defaults to the fake hub's,
/// which is what a dev build shows — a fact about fixtures, not about
/// [PanelApp], which is why it does not default in the widget itself. A
/// scene about the production Panel passes `hubLabel: 'HUB'`.
///
/// [video] defaults to unconfigured for the same reason and one more: it is
/// what every existing scene — goldens included — was baked with, so a test
/// that says nothing about video gets the Popup body the Panel has always
/// drawn.
Widget panelApp(
  HubController controller, {
  String hubLabel = 'FAKE HUB',
  VideoConfig video = const VideoConfig(),
  SnapshotConfig snapshots = const SnapshotConfig(),
  TalkConfig talk = const TalkConfig(),
}) =>
    PanelApp(
        controller: controller,
        hubLabel: hubLabel,
        video: video,
        snapshots: snapshots,
        talk: talk);
