# One Device-vocabulary table + one shared devices.yaml parser

Deepen the Device-kind vocabulary — devices.yaml slug, state-shape family, stand-in seed — into one pure-Dart domain module, and collapse the two divergent devices.yaml parsers into one shared pure-Dart parser, so adding a new kind of hardware costs one vocabulary row plus one icon arm instead of six coordinated edits.

Status: proposed · Strength: Worth exploring · Written against commit 105610c (2026-08-01) — re-verify line numbers before editing.

---

## 1. Why this refactor

Adding one new kind of hardware is the House Plan's most anticipated recurring change — `devices.yaml` is already staged with Devices for hardware still in boxes, and CONTEXT.md's Retrofit plans (ratgdo, ESPHome reflash) plus the user's DIY/ESPHome comfort make new kinds plausible. Today that change requires coordinated edits at **six** sites that each privately re-encode the kind vocabulary. (The originating review counted five; the adversarial verification pass found a sixth — `HaHubClient._toDeviceState` — which is the one *production-path* copy.)

The six sites, all verified against commit 105610c:

1. **`panel/lib/domain/house.dart:123-138`** — the `DeviceKind` enum, 14 kinds (`light` … `energyMonitor`).
2. **`panel/lib/data/house_loader.dart:96-113`** — the private slug→enum switch `_kind`, 14 arms:
   ```dart
   DeviceKind _kind(String slug, String deviceId) => switch (slug) {
         'light' => DeviceKind.light,
         'outlet' => DeviceKind.outlet,
         ...
         'energy-monitor' => DeviceKind.energyMonitor,
         _ => throw FormatException(
             'devices.yaml: device "$deviceId" has unknown kind "$slug"'),
       };
   ```
3. **`panel/lib/ui/theme.dart:38-53`** — the `deviceIcon(DeviceKind)` switch, 14 arms.
4. **`panel/lib/data/fake_hub.dart:86-103`** — `FakeHub._initialState`, an exhaustive switch seeding plausible state for all 14 kinds (camera and doorbell share an arm) — `PowerState(device.id, watts: 812)` at :93, `ThermostatState(..., currentC: 21.4, targetC: 21.0)`, `StatusState(device.id, 'Idle')`, `'Cycle · 32 min left'`, ….
5. **`panel/lib/data/ha_hub.dart:287-311`** — `HaHubClient._toDeviceState`, a 14-arm switch on `device.kind` that picks which `DeviceState` to parse an entity into. **This is the site the original candidate missed** — the kind→state-family concept exists in code twice more (FakeHub groups kinds implicitly, HaHub groups them explicitly) and in comments in the generator (`Panel: SwitchState/GarageDoorState`).
6. **`panel/tool/gen_dev_entities.dart:25-53`** — three slug-string-keyed seed maps (`_toggleSeed`, `_powerSeed`, `_statusSeed`) plus thermostat constants (:51-53), annotated `Seeds match FakeHub` (:38-39), **plus its own second, weaker devices.yaml parser** (`_readDevices` + `_require`, :225-248 — reads only id/name/kind; no position, no entity, no connectivity, no kind validation).

The second parser exists for a structural reason, not by accident: the generator's header says

```dart
// Pure Dart on purpose (no dart:ui), so `dart run` works without Flutter.
```
(`gen_dev_entities.dart:15`), while `house_loader.dart:1` is `import 'dart:ui';` — and so is `house.dart:1`. The weld is in the domain type itself: `Device.position` is an `Offset`, `Room` uses `Rect`. Geometry types weld Device *parsing* to Flutter, so the tool cannot reuse the loader and must re-parse with less validation.

### The unpoliced copies vs the compiler-policed ones

The verification pass corrected the original hazard claim, and the correction matters for scoping: **three of the six copies are exhaustive switches over the enum** — theme.dart, fake_hub.dart, ha_hub.dart — so a new `DeviceKind` value is a *compile error* there, not silent drift. The genuinely unpoliced sites are:

- the generator's string-keyed seed maps — a new kind only fails when the generator is next *run*, via `_fail`/`exit(1)` (`gen_dev_entities.dart:260-263`, arm at :168-172: `'device "$id" has kind "${device.kind}", which this generator does not know'`). HOUSE-PLAN.md's add-a-Device runbook (§5) never mentions running the generator, so "fails weeks later" is fair;
- the hand-copied `entity:` lines in devices.yaml (see below);
- the two hand-transcribed doc lists.

### Seed triplication — verified in all three files

The stand-in seed values are triplicated *by policy* (`Seeds match FakeHub so the dev Hub looks like the fake one you have been developing against` — gen_dev_entities.dart:38-39). Verified: `812` W, `21.4`/`21.0` °C, `'Idle'`, `'Cycle · 32 min left'` appear in

- `fake_hub.dart:86-103` (`_initialState`),
- `gen_dev_entities.dart:25-53` (the seed maps and thermostat constants),
- `test/ha_hub_live_test.dart:32-38` (assertions against the live development Hub: `expect((hub.states['energy-monitor'] as PowerState).watts, 812)` etc., with the comment `The generated stand-ins seed these exact values (hub/dev/README.md)`).

### The binding emitted as a comment

The Device→entity binding the Panel needs is *computed* by the generator but emitted only as a YAML comment — verified in `hub/dev/ha-config/packages/panel_dev.yaml`:

```yaml
# Device -> entity the Panel binds to:
#   garage-door      input_boolean.garage_door
#   ev-charger       sensor.tesla_wall_connector
...
```

