import 'package:web_socket_channel/web_socket_channel.dart';

import 'data/bindings_parser.dart';
import 'data/fake_hub.dart';
import 'data/ha_hub.dart';
import 'data/house_loader.dart';
import 'data/hub_client.dart';
import 'diagnostics/log.dart';
import 'diagnostics/url_redaction.dart';
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
/// token itself (log.dart: **Never log a secret**) — and [hubUrl] cut to its
/// address by [urlForLog], because a Hub behind a reverse proxy is a Hub whose
/// URL can carry basic-auth credentials. The house's name is withheld where it
/// could be hiding one; see the field's own comment.
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
      // The only one of these fields that is author text, and the only line
      // in this list emitted on a *healthy* boot — measured publishing a
      // password on every good start, because `name:` is house.yaml's first
      // line and a paste that overwrites it is silent:
      //
      //     I house.loaded name=rtsp://admin:hunter2@192.168.68.44/live …
      //
      // Withheld rather than positioned, unlike every message in
      // `house_loader.dart`: there is exactly one house, so `name=` identifies
      // nothing — "which house.yaml did this Panel load" is already answered
      // by the four counts beside it, and a position would be "the 1st house".
      // Rejected: dropping the field, which costs the everyday line the one
      // word that catches a Panel booted against the wrong plan; and redacting
      // `House.name` itself, which is rendered on the wall (`main.dart`) where
      // the household can already see it — it is the journald copy that
      // travels off the box, so this is where the rule belongs.
      //
      // What `isQuiet` does *not* catch here, so this comment does not claim
      // more than the code: a name that is itself a bare token
      // (`sk_live_51H8hunter2abcdefghij`) has the shape of a name and prints.
      // That needs the secret to have been typed into `name:` deliberately
      // rather than pasted over it, which is a different accident; see
      // `isQuiet`'s own docstring, where the decision is argued.
      'name': isQuiet(house.name) ? house.name : 'withheld',
      'floors': house.floors.length,
      'rooms': house.floors.fold<int>(0, (n, f) => n + f.rooms.length),
      'devices': devices.length,
      // Devices with no `entity:` can never show state — worth knowing at a
      // glance, without hunting through bindings.yaml.
      'bound': devices.where((d) => d.entityId != null).length,
      // Same argument as `bound`, for the other half of a Device's wiring:
      // which pins can show a live view at all. It is also the only place a
      // copy-pasted `stream:` becomes visible — two Devices are allowed to
      // watch one camera, so nothing refuses it, and this count against
      // `devices` is what makes an accidental one countable.
      'streams': devices.where((d) => d.streamName != null).length,
    });
    return house;
  } catch (error, stack) {
    // A malformed House Plan is fatal, and on the kiosk nobody is standing
    // in front of the red screen. Leave one greppable line on the way out.
    //
    // This line is the one artefact a black-screen boot leaves in journald,
    // which makes it the highest-value credential channel in the Panel — and
    // it publishes whatever `error.toString()` renders. What keeps that safe
    // is not a filter here: it is that every exception the House Plan
    // pipeline can raise is built to be logged. `bindings_parser.dart`
    // withholds values and hand-typed keys; `house_loader.dart` withholds
    // house.yaml's the same way, through the same `isQuiet` (it did not, when
    // this comment was first written — thirteen semantic complaints printed
    // their room ids, floor ids, Device keys and kinds raw, and a mis-paste
    // reached journald through the most ordinary one of them); and `readYaml`
    // is what stops the *yaml package's* own exception arriving — a
    // `SourceSpanFormatException` reproduces the source line it choked on,
    // with a caret under it, and a mis-paste puts a camera URL on that line.
    //
    // Two residuals, stated so the claim above is not read wider than it is.
    // A raw Dart cast failure (`house.yaml` missing `floors:`, a Placement
    // that is a scalar) arrives as a `_TypeError`, which names types and no
    // value — safe, but no help either. And `error.toString()` is only ever as
    // careful as the exception; anything thrown from outside this pipeline is
    // outside the claim.
    //
    // Rejected: sanitising here instead. It would leave the exception object
    // itself carrying the source text for the rethrow and for anyone else who
    // logs it, and `loadHouse` has callers that are not this one.
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
  //
  // And the same now goes for the field beside it, which for four rounds was
  // the counter-example on its own line. `HA_URL` was printed whole here —
  // `url=http://admin:hunter2@ha.local:8123` — on every healthy `HUB=ha`
  // boot, while `GO2RTC_URL` one field over in the same `HubConfig` went
  // through a build-it-up-from-scheme/host/port rule. Home Assistant behind a
  // reverse proxy with basic auth is the ordinary way that value acquires a
  // credential, and `appliance/ansible/roles/kiosk/templates/cage@.service.j2`
  // puts both settings under one `# NON-SECRETS ONLY` comment.
  //
  // This is the line that characterises the operator's value — `path=set` for
  // a mount point, `auth=set` for a credential — because it is the only one
  // that sees it before `HaHubClient.webSocketUrl` rewrites the path. The
  // connect/connected lines print the address alone.
  Log.info('hub', 'configured', {
    ...urlForLog(url),
    'token': token.isEmpty ? 'absent' : 'set',
  });
  if (token.isEmpty) {
    throw ArgumentError('HUB=ha needs HA_TOKEN=<long-lived token> — in the '
        'environment, or --dart-define for web builds; keep it out of the '
        'repo (hub/dev/token)');
  }
  return HaHubClient(
    house: house,
    url: HaHubClient.webSocketUrl(url),
    token: token,
    connect: connect,
  );
}
