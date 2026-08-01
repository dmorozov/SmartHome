# HubClient contract suite + scriptable FakeHub

One contract suite runs against both Hub adapters, the toggle invariant moves behind the seam where both adapters enforce it identically, and FakeHub gains a driving surface (push a state, drop a Device to unknown, set reachability) that replaces every hand-rolled `HubClient` stand-in.

Status: proposed · Strength: Strong · Written 2026-08-01 against commit 105610c (committed 2026-07-31) — re-verify line numbers before editing.

---

## 1. Why this refactor

The `HubClient` seam is real — two adapters exist and `main.dart` selects between them — but it delivers no contract-level leverage. Two reinforcing problems, every claim verified line-by-line against commit 105610c.

### 1a. The toggle invariant is prose, and the two adapters disagree about it

`panel/lib/data/hub_client.dart:19-21` states the invariant in a doc comment only:

```dart
  /// Flip a Device that has a binary state (light, outlet, TV, garage
  /// door). No-op for anything else.
  Future<void> toggle(String deviceId);
```

Only FakeHub honors it, and it does so by pattern-matching the *live state's shape*, not the Device kind — `panel/lib/data/fake_hub.dart:45-52`:

```dart
  @override
  Future<void> toggle(String deviceId) async {
    final next = switch (_states[deviceId]) {
      SwitchState s => SwitchState(deviceId, on: !s.on),
      GarageDoorState g => GarageDoorState(deviceId, open: !g.open),
      _ => null,
    };
    if (next != null) _apply(next);
  }
```

HaHubClient sends `homeassistant.toggle` for ANY bound entity — the only guard is `entityId == null` — `panel/lib/data/ha_hub.dart:89-108`:

```dart
  @override
  Future<void> toggle(String deviceId) async {
    final device = _byEntity.values.where((d) => d.id == deviceId).firstOrNull;
    final entityId = device?.entityId;
    if (entityId == null) {
      // ...
      Log.warn('hub', 'toggle_unbound', {'device': deviceId});
      return;
    }
    // ...
    _send({
      'id': _nextId++,
      'type': 'call_service',
      'domain': 'homeassistant',
      'service': 'toggle',
      'target': {'entity_id': entityId},
    });
  }
```

Concretely: the thermostat Device binds to `climate.ecobee` (`panel/assets/house/devices.yaml`, hall section). Home Assistant's `homeassistant.toggle` delegates per-domain — for `climate.*` that is `climate.toggle`, which **flips the real HVAC**. For sensor-backed Devices (washer → `sensor.lg_washer`) the call merely fails on the Hub and surfaces as a `command_failed` warn (`ha_hub.dart:199-204`). So the interface's "No-op for anything else" is false for the production adapter, and false in the worst way for exactly one Device kind that exists in the shipped House Plan today.

The sole protection is caller-side. `panel/lib/ui/dollhouse/dollhouse_view.dart:190-208`, `_onDeviceTap`, re-derives togglability by pattern-matching `DeviceState` subtypes:

```dart
    final isVideo = device.kind == DeviceKind.camera ||
        device.kind == DeviceKind.doorbell;
    final toggles = !isVideo && (state is SwitchState || state is GarageDoorState);
```

That is **four statements of one fact** — interface prose, fake's behaviour, real adapter's behaviour, caller's guard — and two of them contradict each other.

**The deletion test, re-run by the verifier:** delete the view guard at `dollhouse_view.dart:194` and behaviour changes *nothing* under FakeHub but sends `homeassistant.toggle` to the climate entity under HaHubClient. The invariant lives in the caller, not behind the seam — and worse, the default build masks its absence: `main.dart:63`:

```dart
const _hubKind = String.fromEnvironment('HUB', defaultValue: 'fake');
```

Development runs the adapter that hides the divergence. No test warns of it either: `ha_hub_test.dart:162-174` only toggles a bound light (`light-hall`), and `fake_hub_test.dart:30-36` pins the no-op **against the fake only**:

```dart
  test('toggle is a no-op for devices without a binary state', () async {
    final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    final before = hub.states['thermostat'];
    await hub.toggle('thermostat');
    expect(hub.states['thermostat'], same(before));
    hub.dispose();
  });
```

A contract case "toggle on a non-binary Device sends nothing / changes nothing" would FAIL against HaHubClient today.

### 1b. FakeHub cannot script the world, and the test tree already routes around it

FakeHub's `connected` is hardwired and never mutated — `fake_hub.dart:31`:

```dart
  /// Always up: the fake Hub is in this process.
  @override
  final ValueNotifier<bool> connected = ValueNotifier(true);
```

Its `_apply` is private (`fake_hub.dart:61-64`), and its only mutators are `toggle` plus a random drift timer. So the substitute adapter cannot produce the behaviours the Panel most needs verified: the OFFLINE badge transition (`main.dart:151-193`, `_HubBadge` — the feature `hub_client.dart:8-9` exists for), "pin re-renders on a pushed state", "Device drops to unknown".

The verifier's correction to the original candidate (load-bearing, keep it): **the OFFLINE badge is not entirely untested** — the *static* Hub-down scene is golden-tested, but only because the golden suite hand-rolled a third adapter, `_OfflineHub`, `panel/test/golden/dollhouse_golden_test.dart:76-91`:

```dart
/// What the wall shows when the Hub is down: red badge, and every Device
/// unknown rather than frozen on its last reading. The most important scene
/// to be able to recognise at a glance, and the hardest to reach by hand.
class _OfflineHub implements HubClient {
  @override
  final ValueNotifier<bool> connected = ValueNotifier(false);

  @override
  Map<String, DeviceState> get states => const {};
  // ...
}
```

The scattering the deletion test predicts has already happened once: the tree holds **three Hub-faking constructs** (FakeHub, `_OfflineHub`, `FakeChannel` in `ha_hub_test.dart:14-48`) plus the live dev Hub. The verifier's second correction: the listed widget tests are not "impossible" — they are expressible by driving HaHubClient with FakeChannel JSON frames or more one-off adapters, i.e. only by **routing around FakeHub at the wrong seam**. What has zero tests is the *dynamic* story: OFFLINE badge appearing and clearing as the Hub drops and returns, a pin re-rendering when a `StatusState` arrives, a pin falling to unknown. `dollhouse_test.dart:45-55`'s deepest state assertion is a toggle flip.

