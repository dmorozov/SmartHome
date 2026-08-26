import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/ui/video/camera_health.dart';
import 'package:panel/ui/video/stream_director.dart';

import 'fixtures.dart';

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

  test('dial outcomes are accepted without effect — the probe is the '
      'primary adapter and outcomes need their own decay rules first', () {
    final (controller, _) = fakeHubRig();
    final health = HubCameraHealth(controller: controller);
    addTearDown(health.dispose);
    health.dialOutcome('cam-garage', connected: false);
    expect(health.reachableOf('cam-garage').value, Reachability.unknown);
  });
}
