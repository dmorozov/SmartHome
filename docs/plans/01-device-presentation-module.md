# Device presentation module — one deep module for the kind-by-state matrix

How a Device's kind and live DeviceState become pixels and taps is currently decided independently at four seams; this plan concentrates the whole kind-by-state matrix into one deep module owned by HubController, and mints the single domain-side declaration of which Device kinds toggle.

Status: proposed · Strength: Strong · Written against commit 105610c (2026-08-01) — re-verify line numbers before editing.

---

## 1. Why this refactor

### The friction

The Panel answers "how does this Device look, and what does tapping it do?" in four different places, each re-deriving the answer from the Device's kind and/or the runtime type of its live `DeviceState`. There is no module that owns the answer. Every fact below was verified against the working tree at commit 105610c by an adversarial review pass that read all six named files, both domain files, `theme.dart`, `main.dart`, `ha_hub.dart`, all four ADRs, and every test.

**Seam 1 — the pin's face** (`panel/lib/ui/dollhouse/floor_view.dart:128-139`, inside `_DevicePin.build`):

```dart
final on = switch (state) {
  SwitchState s => s.on,
  GarageDoorState g => g.open,
  _ => false,
};
final reading = switch (state) {
  ThermostatState t => '${t.currentC.toStringAsFixed(1)}°',
  PowerState p => p.watts >= 1000
      ? '${(p.watts / 1000).toStringAsFixed(1)}kW'
      : '${p.watts.round()}W',
  _ => null,
};
```

**Seam 2 — the tap's meaning** (`panel/lib/ui/dollhouse/dollhouse_view.dart:192-194`, inside `_onDeviceTap`):

```dart
final isVideo = device.kind == DeviceKind.camera ||
    device.kind == DeviceKind.doorbell;
final toggles = !isVideo && (state is SwitchState || state is GarageDoorState);
```

**Seam 3 — the Popup's body choice** (`panel/lib/ui/device_popup.dart:15-16`, inside `showDevicePopup`) — the same expression as seam 2's `isVideo`, token for token (only the line wrap differs):

```dart
final isVideo =
    device.kind == DeviceKind.camera || device.kind == DeviceKind.doorbell;
```

**Seam 4 — the Popup's status wording** (`panel/lib/ui/device_popup.dart:122-132`, top-level `statusText`):

```dart
String statusText(DeviceState? state) => switch (state) {
      SwitchState s => s.on ? 'On' : 'Off',
      GarageDoorState g => g.open ? 'Open' : 'Closed',
      ThermostatState t =>
        '${t.currentC.toStringAsFixed(1)} °C now · target ${t.targetC.toStringAsFixed(1)} °C',
      PowerState p => p.watts >= 1000
          ? '${(p.watts / 1000).toStringAsFixed(2)} kW'
          : '${p.watts.round()} W',
      StatusState s => s.status,
      null => 'Unknown',
    };
```

### The rules have already diverged

Three concrete divergences exist between these copies:

1. **The same PowerState renders differently on pin and Popup.** The pin formats `'${(p.watts / 1000).toStringAsFixed(1)}kW'` (floor_view.dart:136) while the Popup formats `'${(p.watts / 1000).toStringAsFixed(2)} kW'` (device_popup.dart:128) — different precision *and* different spacing. Verification correction: this is **not drift** — `git show 7ddf785` (the "flutter panel skeleton" commit) shows both formats present from birth. It is inconsistency-from-birth with no owner, which is arguably worse: no single commit ever decided the rule.

2. **On-ness exists in three copies, two of which disagree.** `_DevicePin` counts `GarageDoorState.open` as "on" (floor_view.dart:128-132: the pin glows when the garage is open), while `HubController.isOn` (hub_controller.dart:27-30) counts only `SwitchState`:

   ```dart
   bool isOn(String deviceId) => switch (stateOf(deviceId)) {
         SwitchState s => s.on,
         _ => false,
       };
   ```

   This was found by the verification pass; the original candidate missed it. A third on-ness copy, already diverged.

3. **The togglability rule exists in triplicate**, none of them owning it: the views' state-shape test (seam 2 above), `FakeHub.toggle`'s identical state-shape switch (`panel/lib/data/fake_hub.dart:45-52`):

   ```dart
   final next = switch (_states[deviceId]) {
     SwitchState s => SwitchState(deviceId, on: !s.on),
     GarageDoorState g => GarageDoorState(deviceId, open: !g.open),
     _ => null,
   };
   ```

   and a doc comment on the `HubClient` interface (`panel/lib/data/hub_client.dart:19-21`) that no implementation enforces:

   ```dart
   /// Flip a Device that has a binary state (light, outlet, TV, garage
   /// door). No-op for anything else.
   Future<void> toggle(String deviceId);
   ```

### Two unpinned connectivity behaviours (verification correction — worse than the candidate claimed)

The original candidate claimed a light silently opens a Popup instead of toggling "when the Hub is down." The verification pass corrected the trigger, and in doing so found the friction is worse — there are **two** distinct connectivity-tied behaviours nobody decided or pinned:

1. **Unknown state flips a light's affordance to Popup.** Because `toggles` at seam 2 is derived from the live state's runtime type, a light whose state is unknown takes the Popup branch. The actual triggers for unknown state are: the pre-snapshot window right after connecting, an entity the Hub reports as `unavailable`/`unknown` (`HaHubClient._toDeviceState` returns null and `_applyEntity` removes the state — ha_hub.dart:250-263), or a Device with no `entityId` bound at all (devices.yaml explicitly supports this: "Omit the line for a Device the Hub does not know about yet; it renders with unknown state"). Tapping such a light opens a Popup that says "Unknown" instead of toggling.