The verifier's third correction: the caller-side guard does **not** "delete for free". The toggle-vs-Popup routing branch in `_onDeviceTap` stays; what deletes is the `DeviceState`-subtype pattern match — and a kind-based answer changes one edge (an unknown-state light would toggle instead of opening its Popup), which needs one deliberate decision (Decision D1 below).

### 1c. Extra findings from plan-writing (not in the candidate or verdict)

Discovered while reading for this plan; both feed the design:

1. **Drop-to-unknown is invisible to the UI in production.** `ha_hub.dart:246-264` (`_applyEntity`, the `state == null` branch) removes the Device from `_states` and logs `state_unusable`, but never emits on `_changes`. `HubController` only repaints on `stateChanges` and `connected` (`hub_controller.dart:13-16`), so a pin whose entity goes `unavailable` keeps showing its **stale reading until some unrelated Device changes state**. Any widget test "pin falls to unknown" written through the seam would expose this. The seam's change-notification shape must carry drops (Decision D3).

2. **`_OfflineHub`'s doc comment misdescribes the production mid-run behaviour.** HaHubClient does *not* clear `_states` on disconnect (`_reconnect`, `ha_hub.dart:142-165`, tears down the socket and flips `connected` but never touches `_states`), so a mid-run outage shows *frozen readings + OFFLINE badge* — exactly what `hub_client.dart:8-9` intends ("my readings are stale has to be visible"). `_OfflineHub`'s empty `states` actually depicts a *cold start with the Hub down*. Both are real scenes; this plan keeps the golden's pixels identical and defers any semantic re-shoot (Non-goals, and plan 08's territory).

3. **`HaHubClient.toggle` finds Devices by linear scan over bound entities** (`ha_hub.dart:90`: `_byEntity.values.where((d) => d.id == deviceId)`), so unbound Devices are found as `null` and fall into `toggle_unbound`. The new `_byId` index (Step 3) makes lookup direct and lets `togglable` answer for unbound Devices too.

### Why now

The repo is two days old (first commit 2026-07-30) so churn history is no signal either way — but this is not a speculative future need: the contract violation and the test-surface fragmentation exist today. Every future call site that might call `toggle` (`toggleRoomLights` at `hub_controller.dart:40-49` today, Automation triggers later) currently has to re-derive the guard or risk toggling HVAC.

---

## 2. Context a fresh session needs

### Domain vocabulary (CONTEXT.md — use these words, quote of the definitions this plan relies on)

- **Panel**: "The wall-mounted touchscreen running the custom dollhouse UI." (Avoid: kiosk, dashboard, screen.)
- **Hub**: "The headless smart-home broker (Home Assistant) that owns device state, integrations, and automations. The Panel is its client, never its replacement." (Avoid: server, backend, HA in domain discussion.)
- **Dollhouse**: "The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms."
- **House Plan**: "The Panel-side description of the house's geometry — Floors with their Rooms and Walls, authored by the family. The Dollhouse renders it; the Hub never sees it."
- **Floor**: "One level of the house in the Dollhouse … Floors stack; tapping one expands it."
- **Room**: "A named area on a Floor. … Rooms display aggregate state (lit, occupied) and hold pinned Devices. Tapping a Room acts on it (e.g. toggles its lights)."
- **Wall**: "A boundary segment drawn on the House Plan."
- **Device**: "A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse." (Avoid: entity — "that is the Hub's internal term".)
- **Popup**: "A transient full-or-partial-screen overlay on the Panel, e.g. live doorbell video on ring."
- **Automation**: "A rule that reacts to Device state … Automations live in the Hub only; the Panel merely displays and triggers."

### Design vocabulary (.claude/skills/codebase-design/SKILL.md — use exactly, never component/service/API/boundary)

A **module** is anything with an **interface** (everything a caller must know: signatures *plus* invariants, error modes, ordering) and an implementation. A module is **deep** when a lot of behaviour sits behind a small interface; depth gives callers **leverage** (more behaviour per unit of interface learned) and maintainers **locality** (fix once, fixed everywhere). A **seam** is where an interface lives — the place behaviour can be altered without editing there; an **adapter** is a concrete thing satisfying the interface at a seam. **The deletion test**: delete the module — if complexity reappears across N callers, it was earning its keep. **The interface is the test surface**: callers and tests cross the same seam; wanting to test past the interface means the module is the wrong shape. "One adapter means a hypothetical seam. Two adapters means a real one."

### ADR constraints (binding sentences, quoted)

- **ADR-0002** (Home Assistant headless Hub): "The Hub is a black-box appliance: versions pinned, updated on our schedule, internals never modified." And: "Automations live in the Hub's native engine; the Panel is a pure view/command layer." And: "A small Dart JSON-over-WebSocket client for HA must be hand-rolled (the official maintained client is JS)." → Everything in this plan is Panel-side; nothing reaches into the Hub. Verified by the review: **no ADR conflict**.
- **ADR-0004** (House Plan pipeline): "`devices.yaml` (id, name, kind, local/cloud, room reference, position in meters, later the Hub entity-id mapping) is **hand-maintained and never touched by the converter**." → The hand-maintained Device *kind* is exactly the fact the toggle refusal keys on. Kinds in the file: `light | outlet | thermostat | camera | doorbell | oven | tv | washer | dryer | litter-robot | feeder | garage-door | ev-charger | energy-monitor`.
- **ADR-0001** (plain Linux kiosk): "Flutter vs web UI stays reversible — both run on the identical substrate" → relevant only to verification: the web build is a faithful check surface.
- **ADR-0003** (Zigbee/Z2M): no bearing on this plan.

### Current-architecture tour (what each file does today)

