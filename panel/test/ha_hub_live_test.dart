// Talks to a REAL Home Assistant — the development Hub (hub/dev/).
// Skipped unless a token is supplied, so `flutter test` stays hermetic:
//
//   cd panel && flutter test test/ha_hub_live_test.dart \
//       --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/domain/device_state.dart';

import 'test_house.dart';

const _token = String.fromEnvironment('HA_TOKEN');
const _url = String.fromEnvironment('HA_URL',
    defaultValue: 'http://localhost:8123');

void main() {
  test('reads live state from the development Hub', () async {
    final hub = HaHubClient(
      house: loadTestHouse(),
      url: HaHubClient.webSocketUrl(_url),
      token: _token,
    );
    addTearDown(hub.dispose);

    // Give the handshake + snapshot a moment.
    for (var i = 0; i < 100 && hub.states.length < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(hub.status.value, HubStatus.up, reason: 'never authenticated');
    // The generated stand-ins seed these exact values (hub/dev/README.md).
    expect((hub.states['energy-monitor'] as PowerState).watts, 812);
    final thermostat = hub.states['thermostat'] as ThermostatState;
    // closeTo, not equals: the Hub reports at the entity's own
    // precision, which is a property of the thermostat, not of us.
    expect(thermostat.currentC, closeTo(21.4, 0.05));
    expect(thermostat.targetC, 21.0);
    expect((hub.states['washer'] as StatusState).status, 'Idle');
    expect((hub.states['light-hall'] as SwitchState).on, isFalse);

    // Round-trip a command: toggle, and wait for the Hub to tell us it
    // happened via the event subscription.
    await hub.toggle('light-hall');
    for (var i = 0; i < 50; i++) {
      if ((hub.states['light-hall'] as SwitchState).on) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect((hub.states['light-hall'] as SwitchState).on, isTrue,
        reason: 'toggle did not come back through state_changed');

    await hub.toggle('light-hall'); // leave it as we found it
  }, skip: _token.isEmpty ? 'set --dart-define=HA_TOKEN to run' : false);
}