The `entity:` lines in `panel/assets/house/devices.yaml` are hand-copied from that comment (the file's own header says the entities "currently point at the development Hub's generated stand-ins"). After a Device rename, drift surfaces only as a runtime `hub.missing_entities` warning (`ha_hub.dart:229`) — and only when running against a live Hub. Nothing in `flutter test` catches it.

### The docs have already drifted

`panel/HOUSE-PLAN.md:168-173` tells the family:

> **Pick the kind** — one of:
> `light` `outlet` `thermostat` `camera` `doorbell` `oven` `tv` `washer` `dryer` `litter-robot` `feeder` `garage-door` `ev-charger` `energy-monitor`
> (they map 1:1 to `DeviceKind` in `lib/domain/house.dart` — a new kind of hardware means adding it there + an icon in `lib/ui/theme.dart` first).

That under-counts the real edit count — six, not two. And the kind list is hand-transcribed in *two* places: HOUSE-PLAN.md:168-171 and the `devices.yaml:4-6` header (`# kind: light | outlet | thermostat | ...`).

### The deletion test, applied

Every copy is individually load-bearing — delete the loader switch and parsing breaks; delete the generator's seed maps and the dev Hub package breaks — which is precisely the smell: the deletion test cannot be applied to any one site because the same knowledge props up six. The verifier re-ran the deletion test on the *proposed* modules: delete the vocabulary module and slug/family/seed knowledge reappears in loader, FakeHub, HaHub, generator, and tests (5+ callers reabsorb it) — it earns its keep, not a pass-through. Delete the shared parser and two divergent devices.yaml parsers reappear (the tool's already validates less). Both earn their keep.

### Honest scope notes from verification

