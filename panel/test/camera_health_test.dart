import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/ui/video/camera_health.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/stream_director.dart';

import 'fixtures.dart';
import 'support/fake_go2rtc.dart';
import 'test_house.dart';

/// Camera Health off the Hub seam (phase-8): each camera Device's `entity:`
/// is the Hub's port-322 daemon probe, and this adapter turns its folded
/// state into the three-valued verdict the Stream Director gates on.
void main() {
  test('the probe drives the verdict: on → reachable, off → unreachable, '
      'a word → unknown', () async {
    final (controller, hub) = fakeHubRig();
    final health = HubCameraHealth(controller: controller);
    addTearDown(health.dispose);
    final verdict = health.reachableOf('cam-garage');

    // FakeHub seeds cameras with the kind seed ('Live') — a word, not a
    // verdict, and a word may not gate a dial.
    expect(verdict.value, Reachability.unknown);

    hub.pushState(StatusState('cam-garage', 'on'));
    await pumpEventQueue();
    expect(verdict.value, Reachability.reachable);

    hub.pushState(StatusState('cam-garage', 'off'));
    await pumpEventQueue();
    expect(verdict.value, Reachability.unreachable);

    // The probe entity itself going unavailable is the Hub seam's absence —
    // nobody knows, so nothing is gated (the dev Hub, permanently).
    hub.dropDevice('cam-garage');
    await pumpEventQueue();
    expect(verdict.value, Reachability.unknown);
  });

  test('one listenable per id, stable across calls — the Director removes '
      'listeners by identity', () {
    final (controller, _) = fakeHubRig();
    final health = HubCameraHealth(controller: controller);
    addTearDown(health.dispose);
    expect(
      identical(health.reachableOf('cam-garage'),
          health.reachableOf('cam-garage')),
      isTrue,
    );
  });

  test('the doorbell is never probed: its entity is the ding event, and a '
      'resting bell must not read as an unreachable camera', () async {
    final (controller, hub) = fakeHubRig();
    final health = HubCameraHealth(controller: controller);
    addTearDown(health.dispose);
    final verdict = health.reachableOf('doorbell');
    hub.pushState(StatusState('doorbell', 'off'));
    await pumpEventQueue();
    expect(verdict.value, Reachability.unknown,
        reason: 'a doorbell integration reporting in the binary word shape '
            'would sit at off all day — that is a bell at rest, not a '
            'camera off the air');
  });

  test('an id that is no video Device is permanently unknown', () async {
    final (controller, hub) = fakeHubRig();
    final health = HubCameraHealth(controller: controller);
    addTearDown(health.dispose);
    final verdict = health.reachableOf('light-family');
    expect(verdict.value, Reachability.unknown);
    hub.pushState(StatusState('light-family', 'on'));
    await pumpEventQueue();
    expect(verdict.value, Reachability.unknown,
        reason: 'a light is not a camera, whatever its entity reports');
  });

  group('dial outcomes — positive evidence only (ADR-0013)', () {
    test('a failed dial never overrules the probe, whatever it says', () async {
      final (controller, hub) = fakeHubRig();
      final health = HubCameraHealth(controller: controller);
      addTearDown(health.dispose);
      final verdict = health.reachableOf('cam-garage');

      health.dialOutcome('cam-garage', connected: false);
      expect(verdict.value, Reachability.unknown);

      hub.pushState(StatusState('cam-garage', 'on'));
      await pumpEventQueue();
      health.dialOutcome('cam-garage', connected: false);
      expect(verdict.value, Reachability.reachable,
          reason: 'one bad dial must never blank a tile the probe vouches '
              'for — negative authority is the probe\'s alone');

      hub.pushState(StatusState('cam-garage', 'off'));
      await pumpEventQueue();
      health.dialOutcome('cam-garage', connected: false);
      expect(verdict.value, Reachability.unreachable);
    });

    test('a failed dial takes back the word a success gave — the verdict '
        'returns to the probe\'s own reading, never below it', () async {
      final (controller, hub) = fakeHubRig();
      final health = HubCameraHealth(controller: controller);
      addTearDown(health.dispose);
      final verdict = health.reachableOf('cam-garage');

      hub.pushState(StatusState('cam-garage', 'off'));
      await pumpEventQueue();
      health.dialOutcome('cam-garage', connected: true);
      expect(verdict.value, Reachability.reachable);

      // The camera died again before the probe ever saw it up: 'off'→'off'
      // emits nothing, so without this withdrawal the evidence would pin
      // `reachable` forever and the grab loop would work a dead daemon
      // indefinitely (found in review, 2026-08-28).
      health.dialOutcome('cam-garage', connected: false);
      expect(verdict.value, Reachability.unreachable,
          reason: 'the probe\'s reading, restored — not new negative '
              'evidence of the dial\'s own');

      // And withdrawn is withdrawn: the next unrelated push changes nothing.
      hub.pushState(StatusState('light-family', 'on'));
      await pumpEventQueue();
      expect(verdict.value, Reachability.unreachable);
    });

    test('an outcome landing before anyone asked for the verdict still '
        'lands — the listenable is minted on first mention, either way', () {
      final (controller, _) = fakeHubRig();
      final health = HubCameraHealth(controller: controller);
      addTearDown(health.dispose);
      health.dialOutcome('cam-garage', connected: true);
      expect(health.reachableOf('cam-garage').value, Reachability.reachable);
    });

    test('evidence held over an unknown probe yields to the probe\'s first '
        'real reading', () async {
      final (controller, hub) = fakeHubRig();
      final health = HubCameraHealth(controller: controller);
      addTearDown(health.dispose);
      final verdict = health.reachableOf('cam-garage');
      health.dialOutcome('cam-garage', connected: true);
      expect(verdict.value, Reachability.reachable,
          reason: 'the dev Hub has no probes — outcomes are its only input');
      hub.pushState(StatusState('cam-garage', 'off'));
      await pumpEventQueue();
      expect(verdict.value, Reachability.unreachable,
          reason: 'a first real reading is the probe speaking');
    });

    test('a successful dial marks the camera reachable now, and the Hub\'s '
        'unrelated traffic cannot re-park it — only a NEW probe reading '
        'regains authority', () async {
      final (controller, hub) = fakeHubRig();
      final health = HubCameraHealth(controller: controller);
      addTearDown(health.dispose);
      final verdict = health.reachableOf('cam-garage');

      // The stale-probe window: the daemon restarted, the once-a-minute
      // probe has not noticed, and a dial just delivered frames.
      hub.pushState(StatusState('cam-garage', 'off'));
      await pumpEventQueue();
      expect(verdict.value, Reachability.unreachable);
      health.dialOutcome('cam-garage', connected: true);
      expect(verdict.value, Reachability.reachable);

      // A thermostat drifting a tenth of a degree refreshes every verdict;
      // the reading the success outranked does not get to come back on it.
      hub.pushState(StatusState('light-family', 'on'));
      await pumpEventQueue();
      expect(verdict.value, Reachability.reachable);

      // The probe speaking again — a new reading — is the evidence's whole
      // lifetime: no clock, no decay rules; the probe is its own decay.
      hub.pushState(StatusState('cam-garage', 'on'));
      await pumpEventQueue();
      expect(verdict.value, Reachability.reachable);
      hub.pushState(StatusState('cam-garage', 'off'));
      await pumpEventQueue();
      expect(verdict.value, Reachability.unreachable,
          reason: 'a fresh off is fresh negative evidence, applied at once');
    });

    test('an outcome for a Device that is no probed camera is dropped — the '
        'popup role reports every dial, the doorbell\'s included', () {
      final (controller, _) = fakeHubRig();
      final health = HubCameraHealth(controller: controller);
      addTearDown(health.dispose);
      health.dialOutcome('doorbell', connected: true);
      expect(health.reachableOf('doorbell').value, Reachability.unknown);
    });

    test('end to end: a popup dial success recovers the tile the stale '
        'probe parked — the recovery rides the flip, not the next probe',
        () async {
      final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'cam-garage', 'garage',
            substream: 'garage-sub'),
      );
      final health = HubCameraHealth(controller: controller);
      addTearDown(health.dispose);
      final go2rtc = FakeGo2rtc();
      final director = StreamDirector(
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        health: health,
      );
      addTearDown(director.dispose);
      final garage = controller.house.floors
          .expand((f) => f.devices)
          .firstWhere((d) => d.id == 'cam-garage');

      hub.pushState(StatusState('cam-garage', 'off'));
      await pumpEventQueue();
      final tile = director.attach(garage, role: FeedRole.tile);
      expect(tile.phase.value, FeedPhase.offline,
          reason: 'the gated role believes the probe');
      expect(go2rtc.opened, isEmpty);

      // Somebody taps the pin: the popup role is health-blind, dials the
      // main stream, and the picture arrives.
      final popup = director.attach(garage, role: FeedRole.popup);
      expect(go2rtc.opened.map((s) => s.name), ['garage']);
      go2rtc.opened.last.plays();

      // The success reported, the verdict flipped, and the parked tile's
      // recovery dial went out on the flip — without waiting the probe out.
      expect(go2rtc.opened.map((s) => s.name), ['garage', 'garage-sub']);
      expect(tile.phase.value, FeedPhase.connecting);

      popup.release();
      tile.release();
    });
  });
}