- **`panel/lib/data/hub_client.dart`** (24 lines) — the seam. `abstract interface class HubClient` with four members: `ValueListenable<bool> get connected` ("Whether the Panel currently has the Hub. A wall display has nobody watching a console, so 'my readings are stale' has to be visible.", lines 8-10), `Map<String, DeviceState> get states` ("A Device absent from the map has unknown state.", 12-14), `Stream<DeviceState> get stateChanges` ("Emits each state change after it has been applied to [states].", 16-17), `Future<void> toggle(String deviceId)` (19-21, prose invariant quoted in §1a), `void dispose()`.
- **`panel/lib/data/ha_hub.dart`** (319 lines) — the production adapter. Deep: token handshake (`auth_required`/`auth_ok`/`auth_invalid`, lines 173-197), snapshot + delta subscription (183-188), endless backoff reconnect (`_reconnect`, 142-165, floor→ceiling doubling), entity→DeviceState fold by Device **kind** not entity domain (`_toDeviceState`, 281-312), missing-entity reporting (215-233), drop-to-unknown with once-per-outage logging (246-279). Constructor takes `WebSocketChannel Function(Uri)? connect` — the internal seam `ha_hub_test.dart` drives. Builds `_byEntity` (entityId → Device) only, from the House (40-43).
- **`panel/lib/data/fake_hub.dart`** (104 lines) — the development adapter. Seeds a plausible state for every Device in the House by kind (`_initialState`, 86-103), answers toggles instantly by state shape (45-52), drifts thermostat/power readings on a timer (66-84; `driftEvery: Duration.zero` disables for deterministic tests). `connected` hardwired `true` (31); `_apply` private (61-64). Logs `fake_ready` at construction.
- **`panel/lib/ui/hub_controller.dart`** (58 lines) — presentation state: folds House + live state into one `ChangeNotifier`. `_sub = hub.stateChanges.listen((_) => notifyListeners())` (line 14) — the payload is ignored. Passthroughs: `connected`, `stateOf`, `isOn`, `isRoomLit`, `toggle`, `toggleRoomLights` (kind == light filter, 40-49). Owns and disposes the hub.
- **`panel/lib/ui/dollhouse/dollhouse_view.dart`** — the Dollhouse. `_onDeviceTap` (190-208) is the tap-routing site quoted in §1a; logs `ui.device` with `action` and `known` fields.
- **`panel/lib/ui/dollhouse/floor_view.dart`** — one Floor as an isometric slab. Pins keyed `ValueKey('pin-${device.id}')` (line 102). `_DevicePin` (120-170) renders a reading string for `ThermostatState` (`'21.4°'` style, `toStringAsFixed(1)`) and `PowerState` (`'812W'` / `'1.2kW'`), an icon (`deviceIcon(device.kind)`, defined in `panel/lib/ui/theme.dart:38`) otherwise; `on`/glow from `SwitchState`/`GarageDoorState`.
- **`panel/lib/main.dart`** — `_hubKind` dart-define selection (60-86, quoted in §1a); `_HubBadge` (151-193) renders `'$label OFFLINE'` and a red dot when `connected` is false; label is `'FAKE HUB'` when `_hubKind == 'fake'` (line 120) — which is the value in every test, since tests get the dart-define default.
- **`panel/lib/domain/device_state.dart`** — `sealed class DeviceState` + `SwitchState(on)`, `ThermostatState(currentC, targetC)`, `GarageDoorState(open)`, `PowerState(watts)`, `StatusState(status)`.
- **`panel/lib/domain/house.dart`** — `House`/`Floor`/`Room`/`Wall`/`Device` + `enum DeviceKind` (14 kinds, lines 123-138) + `enum Connectivity`. `Device.entityId` nullable ("Null while a Device has no Hub counterpart yet — it still renders, with unknown state.").
- **`panel/lib/diagnostics/log.dart`** — structured one-line events; tests capture via `Log.sink = records.add` and assert on `LogRecord` (area/event/fields), pattern at `ha_hub_test.dart:178-184`.
- **Tests**: `fake_hub_test.dart` (seeding, toggle flip + emission, fake-only no-op); `ha_hub_test.dart` (FakeChannel at 14-48, `connectAndSeed` handshake helper at 59-66, fold/ignore/delta/unavailable/toggle/snapshot-report/reconnect cases); `dollhouse_test.dart` (expand floor, tap light pin toggles, doorbell Popup); `test/golden/dollhouse_golden_test.dart` (four scenes incl. `_OfflineHub`); `test/golden/golden_setup.dart` (`setUpPanelGoldens`, `goldenTest`, `pumpPanel` at 1280×800, real fonts, exact comparator); `test/test_house.dart` (`loadTestHouse()` reads the real shipped `assets/house/*.yaml` from disk). Useful test ids from `devices.yaml`: `light-hall` → `input_boolean.light_hall` (hall, ground floor), `thermostat` → `climate.ecobee` (hall), `energy-monitor` → `sensor.emporia_vue` (garage), `washer` → `sensor.lg_washer`, `doorbell` (hall), `litter-robot` (upstairs landing).

---

## 3. Target design

Two moves that together make the seam a real contract: **togglability becomes a fact the seam owns**, and **FakeHub deepens into the scriptable development Hub**. Result: one contract suite runs against BOTH adapters; the golden suite's third adapter dies; the dynamic Hub stories become widget-testable through the adapter dev builds already use.

### 3.1 The togglability fact — one statement, domain-side

Minted in `panel/lib/domain/house.dart` as an enhanced-enum getter. Same truth table as plan 01's declaration but not the same shape: plan 01 (`docs/plans/01-device-presentation-module.md`, its D6) mints `DeviceKindTraits.toggles`, an *extension* on `DeviceKind` in a new `panel/lib/domain/device_traits.dart`. Whichever plan lands first owns the declaration and the second consumes it as-is (see Cross-plan coordination) — if plan 01 or plan 06 already landed, skip minting and read their declaration wherever this plan says `kind.togglable`:

```dart
enum DeviceKind {
  // ... existing 14 values ...
  ;

  /// Whether Devices of this kind carry a binary state the Panel may flip.
  /// The single statement of the togglability fact: the HubClient seam
  /// enforces it, the Dollhouse routes taps by it. (Eventual home: the
  /// domain vocabulary table, plan 06.)
  bool get togglable => switch (this) {
        DeviceKind.light ||
        DeviceKind.outlet ||
        DeviceKind.tv ||
        DeviceKind.garageDoor =>
          true,
        _ => false,
      };
}
```

This is pure Dart, no imports — deliberately, so the domain stays dependency-free.

### 3.2 The deepened HubClient interface

`panel/lib/data/hub_client.dart` after (concrete signatures; `stateChanges` retype is Decision D3):

