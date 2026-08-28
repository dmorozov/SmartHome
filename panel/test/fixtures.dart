import 'package:flutter/widgets.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/main.dart';
import 'package:panel/ui/cameras/camera_order.dart';
import 'package:panel/ui/hub_controller.dart';
import 'package:panel/ui/audio/talk.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/snapshot.dart';
import 'package:panel/ui/video/stream_director.dart';

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
/// A test about camera video states the wiring itself, here, rather than
/// inheriting whatever the shipped `bindings.yaml` happens to say — pair
/// this with [houseWithoutCameraStreams] so the scene is stated in full.
///
/// **This used to be unnecessary and the reason it became necessary is the
/// point.** Until 2026-08-15 the shipped file named a stream on no camera
/// at all: none of them had a go2rtc feed, and a `stream:` pointing at
/// nothing would have been a confident wrong answer in the one file a human
/// hand-edits. (The doorbell was the exception from 2026-08-05 — real
/// hardware, a real `ring_doorbell` stream, a snapshot face.) Then the Wyze
/// fleet came up, `cam-garage` and `cam-living` became real cameras with
/// real streams, and ten Cameras-view cases that had quietly been asserting
/// "nothing here is wired" started failing on a change that was nothing to
/// do with them. A test that reads the house's wiring out of the shipped
/// assets breaks every time the house gains a camera, which is a thing the
/// house is supposed to do.
///
House houseWithStream(House house, String deviceId, String streamName,
    {String? snapshotEntity, String? substream, bool clearSnapshot = false}) {
  Device retarget(Device device) => device.id == deviceId
      ? Device(
          id: device.id,
          name: device.name,
          kind: device.kind,
          connectivity: device.connectivity,
          position: device.position,
          entityId: device.entityId,
          streamName: streamName,
          substream: substream,
          // `??` keeps the device's own binding by default — the doorbell
          // scenes rely on it. [clearSnapshot] is for the one scene that
          // needs the opposite: a device wired for video with NO snapshot
          // face at all, which `??` cannot express.
          snapshotEntityId: clearSnapshot
              ? null
              : (snapshotEntity ?? device.snapshotEntityId),
        )
      : device;
  return _rebuilt(house, retarget);
}

/// [house] with every *camera*'s stream name removed, the doorbell's kept.
///
/// The blank sheet a Cameras-view test starts from, so that what it is
/// about — which sessions exist when, and that closing the view closes all
/// of them — is decided by the case and not by how many Wyze units the
/// family happens to own this month. Layer the wiring back on with
/// [houseWithStream].
///
/// The doorbell is deliberately untouched: several cases assert that it
/// starts *off* despite having a stream (#177014 — an open Ring session
/// suppresses dings), and that is a statement about a Device that has one.
House houseWithoutCameraStreams(House house) => _rebuilt(
      house,
      (device) => device.kind == DeviceKind.camera && device.streamName != null
          ? Device(
              id: device.id,
              name: device.name,
              kind: device.kind,
              connectivity: device.connectivity,
              position: device.position,
              entityId: device.entityId,
              snapshotEntityId: device.snapshotEntityId,
            )
          : device,
    );

/// Rebuilds rather than mutates: [Device] is immutable and [House] is a tree
/// of `const` values, which is exactly the property that makes a golden
/// reproducible.
House _rebuilt(House house, Device Function(Device) retarget) {
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
  Go2rtcStillsConfig stills = const Go2rtcStillsConfig(),
  TalkConfig talk = const TalkConfig(),
  CameraOrderStore? order,
  StreamDirector? director,
}) =>
    PanelApp(
        controller: controller,
        hubLabel: hubLabel,
        video: video,
        snapshots: snapshots,
        stills: stills,
        talk: talk,
        // A store with no writer: it remembers an arrangement for as long as
        // the scene is up — which is what a case about reopening the view
        // needs — and touches no platform channel, which is what every other
        // case needs.
        order: order ?? CameraOrderStore(),
        director: director);