2. **A full Hub outage silently swallows toggles on stale state.** `HaHubClient` never clears `_states` on disconnect (`_reconnect`, ha_hub.dart:142-165, touches only the socket and the `connected` flag), so an outage leaves stale states in place, lights still take the *toggle* branch — and `_send` on a null channel silently drops the command (ha_hub.dart:167-168: `_channel?.sink.add(jsonEncode(message))`). The tap does nothing, with no feedback.

Neither behaviour appears in any test. Grep over `panel/test/` for `toggleRoomLights`, `isRoomLit`, `statusText`, or `isVideo` returns nothing (verified 2026-08-01).

### HubController is a mixed shallow module

`panel/lib/ui/hub_controller.dart` is half pass-through, half real-but-untested:

- **One-line forwards** to the Hub adapter: `connected` (:19), `stateOf` (:25), `toggle` (:36).
- **Real behaviour with zero tests**: the `stateChanges`-plus-`connected` Listenable fold (:14-15, consumed by `main.dart:133-137`'s `ListenableBuilder`), `isOn` (:27-30), `isRoomLit` (:33-34, consumed at floor_view.dart:67), and the all-or-nothing `toggleRoomLights` Room policy (:40-49):

  ```dart
  /// Tapping a Room acts on it: all lights on if none is lit, all off
  /// otherwise.
  Future<void> toggleRoomLights(Room room) async {
    final lit = isRoomLit(room);
    ...
    for (final light in lights) {
      if (isOn(light.id) == lit) await _hub.toggle(light.id);
    }
  }
  ```

Deletion test on HubController today: the forwards vanish at no cost (the pass-through symptom), but the Room-lit aggregation, the Room toggle policy, and the Listenable fold would reappear in `DollhouseView`/`FloorView`/`main.dart` — a half-pass. Run the deletion test in reverse on the *missing* presentation module and its would-be implementation is found at four-plus call sites, two of which are verbatim copies and two of which are rule divergences.

### Test coverage today

`panel/test/dollhouse_test.dart:45-68` covers exactly **two** kind-by-state combinations (a light with `SwitchState` toggles; the doorbell opens the live-view Popup) — each via a full app pump. The rest of the matrix — every other kind, every reading format, the on/off faces, both unknown-state behaviours, the Room policy — is unpinned.

### Honest deflators (kept from the verification pass)

- The controller-policy test gap (`toggleRoomLights`, `isRoomLit`) is fixable today without any refactor; only the kind-by-state matrix genuinely needs the new module to escape widget pumping. This plan does both, but be honest that the first half is a testing omission the deepening merely makes harder to ignore.
- YAGNI check: the repo is 16 commits old and no `DeviceKind` has been added since the skeleton, so "a new kind is the most common change" is speculative. However, phase-1 go2rtc video is documented to land exactly in the `isVideo`/Popup sites (device_popup.dart:7-9: "Cameras and the doorbell show a live-view placeholder (the go2rtc stream lands there in phase 1)") — that is *scheduled* churn at these seams, not hypothetical.
- No ADR conflict. The verification pass confirmed the candidate's key design insight: affordance derived from live state shape is *why* connectivity changes tap behaviour; keying it on kind and deciding unknown-state explicitly fixes a latent behaviour bug, not just aesthetics.

---

## 2. Context a fresh session needs

### Domain vocabulary (CONTEXT.md — use these words, never the "avoid" ones)

- **Panel**: "The wall-mounted touchscreen running the custom dollhouse UI." (Avoid: kiosk, dashboard, screen.)
- **Hub**: "The headless smart-home broker (Home Assistant) that owns device state, integrations, and automations. The Panel is its client, never its replacement." (Avoid: server, backend, HA in domain discussion.)
- **Dollhouse**: "The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms."
- **House Plan**: "The Panel-side description of the house's geometry — Floors with their Rooms and Walls, authored by the family. The Dollhouse renders it; the Hub never sees it."
- **Floor**: "One level of the house in the Dollhouse… Floors stack; tapping one expands it."
- **Room**: "A named area on a Floor. Rooms tile their Floor completely… Rooms display aggregate state (lit, occupied) and hold pinned Devices. Tapping a Room acts on it (e.g. toggles its lights)."
- **Wall**: "A boundary segment drawn on the House Plan. Only drawn Walls exist: where none is drawn, the boundary is an open passage."
- **Device**: "A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse." (Avoid: entity — that is the Hub's internal term.)
- **Local Device / Cloud Device**: local = no vendor cloud; cloud = grandfathered, second-class.
- **Popup**: "A transient full-or-partial-screen overlay on the Panel, e.g. live doorbell video on ring. Phase-1 video is Popup-only (no recording)."

### Design vocabulary (.claude/skills/codebase-design/SKILL.md — use exactly; never component/service/API/boundary)

A **module** is anything with an **interface** (everything a caller must know) and an **implementation**. A module is **deep** when a lot of behaviour sits behind a small interface — depth gives **leverage** to callers (one implementation pays back across N call sites and M tests) and **locality** to maintainers (fix once, fixed everywhere). A **seam** is where a module's interface lives; an **adapter** is a concrete thing satisfying an interface at a seam. **The deletion test**: imagine deleting the module — if complexity vanishes it was a pass-through; if complexity reappears across N callers it was earning its keep. **The interface is the test surface**: callers and tests cross the same seam.

### Binding ADR constraints

- ADR-0002 (Home Assistant headless Hub): "Automations live in the Hub's native engine; **the Panel is a pure view/command layer.**" The presentation module decides how state renders and what a tap *requests* — it never automates.
- ADR-0002: "The Hub is a black-box appliance." All Hub knowledge stays behind the `HubClient` seam; the presentation module consumes only the Panel-side `Device` + `DeviceState` model.
- ADR-0004 (House Plan pipeline): `devices.yaml` is hand-maintained; a Device may legitimately have no `entity:` binding yet. The exact quote — "Omit the line for a Device the Hub does not know about yet; it renders with unknown state" — is the devices.yaml header comment (panel/assets/house/devices.yaml:10-12), which implements ADR-0004's hand-maintained-devices decision. **Unknown state is a normal, expected condition**, which is exactly why its tap behaviour must be decided explicitly.
- ADR-0001 (plain Linux kiosk): the Panel runs unattended on a wall (cage kiosk, no desktop, nobody at a console). The "a silent no-op is the worst failure mode" principle is not ADR text — it is written down in code at ha_hub.dart:93-95 — but it follows directly from unattended operation.

### Current-architecture tour (files this plan touches)

- **`panel/lib/domain/house.dart`** — Panel-side House structure. `Device` (:99-121) has `id`, `name`, `kind`, `connectivity`, `entityId` (nullable — "Null while a Device has no Hub counterpart yet — it still renders, with unknown state"), `position`. `DeviceKind` (:123-138) is a 14-value enum: `light, outlet, thermostat, camera, doorbell, oven, tv, washer, dryer, litterRobot, feeder, garageDoor, evCharger, energyMonitor`. Note: house.dart imports `dart:ui` (for `Offset`), so anything importing it is engine-dependent but still widget-free and unit-testable without pumping.
- **`panel/lib/domain/device_state.dart`** — `sealed class DeviceState` with five shapes: `SwitchState(on)`, `ThermostatState(currentC, targetC)`, `GarageDoorState(open)`, `PowerState(watts)`, `StatusState(status)`. Being sealed, switches over it are exhaustiveness-checked.
- **`panel/lib/data/hub_client.dart`** — the Hub seam: `connected` (ValueListenable), `states` (Map deviceId→DeviceState; "A Device absent from the map has unknown state"), `stateChanges` (Stream), `toggle(deviceId)`, `dispose()`. Two adapters satisfy it: `FakeHub` and `HaHubClient`.
- **`panel/lib/data/fake_hub.dart`** — in-memory Hub adapter; seeds a state for every Device by kind (`_initialState`, :86-103), `toggle` flips by state shape (:45-52).
- **`panel/lib/data/ha_hub.dart`** — the real Hub adapter over the Home Assistant WebSocket API. `_toDeviceState` (:281-312) maps entity→state **by Device kind** (light/outlet/tv → SwitchState; garageDoor → GarageDoorState; thermostat → ThermostatState; energyMonitor/evCharger → PowerState; everything else → StatusState). So kind→state-shape is already deterministic in the real adapter — kind-keyed affordance and state-shape-keyed affordance only disagree when state is *unknown*.
- **`panel/lib/ui/hub_controller.dart`** — "Presentation state: the House structure plus live Device state from the Hub, folded into one Listenable for the widget tree." Contents itemised in section 1.
- **`panel/lib/ui/dollhouse/dollhouse_view.dart`** — the Dollhouse (stacked Floors, selection, drift layout). `_onDeviceTap` (:190-208) is seam 2; it logs `{'action': toggles ? 'toggle' : 'popup', 'known': state != null}` then either `controller.toggle(device.id)` or `showDevicePopup(...)`.
- **`panel/lib/ui/dollhouse/floor_view.dart`** — one Floor as an isometric slab. `_pin` (:94-107) builds each pin: `_DevicePin(device: device, state: controller.stateOf(device.id))`. `_DevicePin` (:120-170) is seam 1. FloorView also consumes `controller.isRoomLit(r)` at :67 for the lit-room glow. The painter/hit-test halves of this file belong to plan 03 — do not touch them.
- **`panel/lib/ui/device_popup.dart`** — `showDevicePopup(context, {device, state})`: header (icon, name, Local/Cloud Device tag), then `isVideo` ? live-view placeholder ("Live view placeholder — go2rtc stream") : `Text(statusText(state))`. Seams 3 and 4.
- **`panel/lib/ui/theme.dart`** — `PanelTheme` palette + `deviceIcon(DeviceKind)` (:38-53), the one existing kind-keyed lookup (used by both the pin and the Popup header — this one is already single-sourced; leave it in theme.dart).
- **`panel/lib/main.dart`** — wires house + hub + `HubController`, consumes `controller.connected` for the `_HubBadge` (:117-123) and rebuilds `DollhouseView` via `ListenableBuilder(listenable: controller, ...)` (:132-138).
- **Tests** — `panel/test/dollhouse_test.dart` (4 widget tests, two kind-by-state combinations), `panel/test/fake_hub_test.dart` (seeding, toggle flip, toggle no-op on thermostat), `panel/test/golden/dollhouse_golden_test.dart` (4 scenes incl. `hub_offline` via an inline `_OfflineHub` whose `states` is `const {}`), goldens in `panel/test/golden/goldens/` (`ground_floor.png`, `upstairs_selected.png`, `device_popup.png`, `hub_offline.png`). `panel/test/test_house.dart` loads the real shipped House Plan assets; useful Device ids: `light-hall`, `doorbell`, `thermostat`.

---

## 3. Target design

### The module

**`DevicePresentation`** — a deep module in a new file **`panel/lib/ui/device_presentation.dart`**, owned by `HubController`. Interface: give it a Device plus its live DeviceState (possibly absent); it answers everything the Dollhouse and the Popup need. The whole kind-by-state matrix hides inside; the views become renderers of answers.

The affordance half of the matrix — *does this kind toggle* — is minted separately, domain-side, in **`panel/lib/domain/device_traits.dart`**, so both Hub adapters can eventually consult the same rule (plan 02 wires them; see section 10). It is deliberately a tiny standalone declaration so plan 06's device vocabulary table can absorb it as a column without touching callers.

### Concrete signatures

`panel/lib/domain/device_traits.dart` (new — widget-free, no Flutter framework import):

```dart
import 'house.dart';

/// Kind-keyed Device affordances, declared once for the whole Panel.
/// This is the single source for "does tapping this kind of Device flip a
/// binary state through the Hub" — the rule previously re-derived from
/// state shapes in the views, re-implemented in FakeHub.toggle, and stated
/// as an unowned comment on HubClient.toggle.
extension DeviceKindTraits on DeviceKind {
  /// Mirrors HubClient.toggle's contract: light, outlet, TV and garage
  /// door toggle; every other kind is observe-only from a tap.
  ///
  /// Exhaustive on purpose: adding a DeviceKind must force the author to
  /// declare its togglability, at compile time.
  bool get toggles => switch (this) {
        DeviceKind.light ||
        DeviceKind.outlet ||
        DeviceKind.tv ||
        DeviceKind.garageDoor =>
          true,
        DeviceKind.thermostat ||
        DeviceKind.camera ||
        DeviceKind.doorbell ||
        DeviceKind.oven ||
        DeviceKind.washer ||
        DeviceKind.dryer ||
        DeviceKind.litterRobot ||
        DeviceKind.feeder ||
        DeviceKind.evCharger ||
        DeviceKind.energyMonitor =>
          false,
      };
}
```

`panel/lib/ui/device_presentation.dart` (new):

```dart
import 'package:flutter/widgets.dart' show IconData;

import '../domain/device_state.dart';
import '../domain/device_traits.dart';
import '../domain/house.dart';
import 'theme.dart';

/// What a tap on a Device pin does. Keyed on the Device's kind — the same
/// Device always answers the same — never on the live state's shape.
enum DeviceTapBehaviour { toggle, showPopup }

/// How one Device, given its kind and live state, looks and behaves on the
/// Panel: the pin's face, the tap's meaning, and the Popup's body and
/// wording — the whole kind-by-state matrix in one place.
///
/// Pure values in, pure answers out: no Hub, no BuildContext, no side
/// effects. The views render these answers; DollhouseView executes
/// [tapBehaviour]; HubController mints instances from live state.
class DevicePresentation {
  const DevicePresentation(this.device, this.state);

  final Device device;

  /// Live state from the Hub, or null when unknown (pre-snapshot,
  /// unavailable entity, or no entityId bound yet — ADR-0004 says an
  /// unbound Device still renders).
  final DeviceState? state;

  /// The pin glows: a switched Device that is on, or the garage door open
  /// (an open door is the attention-worthy state).
  bool get glows => switch (state) {
        SwitchState s => s.on,
        GarageDoorState g => g.open,
        _ => false,
      };

  /// Compact text face for the pin, or null for the icon face.
  String? get reading => switch (state) {
        ThermostatState t => '${t.currentC.toStringAsFixed(1)}°',
        PowerState p => _watts(p.watts, compact: true),
        _ => null,
      };

  IconData get icon => deviceIcon(device.kind);

  DeviceTapBehaviour get tapBehaviour => device.kind.toggles
      ? DeviceTapBehaviour.toggle
      : DeviceTapBehaviour.showPopup;

  /// Cameras and the doorbell get the live-view Popup body (the go2rtc
  /// stream lands there in phase 1); everything else gets [statusText].
  bool get isVideo =>
      device.kind == DeviceKind.camera || device.kind == DeviceKind.doorbell;

  /// Full status wording for the Popup body.
  String get statusText => switch (state) {
        SwitchState s => s.on ? 'On' : 'Off',
        GarageDoorState g => g.open ? 'Open' : 'Closed',
        ThermostatState t =>
          '${t.currentC.toStringAsFixed(1)} °C now · target ${t.targetC.toStringAsFixed(1)} °C',
        PowerState p => _watts(p.watts, compact: false),
        StatusState s => s.status,
        null => 'Unknown',
      };

  /// The one power-formatting rule. Compact (pin) and full (Popup) variants
  /// differ only in spacing; precision is shared, so the pin and the Popup
  /// can never disagree about the number again.
  static String _watts(double watts, {required bool compact}) =>
      watts >= 1000
          ? '${(watts / 1000).toStringAsFixed(1)}${compact ? 'kW' : ' kW'}'
          : '${watts.round()}${compact ? 'W' : ' W'}';
}
```

`panel/lib/ui/hub_controller.dart` (modified — the forwards fold into a genuinely deep interface):

```dart
/// Everything the Dollhouse and the Popup need to render and act on
/// [device], derived from its kind and current live state.
DevicePresentation presentationOf(Device device) =>
    DevicePresentation(device, _hub.states[device.id]);
```

Final `HubController` interface after this plan: `house`, `connected`, `presentationOf(Device)`, `toggle(String)`, `isRoomLit(Room)`, `toggleRoomLights(Room)`, `dispose()`. Gone from the interface: `stateOf` (folds into `presentationOf`), `isOn` (its one honest rule now lives in `DevicePresentation.glows`; the Room policy consults it through `presentationOf`).

### Who calls what

- `FloorView._pin` → `controller.presentationOf(device)` → `_DevicePin(presentation: ...)` renders `glows`/`reading`/`icon`. `_DevicePin`'s two switch ladders are deleted.
- `DollhouseView._onDeviceTap` → `controller.presentationOf(device)`, switches on `tapBehaviour`: `toggle` → `controller.toggle(device.id)`; `showPopup` → `showDevicePopup(context, presentation: presentation)`. Its `isVideo`/`toggles` derivation is deleted.
- `showDevicePopup` takes the presentation, renders `isVideo` ? live-view body : `Text(presentation.statusText)`. Its `isVideo` copy and the top-level `statusText` function are deleted.
- `HubController.isRoomLit`/`toggleRoomLights` consult `presentationOf(d).glows` for lights (identical behaviour: a light's state is `SwitchState` under both adapters, where `glows == on`).
- Hub adapters: unchanged in this plan; plan 02 points `FakeHub.toggle`, `HaHubClient`, and the `HubClient` contract at `DeviceKindTraits.toggles`.

### What hides inside

The on-glow rule (including the garage-door case), both reading formats and the single power-formatting rule, the kind→tap-behaviour mapping including the explicit unknown-state decision, the video-vs-status Popup body choice, and all status wording. None of it is any caller's business anymore.

### Before/after dependency sketch

```
BEFORE
  floor_view/_DevicePin ──switch on state shapes──▶ on-ness(+garage), reading fmt '1.2kW'
  floor_view ──▶ controller.stateOf / controller.isRoomLit
  dollhouse_view/_onDeviceTap ──derives──▶ isVideo(kind) + toggles(state shape)
                              ──▶ controller.toggle | showDevicePopup(device, state)
  device_popup ──re-derives──▶ isVideo (verbatim copy) ──owns──▶ statusText fmt '1.23 kW'
  hub_controller [forwards: connected/stateOf/toggle] + [untested: isOn/isRoomLit/
                  toggleRoomLights/Listenable fold] ──▶ HubClient
  fake_hub.toggle ──re-implements──▶ togglability by state shape
  hub_client.toggle ──doc comment──▶ 'no-op for anything else' (rule stated, unowned)

AFTER
  domain/device_traits.dart [DeviceKindTraits.toggles — THE togglability declaration]
        ▲                    ▲ (plan 02: FakeHub, HaHubClient, HubClient contract)
        │
  ui/device_presentation.dart [DEEP: whole kind-by-state matrix —
        glows · reading · icon · tapBehaviour (unknown-state explicit) ·
        isVideo · statusText · one _watts rule]
        ▲
  hub_controller.presentationOf(device) [owns the module; + Room policy; forwards folded]
        ▲                ▲                   ▲
  floor_view/_DevicePin  dollhouse_view      device_popup
  (renders pin face)     (executes tap)      (renders body + wording)
```

---

## 4. Decision points

Each needs ratification by the user before or during implementation. Recommendations are marked.

**D1 — Unknown-state tap on a togglable kind: toggle or Popup? (BEHAVIOUR CHANGE — the headline decision.)**
Today a light/outlet/tv/garage door with unknown state opens a Popup reading "Unknown" (affordance is derived from state shape; unknown state has no togglable shape). Keying affordance on kind CHANGES this: the tap will attempt a toggle.
- Option A — **toggle (recommended)**: the same Device always does the same thing; matches the user's muscle memory and `HubClient.toggle`'s documented contract; during the pre-snapshot window a toggle sent to a connected Hub genuinely works; for an unbound Device, `HaHubClient.toggle` already logs `toggle_unbound` (ha_hub.dart:95). The residual risk — silent swallow when the socket is down — exists today anyway (stale-state path) and is plan 02's territory (delivery feedback at the Hub seam).
- Option B — Popup: explicit "Unknown" feedback, but it is a dead-end dialog with no controls, and it makes a light's tap behaviour flicker with connectivity — the exact bug class this plan removes.
Whatever is chosen gets pinned by a test for the first time.

**D2 — Power format unification: which precision wins?**
Pin says `1.2kW`, Popup says `1.23 kW`, both since the skeleton commit.
- Option A — **one decimal everywhere, spacing differs by variant (recommended)**: `1.2kW` on the pin (unchanged → goldens unaffected), `1.2 kW` in the Popup. Two decimals of kW is 10 W resolution — meaningless jitter under FakeHub drift and real Emporia noise.
- Option B — keep the Popup at two decimals as the "full" variant: preserves current Popup text exactly, but then "one formatting rule" is a fiction with two precisions.

**D3 — Does the garage door glow the pin?**
`_DevicePin` glows on `GarageDoorState.open`; `HubController.isOn` does not count it. One rule must win.
- Option A — **keep the glow (recommended)**: an open garage door is the attention-worthy state; preserves current pin behaviour and the goldens; `glows` becomes the single named rule and `isOn` dies. Room-lit is unaffected (it filters `kind == DeviceKind.light` first).
- Option B — glow only `SwitchState.on`: changes visible pin behaviour and `ground_floor.png` (the demo garage door seeds closed, so likely no pixel change today — but the rule change is real).

**D4 — HubController surface after folding.**
- Option A — **remove `stateOf` and `isOn` from the interface entirely (recommended)**: no external caller remains after rewiring; a smaller interface is the point. `presentationOf` exposes `state` for the one log field that needs it (`'known': presentation.state != null`).
- Option B — keep them as deprecated forwards for a transition period: pointless in a repo this young with all callers in-tree.

**D5 — Adapter wiring scope: does this plan touch FakeHub/HaHubClient?**
- Option A — **no (recommended)**: this plan mints `DeviceKindTraits.toggles` and wires the presentation module and views; plan 02 rewires both Hub adapters and the `HubClient` contract to consult it. Keeps the diffs disjoint and rebases trivial. Behaviour is identical either way today: `FakeHub` seeds a state for every Device, and its togglable state shapes coincide exactly with the togglable kinds.
- Option B — convert `FakeHub.toggle` here as a demonstration: cheap, but it moves plan 02's ground under it.

**D6 — Placement of the togglability declaration.**
- Option A — **standalone `panel/lib/domain/device_traits.dart` extension (recommended)**: domain-side (the Hub adapters must be able to import it without touching `ui/`), one member, designed for absorption — if plan 06's device vocabulary table exists (or lands later), `toggles` becomes a column of that table and this extension either delegates to it or is deleted; callers keep saying `kind.toggles` either way.
- Option B — put it straight into the presentation module: ui-side placement would force `FakeHub`/`HaHubClient` to import `ui/`, inverting the dependency direction. Rejected.
- Note: if plan 06 has ALREADY been implemented when you execute this plan, do not create device_traits.dart — add the `toggles` column to plan 06's table and expose the same `kind.toggles` reading surface.

---

## 5. Step-by-step implementation

Each step leaves `cd panel && flutter analyze && flutter test` green. All paths repo-relative.

**Step 1 — mint the togglability declaration.**
Create `panel/lib/domain/device_traits.dart` exactly as in section 3 (extension `DeviceKindTraits` on `DeviceKind`, single member `bool get toggles`, exhaustive switch, no wildcard).
Create `panel/test/device_traits_test.dart`:
- `'exactly light, outlet, tv and garage door kinds toggle'` — asserts `DeviceKind.values.where((k) => k.toggles)` equals `{light, outlet, tv, garageDoor}`.
Nothing consumes the file yet; tree green.

**Step 2 — build the presentation module, pure and unwired.**
Create `panel/lib/ui/device_presentation.dart` exactly as in section 3: enum `DeviceTapBehaviour { toggle, showPopup }`, class `DevicePresentation` with members `device`, `state`, `glows`, `reading`, `icon`, `tapBehaviour`, `isVideo`, `statusText`, private static `_watts`.
Create `panel/test/device_presentation_test.dart` (cases named in section 6). This is where D1, D2 and D3's ratified answers get pinned — before any view changes. Tree green (module unused, fully tested).

**Step 3 — hand the module to HubController.**
In `panel/lib/ui/hub_controller.dart`: add `import 'device_presentation.dart';` and the member
`DevicePresentation presentationOf(Device device) => DevicePresentation(device, _hub.states[device.id]);`
Leave `stateOf`/`isOn` in place for now (still have callers).
Create `panel/test/hub_controller_test.dart` (cases in section 6) — the first tests `toggleRoomLights`, `isRoomLit`, and the Listenable fold have ever had. Plain `test()`s with `FakeHub(house, driftEvery: Duration.zero)` and `loadTestHouse()` from `test/test_house.dart`; no widget pumping.

**Step 4 — the pin renders answers.**
In `panel/lib/ui/dollhouse/floor_view.dart`:
- `_pin(Device device)` becomes: `final presentation = controller.presentationOf(device);` and passes `_DevicePin(presentation: presentation)` (keep the `ValueKey('pin-${device.id}')` on the GestureDetector and the `onDeviceTap` callback unchanged).
- `_DevicePin` becomes `const _DevicePin({required this.presentation}); final DevicePresentation presentation;` — its `build` deletes both switch ladders and reads `presentation.glows` (for the glow color and icon color), `presentation.reading`, `presentation.icon`. Add `import '../device_presentation.dart';` and drop the now-unused `import '../../domain/device_state.dart';` (nothing else in floor_view.dart references a state shape after this step; leaving it in fails `flutter analyze`).
- Touch NOTHING else in this file — `_FloorPainter`, `_handleTap`, `hitTest` belong to plan 03.
Run the goldens: they must not change (same pixels, new plumbing).

**Step 5 — the tap executes a chosen behaviour; the Popup renders the rest.**
In `panel/lib/ui/device_popup.dart`: change the signature to
`Future<void> showDevicePopup(BuildContext context, {required DevicePresentation presentation})`
— add `import 'device_presentation.dart';`, read `device` via `presentation.device` (header icon/name/Local-Cloud tag unchanged), replace the local `isVideo` with `presentation.isVideo`, replace `Text(statusText(state))` with `Text(presentation.statusText)`, delete the top-level `statusText` function, drop the now-unused `device_state.dart` import. Keep the string `'Live view placeholder — go2rtc stream'` byte-identical (a test finds it).
In `panel/lib/ui/dollhouse/dollhouse_view.dart`: `_onDeviceTap` becomes

```dart
void _onDeviceTap(BuildContext context, Device device) {
  final presentation = widget.controller.presentationOf(device);
  final toggles = presentation.tapBehaviour == DeviceTapBehaviour.toggle;
  Log.debug('ui', 'device', {
    'id': device.id,
    'kind': device.kind.name,
    'action': toggles ? 'toggle' : 'popup',   // keep log values greppable-stable
    'known': presentation.state != null,
  });
  if (toggles) {
    widget.controller.toggle(device.id);
  } else {
    showDevicePopup(context, presentation: presentation);
  }
}
```

(`showDevicePopup`'s only caller is this file — verified.) Add `import '../device_presentation.dart';` (for `DeviceTapBehaviour`), delete the old `isVideo`/`toggles` derivation and the now-unused `device_state.dart` import. **This is where D1's behaviour change lands.** Add the widget test pinning it (section 6).

**Step 6 — fold the forwards; shrink the interface.**
In `panel/lib/ui/hub_controller.dart` (per D4):
- Delete `stateOf` and `isOn`.
- `isRoomLit` becomes `room.devices.any((d) => d.kind == DeviceKind.light && presentationOf(d).glows);`
- In `toggleRoomLights`, replace `if (isOn(light.id) == lit)` with `if (presentationOf(light).glows == lit)`.
`flutter analyze` confirms no stragglers reference the deleted members (no test ever did — verified by grep).

**Step 7 — full verification** (section 8), including an eyeball pass on the goldens.

Files created: `panel/lib/domain/device_traits.dart`, `panel/lib/ui/device_presentation.dart`, `panel/test/device_traits_test.dart`, `panel/test/device_presentation_test.dart`, `panel/test/hub_controller_test.dart`.
Files modified: `panel/lib/ui/hub_controller.dart`, `panel/lib/ui/dollhouse/floor_view.dart` (_pin/_DevicePin only), `panel/lib/ui/dollhouse/dollhouse_view.dart` (_onDeviceTap only), `panel/lib/ui/device_popup.dart`, `panel/test/dollhouse_test.dart` (one added test).
Files deleted: none. Hub adapters, `hub_client.dart`, `theme.dart`, `main.dart`: untouched.

---

## 6. Test plan

### New: `panel/test/device_traits_test.dart`

- `'exactly light, outlet, tv and garage door kinds toggle'`

### New: `panel/test/device_presentation_test.dart` (pure `test()`s; construct `Device`s inline; zero widget pumping)

glows:
- `'switch on glows; switch off does not'`
- `'open garage door glows; closed does not'` (pins D3)
- `'thermostat, power, status and unknown states never glow'`

reading:
- `'thermostat reads one-decimal degrees'` (`21.4°`)
- `'power under 1 kW reads whole watts'` (`812W`)
- `'power at or above 1 kW reads one-decimal compact kW'` (`1.2kW`)
- `'switch, garage door, status and unknown states show the icon face'` (reading is null)

tapBehaviour (pins D1 — first-ever pin on this behaviour):
- `'togglable kinds toggle even with unknown state'` — light/outlet/tv/garageDoor with `state: null` → `DeviceTapBehaviour.toggle` (THE behaviour change: today this opens a Popup)
- `'video kinds pop up even if the Hub reports a switch-like state'` — camera with `SwitchState` → `showPopup` (kind wins over state shape)
- `'every kind answers the matrix'` — exhaustive loop over `DeviceKind.values` asserting toggle ⇔ `kind.toggles`

statusText:
- `'switch wording: On/Off'`, `'garage door wording: Open/Closed'`
- `'thermostat wording: now and target'` (`21.4 °C now · target 21.0 °C`)
- `'power full variant shares the pin's precision'` — same `PowerState` gives `1.2kW` compact and `1.2 kW` full (pins D2; makes the birth-defect divergence structurally impossible)
- `'status state passes through; unknown reads Unknown'`

### New: `panel/test/hub_controller_test.dart` (plain tests over `FakeHub` + `loadTestHouse()`)

- `'presentationOf folds live Hub state into the answer'` — toggle `light-hall` through the hub; `presentationOf` for that Device flips `glows`
- `'isRoomLit is true when any light in the room is on; ignores non-lights'`
- `'toggleRoomLights turns every light on when none is lit'`
- `'toggleRoomLights turns every light off when any is lit'` (pins the all-or-nothing Room policy for the first time)
- `'notifies listeners on a Hub state change'`
- `'notifies listeners when the Hub connection flips'` (`hub.connected.value = false` on FakeHub's ValueNotifier) — first-ever pins on the Listenable fold consumed at main.dart:133

### Changed: `panel/test/dollhouse_test.dart`

- Existing four tests pass unchanged (light-with-SwitchState toggles; doorbell pops up — behaviour preserved).
- Add `'tapping a light pin with unknown state attempts a toggle, not a popup'`: a small inline `HubClient` stub (pattern: `_OfflineHub` in `test/golden/dollhouse_golden_test.dart` — `states => const {}`) extended to record `toggle` calls; tap `pin-light-hall`; expect one recorded toggle and `find.byType(Dialog)` finds nothing. This is the widget-level pin on D1.

### Dies

- Nothing in `test/`. In `lib/`: the top-level `statusText` function (device_popup.dart:122-132) is deleted with no test casualties (grep verified zero references).

### Golden impact

Goldens live in `panel/test/golden/goldens/` (`ground_floor.png`, `upstairs_selected.png`, `device_popup.png`, `hub_offline.png`); update via `flutter test --update-goldens test/golden`. **Expected impact: none.** The pin face is pixel-identical under D2-A/D3-A (compact format and glow rule preserved); the one golden Popup is the doorbell's video body, which carries no `statusText`. If any golden fails, that is a signal you changed a rule the plan meant to preserve — stop and inspect `test/golden/failures/*_isolatedDiff.png` rather than rubber-stamping.

### Contract: behaviours pinned for the first time

Unknown-state tap on a togglable kind (D1); kind-over-state-shape affordance; the single power format with its compact/full variants (D2); the garage-door glow (D3); the full reading/wording matrix for all five state shapes plus null; `toggleRoomLights`' all-or-nothing policy; `isRoomLit` aggregation; the stateChanges/connected Listenable fold.

---

## 7. Verification

```sh
cd panel && flutter analyze && flutter test
```

Golden-only loop while working: `cd panel && flutter test test/golden` (and `--update-goldens` only after eyeballing a legitimate change — none is expected here).

Live check, if wanted: **this Mac has Flutter via brew but NO Xcode** — run the app with `cd panel && flutter run -d chrome` (web build, FakeHub by default). Never `-d macos`. Tap a light pin, a camera pin, a Room, and (to see D1 live) temporarily comment a light's `entity:` line in `panel/assets/house/devices.yaml` — it renders with unknown state; a tap should attempt a toggle (FakeHub still seeds it, so use `HUB=ha` against the dev Hub or just trust the widget test).

---

## 8. Non-goals

Discipline notes carried from the verification pass — each deferred item has its written-down trigger:

- **No Hub-adapter rewiring.** `FakeHub.toggle`'s state-shape switch, `HaHubClient`, and the `HubClient` contract comment stay as they are. Trigger: plan 02 (`docs/plans/02-*.md`; may not be on disk yet — see section 9) points both adapters and the contract at `DeviceKindTraits.toggles`.
- **No fix for the stale-state/silent-swallow outage behaviour.** `HaHubClient` keeping `_states` across disconnects and `_send`'s null-channel no-op (ha_hub.dart:167-168) are Hub-seam concerns; this plan only removes the *affordance flicker* symptom. Trigger: plan 02, where toggle delivery feedback belongs.
- **No new DeviceKind, no lock.** The verifier noted a lock is plausible (ratgdo already exposes one) — the exhaustive switches in `device_traits.dart` and `_toDeviceState` are the compile-time checklist for that day. Trigger: the hardware actually arriving.
- **No Popup controls** (thermostat setpoint, garage open/close buttons). The presentation module is the seam they will hang off; adding them now is speculation. Trigger: phase-1 go2rtc work landing in the Popup, which is scheduled churn at exactly this seam (device_popup.dart:7-9).
- **No `deviceIcon` move.** It is already single-sourced in `theme.dart`; `DevicePresentation.icon` wraps it. Trigger: plan 06's vocabulary table absorbing icons as a column.
- **No floor_view painting/hit-testing changes** — `_FloorPainter`, `outlineSegments`, `hitTest` belong to plan 03.
- **No change to the `toggleRoomLights` policy** ("all on if none lit, all off otherwise") — the tests merely pin it as-is.

---

## 9. Cross-plan coordination

Plan numbering follows the eight review candidates (01–08), but not every candidate had produced a plan file when this plan was fact-checked (2026-08-01). On disk at that time: `01-device-presentation-module.md` (this plan), `03-floor-geometry-owner.md`, `05-floor-arrangement-module.md`, `06-device-vocabulary-table.md`, `07-hub-status-three-state.md`, `08-panel-boot-module.md`. Plans 02 (the HubClient-seam contract: both adapters agree on the toggle invariant, FakeHub becomes scriptable) and 04 (the House Plan Python/Dart schema contract) were still being written — run `ls docs/plans/` before starting, and read every "plan 02" note below as conditional on that file existing by then. Verbatim coordination notes for this plan:

- Plan 02 shares the domain-side togglability declaration: THIS plan mints it (a small pure-Dart declaration of which Device kinds toggle). If plan 02 was implemented first, the declaration already exists — reuse it. If plan 06 (device vocabulary table) exists, the declaration belongs as a column of its table instead of a standalone file; design yours so 06 can absorb it. (This plan's D6 does exactly that: the reading surface is `kind.toggles`, whatever backs it.)
- Plan 02 also rewrites the tap routing in dollhouse_view (view asks the seam "does this Device toggle"). **Coordinated end state, stated explicitly: the views ask the presentation module; the presentation module AND both Hub adapters (FakeHub and HaHubClient) consult the one domain declaration (`DeviceKindTraits.toggles`).** After this plan, the views-ask-presentation half is done and the declaration exists; plan 02 completes the adapter half and deletes the last two state-shape copies of the rule (fake_hub.dart:45-52 and the unowned comment at hub_client.dart:19-21).
- Plan 03 refactors floor_view's painting/hit-testing; this plan touches floor_view's `_DevicePin` (and the `_pin` builder) only — disjoint concerns in the same file; either order works, rebase carefully.

Discovered while writing this plan:

- `dollhouse_test.dart` and the golden tests pump the full `PanelApp`; any plan that changes `main.dart` wiring will touch the same pumps. This plan does not change `main.dart`.
- The `'action'` values in the `Log.debug('ui', 'device', ...)` line are kept as `'toggle'`/`'popup'` on purpose — log lines are greppable diagnostics; plan 02's tap-routing rewrite should preserve them too.

Added by the fact-check pass (2026-08-01), from reading the sibling plans on disk:

- **Naming reconciliation with plan 06**: plan 06's cross-plan section names the absorbed togglability rule `StateFamilyTraits.togglable`, derived from its kind→state-family column, while this plan's reading surface is `kind.toggles`. One declaration must win: whichever plan lands second reconciles the name and deletes the other copy (a one-line delegate is acceptable during the transition). Do not ship both `kind.toggles` and a divergent `togglable`.
- **Plan 05** (floor-arrangement extraction) explicitly keeps `_onDeviceTap` byte-identical because this plan owns it; both plans edit `dollhouse_view.dart` in disjoint regions (`build` there, `_onDeviceTap` here), so either order works and merges are textual. Plan 05 also demands zero golden updates — same expectation as this plan.
- **Plan 07** widens `HubClient.connected`/`HubController.connected` from a bool to a three-state Hub status and modifies `hub_client.dart`, `fake_hub.dart`, `ha_hub.dart`, `hub_controller.dart`, `main.dart`. This plan leaves `connected` untouched (disjoint members of `hub_controller.dart`), but the new `hub_controller_test.dart` case `'notifies listeners when the Hub connection flips'` pokes `FakeHub.connected` (a `ValueNotifier<bool>`) — if plan 07 lands first, write that test against the equivalent status flip instead.

---

## 10. Sources

- `CONTEXT.md` (repo root) — domain language quoted in section 2.
- `docs/adr/0001-plain-linux-kiosk-not-fuchsia-or-chromeos.md`, `0002-home-assistant-headless-hub.md`, `0003-zigbee-z2m-not-matter-thread.md`, `0004-house-plan-sweet-home-3d-yaml-pipeline.md` — binding constraints in section 2.
- `.claude/skills/codebase-design/SKILL.md` — the design vocabulary (deep module, interface, seam, adapter, leverage, locality, deletion test).
- Originating architecture review: candidate "Device presentation and affordances have no module: kind/state switches at four seams while HubController stays shallow", verdict Strong — produced as a temp HTML report (ephemeral, not in the repo); its verified findings are reproduced in full in section 1.
- Source files as of 105610c: `panel/lib/ui/hub_controller.dart`, `panel/lib/ui/dollhouse/dollhouse_view.dart`, `panel/lib/ui/dollhouse/floor_view.dart`, `panel/lib/ui/device_popup.dart`, `panel/lib/data/fake_hub.dart`, `panel/lib/data/hub_client.dart`, `panel/lib/data/ha_hub.dart`, `panel/lib/domain/house.dart`, `panel/lib/domain/device_state.dart`, `panel/lib/ui/theme.dart`, `panel/lib/main.dart`; tests under `panel/test/`.