```dart
abstract interface class HubClient {
  /// Whether the Panel currently has the Hub. A wall display has nobody
  /// watching a console, so "my readings are stale" has to be visible.
  ValueListenable<bool> get connected;

  /// Current state of every known Device, keyed by Device id. A Device
  /// absent from the map has unknown state.
  Map<String, DeviceState> get states;

  /// Emits the id of each Device whose entry in [states] just changed —
  /// including a drop to unknown, where the id is no longer in the map.
  Stream<String> get stateChanges;

  /// Whether [toggle] would act on this Device: true only for Device kinds
  /// with a binary state (light, outlet, TV, garage door), false for ids
  /// the House does not contain. Answered from the House, never from live
  /// state — a light with unknown state still toggles.
  bool togglable(String deviceId);

  /// Flip a Device with a binary state. Refuses — observably, with one
  /// `hub.toggle_refused` warn line, touching neither [states] nor the
  /// Hub — any Device for which [togglable] is false.
  Future<void> toggle(String deviceId);

  void dispose();
}
```

What deepened: the invariant moved from prose into an **enforced, observable behaviour** plus a queryable member. Callers stop pattern-matching `DeviceState` subtypes; the "which Devices toggle" fact collapses from four statements (two of them contradictory) into one domain declaration enforced at one seam.

### 3.3 Both adapters enforce identically

Both adapters build a `Map<String, Device> _byId` from the House they already receive. Both implement:

```dart
@override
bool togglable(String deviceId) => _byId[deviceId]?.kind.togglable ?? false;
```

Both open `toggle` with the same guard and the same log line (identity pinned by the contract suite, Decision D2):

```dart
final device = _byId[deviceId];
if (device == null || !device.kind.togglable) {
  Log.warn('hub', 'toggle_refused',
      {'device': deviceId, 'kind': device?.kind.name});
  return;
}
```

HaHubClient keeps its second, distinct guard afterwards — `toggle_unbound` for a togglable Device with no `entityId` — because that is a different failure ("Hub doesn't know this Device yet") with a different fix (edit `devices.yaml`).

### 3.4 FakeHub: the scriptable development Hub

FakeHub keeps `implements HubClient` and gains a small **driving surface** — concrete methods on the concrete type, used by tests and by its own built-in seed+drift script (the interface stays untouched; the driving surface is exactly the "internal seam used by its own tests" pattern from the design skill):

```dart
class FakeHub implements HubClient {
  FakeHub(House house, {Duration driftEvery = const Duration(seconds: 3)});

  // ── HubClient (unchanged surface, now enforced) ─────────────────────

  // ── Driving surface: how a test (or the drift script) moves the world ──

  /// The world reports [state]: applied to [states], its Device id emitted
  /// on [stateChanges]. Accepts any Device id — the fake never validates
  /// against the House, so tests can stage whatever they need.
  void pushState(DeviceState state);

  /// The world loses a Device: removed from [states] (drop to unknown),
  /// its id emitted on [stateChanges]. No-op if already unknown.
  void dropDevice(String deviceId);

  /// The world drops or returns the Hub: sets [connected]. (Today this
  /// sets the bool; if plan 07 landed first, it sets the three-state
  /// status — see Cross-plan coordination.)
  void setReachable(bool reachable);
}
```

Inside: `_apply` becomes `pushState` (public); the constructor seeds through it; `_drift()` becomes the one built-in script over the surface (it calls `pushState`). `connected` stays a `final ValueNotifier<bool>` field; `setReachable` mutates `.value`; the "/// Always up" comment dies. `toggle` on a togglable Device with unknown state pushes the toggled-from-off state (`SwitchState(on: true)` / `GarageDoorState(open: true)`) — the real Hub knows the entity even when the Panel does not, so the fake models the toggle landing (part of Decision D1).

### 3.5 Who calls what, what dies

- `DollhouseView._onDeviceTap` asks the seam: `final toggles = widget.controller.togglable(device.id);` — the `isVideo` line and the `DeviceState`-subtype pattern match delete (camera/doorbell kinds are simply not togglable). The toggle-vs-Popup branch and the `ui.device` log line stay.
- `HubController` gains the one-line passthrough `bool togglable(String deviceId) => _hub.togglable(deviceId);`. `toggleRoomLights` keeps its kind filter (now a redundant belt over the seam's braces — fine, it's selection logic, not a guard).
- `_OfflineHub` (dollhouse_golden_test.dart:76-91) **is deleted**; the `hub unreachable` golden scene is scripted through FakeHub (drop every Device, `setReachable(false)`) — observably identical, so `goldens/hub_offline.png` should not change by a pixel.
- `fake_hub_test.dart`'s fake-only no-op test dies, superseded by the contract case that runs against both adapters.
- `FakeChannel` moves out of `ha_hub_test.dart` into `panel/test/support/fake_channel.dart` so the contract suite can drive HaHubClient through it.

### 3.6 Before/after dependency sketch

```
BEFORE
  hub_client.dart  HubClient {connected, states, stateChanges, toggle}
        ▲                    invariant: PROSE ONLY
        ├── ha_hub.dart    HaHubClient   toggle → homeassistant.toggle for ANY bound entity  ✗ violates prose
        ├── fake_hub.dart  FakeHub       toggle → switch on state SHAPE ✓ honors prose
        │                                connected hardwired true · _apply private → unscriptable
        └── dollhouse_golden_test.dart  _OfflineHub (3rd adapter, hand-rolled for one scene)
  dollhouse_view.dart  _onDeviceTap: OWNS the guard (DeviceState-subtype pattern match)
  tests: fake_hub_test pins fake-only no-op · ha_hub_test drives via FakeChannel (never a non-binary toggle)

AFTER
  domain/house.dart  DeviceKind.togglable          ← the ONE statement of the fact
  hub_client.dart    HubClient {connected, states, stateChanges(ids incl. drops), togglable, toggle}
        ▲                    invariant: ENFORCED + observable (hub.toggle_refused)
        ├── ha_hub.dart    HaHubClient   guard(kind) → guard(entity) → send; drop-to-unknown now emits
        └── fake_hub.dart  FakeHub       guard(kind) → pushState
                            driving surface: pushState / dropDevice / setReachable
                            seed + drift = built-in script over that surface
  dollhouse_view.dart  _onDeviceTap: asks controller.togglable (no state pattern match)
  tests: hub_contract_test.dart runs ONE suite against BOTH adapters
         (FakeHub directly · HaHubClient via test/support/fake_channel.dart)
         dollhouse_test drives badge/push/drop through FakeHub's surface
         golden suite scripts FakeHub — _OfflineHub deleted
```

---

## 4. Decision points

