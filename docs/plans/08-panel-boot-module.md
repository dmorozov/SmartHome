# Panel boot module — composition testable, Hub kind out of the widget tree

One deep boot module takes plain strings (Hub kind, url, token, the two House Plan YAML texts) and yields the ready assembly — House, chosen HubClient adapter, HubController, and the Hub badge label as data — so config validation, token redaction, and the fatal House Plan log become testable, and `PanelApp` stops reading a compile-time const to label its badge.

Status: proposed · Strength: Worth exploring · Written against commit 105610c (2026-08-01) — re-verify line numbers before editing.

---

## 1. Why this refactor

### The friction, with evidence

All of the Panel's composition knowledge lives in private helpers of `panel/lib/main.dart`, fused to `String.fromEnvironment` consts. None of it is reachable by any test without compiling one build per dart-define combination — the knowledge is **untestable, not merely untested**.

**(a) The Hub kind is a compile-time const, and the widget tree reads it.**

`panel/lib/main.dart:63`:

```dart
const _hubKind = String.fromEnvironment('HUB', defaultValue: 'fake');
```

and inside `PanelApp.build`, `main.dart:120`:

```dart
label: _hubKind == 'fake' ? 'FAKE HUB' : 'HUB',
```

The widget tree reaches past `HubController` into the composition root. Consequence, verified against the committed golden: `panel/test/golden/goldens/hub_offline.png` renders **"FAKE HUB OFFLINE"**. The production "HUB OFFLINE" scene — which the golden test's own doc comment calls "The most important scene to be able to recognise at a glance, and the hardest to reach by hand" (`dollhouse_golden_test.dart:73-75`) — is **provably unrenderable through `PanelApp`'s interface**. The offline golden pumps a `_OfflineHub` adapter (`dollhouse_golden_test.dart:64-70`) yet can only ever show the fake-build badge, because the label comes from the const, not from anything the test can inject.

**(b) Hub selection and config validation are unreachable.** `main.dart:65-86`, `_hub(House house)`:

```dart
HubClient _hub(House house) {
  const which = _hubKind;
  if (which == 'fake') return FakeHub(house);
  if (which != 'ha') {
    throw ArgumentError('unknown HUB "$which" (fake | ha)');
  }
  const url = String.fromEnvironment('HA_URL',
      defaultValue: 'http://localhost:8123');
  const token = String.fromEnvironment('HA_TOKEN');
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
  );
}
```

