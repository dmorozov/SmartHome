import 'package:web_socket_channel/web_socket_channel.dart';

import 'data/fake_hub.dart';
import 'data/ha_hub.dart';
import 'data/house_loader.dart';
import 'data/hub_client.dart';
import 'diagnostics/log.dart';
import 'domain/house.dart';
import 'ui/hub_controller.dart';

/// The ready-to-run Panel: everything `main()` needs once it has read the
/// environment, and everything a boot test needs to assert on.
class PanelBoot {
  PanelBoot({
    required this.hub,
    required this.controller,
    required this.hubLabel,
  });

  /// The chosen Hub adapter. `main()` never touches it — the controller owns
  /// its lifecycle — but which one was chosen is the boot decision worth
  /// asserting.
  final HubClient hub;

  final HubController controller;

  /// The header badge's base text: `FAKE HUB` for the in-memory Hub, `HUB`
  /// for the real one. It travels as data because the widget tree must not
  /// know which Hub the build was compiled against — a rule that used to be
  /// broken, which is why the Hub-down goldens rendered a fake-build badge
  /// for a scene that only happens in production.
  final String hubLabel;

  House get house => controller.house;
}

/// Boots the Panel from plain data: the House Plan's two YAML texts
/// (ADR-0004, reshaped by ADR-0005 — generated `house.yaml` joined with
/// hand-maintained `bindings.yaml`) and the Hub configuration as ordinary
/// strings. Reads no files and no environment, so every boot outcome is
/// reachable from a test.
///
/// Fails in exactly three ways, each leaving the greppable line the
/// appliance's journald is the only witness to (ADR-0001 — nobody is
/// standing in front of the screen):
///
/// - a malformed House Plan logs fatal `house.invalid` and rethrows the
///   loader's [FormatException];
/// - an unknown [hubKind] throws [ArgumentError] naming the choices;
/// - `ha` with an empty [hubToken] logs `hub.configured token=absent` and
///   *then* throws [ArgumentError] — the log first, deliberately: it is the
///   breadcrumb that explains the crash that follows.
///
/// On the way up it logs `house.loaded` (name and floor/room/device/bound
/// counts) and, for `ha`, `hub.configured` with `token=set` — never the
/// token itself (log.dart: **Never log a secret**).
///
/// [haConnect] is a test-only pass-through to [HaHubClient]'s existing
/// socket-injection seam, so a boot test can choose the real adapter without
/// dialling anything. Production callers pass nothing.
PanelBoot bootPanel({
  required String hubKind,
  required String hubUrl,
  required String hubToken,
  required String houseYaml,
  required String bindingsYaml,
  WebSocketChannel Function(Uri)? haConnect,
}) {
  final house = _loadHouse(houseYaml: houseYaml, bindingsYaml: bindingsYaml);
  final hub = _hub(house,
      kind: hubKind, url: hubUrl, token: hubToken, connect: haConnect);
  return PanelBoot(
    hub: hub,
    controller: HubController(house: house, hub: hub),
    // After the kind is known good: an unknown kind must throw, not get a
    // label.
    hubLabel: hubKind == 'fake' ? 'FAKE HUB' : 'HUB',
  );
}

House _loadHouse({required String houseYaml, required String bindingsYaml}) {
  try {
    final house = loadHouse(houseYaml: houseYaml, bindingsYaml: bindingsYaml);
    final devices = [for (final floor in house.floors) ...floor.devices];
    Log.info('house', 'loaded', {
      'name': house.name,
      'floors': house.floors.length,
      'rooms': house.floors.fold<int>(0, (n, f) => n + f.rooms.length),
      'devices': devices.length,
      // Devices with no `entity:` can never show state — worth knowing at a
      // glance, without hunting through bindings.yaml.
      'bound': devices.where((d) => d.entityId != null).length,
    });
    return house;
  } catch (error, stack) {
    // A malformed House Plan is fatal, and on the kiosk nobody is standing
    // in front of the red screen. Leave one greppable line on the way out.
    Log.error('house', 'invalid', error: error, stack: stack);
    rethrow;
  }
}

HubClient _hub(
  House house, {
  required String kind,
  required String url,
  required String token,
  required WebSocketChannel Function(Uri)? connect,
}) {
  if (kind == 'fake') return FakeHub(house);
  if (kind != 'ha') {
    throw ArgumentError('unknown HUB "$kind" (fake | ha)');
  }
  // `set`, never the token itself: these lines end up in logs.
  Log.info('hub', 'configured',
      {'url': url, 'token': token.isEmpty ? 'absent' : 'set'});
  if (token.isEmpty) {
    throw ArgumentError('HUB=ha needs --dart-define=HA_TOKEN=<long-lived '
        'token>; keep it out of the repo (hub/dev/token)');
  }
  return HaHubClient(
    house: house,
    url: HaHubClient.webSocketUrl(url),
    token: token,
    connect: connect,
  );
}