**D1 — Unknown-state togglable Device tap: toggle (kind-keyed) or Popup (state-keyed)?** *This is the one behaviour change in the plan.* Today a light whose state is unknown opens its Popup showing "Unknown" (because `state is SwitchState` fails); after the change it toggles. Options: (a) kind-keyed toggle — **recommended**: a pin's affordance must not flap with state availability; a wall-panel tap on a light should always try to act, the OFFLINE badge already explains dead taps, and the production Hub can execute the toggle even when the Panel's knowledge lapsed (snapshot gap, transient `unavailable`). (b) Keep state-keyed Popup for unknown state — preserves today's behaviour but re-imports live-state logic into the routing, half-defeating the point. Sub-choice under (a): FakeHub toggling an unknown-state togglable Device pushes `on: true`/`open: true` (recommended — models the Hub acting and replying) vs stays a silent no-op (makes the widget test unassertable). **Plan 01 faces this same decision; whichever plan lands first records the ratified answer and the other adopts it.**

**D2 — Refusal guard: duplicated per adapter, or shared helper?** Options: (a) each adapter opens `toggle` with the same 5-line guard, and the contract suite pins that both refuse with the identical `hub.toggle_refused` event and fields — **recommended**: the *fact* already lives in one place (`DeviceKind.togglable`); the guard is mechanical; a shared helper would drag `Log` into `hub_client.dart` and export a function to save three lines, and the contract suite is the drift alarm. (b) A shared top-level `bool refuseUntogglable(Device? device, String deviceId)` in `hub_client.dart`. Revisit trigger: a third production adapter appears.

**D3 — How does the seam announce a drop to unknown?** Today `stateChanges` is `Stream<DeviceState>`, and a drop has no `DeviceState` to emit — which is why HaHubClient silently doesn't emit (finding §1c-1) and the UI misses drops. Options: (a) retype to `Stream<String>` of changed Device ids, drops included — **recommended**: it matches the only production caller exactly (`HubController` ignores the payload, `hub_controller.dart:14`), keeps the interface at one member, and makes "Device drops to unknown" contract-testable; tests that asserted payloads read `states` after the emission instead. (b) Keep `Stream<DeviceState>` and add `Stream<String> get stateDrops` — two overlapping members, wider interface. (c) A sealed `StateChange` event hierarchy — the richest, but pays interface for expressiveness nobody consumes yet. (a) also fixes the production stale-pin repaint gap as a side effect, in both adapters, contract-pinned.

**D4 — Where does FakeChannel live?** Recommended: `panel/test/support/fake_channel.dart` (new `support/` directory for cross-suite test infrastructure), exported class `FakeChannel` unchanged. Note the sibling-plan divergence: plan 07's own D5 extracts the same class to `panel/test/fake_channel.dart` (no `support/`) and adds a session-aware `FakeHubServer` beside it. Whichever plan lands first fixes the path; the second reuses that location instead of creating a second one (Cross-plan coordination).