The two `ArgumentError` modes (unknown `HUB` value; `HUB=ha` with a missing `HA_TOKEN`) and the token-redaction rule (`token=set`, never the token — the rule `log.dart`'s header comment declares in bold: "**Never log a secret.**") have zero test assertions, and cannot get any: each path needs a separately compiled build.

**(c) The fatal House Plan log is unreachable.** `main.dart:38-58`, `_loadHouse`, is the only place House Plan load failure produces its greppable exit line:

```dart
  } catch (error, stack) {
    // A malformed House Plan is fatal, and on the kiosk nobody is standing
    // in front of the red screen. Leave one greppable line on the way out.
    Log.error('house', 'invalid', error: error, stack: stack);
    rethrow;
  }
```

The success side logs `house.loaded` with `name/floors/rooms/devices/bound` counts (`main.dart:42-50`) — the `bound` count being the at-a-glance answer to "which Devices can never show state". The entire boot diagnostics story has zero test assertions, even though the infrastructure to assert it exists (`Log.sink` swap, `log.dart:86`, pattern demonstrated in `log_test.dart:7-16`).

**(d) Locality.** Understanding "how does the Panel come up" today requires `main.dart` (three private helpers plus a const read inside a build method), `test_house.dart` (the test-side House acquisition), and each test file's private factory (`dollhouse_test.dart:11-15` `makeController()`, `dollhouse_golden_test.dart:27-31` `fakeHub()`). Knowledge about one thing spread across four files.

### The verifier's corrections — these bound the fix

The adversarial verification pass confirmed the defect but **corrected the original candidate's proposed size**. These corrections are binding on this plan:

1. **"https→wss derivation becomes unit-testable" was overstated.** `HaHubClient.webSocketUrl` is already a public static (`ha_hub.dart:49-55`); it is testable today, just untested. Nothing about it moves.

2. **The deletion test only half-passes.** The test-side "duplicates" are not re-grown main composition but **deliberate fixture variation**: `FakeHub(house, driftEvery: Duration.zero)` where main's FakeHub drifts every 3 s; an `_OfflineHub` main can never produce; `dart:io` `File` reads in `test_house.dart:9-12` instead of `rootBundle` precisely so binding-free `test()` bodies work. A ten-line shared helper collapses that duplication with no production module. Forcing goldens through a config-driven composition interface would make it grow adapter-injection and drift knobs — a shallow module with a widened interface.

3. **`HubController(house:, hub:)` is already the right seam** (`hub_controller.dart:13`). It satisfies "accept dependencies, don't create them", and two real adapters exist at it: `FakeHub` and `HaHubClient` (plus the test-only `_OfflineHub`). A real seam, not a hypothetical one. Widget and golden tests keep injecting there — they are **not** routed through the boot module.

4. **What genuinely survives deletion-test scrutiny:** the config-validation / badge-label / fatal-log knowledge lives nowhere reachable, and the badge rule has leaked into a build method. That — and only that — is what the module concentrates.

5. **ADR clearance:** ADR-0002 keeps the Hub a black box and the Panel a view/command layer — this refactor is Panel-side wiring only, the `HubClient` seam is untouched. ADR-0004's two-YAML-texts contract is exactly what the module accepts. No conflict with 0001/0003.

6. **Churn/YAGNI:** `main.dart` appears in 4 of the panel-era commits (`7ddf785`, `163b618`, `e49dd24`, `70f415b`), but the repo is weeks old, so churn evidence is thin either way. Composition will plausibly grow — go2rtc Popup config is coming, and a `LOG` dart-define already lives separately in `log.dart:72`. Net verdict: **real defect, wrong-sized fix in the original — corrected to a narrower boot/config module**, keeping widget/golden tests at the existing HubController seam.

---

## 2. Context a fresh session needs

### Domain terms (CONTEXT.md — use these words, never the avoided ones)

- **Panel**: "The wall-mounted touchscreen running the custom dollhouse UI." _Avoid: kiosk, dashboard, screen._
- **Hub**: "The headless smart-home broker (Home Assistant) that owns device state, integrations, and automations. The Panel is its client, never its replacement." _Avoid: server, backend, HA (in domain discussion)._
- **Dollhouse**: "The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms."
- **House Plan**: "The Panel-side description of the house's geometry — Floors with their Rooms and Walls, authored by the family. The Dollhouse renders it; the Hub never sees it."
- **Floor**: "One level of the house in the Dollhouse … Floors stack; tapping one expands it."
- **Room**: "A named area on a Floor. Rooms tile their Floor completely … Tapping a Room acts on it (e.g. toggles its lights)."
- **Wall**: "A boundary segment drawn on the House Plan. Only drawn Walls exist."
- **Device**: "A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse." _Avoid: entity (that is the Hub's internal term)._
- **Popup**: "A transient full-or-partial-screen overlay on the Panel, e.g. live doorbell video on ring."

### Design vocabulary (.claude/skills/codebase-design/SKILL.md — use exactly, never "component/service/API/boundary")

A **module** is anything with an **interface** (everything a caller must know: signature, invariants, error modes, required configuration) and an implementation. A module is **deep** when a lot of behaviour sits behind a small interface; depth gives **leverage** to callers and **locality** to maintainers. A **seam** is where an interface lives — a place to alter behaviour without editing in that place; an **adapter** is a concrete thing satisfying an interface at a seam. The **deletion test**: delete the module — if complexity reappears across N callers, it was earning its keep. "The interface is the test surface": callers and tests cross the same seam. "One adapter means a hypothetical seam. Two adapters means a real one."

### ADR constraints (binding sentences)

- **ADR-0002**: "The Hub is a black-box appliance: versions pinned, updated on our schedule, internals never modified." / "Automations live in the Hub's native engine; the Panel is a pure view/command layer." / "A small Dart JSON-over-WebSocket client for HA must be hand-rolled" — that client is `HaHubClient`; this plan does not touch it beyond forwarding its existing constructor parameters.
- **ADR-0004**: "Two files with two lifecycles: `house.yaml` (Floors → Rooms → Walls) is **generated and never hand-edited** … `devices.yaml` … is **hand-maintained and never touched by the converter**." The boot module's input contract — two raw YAML texts — is exactly this shape.
- **ADR-0001**: the appliance boots `cage` straight into the Panel; nobody is at a console. This is why every boot outcome must leave a greppable `[panel]` line — the motivation for pinning the log contract.
- **ADR-0003**: not implicated (device bus choice).

### Current-architecture tour (commit 105610c)

- **`panel/lib/main.dart`** — entry point and composition root. `main()` (lines 15-36): installs error handlers, logs `panel.start` (reading `_hubKind`, line 19), loads the two House Plan assets via `rootBundle.loadString`, then `runApp(PanelApp(controller: HubController(house: house, hub: _hub(house))))`. Private `_loadHouse` (38-58): calls `loadHouse`, logs `house.loaded` counts or the fatal `house.invalid` and rethrows. Private `_hub` (65-86): kind dispatch, `HA_URL`/`HA_TOKEN` consts, redacted `hub.configured` log, two `ArgumentError` modes, `HaHubClient` construction. `PanelApp` (88-146): `MaterialApp` + header row with the House name, the `_HubBadge`, and the `DollhouseView`; line 120 is the const leak. `_HubBadge` (151-193): takes `label` and `connected`, renders `connected ? label : '$label OFFLINE'` with a green/red dot.
- **`panel/lib/ui/hub_controller.dart`** — "Presentation state: the House structure plus live Device state from the Hub, folded into one Listenable for the widget tree." Constructor `HubController({required this.house, required HubClient hub})` (line 13) — the existing seam. Also owns `toggle`, `toggleRoomLights`, `isRoomLit`, `connected`.
- **`panel/lib/data/hub_client.dart`** — the interface at the seam: `connected` (ValueListenable), `states` map, `stateChanges` stream, `toggle`, `dispose`.
- **`panel/lib/data/fake_hub.dart`** — adapter: in-memory Hub; seeds a state per Device, drifts readings every `driftEvery` (default 3 s; `Duration.zero` disables — "deterministic tests"). Logs `hub.fake_ready` in its constructor.
- **`panel/lib/data/ha_hub.dart`** — adapter: the real Hub over its WebSocket API. Constructor already accepts a `WebSocketChannel Function(Uri)? connect` override (lines 29, 39) — used by `ha_hub_test.dart`'s `FakeChannel`. `static Uri webSocketUrl(String baseUrl)` at lines 49-55.
- **`panel/lib/data/house_loader.dart`** — `loadHouse({required String houseYaml, required String devicesYaml})`; "Throws [FormatException] with an actionable message on mismatch." Pure; no binding required.
- **`panel/lib/diagnostics/log.dart`** — `Log.sink` (line 86: `static void Function(LogRecord record) sink = printRecord;`) is the test capture point; `LogRecord` carries `level/area/event/fields/error/stack`. `flutter_test_config.dart` sets `Log.level = LogLevel.warn` for all tests; tests that assert on records set their own level and sink (pattern: `log_test.dart:7-16`).
- **`panel/test/test_house.dart`** — `loadTestHouse()`: real loader over the shipped placeholder assets via `dart:io` `File` (deliberate: binding-free `test()` bodies, tests run with package root as cwd).
- **`panel/test/dollhouse_test.dart`** — widget tests; local `makeController()` at lines 11-15 builds `HubController` + drift-frozen `FakeHub`; pumps `PanelApp(controller: ...)` four times.
- **`panel/test/golden/golden_setup.dart`** — `setUpPanelGoldens()` (fonts + comparator), `goldenTest` (real shadows), `pumpPanel(tester, controller, {size})` (lines 43-56) which pumps `PanelApp(controller: controller)` at 1280×800.
- **`panel/test/golden/dollhouse_golden_test.dart`** — four scenes into `test/golden/goldens/` (`ground_floor.png`, `upstairs_selected.png`, `device_popup.png`, `hub_offline.png`); local `fakeHub()` factory at 27-31; `_OfflineHub` adapter at 76-91. Comparator tolerance is 0; failures write diffs into `test/golden/failures/`.

---

## 3. Target design

### The module

**Name:** `bootPanel`, returning a `PanelBoot`, in a new file **`panel/lib/boot.dart`** (top level, sibling to `main.dart` — it composes the data and ui layers, so it belongs to neither).

**Seam placement:** between the environment edge (dart-define reads, asset reads — these stay in `main()`) and everything else. The module's interface accepts only **plain data**; all effects behind it are construction and logging.

**Interface (concrete Dart):**

```dart
// panel/lib/boot.dart
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'data/fake_hub.dart';
import 'data/ha_hub.dart';
import 'data/house_loader.dart';
import 'data/hub_client.dart';
import 'diagnostics/log.dart';
import 'domain/house.dart';
import 'ui/hub_controller.dart';

/// The ready-to-run Panel assembly: everything `main()` needs after reading
/// the environment, and everything a boot test needs to assert on.
class PanelBoot {
  PanelBoot({required this.hub, required this.controller, required this.hubLabel});

  /// The chosen Hub adapter. `main()` never touches it (the controller owns
  /// its lifecycle); boot tests assert kind selection on it.
  final HubClient hub;
  final HubController controller;

  /// The header badge's base text: 'FAKE HUB' for the in-memory Hub,
  /// 'HUB' for the real one. Travels as data — the widget tree must not
  /// know which Hub the build was compiled against.
  final String hubLabel;

  House get house => controller.house;
}

/// Boots the Panel from plain data: the House Plan's two YAML texts
/// (ADR-0004) and the Hub configuration as ordinary strings.
///
/// Error modes (all before any adapter is constructed for the bad path):
/// - unknown [hubKind] → [ArgumentError] 'unknown HUB "<kind>" (fake | ha)'
/// - [hubKind] == 'ha' with empty [hubToken] → [ArgumentError] (after
///   logging `hub.configured token=absent` — the breadcrumb for the crash)
/// - malformed House Plan → logs fatal `house.invalid`, rethrows the
///   loader's [FormatException]
///
/// Logs on the way up: `house.loaded` with name/floors/rooms/devices/bound
/// counts; for 'ha', `hub.configured` with the url and `token=set` —
/// never the token itself (see log.dart: **Never log a secret**).
///
/// [haConnect] is a test-only pass-through to [HaHubClient]'s existing
/// socket-injection seam; production callers must not pass it.
PanelBoot bootPanel({
  required String hubKind,
  required String hubUrl,
  required String hubToken,
  required String houseYaml,
  required String devicesYaml,
  @visibleForTesting WebSocketChannel Function(Uri)? haConnect,
}) { ... }
```

(`@visibleForTesting` comes from the `package:flutter/foundation.dart` import above — do **not** import `package:meta` directly: it is not a declared dependency in `panel/pubspec.yaml`, and the repo's `flutter_lints` include flags undeclared imports via `depend_on_referenced_packages`. If the pinned analyzer version rejects `@visibleForTesting` on a parameter, drop the annotation and keep the doc-comment sentence — the contract is the doc, the annotation is a bonus lint.)

**What hides inside:** kind dispatch (`fake` → `FakeHub(house)` with the production 3 s drift, `ha` → `HaHubClient`), both `ArgumentError` validations, the token-redaction rule, the `house.loaded` / `house.invalid` / `hub.configured` log events, the `HaHubClient.webSocketUrl(hubUrl)` call, the badge-label rule, and `HubController` assembly. Seven facts, one entry point — depth.

**Who calls it:** exactly two kinds of caller. `main()` (production), and `panel/test/boot_test.dart` (the module's own tests). **Not** widget tests, **not** golden tests — they keep injecting adapters at the `HubController` seam, which already serves them (verifier's explicit correction). One sentence of the verifier's after-sketch can be read as also routing the shared fixture helper (step 5) through `bootPanel`; that reading contradicts the verifier's own drift-freeze correction — the rig needs `FakeHub(house, driftEvery: Duration.zero)` and `_OfflineHub`, which `bootPanel` deliberately cannot express without the interface widening the verifier rejected. The helper therefore assembles at the `HubController` seam (resolved deliberately, not an oversight).

**What gets deleted:** `main.dart`'s `_loadHouse` and `_hub` in their entirety; the `_hubKind` read inside `PanelApp.build`; the `makeController()` factory in `dollhouse_test.dart` and the `fakeHub()` factory in `dollhouse_golden_test.dart` (collapsed into one shared fixture helper — see step 5).

### Before/after dependency sketch

```
BEFORE
main.dart ──reads──> String.fromEnvironment HUB/HA_URL/HA_TOKEN (compile-time)
main() ──calls──> _loadHouse   (private: loadHouse + loaded/invalid logging — unreachable)
main() ──calls──> _hub         (private: kind dispatch + validation + redacted log — unreachable)
PanelApp.build ──reads──> _hubKind const        ← LEAK: widget tree into composition root
HubController ──accepts──> house + HubClient    (good seam; adapters: FakeHub, HaHubClient, _OfflineHub)
dollhouse_test ──owns──> makeController()       (hand-rolled)
dollhouse_golden_test ──owns──> fakeHub() + _OfflineHub (hand-rolled)

AFTER
main() ──reads──> dart-defines + rootBundle     (the whole edge, nothing else)
main() ──calls──> bootPanel(plain strings) ──yields──> PanelBoot{hub, controller, hubLabel}
boot.dart ──hides──> kind dispatch · validation · token redaction
                     house.loaded / house.invalid / hub.configured · label rule
PanelApp ──receives──> hubLabel via constructor (const read deleted)
boot_test.dart ──calls──> bootPanel             (config/validation/log assertions)
widget & golden tests ──keep calling──> HubController seam via test/fixtures.dart
                                        (FakeHub driftEvery: zero, _OfflineHub)
```

---

## 4. Decision points

Each needs ratification by the user before or during implementation.

**D1 — Regenerate `hub_offline.png` with the production "HUB OFFLINE" label.**
This CHANGES a committed golden's rendered text (today it provably shows "FAKE HUB OFFLINE").
- Option A (recommended): the hub-unreachable golden passes `hubLabel: 'HUB'` and the golden is regenerated. The scene the golden exists to pin — what the wall shows in production when the Hub is down — becomes the scene it actually renders. This is the refactor's headline payoff.
- Option B: keep the fake label in the golden; add no production-label scene. Rejected by default: it preserves the exact defect the verifier confirmed.

**D2 — `PanelApp.hubLabel`: required parameter vs defaulted.**
- Option A (recommended): `required this.hubLabel`. Seam hygiene: the widget must not embed a guess about the Hub kind; every pump site states its label. Fixture convenience is recovered by giving `pumpPanel` (golden_setup) and the shared fixture helper a `'FAKE HUB'` default — a fixture default is a fact about fixtures, not about the widget.
- Option B: `this.hubLabel = 'FAKE HUB'` on PanelApp. Smaller diff, but re-hides a composition fact inside the widget layer — the same smell one layer down.

**D3 — How boot tests exercise the `ha` path.**
- Option A (recommended): the `haConnect` pass-through parameter shown above, forwarded to `HaHubClient`'s existing `connect` constructor parameter. This is not new widening — `HaHubClient` already established this exact internal seam for `ha_hub_test.dart`; boot merely forwards it. Tests hand it an idle channel and assert adapter kind, label, and the `hub.configured` record.
- Option B: no parameter; the ha-path test lets `HaHubClient` attempt a real socket to a dead url and disposes immediately. No interface addition, but nondeterministic log noise (`hub.connect_failed`/`hub.reconnecting`) and a needless live-socket attempt inside a unit test.
- Option C: split a pure `HubConfig.parse(...)` out of the effectful boot. Two entries where one suffices — shallower, rejected.

**D4 — Where the `HA_URL` default `'http://localhost:8123'` lives.**
- Option A (recommended): stays at main's edge, as today, in the const read: `String.fromEnvironment('HA_URL', defaultValue: 'http://localhost:8123')`. Dart-define defaults are facts about the environment read (exactly like `HUB` defaulting to `'fake'`); `bootPanel` treats `hubUrl` as given and its error modes stay crisp.
- Option B: `bootPanel` applies the default to an empty `hubUrl`. Makes the default assertable, but splits the dart-define contract across two files for one constant with zero logic.

**D5 — Shared fixture helper: new `panel/test/fixtures.dart` vs extending `test_house.dart`.**
- Option A (recommended): new file `panel/test/fixtures.dart` importing `test_house.dart`. `test_house.dart` stays exactly as is (it is imported by `fake_hub_test.dart`, `ha_hub_test.dart`, and others that need only the House). Coordination-friendly: plans 02 and 05 rewrite parts of the tests that will import the new file — a small new file merges more cleanly than edits to a shared old one.
- Option B: add the controller factory to `test_house.dart`. Fewer files, but couples House acquisition to widget-rig assembly for callers that want only the former.

---

## 5. Step-by-step implementation

Every step leaves `flutter analyze` and `flutter test` green. Paths are relative to `panel/`.

**Step 1 — Create `lib/boot.dart`.**
New file containing `PanelBoot` and `bootPanel` exactly as specified in §3. Implementation is a move of the bodies of `_loadHouse` (main.dart:38-58) and `_hub` (main.dart:65-86), with these transformations:
- `const which = _hubKind;` → the `hubKind` parameter; the `const url`/`const token` reads → the `hubUrl`/`hubToken` parameters.
- Preserve the existing log-then-throw ordering for the missing-token path: `hub.configured` with `token=absent` is emitted **before** the `ArgumentError` — that line is the crash's breadcrumb in journald.
- Preserve message texts verbatim: `'unknown HUB "$kind" (fake | ha)'` and `'HUB=ha needs --dart-define=HA_TOKEN=<long-lived token>; keep it out of the repo (hub/dev/token)'`.
- Add the label rule as the one new line of knowledge: `final hubLabel = hubKind == 'fake' ? 'FAKE HUB' : 'HUB';` (compute it after kind validation so an unknown kind throws rather than labelling).
- `HaHubClient` construction forwards `connect: haConnect`.
- Return `PanelBoot(hub: hub, controller: HubController(house: house, hub: hub), hubLabel: hubLabel)`.
Nothing calls it yet; tree stays green (`main.dart` untouched).

**Step 2 — Create `test/boot_test.dart`.**
Pin the module's contract before switching production onto it. Cases and fixtures in §6. Plain `test()` bodies, no binding needed (loader, FakeHub, HubController, Log are all binding-free). Run: green.

**Step 3 — Rewire `main.dart` and `PanelApp`.**
- `main()` becomes: `ensureInitialized` → `installErrorHandlers` → `panel.start` log (unchanged, still reads `_hubKind`) → the two `rootBundle.loadString` calls → `final boot = bootPanel(hubKind: _hubKind, hubUrl: _haUrl, hubToken: _haToken, houseYaml: ..., devicesYaml: ...)` → `runApp(PanelApp(controller: boot.controller, hubLabel: boot.hubLabel))`.
- Add edge consts next to `_hubKind` (its doc comment stays):
  ```dart
  const _haUrl = String.fromEnvironment('HA_URL', defaultValue: 'http://localhost:8123');
  const _haToken = String.fromEnvironment('HA_TOKEN');
  ```
- Delete `_loadHouse` and `_hub` entirely. Delete the imports main no longer needs (`fake_hub.dart`, `ha_hub.dart`, `house_loader.dart`, `hub_client.dart`, `house.dart`).
- `PanelApp` gains `required this.hubLabel` (String); line 120 becomes `label: hubLabel,`.
- Update the three files that pump `PanelApp` (found via `grep -rl 'package:panel/main.dart' panel/test`):
  - `test/golden/golden_setup.dart` — `pumpPanel` gains `String hubLabel = 'FAKE HUB'` and passes it through (fixture default per D2).
  - `test/dollhouse_test.dart` — each `pumpWidget(PanelApp(controller: controller))` gains `hubLabel: 'FAKE HUB'` (interim; step 5 tidies).
  - `test/golden/dollhouse_golden_test.dart` — no change yet (goes through `pumpPanel`).
- Goldens must NOT change in this step: every scene still renders `FAKE HUB`. Run the full suite to prove it.

**Step 4 — The true "HUB OFFLINE" scene (needs D1 ratified).**
In `dollhouse_golden_test.dart`'s `'hub unreachable'` test, pass `hubLabel: 'HUB'` to `pumpPanel`. Regenerate: `cd panel && flutter test --update-goldens test/golden`. Verify with `git status`/`git diff --stat` that **only `test/golden/goldens/hub_offline.png` changed**; eyeball it — red dot, badge reads "HUB OFFLINE", every Device pin in the unknown state. If any other PNG changed, stop and investigate before committing.

**Step 5 — Shared fixture helper (needs D5 ratified).**
New file `test/fixtures.dart`:
```dart
import 'package:panel/data/fake_hub.dart';
import 'package:panel/ui/hub_controller.dart';

import 'test_house.dart';

/// The standard widget/golden rig: the shipped House Plan, a drift-frozen
/// FakeHub (readings must not wander between pumps), and the controller —
/// injected at the HubController seam, NOT via bootPanel (boot's callers
/// are main() and boot_test only).
(HubController, FakeHub) fakeHubRig() {
  final house = loadTestHouse();
  final hub = FakeHub(house, driftEvery: Duration.zero);
  return (HubController(house: house, hub: hub), hub);
}
```
- `dollhouse_test.dart`: delete local `makeController()`, import `fixtures.dart`, use `fakeHubRig()`.
- `dollhouse_golden_test.dart`: delete local `fakeHub()`, use `fakeHubRig().$1`. `_OfflineHub` **stays in the golden file** — it is that suite's own adapter, and plan 02 owns those fakes.
- Full suite; goldens byte-identical to step 4's.

**Step 6 — Sweep.**
`grep -rn '_hubKind' panel/lib` must show only the edge consts in `main.dart` (the `panel.start` field and the `bootPanel` argument). `grep -rn 'FAKE HUB' panel/lib` must show only `boot.dart`. `cd panel && flutter analyze && flutter test`.

Files summary — created: `lib/boot.dart`, `test/boot_test.dart`, `test/fixtures.dart`. Modified: `lib/main.dart`, `test/dollhouse_test.dart`, `test/golden/golden_setup.dart`, `test/golden/dollhouse_golden_test.dart`, `test/golden/goldens/hub_offline.png` (regenerated). Deleted: nothing at file level (deletions are within `main.dart` and the two test factories). Untouched on purpose: `test/test_house.dart`, `lib/ui/hub_controller.dart`, `lib/data/*`, `lib/diagnostics/log.dart`.

---

## 6. Test plan

### New: `panel/test/boot_test.dart`

Setup mirrors `log_test.dart:7-16`: `setUp` installs `records = []; Log.sink = records.add; Log.level = LogLevel.debug;`, `tearDown` restores `Log.sink = Log.printRecord; Log.level = LogLevel.warn;` (the level `flutter_test_config.dart` sets). House Plan inputs are **inline YAML constants** in the style of `house_loader_test.dart:7-29` (deterministic counts, no cwd dependence, immune to other plans editing the placeholder assets). For the ha path, a ~20-line `_IdleChannel implements WebSocketChannel` (open `StreamController` that never emits; a sink whose `close()` works; `noSuchMethod` for the rest — the `FakeChannel` pattern from `ha_hub_test.dart:14-48`, minus the frame plumbing). Every test that constructs an assembly disposes it: `boot.controller.dispose()` (which disposes the hub and cancels FakeHub's drift timer).

Cases (names are the test descriptions):

1. `'fake kind assembles a FakeHub-backed controller with the FAKE HUB label'` — `bootPanel(hubKind: 'fake', hubUrl: '', hubToken: '', ...)`: `boot.hub is FakeHub`, `boot.hubLabel == 'FAKE HUB'`, `boot.controller.connected` is true, `boot.house.name` matches the inline plan.
2. `'ha kind assembles an HaHubClient with the HUB label'` — with `haConnect: (_) => _IdleChannel()`: `boot.hub is HaHubClient`, `boot.hubLabel == 'HUB'`, `boot.controller.connected` is false (not yet authenticated).
3. `'unknown kind throws ArgumentError naming the kind and the choices'` — `hubKind: 'mqtt'` → `throwsA(isA<ArgumentError>())` with message containing `'unknown HUB "mqtt" (fake | ha)'`; no `hub.configured` record emitted.
4. `'ha with empty token logs token=absent then throws'` — expect `ArgumentError`; `records` contain exactly one `hub.configured` with `fields['token'] == 'absent'`, and it was emitted (list is ordered) before the throw. **Pins the breadcrumb ordering for the first time.**
5. `'ha logs hub.configured with token=set and never the token text'` — token `'super-secret-token'`; the `hub.configured` record has `fields['token'] == 'set'`, and `records.map((r) => r.toString())` contains no element containing `'super-secret-token'`. **Pins the redaction rule (log.dart: "Never log a secret") for the first time.**
6. `'a valid House Plan logs house.loaded with the counts'` — record with area `house`, event `loaded`, fields `name/floors/rooms/devices/bound` matching the inline plan (include one Device with `entity:` and one without so `bound < devices`). **Pins the boot diagnostics story for the first time.**
7. `'a malformed House Plan logs house.invalid and rethrows'` — devicesYaml referencing a missing room → `throwsA(isA<FormatException>())`; one record with level `error`, area `house`, event `invalid`, non-null `error`. **Pins the kiosk's greppable-line-on-the-way-out contract.**

### Existing tests that change

- `dollhouse_test.dart` — loses `makeController()`, gains `fixtures.dart` import and `hubLabel: 'FAKE HUB'` at pump sites (or via rig; four `testWidgets` bodies otherwise unchanged).
- `dollhouse_golden_test.dart` — loses `fakeHub()`, keeps `_OfflineHub`, `'hub unreachable'` passes `hubLabel: 'HUB'`.
- `golden_setup.dart` — `pumpPanel` gains the `hubLabel` parameter (default `'FAKE HUB'`).
- Nothing dies. `test_house.dart`, `fake_hub_test.dart`, `ha_hub_test.dart`, `ha_hub_live_test.dart`, `house_loader_test.dart`, `log_test.dart`, `plan_geometry_test.dart` are untouched.

### Golden impact

Exactly one PNG changes: `test/golden/goldens/hub_offline.png` ("FAKE HUB OFFLINE" → "HUB OFFLINE", D1). Regenerate with `cd panel && flutter test --update-goldens test/golden`; the comparator tolerance is 0, so any other diff is a bug in this refactor. Failure diffs, if needed, appear in `test/golden/failures/`.

### Contract summary — pinned for the first time

Unknown-kind and missing-token `ArgumentError` modes and their message texts; the `hub.configured` redaction (`token=set`/`absent`, never the value) and its emit-before-throw ordering; the `house.loaded` count fields including `bound`; the fatal `house.invalid` + rethrow; the badge-label rule as data (`fake`→`FAKE HUB`, `ha`→`HUB`); and — via the regenerated golden — the production Hub-down scene.

---

## 7. Verification

```sh
cd panel && flutter analyze && flutter test
```

Golden regeneration (step 4 only): `cd panel && flutter test --update-goldens test/golden`, then inspect `git diff --stat` — only `hub_offline.png` may change.

Live check, if wanted: **this Mac has Flutter via brew but NO Xcode** — never `flutter run -d macos`. Use the web build: `cd panel && flutter run -d chrome` (default fake build shows "FAKE HUB"); a `--dart-define=HUB=ha --dart-define=HA_URL=... --dart-define=HA_TOKEN=...` run against the dev Hub (see `hub/dev/README.md`) shows "HUB" and, with the Hub stopped, the newly-honest "HUB OFFLINE".

---

## 8. Non-goals

Straight from the verifier's discipline notes — repeat these to whoever touches this next:

- **Widget and golden tests are NOT routed through the boot module.** The verifier was explicit: they keep injecting `FakeHub(driftEvery: Duration.zero)` and `_OfflineHub` at the `HubController` seam, which is already the right one with two real production adapters. Forcing them through `bootPanel` would grow adapter-injection and drift knobs on its interface — a shallow module with a widened interface.
- **No `driftEvery` or adapter-injection parameters on `bootPanel`** (the sole, documented exception is the `haConnect` pass-through of D3, which forwards a seam `HaHubClient` already has).
- **`HaHubClient.webSocketUrl` does not move** and gets no new plumbing — it is already a public static and already testable (the original candidate overstated this).
- **`test_house.dart`'s `File`-based House Plan reads stay** — deliberate fixture variation so binding-free `test()` bodies work; not re-grown composition.
- **The `LOG` dart-define stays in `log.dart`**, and `panel.start` (with its `kReleaseMode`/`kIsWeb` environment facts) stays in `main()` — environment edge, not composition.
- **`PanelApp` stays in `main.dart`**; no `HubClient`/`HaHubClient`/ADR-0002 surface changes; no `_HubBadge` semantics changes (that is plan 07's).
- **Deferred, with its trigger written down:** when go2rtc Popup configuration arrives (it is coming — CONTEXT.md's Popup, ADR-0002's consequences), it enters `bootPanel` as more plain-data inputs; it must not become new `String.fromEnvironment` consts scattered through `main.dart` or the widget tree.

---

## 9. Cross-plan coordination

The review produced a set of 8 plans, numbered `docs/plans/01-*.md` … `docs/plans/08-*.md` (this is 08). On disk at fact-check time (HEAD 105610c), four exist: `docs/plans/01-device-presentation-module.md`, `docs/plans/05-floor-arrangement-module.md`, `docs/plans/07-hub-status-three-state.md`, and this file. Plans 02, 03, 04 and 06 are referenced by number in the notes below but had no files yet — run `ls docs/plans/` before implementing, and treat notes about absent plans as forward guidance, not as landed work. Verbatim coordination notes from the review that produced this plan:

- **Implement this LAST (or rebase): plan 07 changes badge semantics (three-state), plan 02 changes the golden suite's fakes, plan 01 changes tap routing — all touch files you reorganize.**
- **Your shared test fixture helper consolidates hand-rolled factories in dollhouse_test and the golden suite — plans 02 and 05 also rewrite parts of those tests; coordinate.**
- **Widget/golden tests keep injecting at the HubController seam — do NOT route them through the boot module (the verifier was explicit); repeat that non-goal.** (Repeated in §8.)

Additional observations from writing this plan:

- Plan 07's three-state badge survives this refactor cleanly if it keeps treating the label as data: `hubLabel` is orthogonal to `connected`'s arity. If plan 07 lands first, rebase step 3's `_HubBadge` touch (main.dart:120) onto its new badge; the label-as-constructor-data principle is unchanged.
- Plan 02 owns the golden suite's fakes: `_OfflineHub` deliberately stays in `dollhouse_golden_test.dart` here so plan 02 can move/replace it without colliding with `fixtures.dart`. If plan 02 lands first and relocates the factories, step 5 shrinks to pointing its helper at `fakeHubRig()` (or adopting its equivalent).
- Plan 01 rewrites tap routing (`dollhouse_view.dart`'s `_onDeviceTap`) and, per its own files-modified list, adds one test to `dollhouse_test.dart`; this plan only touches that file's setup lines (imports, rig, `hubLabel`), so conflicts are mechanical. Plan 01 also records a behaviour-change decision of the same kind as D1 here (unknown-state light taps: toggle vs Popup) — same ratification pattern.
- The `hub_offline.png` regeneration (D1), checked against plan 07's actual text: plan 07 does **not** regenerate that golden — its step 4 explicitly requires `hub_offline.png` byte-identical after its changes, and its new scene is `hub_gave_up.png`. So D1 is the only planned change to that PNG. If plan 07 lands first, D1 regenerates on top of its badge rendering; if this plan lands first, plan 07's "should not change" check then runs against the regenerated "HUB OFFLINE" image (still a valid check). Either order: regenerate once per landing, and never rubber-stamp a diff the landing plan didn't predict.

---

## 10. Sources

- `/Users/dmorozov/Work/ITConsulting/SmartHome/CONTEXT.md` — domain language (Panel, Hub, Dollhouse, House Plan, Floor, Room, Wall, Device, Popup).
- `/Users/dmorozov/Work/ITConsulting/SmartHome/.claude/skills/codebase-design/SKILL.md` — deep module, interface, seam, adapter, depth, leverage, locality, deletion test.
- `/Users/dmorozov/Work/ITConsulting/SmartHome/docs/adr/0001-plain-linux-kiosk-not-fuchsia-or-chromeos.md`, `0002-home-assistant-headless-hub.md`, `0003-zigbee-z2m-not-matter-thread.md`, `0004-house-plan-sweet-home-3d-yaml-pipeline.md`.
- Originating architecture review: candidate 7 ("Panel composition root: untestable wiring, with the compile-time Hub kind leaking into the widget tree") plus its adversarial verification verdict — produced as a temp HTML report, ephemeral; the load-bearing findings and corrections are reproduced in §1 of this document.
- Code read at commit 105610c: `panel/lib/main.dart`, `panel/lib/ui/hub_controller.dart`, `panel/lib/data/{hub_client,fake_hub,ha_hub,house_loader}.dart`, `panel/lib/diagnostics/log.dart`, `panel/test/{test_house,dollhouse_test,fake_hub_test,ha_hub_test,house_loader_test,log_test,flutter_test_config}.dart`, `panel/test/golden/{dollhouse_golden_test,golden_setup}.dart`, `panel/test/golden/goldens/*.png`.
