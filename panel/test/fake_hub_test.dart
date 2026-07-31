import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/domain/device_state.dart';

import 'test_house.dart';

void main() {
  test('seeds a state for every device in the demo house', () {
    final house = loadTestHouse();
    final hub = FakeHub(house, driftEvery: Duration.zero);
    final deviceIds =
        house.floors.expand((f) => f.devices).map((d) => d.id).toSet();
    expect(hub.states.keys.toSet(), deviceIds);
    hub.dispose();
  });

  test('toggle flips a switch and emits the change', () async {
    final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    const id = 'light-hall';
    final before = (hub.states[id] as SwitchState).on;
    final emitted = hub.stateChanges.first;
    await hub.toggle(id);
    final change = await emitted as SwitchState;
    expect(change.deviceId, id);
    expect(change.on, !before);
    expect((hub.states[id] as SwitchState).on, !before);
    hub.dispose();
  });

  test('toggle is a no-op for devices without a binary state', () async {
    final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    final before = hub.states['thermostat'];
    await hub.toggle('thermostat');
    expect(hub.states['thermostat'], same(before));
    hub.dispose();
  });
}