**D5 — `hub_offline.png` semantics.** The scripted replacement reproduces the committed scene byte-identically (empty states + red badge = cold start with the Hub down; if plan 08's D1 already regenerated this golden with the production 'HUB OFFLINE' label, "identical" means identical to *that* — pass `hubLabel: 'HUB'` in the rewritten scene). The *truthful mid-run* scene (frozen readings + OFFLINE badge, finding §1c-2) is a different picture. Recommended: keep pixels identical here, record the mid-run scene as a candidate new golden for plan 08's golden-fixture territory. Do not re-shoot goldens in this plan.

---

## 5. Step-by-step implementation

Every step leaves `flutter analyze` and `flutter test` green. Paths relative to repo root.

**Step 0 — Preconditions.** Check which sibling plans landed: a togglability declaration may already exist (plan 01's `DeviceKindTraits.toggles` in `panel/lib/domain/device_traits.dart`, or plan 06's vocabulary-table column); plan 07 may have widened `connected` to a three-state status in `panel/lib/data/hub_client.dart` and extracted `panel/test/fake_channel.dart`; plan 08 may have added `PanelApp.hubLabel` plus `panel/test/fixtures.dart` and regenerated `hub_offline.png` with the production label. Adjust per Cross-plan coordination. Re-verify the line numbers quoted above against the working tree.

**Step 1 — Mint the togglability declaration** (skip if plan 01 or plan 06 landed — consume their declaration instead; plan 01's reads `kind.toggles`, imported from `panel/lib/domain/device_traits.dart`). Modify `panel/lib/domain/house.dart`: add the `bool get togglable` getter to `enum DeviceKind` exactly as written in §3.1 (the enum body needs a `;` after the last value).

**Step 2 — Add `togglable` to the seam.** Modify `panel/lib/data/hub_client.dart`: add the `bool togglable(String deviceId);` member with the doc comment from §3.2 (leave `stateChanges` alone for now). Implement in all three current adapters in the same step (an interface member addition breaks every implementor at once):
- `panel/lib/data/fake_hub.dart`: add `final _byId = <String, Device>{};`, fill it in the constructor loop (`_byId[device.id] = device;`), implement `togglable` per §3.3.
- `panel/lib/data/ha_hub.dart`: add `final _byId = <String, Device>{};`, fill it in the existing constructor loop (lines 40-43), implement `togglable`.
- `panel/test/golden/dollhouse_golden_test.dart` `_OfflineHub`: add `@override bool togglable(String deviceId) => false;` (temporary — dies in Step 9).

**Step 3 — Enforce the guard in both adapters.** Modify both `toggle` methods to open with the §3.3 guard (identical event name `toggle_refused`, identical fields `device`, `kind`). In `ha_hub.dart` also replace the linear scan (`_byEntity.values.where(...)`) with `_byId[deviceId]`; the `toggle_unbound` guard stays, after the refusal guard. In `fake_hub.dart` the state-shape `switch` stays for now (rewritten in Step 6). Update the `toggle` doc comment in `hub_client.dart` to the enforced wording (§3.2). Add the regression test that would have caught today's bug, in `panel/test/ha_hub_test.dart`:
- `'refuses to toggle the thermostat — nothing reaches the Hub'`: connectAndSeed with the `climate.ecobee` entity, clear `channel.sent`, `await hub.toggle('thermostat')`, expect `channel.sent` empty and a captured `LogRecord` with area `hub`, event `toggle_refused`, fields `{'device': 'thermostat', 'kind': 'thermostat'}` (Log capture pattern from `ha_hub_test.dart:178-184`, with `Log.level = LogLevel.warn`).
The existing `fake_hub_test.dart:30-36` no-op test still passes (delete it in Step 8 when the contract suite supersedes it).

**Step 4 — Route the Dollhouse tap through the seam (D1 lands here).** Modify `panel/lib/ui/hub_controller.dart`: add `bool togglable(String deviceId) => _hub.togglable(deviceId);`. Modify `panel/lib/ui/dollhouse/dollhouse_view.dart` `_onDeviceTap`: delete the `isVideo` computation and the pattern-match line; `final toggles = widget.controller.togglable(device.id);`. Keep the `ui.device` debug log (its `known` field still reads `state != null`). Existing `dollhouse_test.dart` cases still pass (light toggle: known state; doorbell: kind not togglable → Popup). If plan 01 landed first, `_onDeviceTap` already routes by kind via `DevicePresentation.tapBehaviour` (plan 01 §9's coordinated end state: views ask the presentation module; the adapters and the contract consult the one domain declaration) — in that case leave the view alone and skip the `HubController.togglable` passthrough; the seam member `togglable` still lands (the contract suite and non-view callers need it).

**Step 5 — Retype `stateChanges` to carry drops (D3).** Modify:
- `panel/lib/data/hub_client.dart`: `Stream<String> get stateChanges;` with the §3.2 doc comment.
- `panel/lib/data/fake_hub.dart`: `_changes` becomes `StreamController<String>.broadcast()`; `_apply` adds `_changes.add(state.deviceId)`.
- `panel/lib/data/ha_hub.dart`: `_changes` becomes `StreamController<String>.broadcast()`; success path emits `device.id`; **the drop-to-unknown branch of `_applyEntity` (state == null, lines 250-264) now also emits `device.id` after `_states.remove`** — this fixes finding §1c-1.
- `panel/lib/ui/hub_controller.dart`: `late final StreamSubscription<String> _sub;` (the listener body is already payload-blind).
- `panel/test/fake_hub_test.dart` `'toggle flips a switch and emits the change'`: `expect(await emitted, id);` then assert the flip via `hub.states`.
- `panel/test/ha_hub_test.dart` `'state_changed events update state and reach the stream'`: collect `List<String>`, expect `changes.single == 'light-hall'`, read the new state from `hub.states`. Extend `'unavailable drops the Device back to unknown…'` to also assert the drop emitted `'energy-monitor'`.
- `panel/test/golden/dollhouse_golden_test.dart` `_OfflineHub`: `Stream<String> get stateChanges => const Stream.empty();`.

**Step 6 — Deepen FakeHub with the driving surface.** Modify `panel/lib/data/fake_hub.dart`:
- Rename `_apply` → `pushState` (public, doc from §3.4). Constructor seeds through it; `_drift()` calls it (the built-in script).
- Add `dropDevice(String deviceId)`: `if (_states.remove(deviceId) != null) _changes.add(deviceId);`.
- Add `setReachable(bool reachable)`: `connected.value = reachable;`. Delete the "/// Always up" comment; the field stays `final ValueNotifier<bool>`.
- Rewrite `toggle`'s body per §3.4: guard (already there from Step 3), then flip known state or push the toggled-from-off state for unknown (D1 sub-choice).
Extend `panel/test/fake_hub_test.dart` with the fake-specific case `'toggling an unknown-state light seeds it on'` (drop `light-hall`, toggle, expect `SwitchState(on: true)` and an emission).

**Step 7 — Extract FakeChannel.** Create `panel/test/support/fake_channel.dart` containing `FakeChannel` and its private `_FakeSink`, moved verbatim from `panel/test/ha_hub_test.dart:14-48`. `ha_hub_test.dart` imports `support/fake_channel.dart`. (If plan 07 landed first, its session-aware infrastructure already exists at `panel/test/fake_channel.dart` — reuse that file and location instead; see Cross-plan coordination.)

**Step 8 — The contract suite.** Create `panel/test/hub_contract_test.dart`:

```dart
/// The hands that move an adapter's world. Every assertion in the contract
/// crosses the HubClient interface; these closures only stage scenarios.
typedef HubWorld = ({
  HubClient hub,
  Future<void> Function() seed,          // light-hall known off, thermostat known 21.4/21.0
  Future<void> Function(DeviceState state) push,
  Future<void> Function(String deviceId) makeUnknown,
  Future<void> Function() dropHub,
  Future<void> Function() returnHub,
  Future<void> Function() dispose,
});

void runHubContract(String adapter, Future<HubWorld> Function() build) { ... }
```

`runHubContract` defines a `group('HubClient contract · $adapter')` with these cases (Log captured via `Log.sink`/`Log.level = LogLevel.warn`, restored in teardown):
1. `'togglable answers from Device kind, not live state'` — before seeding: `togglable('light-hall')` true, `togglable('thermostat')` false, `togglable('no-such-device')` false; still true for `light-hall` after `makeUnknown('light-hall')`.
2. `'toggle on a non-togglable Device changes nothing, emits nothing, and refuses observably'` — seed; toggle `'thermostat'`; states deep-unchanged, no `stateChanges` emission, exactly one warn `hub.toggle_refused` with `{'device': 'thermostat', 'kind': 'thermostat'}`.
3. `'toggle on an id the House does not contain refuses the same way'` — event `toggle_refused`, `kind` field null/absent, no crash.
4. `'a state the world reports lands in states and emits its Device id'` — push `SwitchState('light-hall', on: true)`; `states['light-hall']` is on; stream emitted `'light-hall'`.
5. `'a Device the world loses leaves states and emits its Device id'` — seed; makeUnknown `'light-hall'`; id gone from `states`; stream emitted `'light-hall'`.
6. `'connected falls when the Hub goes away and rises when it returns'` — dropHub → `connected.value` false; returnHub → true. (If plan 07 landed first, assert on its three-state status instead — same scenario.)

`main()` invokes the runner twice. FakeHub world: `FakeHub(loadTestHouse(), driftEvery: Duration.zero)`; closures map 1:1 onto the driving surface (`seed` pushes the two fixture states; `dropHub`/`returnHub` = `setReachable(false/true)`). HaHubClient world: session-aware connect factory `connect: (_) { channel = FakeChannel(); return channel; }` with `retryFloor: 1ms / retryCeiling: 2ms`; `seed` = the `connectAndSeed` handshake replayed from `ha_hub_test.dart:59-66` with `_entity('input_boolean.light_hall', 'off')` and `_entity('climate.ecobee', 'heat', {'current_temperature': 21.4, 'temperature': 21.0})`; `push` maps the fixture `DeviceState`s back to `state_changed` frames (only `SwitchState`/`ThermostatState` needed); `makeUnknown` sends the entity as `'unavailable'`; `dropHub` = `channel.serverDrops()` + `await Future.delayed(20ms)`; `returnHub` = replay the handshake on the fresh channel the factory produced. Entity mapping the world needs: `light-hall → input_boolean.light_hall`, `thermostat → climate.ecobee`. (`_entity` and `connectAndSeed` are private to `ha_hub_test.dart` — reproduce them locally in the contract file, or move them into the support file beside FakeChannel.) Delete the now-superseded `'toggle is a no-op for devices without a binary state'` from `fake_hub_test.dart`.

**Step 9 — Widget tests through the surface; golden third adapter dies.** Extend `panel/test/dollhouse_test.dart` (its `makeController()` already returns the concrete `(HubController, FakeHub)` pair):
- `'OFFLINE badge appears when the Hub drops and clears when it returns'` — pump; `find.text('FAKE HUB')`; `hub.setReachable(false)`; pump; `find.text('FAKE HUB OFFLINE')`; `setReachable(true)`; pump; badge back.
- `'a pushed state re-renders its pin'` — hall thermostat pin shows the seeded `'21.4°'`; `hub.pushState(const ThermostatState('thermostat', currentC: 23.0, targetC: 21.0))`; pump; `find.text('23.0°')`.
- `'a Device the Hub loses re-renders as unknown'` — garage energy monitor shows seeded `'812W'`; `hub.dropDevice('energy-monitor')`; pump; `'812W'` gone, `deviceIcon(DeviceKind.energyMonitor)` icon shown.
- `'tapping an unknown-state light toggles instead of opening a Popup'` (pins D1) — `hub.dropDevice('light-hall')`; tap `pin-light-hall`; `find.byType(Dialog)` findsNothing; `hub.states['light-hall']` is `SwitchState(on: true)`.
Modify `panel/test/golden/dollhouse_golden_test.dart`: delete `_OfflineHub` (if plan 07 landed first it is already its `_StubHub` replacement — delete that instead) and its now-unused imports; rewrite `'hub unreachable'` (if plan 08 landed first, also pass `hubLabel: 'HUB'` through `pumpPanel` — its D1 regenerated this golden with the production label):

```dart
goldenTest('hub unreachable', (tester) async {
  final house = loadTestHouse();
  final hub = FakeHub(house, driftEvery: Duration.zero);
  for (final device in house.floors.expand((f) => f.devices)) {
    hub.dropDevice(device.id);
  }
  hub.setReachable(false);
  await pumpPanel(tester, HubController(house: house, hub: hub));
  await expectLater(
      find.byType(PanelApp), matchesGoldenFile('goldens/hub_offline.png'));
});
```

Expected: byte-identical to the golden committed at implementation time (same observable seam state; if plan 08 landed first, that is its regenerated 'HUB OFFLINE' scene). If it diffs, something in the scripting is wrong — investigate before reaching for `--update-goldens`.

**Step 10 — Sweep.** Re-read `hub_client.dart` top-of-file doc (line 5-6 "the fake hub serves development" — extend: "and, scripted, the widget and golden tests"). Confirm no remaining reference to `_OfflineHub`, no `DeviceState`-subtype toggle guard outside the adapters: `grep -rn "is SwitchState" panel/lib/ui` should return **nothing** after Step 4 — its only pre-plan hit is the deleted guard (dollhouse_view.dart:194); the rendering switches in `_DevicePin`/`statusText` use pattern arms (`SwitchState s =>`), which the grep does not match and which stay — they are display logic, not guards. Run the full verification (§7).

---

## 6. Test plan

**New files:**
- `panel/test/hub_contract_test.dart` — the six contract cases of Step 8, run against both adapters (twelve executions). This is the first time the seam's invariants are pinned as a *contract*: refusal identity, togglability-by-kind, push-lands-and-emits, drop-leaves-and-emits, reachability transitions.
- `panel/test/support/fake_channel.dart` — moved infrastructure, no new behaviour.

**Changed tests:**
- `panel/test/ha_hub_test.dart`: + `'refuses to toggle the thermostat — nothing reaches the Hub'` (the regression test for the live bug); `'state_changed events…'` and `'unavailable drops…'` adjusted for `Stream<String>` (the latter gains a drop-emission assertion); imports FakeChannel from support.
- `panel/test/fake_hub_test.dart`: `'toggle flips a switch and emits the change'` asserts the emitted id + reads `states`; `'toggle is a no-op for devices without a binary state'` **deleted** (superseded by contract case 2, which now covers both adapters); + `'toggling an unknown-state light seeds it on'`.
- `panel/test/dollhouse_test.dart`: + the four widget cases of Step 9 (badge transition, pushed-state re-render, drop-to-unknown re-render, unknown-light tap routing — the last one pins D1's behaviour change).
- `panel/test/golden/dollhouse_golden_test.dart`: `_OfflineHub` deleted; `'hub unreachable'` scripted through FakeHub.

**Golden impact:** goldens live in `panel/test/golden/goldens/`; none should change — the scripted offline scene is observably identical to `_OfflineHub`. If a legitimate regeneration is ever needed: `cd panel && flutter test --update-goldens test/golden`, then eyeball the diff (never rubber-stamp; see the comparator's doc in `golden_setup.dart:123-131`).

**Behaviours pinned for the first time:** toggle refusal on the production adapter (would fail today); refusal observability (`hub.toggle_refused`, same event and fields from both adapters); `togglable` keyed on Device kind independent of live state; drop-to-unknown emitting a change notification (fixes the production stale-pin gap); OFFLINE badge dynamic transition; pin re-render on a pushed state; unknown-state light tap routing (D1).

---

## 7. Verification

```sh
cd panel && flutter analyze && flutter test
```

Both must be clean after every step, not just at the end. For a live look at the result: **this Mac has Flutter via brew but NO Xcode** — any live check is `cd panel && flutter run -d chrome` (web build; ADR-0001 guarantees it's a faithful substrate), never `-d macos`. The default build runs FakeHub (`HUB=fake`), which after this plan is the same adapter, same code path, the tests script. Optional live check against the dev Hub: `--dart-define=HUB=ha --dart-define=HA_URL=... --dart-define=HA_TOKEN=...` per `hub/dev/README.md` — tap the thermostat pin and confirm the Popup opens and the log shows no `call_service` (before this plan it would have toggled the climate entity).

---

## 8. Non-goals

- **No three-state `connected`.** Reachability stays `ValueListenable<bool>`; widening to a status is plan 07's whole subject. `setReachable` is written so 07 only changes what it *sets*, not the surface.
- **No golden re-composition or new golden scenes.** The truthful mid-run outage picture (frozen readings + OFFLINE badge, finding §1c-2) is recorded here as a candidate for plan 08; this plan keeps `hub_offline.png` byte-identical.
- **No change to HaHubClient's keep-stale-readings-during-outage behaviour.** That is the documented intent of `connected` ("my readings are stale has to be visible") and any change is a UX decision for the reachability plan (07), not this one.
- **No scenario DSL for FakeHub.** The driving surface is three methods; seed+drift stays the only built-in script. Trigger to revisit: a test needs ordered multi-step scripts in more than two places.
- **No shared refusal helper** (per D2 recommendation). Trigger to revisit: a third production adapter.
- **No `toggleRoomLights` changes.** Its kind filter is selection logic and now has the seam as backstop.
- **No togglability in `devices.yaml`.** ADR-0004's hand-maintained file owns the *kind*; kind→togglable is a domain fact in code (plan 06's vocabulary table is its eventual documentation home).
- **No new capability on the Popup or pins** — plan 01's subject. This plan only re-routes the existing tap decision through the seam.

---

## 9. Cross-plan coordination

There are 8 plans, `docs/plans/01-*.md` … `docs/plans/08-*.md`. The notes below were handed to this plan verbatim-in-spirit, plus what was discovered while writing it:

- **Plan 01** (`docs/plans/01-device-presentation-module.md`) mints the domain-side togglability declaration this plan enforces at the seam — concretely (its D6): `DeviceKindTraits.toggles`, an extension on `DeviceKind` in a new `panel/lib/domain/device_traits.dart`, same truth table as §3.1. If 01 is not yet implemented when this plan runs, mint the declaration here (Step 1; plan 01 then reuses it). If 01 landed first, skip Step 1 and read `kind.toggles` from `device_traits.dart` wherever this plan says `kind.togglable` — and skip Step 4's view rewiring too: plan 01 already routes taps by kind via `DevicePresentation.tapBehaviour`, and its §9 records the coordinated end state (views ask the presentation module; this plan's remaining job is the adapters, the seam member, and the contract suite). Decision D1 (unknown-state light tap) is shared with plan 01 (its D1, same recommendation) — whichever lands first records the ratified answer; the second plan must not re-litigate it.
- **Plan 06** (`docs/plans/06-device-vocabulary-table.md`) is the declaration's eventual home: its table derives `togglable` from a kind's state family. If 06 landed first, consume its declaration instead of minting (Step 1 skipped); if this plan lands first, 06 absorbs the standalone declaration as a table column — callers keep compiling either way.
- **Plan 07** (`docs/plans/07-hub-status-three-state.md`) widens `HubClient.connected` from bool to a three-state status. FakeHub's driving surface "set reachability" is therefore described both ways: **today** `setReachable(bool)` sets `connected.value`; **if 07 landed first**, the same method sets the status (and contract case 6 asserts the status transitions instead of the bool). Both plans edit `hub_client.dart` — trivially compatible, different members.
- **Plan 07** also rebuilds `ha_hub_test` with a session-aware fake connect factory (fresh channel per attempt) and, per its D5, extracts `FakeChannel`/`_FakeSink` to `panel/test/fake_channel.dart` with a `FakeHubServer` beside them; if it runs first it also replaces the golden suite's `_OfflineHub` with a `_StubHub`. This plan's contract suite drives HaHubClient through FakeChannel with exactly that factory shape (Step 8's `connect: (_) { channel = FakeChannel(); return channel; }`) and extracts FakeChannel to `panel/test/support/fake_channel.dart` (Step 7) — the two plans choose different paths, so **whichever lands second reuses the first's location and infrastructure**; do not create a second FakeChannel or a second extraction location.
- **Plan 08** (`docs/plans/08-panel-boot-module.md`) is the boot/composition plan, and it owns the golden fixtures this plan's Step 9 touches: it creates a shared `panel/test/fixtures.dart`, gives `PanelApp` and `pumpPanel` a `hubLabel` parameter, and (its D1) regenerates `hub_offline.png` with the production 'HUB OFFLINE' label; it explicitly leaves `_OfflineHub` for this plan to own ("`_OfflineHub` stays in the golden file — plan 02 owns those fakes"). If 08 landed first: build Step 9's scene through its fixtures and pass `hubLabel: 'HUB'` in the hub-unreachable golden. If this plan lands first: 08's fixture helper should compose scenes on FakeHub's driving surface and must not resurrect one-off `HubClient` adapters. The candidate mid-run-outage golden (frozen readings + OFFLINE badge) is handed to plan 08 as an idea, with D5's rationale.
- **Plans 03, 04, 05** (`docs/plans/03-floor-geometry-owner.md`, `04-house-plan-gatekeeper.md`, `05-floor-arrangement-module.md`) do not overlap this plan's edits: 03 and 05 rework other regions of `floor_view.dart`/`dollhouse_view.dart` and both explicitly leave `_onDeviceTap` out of scope; 04 is loader-side. Any order works.

---

## 10. Sources

- `CONTEXT.md` (repo root) — domain language quoted in §2.
- `docs/adr/0001-plain-linux-kiosk-not-fuchsia-or-chromeos.md`, `docs/adr/0002-home-assistant-headless-hub.md`, `docs/adr/0003-zigbee-z2m-not-matter-thread.md`, `docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md` — constraints quoted in §2.
- `.claude/skills/codebase-design/SKILL.md` — the deep-module vocabulary used throughout (module, interface, seam, adapter, depth, leverage, locality, deletion test).
- The originating architecture review and its adversarial verification pass (temp HTML artifact, ephemeral — not in the repo; its verified findings, corrections, and shapes are reproduced in full in §1 and §3 so nothing depends on it surviving).
- Source of truth for all code excerpts: commit `105610c` (committed 2026-07-31), files under `panel/lib/` and `panel/test/` as cited inline.
- `docs/plans/01-…08-*.md` — the sibling plans whose declarations, paths, and decisions §9 coordinates with (read the relevant one before executing a conditional step).