- The **icon leg is a wash**: `IconData` cannot live in a pure-Dart table, and the exhaustive `deviceIcon` switch in theme.dart is already compiler-policed. Icons stay a separate one-arm edit; this plan does not touch theme.dart.
- **No churn history**: the repo is young (files touched 1-3 times during initial construction), and ADR-0003's planned 10-25 device purchase is mostly *existing* kinds (outlets, switches), which cost one devices.yaml block and zero code. New kinds are plausible (Retrofits, DIY/ESPHome) but unscheduled. The payoff is dev-scaffolding parity, testability of a currently untestable tool, and doc truthfulness — not production correctness. Hence **Worth exploring**, not Strong.
- The proposed binding-drift test **must be scoped**: devices.yaml's header says generated stand-in entity ids get replaced by real ones as hardware integrates ("replace each one with the real entity id as the hardware is integrated"), and ADR-0004 anticipates the same lifecycle (devices.yaml holds "later the Hub entity-id mapping"), so asserting `entity == generator-derived` unconditionally would go red *by design*. See Decision 2.
- **Nothing may ever write devices.yaml** (ADR-0004's single-writer rule): the deepening derives and tests bindings but never writes them. Any variant that auto-writes `entity:` lines must be rejected.

## 2. Context a fresh session needs

### Domain vocabulary (CONTEXT.md — use these terms, and only these)

- **Panel**: "The wall-mounted touchscreen running the custom dollhouse UI." (Avoid: kiosk, dashboard, screen.)
- **Hub**: "The headless smart-home broker (Home Assistant) that owns device state, integrations, and automations. The Panel is its client, never its replacement." (Avoid: server, backend, HA in domain discussion.)
- **Dollhouse**: "The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms."
- **House Plan**: "The Panel-side description of the house's geometry — Floors with their Rooms and Walls, authored by the family. The Dollhouse renders it; the Hub never sees it."
- **Floor**: "One level of the house in the Dollhouse … Floors stack; tapping one expands it."
- **Room**: "A named area on a Floor. Rooms tile their Floor completely … Rooms display aggregate state (lit, occupied) and hold pinned Devices."
- **Wall**: "A boundary segment drawn on the House Plan. Only drawn Walls exist."
- **Device**: "A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse." (Avoid: **entity** — "that is the Hub's internal term".)
- **Local Device** / **Cloud Device** / **Retrofit**: local = no vendor cloud; cloud = grandfathered second-class; Retrofit = hardware added to make a dumb/cloud device Local (ratgdo, ESPHome reflash).

### Design vocabulary (.claude/skills/codebase-design/SKILL.md)

Design **deep modules**: a lot of behaviour behind a small **interface** (everything a caller must know — types, invariants, error modes), placed at a clean **seam** (the location where the interface lives; where behaviour can be altered without editing in place). An **adapter** is a concrete thing satisfying an interface at a seam. **Depth** yields **leverage** for callers (more behaviour per unit of interface learned) and **locality** for maintainers (change concentrates in one place). The **deletion test**: imagine deleting the module — if complexity vanishes it was a pass-through; if it reappears across N callers it was earning its keep. Never say component/service/API/boundary.

### ADR constraints that bind this plan

- **ADR-0004** (House Plan pipeline): "Two files with two lifecycles: `house.yaml` … is **generated and never hand-edited** … `devices.yaml` (id, name, kind, local/cloud, room reference, position in meters, later the Hub entity-id mapping) is **hand-maintained and never touched by the converter**." This plan derives and *tests* bindings but never writes devices.yaml. It also expects stand-in entity ids to be replaced: devices.yaml header — "replace each one with the real entity id as the hardware is integrated."
- **ADR-0002** (Home Assistant headless Hub): "The Hub is a black-box appliance … the Panel is a pure view/command layer." Untouched by this plan; `HaHubClient` remains the adapter at the `HubClient` seam.
- **ADR-0003** (Zigbee/Z2M): the planned 10-25 device purchase is mostly existing kinds — context for why this is Worth exploring, not urgent.
- **ADR-0001** (plain Linux kiosk): no bearing here beyond "Flutter app".

### Current-architecture tour (all paths relative to repo root)

- **`panel/lib/domain/house.dart`** — the House Plan domain: `House` → `Floor` → `Room` → `Device`, plus `Wall`. Deep geometry math (`Room.contains` even-odd point-in-polygon, `Room.bounds`) **but** line 1 is `import 'dart:ui';` — `Device.position` is an `Offset`, `Wall` holds two `Offset`s, `Room.bounds` returns a `Rect`. Owns `enum DeviceKind` (:123-138) and `enum Connectivity { local, cloud }` (:142).
- **`panel/lib/domain/device_state.dart`** — **already pure Dart, zero imports.** Sealed `DeviceState` with exactly five subclasses: `SwitchState` ("Lights, outlets, TVs — anything that is simply on or off"), `ThermostatState` (currentC/targetC), `GarageDoorState` (open), `PowerState` (watts), `StatusState` (free text). These five are the state-shape families; `hub/dev/README.md`'s stand-in table is organized by exactly these families too.
- **`panel/lib/data/house_loader.dart`** — `House loadHouse({required String houseYaml, required String devicesYaml})`. Parses devices first (duplicate-id check, entity-id regex `^[a-z_]+\.[a-z0-9_]+$`, one-entity-one-Device clash check, kind via `_kind`, connectivity switch, `_point` for `[x, y]` → `Offset`), groups them by `room:`, then builds Floors/Rooms from house.yaml and joins; throws `FormatException` naming orphaned room references.
- **`panel/lib/data/hub_client.dart`** — the seam to the Hub: `abstract interface class HubClient` with `connected`, `states` (Device-id-keyed `Map<String, DeviceState>`), `stateChanges`, `toggle(String deviceId)` ("Flip a Device that has a binary state (light, outlet, TV, garage door). No-op for anything else."), `dispose`.
- **`panel/lib/data/fake_hub.dart`** — in-memory adapter at the HubClient seam. Constructor seeds every Device via `_initialState` (the exhaustive kind switch); `Random(7)` drives `light => SwitchState(device.id, on: _random.nextBool())` — **lights are seeded randomly; all other kinds deterministically**. Drift timer perturbs thermostat/power readings; `driftEvery: Duration.zero` disables it for tests.
- **`panel/lib/data/ha_hub.dart`** — the real adapter: WebSocket to the Hub, folds "the Hub's entity-shaped world down to the Panel's one-state-per-Device model." `_toDeviceState` (:281-312) switches on `device.kind` — 14 arms grouped into exactly the five families: light/outlet/tv → `SwitchState(on: raw == 'on')`; garageDoor → `GarageDoorState(open: raw == 'on' || raw == 'open')`; thermostat → `ThermostatState` from `current_temperature`/`temperature` attrs (null if either missing); energyMonitor/evCharger → `PowerState` from `_number(raw)`; camera/doorbell/oven/washer/dryer/litterRobot/feeder → `StatusState(device.id, raw)`. Also: `hub.missing_entities` warning at :229, `snapshot` log at :217.
- **`panel/lib/ui/theme.dart:38-53`** — `IconData deviceIcon(DeviceKind kind)`, exhaustive, stays as-is.
- **`panel/tool/gen_dev_entities.dart`** — "Generates the development Hub's stand-in fleet from the Panel's own devices.yaml, so every Device pin has a real Home Assistant entity behind it while the actual hardware is still in boxes." Writes `../hub/dev/ha-config/packages/panel_dev.yaml`. Everything is inline in `main()`: arg parsing, file I/O, the seed maps, YAML text assembly (`_section`, `_q`, `_slugify` — HA's entity-id rule), the name-slug clash check (:92-98), the binding derivation (`binding[id] = 'input_boolean.$obj'` from *device id* for toggle kinds; `'sensor.$slug'` / `'climate.$slug'` from *slugified device name* for the rest), and `_fail` → `exit(1)`. **Zero tests, untestable as shaped.**
- **`panel/lib/main.dart`** — wires it together: `loadHouse` on the bundled assets, then `FakeHub(house)` or `HaHubClient(...)` per `--dart-define=HUB`.
- **UI consumers of kind**: `hub_controller.dart:34,43` (`d.kind == DeviceKind.light` for Room lit-aggregate and Room tap), `device_popup.dart:16` and `dollhouse/dollhouse_view.dart:192-194` (camera/doorbell → video Popup affordance; `toggles = !isVideo && (state is SwitchState || state is GarageDoorState)`).
- **Tests**: `test/house_loader_test.dart` (parse + orphan room + unknown kind), `test/fake_hub_test.dart` (seed coverage, toggle semantics), `test/ha_hub_test.dart` (FakeChannel-driven protocol tests incl. "folds entity states down to Device states by kind"), `test/ha_hub_live_test.dart` (live dev-Hub test, token-gated, asserts the triplicated seed literals), `test/test_house.dart` (`loadTestHouse()` reads the real shipped assets from disk), goldens in `test/golden/` — three scenes (`ground_floor.png`, `upstairs_selected.png`, `device_popup.png`) render the Dollhouse over `FakeHub(house, driftEvery: Duration.zero)` and **depend on FakeHub's `Random(7)` light-seeding sequence**; the fourth (`hub_offline.png`) renders over the file-local `_OfflineHub` (empty states, every Device unknown) and does not.
- **Docs**: `panel/HOUSE-PLAN.md` (the family runbook), `hub/dev/README.md` (the stand-in fleet table, regeneration instructions).

Git history for the area: `e49dd24 connect to HUB` introduced ha_hub/gen_dev_entities/dev Hub; `70f415b added loggin and mcp` touched logging. No churn evidence — this plan is justified by locality and testability, not by observed change frequency.

## 3. Target design

Two new pure-Dart modules, one production-path simplification, one tool gutted to a shell.

### 3.1 `panel/lib/domain/device_vocabulary.dart` — the Device-vocabulary table (NEW, pure Dart)

Domain-owned. Imports only `device_state.dart` (already pure). No `dart:ui`, no Flutter, no yaml. `DeviceKind` and `Connectivity` **move here verbatim** from house.dart; house.dart re-exports them so no import site changes (Decision 3).

```dart
import 'device_state.dart';

/// The five shapes of DeviceState a kind can produce — mirrors the sealed
/// DeviceState subclasses one-to-one. New kinds almost always reuse an
/// existing family; a new family means a new DeviceState subclass first.
enum StateFamily { toggle, garageDoor, thermostat, power, status }

extension StateFamilyTraits on StateFamily {
  /// A binary state the Panel may flip with HubClient.toggle.
  /// (Plans 01/02 consume this — see Cross-plan coordination.)
  bool get togglable =>
      this == StateFamily.toggle || this == StateFamily.garageDoor;
}

/// Everything the codebase knows about one kind of hardware, in one row:
/// its devices.yaml slug, its state-shape family, and the plausible
/// stand-in state both FakeHub and the dev Hub generator seed.
final class KindSpec {
  const KindSpec(
      {required this.slug, required this.family, required this.seed});

  final String slug;
  final StateFamily family;
  final DeviceState Function(String deviceId) seed;
}

/// THE vocabulary. Exhaustive switch on purpose: a new DeviceKind without a
/// row here is a compile error, exactly like the icon switch in theme.dart.
KindSpec specOf(DeviceKind kind) => switch (kind) {
      DeviceKind.light => const KindSpec(
          slug: 'light', family: StateFamily.toggle, seed: _lightSeed),
      DeviceKind.outlet => const KindSpec(
          slug: 'outlet', family: StateFamily.toggle, seed: _outletSeed),
      // ... 12 more rows, see the table below ...
    };

DeviceKind? kindFromSlug(String slug) => _bySlug[slug];

final _bySlug = {
  for (final kind in DeviceKind.values) specOf(kind).slug: kind,
};

DeviceState _lightSeed(String id) => SwitchState(id, on: false);
DeviceState _outletSeed(String id) => SwitchState(id, on: true);
// ... one small top-level function per kind; static tear-offs are const.
```

The 14 rows (values taken verbatim from today's fake_hub.dart:86-103 and gen_dev_entities.dart:25-53 — they already agree, by the "Seeds match FakeHub" policy):

| DeviceKind | slug | family | seed |
|---|---|---|---|
| light | `light` | toggle | `SwitchState(on: false)` (generator's value; FakeHub randomizes — Decision 1) |
| outlet | `outlet` | toggle | `SwitchState(on: true)` |
| tv | `tv` | toggle | `SwitchState(on: false)` |
| garageDoor | `garage-door` | garageDoor | `GarageDoorState(open: false)` |
| thermostat | `thermostat` | thermostat | `ThermostatState(currentC: 21.4, targetC: 21.0)` |
| energyMonitor | `energy-monitor` | power | `PowerState(watts: 812)` |
| evCharger | `ev-charger` | power | `PowerState(watts: 0)` |
| washer | `washer` | status | `StatusState('Idle')` |
| dryer | `dryer` | status | `StatusState('Cycle · 32 min left')` |
| oven | `oven` | status | `StatusState('Off')` |
| litterRobot | `litter-robot` | status | `StatusState('Clean · cycled 2 h ago')` |
| feeder | `feeder` | status | `StatusState('Next meal 5:00 pm')` |
| camera | `camera` | status | `StatusState('Live')` |
| doorbell | `doorbell` | status | `StatusState('Live')` |

**Interface** (everything a caller must know): `specOf(kind)` is total over `DeviceKind` (compiler-enforced); `kindFromSlug` returns null for unknown slugs (callers own their error message); slugs are unique and kebab-case (pinned by test); `seed(id)`'s runtime type always matches `family` (pinned by test); `togglable` is derived from family, never stored. **What hides inside**: the entire kind→slug/family/seed knowledge that today lives at six sites.

### 3.2 `panel/lib/data/device_parser.dart` — the one devices.yaml parser (NEW, pure Dart)

Imports `package:yaml`, `../domain/device_vocabulary.dart`. Positions are plain records; `Offset` conversion happens at the Flutter edge (inside house_loader).

```dart
/// One Device as declared in devices.yaml — pure data, no dart:ui.
/// house_loader converts position to Offset; the dev-entity generator
/// consumes it as-is.
final class ParsedDevice {
  const ParsedDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.connectivity,
    required this.roomId,
    required this.position,
    this.entityId,
  });

  final String id;
  final String name;
  final DeviceKind kind;
  final Connectivity connectivity;
  final String roomId;

  /// Meters from the house NW corner: (x east, y south) — ADR-0004.
  final (double, double) position;
  final String? entityId;
}

/// Parses and fully validates the hand-maintained devices.yaml (ADR-0004):
/// duplicate ids, entity-id shape (domain.object_id), one-entity-one-Device,
/// unknown kind (via the vocabulary), unknown connectivity, malformed
/// position. Throws FormatException with an actionable message.
List<ParsedDevice> parseDevices(String devicesYaml);
```

All validation moves here verbatim from house_loader.dart:15-53 + `_kind` + `_point` (entity regexp, clash map, error wordings preserved). The kind lookup becomes:

```dart
final kind = kindFromSlug(slug) ??
    (throw FormatException(
        'devices.yaml: device "$id" has unknown kind "$slug"'));
```

### 3.3 Callers become shallow

- **`house_loader.dart`** keeps its interface — `loadHouse({houseYaml, devicesYaml})`, same `FormatException` contract — but its device half becomes: `parseDevices(devicesYaml)`, then map each `ParsedDevice` to a `Device` with `Offset(p.position.$1, p.position.$2)`, group by `roomId`, join to Rooms exactly as today. `_kind` and the device-side validation are deleted. (`_point` stays for house.yaml footprints/walls.)
- **`fake_hub.dart`** `_initialState` becomes:
  ```dart
  DeviceState _initialState(Device device) => device.kind == DeviceKind.light
      // Lights randomize so the Dollhouse opens looking lived-in — a FakeHub
      // liveliness choice, deliberately not in the vocabulary (Decision 1).
      ? SwitchState(device.id, on: _random.nextBool())
      : specOf(device.kind).seed(device.id);
  ```
- **`ha_hub.dart`** `_toDeviceState` switches on `specOf(device.kind).family` — **5 stable arms instead of 14 growing ones**; new kinds reuse a family arm for free. Bodies move verbatim (same null-on-unparseable contract):
  ```dart
  switch (specOf(device.kind).family) {
    case StateFamily.toggle:
      return SwitchState(device.id, on: raw == 'on');
    case StateFamily.garageDoor:
      return GarageDoorState(device.id, open: raw == 'on' || raw == 'open');
    case StateFamily.thermostat: /* current_temperature/temperature, as today */
    case StateFamily.power:      /* _number(raw) -> PowerState, as today */
    case StateFamily.status:     return StatusState(device.id, raw);
  }
  ```
- **`theme.dart`** — unchanged. Icons stay an exhaustive compiler-policed switch; `IconData` cannot be pure Dart.

### 3.4 `panel/tool/dev_entities_core.dart` — the generator's pure core (NEW, pure Dart)

```dart
import 'package:panel/data/device_parser.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/domain/device_vocabulary.dart';

/// The generated development-Hub package, before any file I/O.
final class DevPackage {
  const DevPackage(
      {required this.text, required this.binding, required this.summary});

  /// Full text of hub/dev/ha-config/packages/panel_dev.yaml.
  final String text;

  /// Device id -> the stand-in entity the Panel binds to. Today this is
  /// emitted as the file's header comment; the binding-drift test consumes
  /// it directly.
  final Map<String, String> binding;

  /// The one-line count summary main() prints on success.
  final String summary;
}

/// Pure function: parsed Devices in, package text + binding table out.
/// Throws FormatException on a name-slug clash (two Devices whose names
/// slugify to one HA entity id). Never touches the filesystem.
DevPackage generateDevPackage(List<ParsedDevice> devices,
    {String source = 'assets/house/devices.yaml'});
```

Everything between arg parsing and file writing in today's `main()` moves here: the per-kind emission (switching on `specOf(kind).family` — toggle & garageDoor → `input_boolean`; power → `input_number` + template sensor; status → `input_text` + template sensor; thermostat → the `generic_thermostat` rig), seed values via `specOf(kind).seed(...)` pattern-matched to raw YAML values, `_slugify`, `_q`, `_section`, the binding derivation, the header comment. The slug-string seed maps, `_Device`, `_readDevices`, `_require` are deleted. **The output must be byte-identical to today's** (verified in step 5 below) — keep insertion order (devices.yaml order) and the `# Source: panel/$devicesPath` header parameterized.

`gen_dev_entities.dart` shrinks to `main()`: parse args, read the file, `parseDevices`, `generateDevPackage`, write, print summary — `on FormatException catch (e) { stderr.writeln('error: ${e.message}'); exit(1); }`. Exit codes and I/O live only at main()'s edge.

### 3.5 Before/after dependency sketch

```
BEFORE
  house.dart (dart:ui; owns DeviceKind) <── house_loader.dart (dart:ui; slug→kind switch ×14)
                                              │ parses devices.yaml (full validation)
  gen_dev_entities.dart (pure Dart) ──────────┘ re-parses devices.yaml (weak: id/name/kind only)
      owns 3 slug-keyed seed maps + thermostat consts ("Seeds match FakeHub")
      derives binding → emits as YAML comment → hand-copied into devices.yaml entity:
  fake_hub.dart   ── switch on DeviceKind ×14 (seeds; duplicates literals)
  ha_hub.dart     ── switch on DeviceKind ×14 (entity→DeviceState)   ← missed by candidate
  theme.dart      ── switch on DeviceKind ×14 (icons; fine)
  ha_hub_live_test.dart ── asserts the same seed literals (3rd copy)
  HOUSE-PLAN.md + devices.yaml header ── two hand-written kind lists; runbook says 2 edits, truth is 6

AFTER
  device_vocabulary.dart (NEW, pure, domain)   ── kind → slug + family + seed (+ togglable)
      ▲            ▲             ▲          ▲
      │            │             │          └── ha_hub.dart: switch on 5 families, not 14 kinds
      │            │             └── fake_hub.dart: seeds = specOf(kind).seed (lights random)
      │            └── device_parser.dart (NEW, pure): THE devices.yaml parser, record positions
      │                    ▲                    ▲
      │                    │                    └── dev_entities_core.dart (NEW, pure):
      │                    │                          ParsedDevice list → DevPackage(text, binding)
      │                    │                          gen_dev_entities.dart main() = I/O shell only
      │                    └── house_loader.dart: parseDevices → Offset at the Flutter edge
      └── house.dart re-exports DeviceKind/Connectivity (import sites unchanged)
  theme.dart unchanged (icons stay compiler-policed Flutter-side)
  devices.yaml stays hand-maintained — NOTHING writes it (ADR-0004)
  tests: vocabulary completeness · scoped binding drift · generator string-in/string-out
```

Adding a kind of hardware after this lands: one `DeviceKind` value + one `specOf` row (one compile error walks you there) + one icon arm (second compile error) — and HOUSE-PLAN.md's instruction becomes true again.

## 4. Decision points

**Decision 1 — FakeHub light seeding: keep random, or adopt the table's deterministic seed?**
- (a) **Keep `_random.nextBool()` for lights** (recommended): preserves FakeHub's deliberate liveliness (the Dollhouse opens looking lived-in), keeps the `Random(7)` draw sequence identical (lights are the only `nextBool` consumers, iteration order unchanged), so **all four goldens stay byte-identical**. The vocabulary still carries `light → SwitchState(on: false)` as the canonical seed because the *generator* needs one.
- (b) Adopt `on: false` from the table for lights too: FakeHub becomes exactly the dev Hub, but every light starts off, the Dollhouse opens dark, and the three FakeHub-rendered goldens (`ground_floor.png`/`upstairs_selected.png`/`device_popup.png`) need `--update-goldens` and eyeballing (`hub_offline.png` renders over the golden test's `_OfflineHub` with empty states and is unaffected).
- This is a behaviour-affecting choice; (a) changes nothing user-visible.

**Decision 2 — binding-drift test scoping (the verifier's correction #3).** Asserting `entity: == generator-derived` for *every* Device goes red by design once real hardware integrates (the devices.yaml header expects replacement; ADR-0004's "later the Hub entity-id mapping" anticipates it). Options:
- (a) **Explicit allowlist in the test** (recommended): `const integratedDevices = <String>{};` — the test asserts, for every Device *not* in the set, that `entityId == derived.binding[id]`. Today the set is empty (all 33 Devices are stand-in-bound; hardware is in boxes). When the real Ecobee lands, add `'thermostat'` to the set — one line, in the test, hand-maintained in ADR-0004's spirit, and the test doubles as the ledger of what is actually integrated.
- (b) A `standIn: true` flag per Device in devices.yaml: self-describing but grows the hand-maintained schema and 33 lines of noise for a test's benefit.
- (c) Scope to helper domains only (`input_boolean.*`/`input_number.*`/`input_text.*` are unambiguously stand-ins): zero maintenance but blind to exactly the worst case — `sensor.*`/`climate.*` stand-ins drifting after a Device *name* change (their binding derives from the slugified name).

**Decision 3 — where `DeviceKind`/`Connectivity` live.** They must leave house.dart (it imports dart:ui; the vocabulary must be pure).
- (a) **Move to device_vocabulary.dart and re-export from house.dart** (recommended): `export 'device_vocabulary.dart' show DeviceKind, Connectivity;` — zero import-site churn across ui/, data/, tests.
- (b) Move and update every import site: cleaner long-term, ~10 files of mechanical churn now. Fine as a later sweep; not worth coupling to this plan.

**Decision 4 — seed representation.**
- (a) **`DeviceState Function(String deviceId)` per row** (recommended): the seed *is* a DeviceState — FakeHub applies it directly; the generator pattern-matches the sealed type to get raw YAML values; the completeness test asserts seed-type ↔ family agreement. One representation, no parallel value classes.
- (b) A sealed `Seed` hierarchy mirroring the five families: more ceremony, duplicates what `DeviceState` already expresses.
- (c) Raw per-family maps (status quo, relocated): keeps the string-keyed shape that caused the problem.

**Decision 5 — where the generator's pure core lives.**
- (a) **`panel/tool/dev_entities_core.dart`** (recommended): dev scaffolding stays in tool/ next to its entrypoint; tests reach it with `import '../tool/dev_entities_core.dart';` (legal — it's pure Dart and imports only `package:panel/...` pure files).
- (b) `panel/lib/data/dev_entities.dart`: package imports from tests look tidier, but dev-Hub scaffolding enters the app's lib/ (tree-shaken, yet conceptually wrong side of the seam).

**Decision 6 — doc-drift pinning test.** A test that reads `assets/house/devices.yaml` and `HOUSE-PLAN.md` as text and asserts every vocabulary slug appears in each (recommended: include — it is five lines and turns the two hand-transcribed kind lists from silent drift into a red test; it checks `contains(slug)` only, so prose edits stay free). Skip if the user finds text-grepping tests distasteful.

**Ratified defaults if the user does not object**: 1(a), 2(a), 3(a), 4(a), 5(a), 6 include.

## 5. Step-by-step implementation

Each step leaves `flutter analyze` and `flutter test` green. Work in `panel/`.

**Step 1 — mint the vocabulary.**
- Create `lib/domain/device_vocabulary.dart`: move `enum DeviceKind` (house.dart:123-138) and `enum Connectivity` (house.dart:140-142) here verbatim (keep doc comments); add `StateFamily`, `StateFamilyTraits.togglable`, `KindSpec`, `specOf` (exhaustive switch, 14 rows per the table in §3.1), `kindFromSlug`, `_bySlug`, and the 14 seed tear-off functions.
- In `house.dart`: delete the two enums; add `import 'device_vocabulary.dart';` (its own `Device.kind`/`Device.connectivity` fields need the types) and `export 'device_vocabulary.dart' show DeviceKind, Connectivity;` so every existing import site keeps resolving.
- Create `test/device_vocabulary_test.dart` (cases in §6).
- Green: nothing else changed; all existing imports of `DeviceKind` resolve via the re-export.

**Step 2 — the one parser.**
- Create `lib/data/device_parser.dart`: `ParsedDevice` + `parseDevices` per §3.2, moving the validation block from house_loader.dart:15-53 verbatim (error strings unchanged — house_loader_test pins some of them), with `_kind` replaced by `kindFromSlug` + the same FormatException wording, and position parsed to a `(double, double)` record.
- Rewrite the device half of `loadHouse` to consume `parseDevices` (§3.3); delete `_kind`; keep `_point` for geometry.
- Create `test/device_parser_test.dart` (cases in §6). `house_loader_test.dart` stays green untouched — `loadHouse`'s interface and error messages are unchanged.

**Step 3 — FakeHub seeds from the vocabulary.**
- Replace `_initialState`'s kind switch (fake_hub.dart:86-103) with the two-liner in §3.3 (Decision 1a: lights keep `_random.nextBool()`).
- Green: `fake_hub_test.dart` unchanged; goldens unchanged (verify with `flutter test test/golden` — the `Random(7)` draw sequence is identical because only lights consume it, in the same house order).

**Step 4 — HaHub parses by family.**
- Rewrite `_toDeviceState` (ha_hub.dart:281-312) as the 5-arm family switch in §3.3, bodies moved verbatim.
- Green: `ha_hub_test.dart` unchanged, including 'folds entity states down to Device states by kind'.

**Step 5 — gut the generator.**
- Create `tool/dev_entities_core.dart`: `DevPackage` + `generateDevPackage` per §3.4. Move `_slugify`, `_q`, `_section`, the emission loops, the name-clash check (now `throw FormatException(...)`), the header/binding-comment assembly. Delete `_toggleSeed`, `_powerSeed`, `_statusSeed`, `_thermostatKind`, `_thermostatCurrentC`, `_thermostatTargetC`, `_Device`, `_readDevices`, `_require`.
- Rewrite `tool/gen_dev_entities.dart` as the thin `main()` shell (§3.4). Keep the file-not-found guidance ('run this from the panel/ directory') and the two success/restart stdout lines.
- **Byte-identity check** (this is the step's acceptance test):
  `dart run tool/gen_dev_entities.dart -o /tmp/panel_dev.regen.yaml && diff /tmp/panel_dev.regen.yaml ../hub/dev/ha-config/packages/panel_dev.yaml` → empty diff. (The stricter parser now validates entity/position/connectivity on the tool path too; the shipped devices.yaml already satisfies all of it.)
- Create `test/dev_entities_core_test.dart` (cases in §6), importing `../tool/dev_entities_core.dart`.

**Step 6 — kill the third seed copy.**
- In `test/ha_hub_live_test.dart:32-38`, replace the literals with vocabulary lookups:
  `final power = specOf(DeviceKind.energyMonitor).seed('x') as PowerState; expect((hub.states['energy-monitor'] as PowerState).watts, power.watts);` — same pattern for thermostat (`closeTo(seed.currentC, 0.05)` — keep `closeTo`, the precision comment explains why) and washer. The light-hall `isFalse` assertion stays as-is (it asserts the *generator's* light seed, which is the vocabulary's `on: false`).
- This file is token-gated (skipped in CI-less `flutter test`); it still compiles, which is all the hermetic run checks.

**Step 7 — docs made true again.**
- `panel/HOUSE-PLAN.md` §5 step 3: replace the parenthetical with: kinds map 1:1 to `DeviceKind` in `lib/domain/device_vocabulary.dart` — a new kind of hardware means one row there (slug + state family + stand-in seed), one icon arm in `lib/ui/theme.dart` (the compiler points at both), then `dart run tool/gen_dev_entities.dart` and a dev-Hub restart. Keep the slug list (the Decision-6 test now pins it).
- `hub/dev/README.md`: no factual change required (its family table is already the five-family view); optionally point "The generator refuses unknown Device kinds" at the vocabulary.
- `devices.yaml` header: unchanged (hand-maintained, now test-pinned).

**Step 8 — final sweep.** `cd panel && flutter analyze && flutter test`; re-run the byte-identity diff; commit.

Files created: `lib/domain/device_vocabulary.dart`, `lib/data/device_parser.dart`, `tool/dev_entities_core.dart`, `test/device_vocabulary_test.dart`, `test/device_parser_test.dart`, `test/dev_entities_core_test.dart`.
Files modified: `lib/domain/house.dart`, `lib/data/house_loader.dart`, `lib/data/fake_hub.dart`, `lib/data/ha_hub.dart`, `tool/gen_dev_entities.dart`, `test/ha_hub_live_test.dart`, `panel/HOUSE-PLAN.md` (and optionally `hub/dev/README.md`).
Files deleted: none (the two weak parsers and five switches die inside modified files).

## 6. Test plan

**New: `test/device_vocabulary_test.dart`** — the vocabulary-completeness contract, pinned for the first time:
- `'every kind has a slug, a family, and a seed of the family's shape'` — iterate `DeviceKind.values`; assert `specOf(kind)` returns; assert `seed('probe')` runtime type matches `family` (toggle→SwitchState, garageDoor→GarageDoorState, thermostat→ThermostatState, power→PowerState, status→StatusState). This turns "forgot to update the generator" from a generation-time `exit(1)` weeks later into a red test now.
- `'slugs are unique, kebab-case, and round-trip through kindFromSlug'`.
- `'kindFromSlug returns null for an unknown slug'`.
- `'toggle and garage-door families are togglable; thermostat, power, status are not'` — the togglability declaration plans 01/02 consume.
- (Decision 6) `'devices.yaml header and HOUSE-PLAN.md both list every slug'` — read both files as text (`File('assets/house/devices.yaml')` and `File('HOUSE-PLAN.md')` — tests run with the package root `panel/` as cwd, same pattern as `test_house.dart`), `expect(text, contains(spec.slug))` per kind.

**New: `test/device_parser_test.dart`** — the parser inherits and extends the loader's device-side pins:
- `'parses id, name, kind, connectivity, room, position record, entity'` (happy path, one device).
- `'rejects a duplicate device id'`, `'rejects a malformed entity id'`, `'rejects two Devices bound to one entity'`, `'rejects an unknown kind'`, `'rejects an unknown connectivity'`, `'rejects a position that is not an [x, y] pair'` — the last three were previously only reachable through `loadHouse`; the entity/duplicate checks were pinned nowhere below `loadHouse` either.

**New: `test/dev_entities_core_test.dart`** — the generator goes from zero tests (inline file I/O + `exit(1)`) to string-in/string-out:
- `'emits an input_boolean with the vocabulary seed for a toggle kind'`
- `'emits input_number + template power sensor for a power kind'`
- `'emits input_text + template sensor for a status kind'`
- `'emits the generic_thermostat rig for a thermostat'` (pin `precision: 0.1` — the comment at gen_dev_entities.dart:162-164 explains the Panel shows 21° for a 21.4° room without it)
- `'derives the binding: input_boolean from device id, sensor/climate from slugified name'`
- `'throws FormatException when two Device names slugify to one entity id'` (was `exit(1)`)
- `'binding drift: every Device not yet integrated binds to exactly the derived stand-in'` — the scoped drift test (Decision 2a): parse the real `assets/house/devices.yaml`, generate, assert `entityId == binding[id]` for every Device outside `integratedDevices` (empty today). This turns the silent-rename hazard — today a runtime `hub.missing_entities` warning, and only when live — into a red test.

**Existing tests:** `house_loader_test.dart`, `fake_hub_test.dart`, `ha_hub_test.dart` — unchanged and must stay green (they pin that this refactor is behaviour-preserving). `ha_hub_live_test.dart` — literals replaced by vocabulary lookups (step 6); semantics identical.

**Goldens** (`panel/test/golden/goldens/`: `ground_floor.png`, `upstairs_selected.png`, `device_popup.png` over FakeHub; `hub_offline.png` over the file-local `_OfflineHub`): unchanged under Decision 1a. If any golden diffs, the `Random(7)` draw sequence changed — that is a bug in step 3, not a reason to `--update-goldens`. Only Decision 1b legitimately regenerates the three FakeHub scenes (`flutter test --update-goldens`, then eyeball; `test/golden/failures/` is empty on re-run); `hub_offline.png` never changes under either decision.

**Behaviours pinned for the first time:** vocabulary totality; seed-shape/family agreement; slug uniqueness; togglability by family; FakeHub↔dev-Hub seed identity (by construction — both read one table — rather than by the "Seeds match FakeHub" comment); generator output shape; stand-in binding freshness; the two doc kind-lists.

## 7. Verification

```sh
cd panel && flutter analyze && flutter test
```

Plus the generator byte-identity check after step 5 (and again at the end):

```sh
cd panel && dart run tool/gen_dev_entities.dart -o /tmp/panel_dev.regen.yaml \
  && diff /tmp/panel_dev.regen.yaml ../hub/dev/ha-config/packages/panel_dev.yaml
```

Live check of the app, if wanted: **this Mac has Flutter via brew but NO Xcode** — use `flutter run -d chrome` (web build), never `-d macos`. Optional live Hub round-trip (needs the dev Hub up): `flutter test test/ha_hub_live_test.dart --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"`.

## 8. Non-goals

Taken from the verifier's discipline notes, each with its written-down trigger:

- **Never write devices.yaml.** The plan derives and tests bindings; the file stays hand-maintained under ADR-0004's single-writer rule. Any "convenience" that auto-fills `entity:` lines is rejected, permanently.
- **No icon column.** `IconData` cannot live in a pure-Dart table, and `deviceIcon` is already compiler-policed. Trigger to revisit: never (the leg is a wash); at most an icon-*name* string column if the Panel ever theme-switches icon sets.
- **No video-affordance column.** `device_popup.dart:16` / `dollhouse_view.dart:192-194` key the video Popup off camera/doorbell directly. Trigger: a third video-bearing kind, or plans 01/02 introducing a kind-keyed affordance table — then `isVideo` becomes a vocabulary column beside `togglable`.
- **No de-Flutter-izing of house.dart geometry.** `Device.position`/`Wall`/`Room.bounds` keep `Offset`/`Rect`; only devices.yaml *parsing* goes pure. Trigger: a second pure-Dart consumer of full House geometry (e.g. a converter that validates against house.yaml).
- **No generated docs.** The two kind lists stay hand-written prose, pinned by a `contains` test only. Trigger: a third hand-transcribed list appearing.
- **No new kinds, no schema changes to devices.yaml, no UI changes.** This is a behaviour-preserving refactor; the byte-identity diff and untouched goldens are the proof.

## 9. Cross-plan coordination

There are 8 plans in `docs/plans/`: `01-device-presentation-module.md`, `02-hubclient-contract-and-scriptable-fakehub.md`, `03-floor-geometry-owner.md`, `04-house-plan-gatekeeper.md`, `05-floor-arrangement-module.md`, `06-device-vocabulary-table.md` (this one), `07-hub-status-three-state.md`, `08-panel-boot-module.md`. Coordination notes for this one:

- **Plans 01/02** mint a domain-side togglability declaration; this vocabulary table is its natural final home (kind → state family already implies binary-ness). **If they landed first**: absorb their declaration into the table (as the `StateFamilyTraits.togglable` getter here) and delete the standalone. **If not**: this plan adds togglability as a table column anyway (`togglable`, derived from family) — 01/02 should consume it instead of minting their own. Related recorded fact from plan 01's territory: kind-keyed tap affordances (e.g. unknown-state light taps — toggle vs Popup) CHANGE current behaviour; this plan deliberately changes none (FakeHub/HaHub/loader behaviour is bit-preserved), so 01/02 own any affordance semantics.
- **Plan 04** adds geometry validation to `loadHouse`; this plan's parser extraction touches the same file (`house_loader.dart`) — either order works (see 04's plan for the split). This plan only removes the *device* half of `loadHouse`; 04's geometry validation lands in the half that stays.
- **Plan 02** touches FakeHub (driving surface); this plan's seed changes are disjoint (seeds come from the table; 02's driving is about mutations, not initial state) — same file, coordinate on merge order, expect no semantic conflict.
- **Plan 03** grows `house.dart`'s geometric interface (`Floor.outline`, `House.planExtent`, `plan_geometry` sinking in as a `part`); this plan's `house.dart` edit is confined to deleting the two enums and adding the import + re-export — disjoint regions of the same file, either order works.
- **Plan 07** reworks `ha_hub.dart`'s session lifecycle / connection-status handling (three-state Hub status) and explicitly leaves the `_applyEntity`/`_toDeviceState` fold untouched; this plan's 14-arms→5-families change touches only `_toDeviceState` — disjoint halves of the same file, coordinate on merge order.
- **Plans 05 and 08** share no files with this one (05 is Dollhouse-side floor arrangement; 08 is `main.dart` boot composition — `main.dart` is untouched here).
- Discovered while writing this plan: `test/ha_hub_live_test.dart` is touched here (step 6); if plan 07 also edits its assertions, land whichever first and rebase the other — the vocabulary-lookup form is the end state either way.

## 10. Sources

- `/Users/dmorozov/Work/ITConsulting/SmartHome/CONTEXT.md` — domain language (Panel, Hub, Dollhouse, House Plan, Device, Local/Cloud Device, Retrofit).
- `/Users/dmorozov/Work/ITConsulting/SmartHome/docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md` — the two-file, two-lifecycle rule this plan must not violate; also `0002` (black-box Hub), `0003` (purchase pipeline context), `0001` (kiosk substrate).
- `/Users/dmorozov/Work/ITConsulting/SmartHome/.claude/skills/codebase-design/SKILL.md` — deep module / interface / seam / adapter / leverage / locality / deletion test, used exactly as defined there.
- Originating architecture review: candidate 3 of the 2026-08-01 review (temp HTML artifact, ephemeral), including the adversarial verification verdict whose corrections (the sixth site in ha_hub.dart; the compiler-policed vs unpoliced split; the scoped binding-drift test; the icon wash; the Worth-exploring strength) are folded into §1 and §4 above.
- Key code evidence at commit 105610c: `panel/lib/domain/house.dart:1,123-142`; `panel/lib/data/house_loader.dart:1,15-53,96-121`; `panel/lib/data/fake_hub.dart:86-103`; `panel/lib/data/ha_hub.dart:229,281-312`; `panel/lib/ui/theme.dart:38-53`; `panel/tool/gen_dev_entities.dart:15,25-53,92-98,168-172,225-263`; `panel/assets/house/devices.yaml:4-13`; `panel/HOUSE-PLAN.md:168-173`; `panel/test/ha_hub_live_test.dart:32-39`; `hub/dev/ha-config/packages/panel_dev.yaml` header; `hub/dev/README.md` stand-in fleet table.
