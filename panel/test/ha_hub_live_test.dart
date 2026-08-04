// Talks to a REAL Home Assistant — the development Hub (hub/dev/), or the
// appliance Hub. It authenticates, and it TOGGLES A REAL LIGHT, so running it
// has to be something you asked for on purpose:
//
//   cd panel && flutter test test/ha_hub_live_test.dart \
//       --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"
//
//   PANEL_LIVE_HUB=1 HA_URL=http://192.168.68.81:8123 \
//       HA_TOKEN="$(cat ../hub/token)" flutter test test/ha_hub_live_test.dart
//
// The second form is what phase 1 wants: pointing this at a Hub that moved
// must not mean recompiling the test.
//
// PANEL_LIVE_HUB is the opt-in for the environment path, and it is the reason
// `flutter test` is still hermetic. Settings resolve environment-first
// (config/hub_config.dart), so gating on HA_TOKEN alone would let a token
// that merely happens to be exported in someone's shell — an ordinary thing
// to have — reach out to a live house and flip a switch. A dedicated name
// nobody exports for another reason cannot arrive by accident. A
// `--dart-define` is already per-invocation, so it needs no second gate.
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/config/hub_config.dart';
import 'package:panel/config/runtime_env.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/domain/device_vocabulary.dart';

import 'test_house.dart';

const String? _buildToken =
    bool.hasEnvironment('HA_TOKEN') ? String.fromEnvironment('HA_TOKEN') : null;
const String? _buildUrl =
    bool.hasEnvironment('HA_URL') ? String.fromEnvironment('HA_URL') : null;

final _config = resolveHubConfig(
  environment: runtimeEnvironment(),
  buildUrl: _buildUrl,
  buildToken: _buildToken,
);
final _token = _config.token;
final _url = _config.url;

/// Deliberate, per-invocation intent — never something the ambient shell can
/// supply on its own.
final _optedIn = (_buildToken ?? '').isNotEmpty ||
    (runtimeEnvironment()['PANEL_LIVE_HUB'] ?? '').isNotEmpty;

String? get _skipReason {
  if (!_optedIn) {
    return 'live Hub test: pass --dart-define=HA_TOKEN, or set '
        'PANEL_LIVE_HUB=1 with HA_TOKEN in the environment';
  }
  if (_token.isEmpty) return 'PANEL_LIVE_HUB is set but HA_TOKEN is not';
  return null;
}

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
    // Asserted against the Device vocabulary, not against copies of its
    // numbers: the stand-ins were generated from this same table, so what
    // is really being checked is that a real Home Assistant round-trips
    // them unchanged — and changing a seed can no longer leave this test
    // asserting a value nothing produces any more.
    final watts = specOf(DeviceKind.energyMonitor).seed('x') as PowerState;
    expect((hub.states['energy-monitor'] as PowerState).watts, watts.watts);

    final seed = specOf(DeviceKind.thermostat).seed('x') as ThermostatState;
    final thermostat = hub.states['thermostat'] as ThermostatState;
    // closeTo, not equals: the Hub reports at the entity's own
    // precision, which is a property of the thermostat, not of us.
    expect(thermostat.current, closeTo(seed.current, 0.05));
    expect(thermostat.target, seed.target);
    // Not a specific unit — that is the Hub owner's setting, and this test
    // is pointed at whichever Hub the invoker chose. What has to be true of
    // any of them is that `get_config` was asked and answered, because a
    // reading with no unit is a reading the wall renders bare.
    expect(thermostat.unit, isNotNull,
        reason: 'get_config never landed — the Panel does not know whether '
            'this Hub speaks °C or °F');

    final washer = specOf(DeviceKind.washer).seed('x') as StatusState;
    expect((hub.states['washer'] as StatusState).status, washer.status);
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
  }, skip: _skipReason ?? false);
}
