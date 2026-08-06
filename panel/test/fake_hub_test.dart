import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/domain/device_state.dart';

import 'test_house.dart';

/// What the fake Hub does beyond the shared HubClient contract
/// (hub_contract_test.dart): the seeding script, and the one behaviour only
/// it can have — inventing the state a real Hub would have known.
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
    expect(await emitted, id);
    expect((hub.states[id] as SwitchState).on, !before);
    hub.dispose();
  });

  test('toggling a light with unknown state seeds it on', () async {
    final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    hub.dropDevice('light-hall');
    expect(hub.states.containsKey('light-hall'), isFalse);

    final emitted = hub.stateChanges.first;
    await hub.toggle('light-hall');

    // The real Hub knows the Device even when the Panel's knowledge has
    // lapsed, so the fake models the command landing rather than vanishing
    // — otherwise a tap on an unknown-state pin would be untestable.
    expect(await emitted, 'light-hall');
    expect((hub.states['light-hall'] as SwitchState).on, isTrue);
    hub.dispose();
  });

  test('setThermostatTarget moves only the target — the reading and the '
      'unit are the room\'s and the Hub\'s to change', () async {
    final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    const id = 'thermostat';
    hub.pushState(const ThermostatState(id,
        current: 21.4, target: 21.0, unit: TemperatureUnit.celsius));

    final emitted = hub.stateChanges.first;
    await hub.setThermostatTarget(id, 22.5);

    expect(await emitted, id);
    final state = hub.states[id] as ThermostatState;
    expect(state.target, 22.5);
    expect(state.current, 21.4);
    expect(state.unit, TemperatureUnit.celsius);
    hub.dispose();
  });

  test('a setpoint commanded at an unknown-state thermostat lands on the '
      'seed', () async {
    final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    const id = 'thermostat';
    hub.dropDevice(id);

    final emitted = hub.stateChanges.first;
    await hub.setThermostatTarget(id, 19.5);

    // Same argument as the unknown-state toggle above: the command lands.
    expect(await emitted, id);
    final state = hub.states[id] as ThermostatState;
    expect(state.target, 19.5);
    expect(state.current, 21.4); // the vocabulary seed's reading
    hub.dispose();
  });
}
