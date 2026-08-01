# Three-state Hub status (up / retrying / gave-up) + sleep-free recovery tests

Widen `HubClient`'s single reachability member from a `bool` to a three-state Hub status so a dead token is distinguishable from a rebooting Hub, remove the uncatchable `StateError` thrown into the socket stream listener, and pin the Panel's entire recovery promise (backoff floor→double→clamp, reset on auth_ok, re-auth + re-snapshot after a Hub restart, gave-up halts) with deterministic, sleep-free tests through the seams that already exist.

Status: proposed · Strength: Worth exploring · Written against commit 105610c (2026-08-01) — re-verify line numbers before editing.

---

## 1. Why this refactor

### The friction

`HaHubClient` (`panel/lib/data/ha_hub.dart`) is the Panel's adapter for the real Hub: ~320 lines interleaving the session lifecycle (connect, authenticate, subscribe, back off, retry forever) with the entity-to-`DeviceState` fold. The lifecycle is the Panel's core appliance promise — its own class doc says so:

```dart
/// Connection handling is deliberately dumb and endless: the Panel is a
/// wall display that must recover on its own from a Hub restart, a network
/// blip, or the appliance rebooting, with nobody there to press anything.
```

(`ha_hub.dart:21-23`)

Yet that promise has **no deterministic tests**, and the interface it hides behind tells a lie. Specifics, all verified against the code at 105610c:

1. **The only reconnect test sleeps against the wall clock.** `ha_hub_test.dart:198-220` ("a dropped connection is retried") does:

   ```dart
   reconnected.serverDrops();
   await Future<void>.delayed(const Duration(milliseconds: 20));

   expect(connects, greaterThan(1));
   ```

   (`ha_hub_test.dart:215-218`). That is the entire recovery coverage: sleep 20ms, assert the connect factory was called more than once.

2. **Worse — the verification pass found the test is a crash loop, not a reconnect.** `FakeChannel`'s stream is a plain single-subscription `StreamController` (`ha_hub_test.dart:15`, `_fromServer.stream` at line 25), and the reconnect test's factory returns *the same* `FakeChannel` instance on every attempt (`ha_hub_test.dart:202-211`). So the second `_open` calls `channel.stream.listen(...)` on an already-listened stream, which throws `Bad state: Stream has already been listened to`, which is caught by `_open`'s blanket handler:

   ```dart
   } on Object catch (error) {
     Log.warn('hub', 'connect_failed', {'error': error});
     _reconnect();
   }
   ```

   (`ha_hub.dart:136-139`). The counter increments, `_reconnect` schedules the next attempt, and the loop repeats. The test passes via connect-crash-connect-crash — **a second handshake is never replayed**. The fake lacks a session concept (fresh channel per attempt); the test asserts something other than what its name claims.

3. **The backoff arithmetic is asserted nowhere.** Floor→double→clamp-to-ceiling lives at `ha_hub.dart:150-154`:

   ```dart
   _retryIn = _retryIn == Duration.zero
       ? retryFloor
       : Duration(
           microseconds:
               (_retryIn.inMicroseconds * 2).clamp(0, retryCeiling.inMicroseconds));
   ```

   Reset-to-floor on auth_ok (`_retryIn = Duration.zero;`, `ha_hub.dart:178`), re-snapshot after reconnect (the `get_states` send at `ha_hub.dart:183` runs on *every* auth_ok, which is what re-seeds states after a Hub restart), and the give-up path all have zero tests.

4. **The interface has a hidden, uncatchable error mode.** On `auth_invalid`, `_onFrame` does:

   ```dart
   case 'auth_invalid':
     // A bad token is not worth retrying — it will not fix itself.
     Log.error('hub', 'auth_invalid', fields: {'reason': message['message']});
     connected.value = false;
     _disposed = true;
     _channel?.sink.close();
     throw StateError(
         'Home Assistant rejected the token: ${message['message']}. '
         'Create a new long-lived token and rebuild with --dart-define.');
   ```

   (`ha_hub.dart:189-197`). `_onFrame` runs as the socket stream's `onData` callback (`channel.stream.listen(_onFrame, ...)`, `ha_hub.dart:127`), so **no caller can catch that StateError through the interface** — it is thrown into the stream listener zone and lands in the global error handler at best. The UI observes only `connected == false`.

5. **The `connected` bool compresses retrying and gave-up into one value.** `_HubBadge` (`main.dart:151-193`) renders `connected ? label : '$label OFFLINE'` (`main.dart:181`) with a red dot (`main.dart:174-176`). A Hub mid-reboot (recovers by itself in a minute) and a dead token (never recovers without a human minting a new long-lived token and rebuilding) show the **identical OFFLINE badge forever**. On a wall display with nobody watching a console, that distinction is exactly the thing the badge exists to communicate (`hub_client.dart:8-9`: "A wall display has nobody watching a console, so 'my readings are stale' has to be visible").

6. **Understanding "what does the Panel do when the Hub reboots" requires hand-tracing** the `_open`/`_reconnect`/`_onFrame` timer interleavings — poor locality for the single most load-bearing behavior in the file.

### The verification pass's corrections (these override the original candidate)

The original candidate proposed extracting the reconnect session into its own module with an injectable clock, claiming the policy is "only testable by sleeping." The adversarial verifier read the code and **disproved that claim**:

- **The clock seam already exists.** `fake_async` is already in `panel/pubspec.lock` (v1.3.3, transitive via flutter_test) and Dart `Timer`s are zone-hooked, so a deterministic clock is available today **with no production change**. The injectable connect factory (`WebSocketChannel Function(Uri)? connect`, `ha_hub.dart:29`, defaulted at line 39) is the other existing seam. Together they are sufficient.
- **The real harness defect is the fake, not the production code**: the single-subscription `FakeChannel` reused across attempts (point 2 above) — that is test-harness work, not a production seam.
- **Deletion test re-run on the proposed session module**: its complexity would reappear in exactly ONE caller, across a clock seam the zone already provides — one adapter, hypothetical seam. The extraction **fails the two-adapter discipline today**. It becomes real if heartbeat/ping or message-id correlation lands (that trigger is written down in Non-goals below).
- **What survives verification** is the interface defect (uncatchable error mode + retrying/gave-up compressed into one bool) and the missing deterministic coverage.
- **Churn context**: 2 of the repo's meaningful commits touch `ha_hub.dart` (`e49dd24 connect to HUB`, `70f415b added loggin and mcp`) — the repo is too young to weigh YAGNI either way, but the class doc declares recovery the Panel's core promise, so the behavior is load-bearing now.
- **No ADR conflict.**

So the plan is: **deepen `HaHubClient` behind its existing five-member interface** — widen the one reachability member to a three-state status, make gave-up an interface fact instead of a thrown-into-the-void exception, and cover the recovery behaviors with sleep-free tests through the two seams that already exist.

The deletion test still bites in the right place: deleting the *current wall-clock retry test* loses almost nothing (it never replays a handshake) — which is the symptom that the behavior is real but untested. After this plan, deleting the recovery suite would lose pinned coverage of every recovery behavior the Panel promises.

---

## 2. Context a fresh session needs

### Domain terms (CONTEXT.md — quote-level definitions this plan relies on)

- **Panel**: "The wall-mounted touchscreen running the custom dollhouse UI. There is one Panel now; more may exist later." (Avoid: kiosk, dashboard, screen.)
- **Hub**: "The headless smart-home broker (Home Assistant) that owns device state, integrations, and automations. The Panel is its client, never its replacement." (Avoid: server, backend, HA in domain discussion.)
- **Appliance**: "The always-on computer hosting the Hub and driving the Panel."
- **Device**: "A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse." (Avoid: entity — that is the Hub's internal term.)
- **Dollhouse**: "The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms." Also relevant: **House Plan**, **Floor**, **Room** — the Panel-side geometry the Dollhouse renders; the Hub never sees it.

### Design vocabulary (`.claude/skills/codebase-design/SKILL.md`)

Use these words exactly — never "component/service/API/boundary". A **module** is anything with an **interface** (everything a caller must know: signatures *plus* invariants, ordering, error modes) and an implementation. A module is **deep** when a lot of behavior sits behind a small interface; depth gives callers **leverage** and maintainers **locality**. A **seam** is where an interface lives; an **adapter** is a concrete thing satisfying an interface at a seam. The **deletion test**: delete the module — if complexity reappears across N callers it earned its keep; if it vanishes it was a pass-through. Discipline: "One adapter means a hypothetical seam. Two adapters means a real one." And: "The interface is the test surface."

### ADR constraints (binding sentences)

- **ADR-0002** (Home Assistant as headless Hub): "the custom Flutter Panel talks to its WebSocket API (the same API HA's own frontend uses) with a 10-year long-lived token." "The Hub is a black-box appliance: versions pinned, updated on our schedule, internals never modified." "A small Dart JSON-over-WebSocket client for HA must be hand-rolled (the official maintained client is JS)." — `HaHubClient` *is* that hand-rolled client; the fix must live Panel-side.
- **ADR-0001** (plain Linux kiosk): the Panel runs unattended under cage at boot — this is why recovery-with-nobody-there is the core promise, and why "needs a new token" must be legible on the wall (the only human-facing surface).
- ADR-0003 (Zigbee/Z2M) and ADR-0004 (House Plan pipeline) do not constrain this plan.

### Current-architecture tour (files this plan touches)

- **`panel/lib/data/hub_client.dart`** — the seam. Five-member abstract interface `HubClient`; the reachability member today:

  ```dart
  /// Whether the Panel currently has the Hub. A wall display has nobody
  /// watching a console, so "my readings are stale" has to be visible.
  ValueListenable<bool> get connected;
  ```

  (lines 8-10). Other members: `Map<String, DeviceState> get states`, `Stream<DeviceState> get stateChanges`, `Future<void> toggle(String deviceId)`, `void dispose()`.

- **`panel/lib/data/ha_hub.dart`** — `HaHubClient implements HubClient`, the real-Hub adapter (deep: 5-member interface over ~320 lines of handshake + backoff + fold). Key landmarks: `ValueNotifier<bool> connected = ValueNotifier(false)` at lines 78-80 (doc: "Up once the socket is open, authenticated and subscribed."); `_open()` at 121-140 (with the blanket `on Object catch` at 136); `_reconnect()` at 142-165 (backoff at 150-154, `Timer(_retryIn, ...)` at 161, the `was_connected` log distinguishing "went away" from "never there" at 155-160); `_onFrame` handshake cases at 173-197 (`auth_required` → send token, `auth_ok` → reset backoff + `connected.value = true` + `get_states` + `subscribe_events`, `auth_invalid` → the throw); the fold `_applyEntity`/`_toDeviceState` at 246-312 (untouched by this plan). Constructor takes the injectable connect factory `WebSocketChannel Function(Uri)? connect` plus `retryFloor` (default 1s) and `retryCeiling` (default 30s).

- **`panel/lib/data/fake_hub.dart`** — `FakeHub implements HubClient`, the in-memory development adapter. `final ValueNotifier<bool> connected = ValueNotifier(true);` at lines 30-31, doc: "Always up: the fake Hub is in this process."

- **`panel/lib/ui/hub_controller.dart`** — presentation state, one `Listenable` for the widget tree. Reads the bool: `bool get connected => _hub.connected.value;` (line 19); wires `hub.connected.addListener(notifyListeners)` (line 15) and removes it in `dispose()` (line 54).

- **`panel/lib/main.dart`** — hub selection via `--dart-define=HUB=fake|ha` (`_hubKind` at line 63, `_hub()` at 65-86); `PanelApp` builds `_HubBadge(label: _hubKind == 'fake' ? 'FAKE HUB' : 'HUB', connected: controller.connected)` inside a `ListenableBuilder` (lines 117-123). `_HubBadge` (151-193): green/red dot at 174-176, `connected ? label : '$label OFFLINE'` at 181. Doc at 148-150: "Hub reachability, always visible… 'these readings are frozen' must be legible from across the room."

- **`panel/test/ha_hub_test.dart`** — `FakeChannel`/`_FakeSink` hand-driven WebSocketChannel (lines 14-48: `serverSays` plays a frame, `serverDrops` closes the stream, `sent` records client writes); the `connectAndSeed` handshake helper (59-66, uses `pumpEventQueue()`); seven behavior tests plus the sleeping reconnect test (198-220).

- **`panel/test/ha_hub_live_test.dart`** — talks to a REAL development Hub, skipped without `HA_TOKEN`. Asserts `hub.connected.value, isTrue` at line 30.

- **`panel/test/golden/dollhouse_golden_test.dart`** — four golden scenes rendered via `pumpPanel(tester, controller)`; the "hub unreachable" scene (64-70) uses `_OfflineHub` (76-91), a stub `HubClient` with `ValueNotifier<bool> connected = ValueNotifier(false)` and empty states. Its doc: "The most important scene to be able to recognise at a glance, and the hardest to reach by hand." Goldens live in `panel/test/golden/goldens/` (`ground_floor.png`, `upstairs_selected.png`, `device_popup.png`, `hub_offline.png`).

- **`panel/pubspec.yaml`** — dev_dependencies today: `flutter_test`, `flutter_lints` only. `fake_async 1.3.3` is present in `pubspec.lock` transitively; importing it directly from tests requires declaring it (the `depend_on_referenced_packages` lint in flutter_lints fires otherwise).

- **`panel/test/test_house.dart`** — `loadTestHouse()` loads the real shipped `assets/house/*.yaml` from disk; every hub test uses it.

### Complete inventory of `connected` consumers (each one migrates in step 1)

| Consumer | Location | Today |
|---|---|---|
| `HubClient.connected` declaration | `hub_client.dart:10` | `ValueListenable<bool>` |
| `HaHubClient.connected` | `ha_hub.dart:78-80`, disposed at 118; read at 144, writes at 145, 179, 192 | `ValueNotifier<bool>(false)` |
| `FakeHub.connected` | `fake_hub.dart:30-31`, disposed at 58 | `ValueNotifier<bool>(true)` |
| `HubController.connected` + listener wiring | `hub_controller.dart:15, 19, 54` | `bool` getter |
| `_HubBadge` + call site | `main.dart:119-122, 151-193` | `bool connected` field |
| `_OfflineHub.connected` (golden stub) | `test/golden/dollhouse_golden_test.dart:78, 90` | `ValueNotifier<bool>(false)` |
| handshake test assertion | `test/ha_hub_test.dart:94` | `hub.connected.value, isTrue` |
| sleeping reconnect test | `test/ha_hub_test.dart:219` | `hub.connected.value, isFalse` (test is deleted, section 6 step 5) |
| live test assertion | `test/ha_hub_live_test.dart:30` | `hub.connected.value, isTrue` |

`grep -rn "connected" panel/lib panel/test --include="*.dart"` before starting; anything new since 105610c joins the table. (The grep also hits log *names* that are not the interface member — leave these alone: the `hub.connected` log event in a doc comment at `log.dart:5`, its formatting test at `log_test.dart:19-22`, its emit site `Log.info('hub', 'connected', ...)` at `ha_hub.dart:180`, and the `was_connected` log field at `ha_hub.dart:155-159`, whose surrounding lines step 1 rewrites but whose name and meaning stay.)

---

## 3. Target design

**No new module.** `HaHubClient` stays one deep module behind the existing five-member `HubClient` interface at the existing seam (`panel/lib/data/hub_client.dart`). The deepening is entirely in the interface's honesty: the one reachability member widens from a `bool` that lies by omission to a three-state status that names every condition the wall needs to distinguish, and the interface sheds a hidden error mode (the uncatchable StateError). Member count unchanged; one more behavior per interface fact — that is leverage.

### The interface

In `panel/lib/data/hub_client.dart`:

```dart
/// How the Panel's link to the Hub stands. A wall display has nobody
/// watching a console, so "my readings are stale" — and whether waiting
/// will fix it — has to be visible.
enum HubStatus {
  /// Socket open, authenticated, subscribed: readings are live.
  up,

  /// The Hub is unreachable and the client is backing off and retrying
  /// forever on its own. Also the state before the first connection.
  /// Waiting fixes it.
  retrying,

  /// The Hub rejected the token. Retrying cannot fix it; the client has
  /// stopped. A human must mint a new long-lived token and rebuild
  /// (--dart-define=HA_TOKEN, see hub/dev/README.md).
  gaveUp,
}

abstract interface class HubClient {
  /// The Hub link's status, live. Replaces the old `connected` bool, which
  /// compressed retrying and gave-up into one indistinguishable value.
  ValueListenable<HubStatus> get status;

  // states / stateChanges / toggle / dispose unchanged.
}
```

### The adapters

`HaHubClient` (`ha_hub.dart`):

```dart
/// Retrying until the socket is open, authenticated and subscribed; up
/// after; gaveUp only when the Hub rejects the token.
@override
final ValueNotifier<HubStatus> status = ValueNotifier(HubStatus.retrying);
```

- `_reconnect()`: `final wasConnected = status.value == HubStatus.up;` then `status.value = HubStatus.retrying;` (the `was_connected` log field keeps its name and meaning).
- `auth_ok`: `status.value = HubStatus.up;` (backoff reset and snapshot/subscribe sends unchanged).
- `auth_invalid`: becomes a state transition instead of a throw:

  ```dart
  case 'auth_invalid':
    // A bad token is not worth retrying — it will not fix itself. Stop,
    // and say so where the wall can see it: gave-up is a different
    // problem from a Hub reboot, and it needs a human with a new token.
    Log.error('hub', 'auth_invalid', fields: {'reason': message['message']});
    _disposed = true;
    status.value = HubStatus.gaveUp;
    _channel?.sink.close();
  ```

  No `throw`. `_disposed = true` already guarantees the loop halts: the socket close will fire `onDone` → `_reconnect()`, which returns immediately on `if (_disposed || _retryTimer != null) return;` (`ha_hub.dart:143`). `dispose()` still runs later and closes `_changes` / disposes `status` exactly once — same shape as today.
- `dispose()`: `connected.dispose()` → `status.dispose()`.

`FakeHub` (`fake_hub.dart`):

```dart
/// Always up: the fake Hub is in this process.
@override
final ValueNotifier<HubStatus> status = ValueNotifier(HubStatus.up);
```

### The callers

`HubController` (`hub_controller.dart`) forwards the status instead of a bool — still one fact:

```dart
/// The Hub link's status, for the badge.
HubStatus get status => _hub.status.value;
```

(listener wiring: `hub.status.addListener(notifyListeners)` / `removeListener` in `dispose()`.)

`_HubBadge` (`main.dart`) renders all three states — this is where the new behavior lands, in one widget (locality):

```dart
class _HubBadge extends StatelessWidget {
  const _HubBadge({required this.label, required this.status});

  final String label;
  final HubStatus status;
  // dot color: up → green 0xFF4CAF50, otherwise red 0xFFE05A5A (unchanged);
  // text: switch (status) {
  //   HubStatus.up => label,
  //   HubStatus.retrying => '$label OFFLINE',
  //   HubStatus.gaveUp => '$label NEEDS NEW TOKEN',
  // }
}
```

### What hides inside, what gets deleted

Hidden inside `HaHubClient`, exactly as today: socket lifecycle, timer bookkeeping, backoff arithmetic, auth-handshake ordering, dispose-vs-retry races, and the entity fold. Nothing about timers or backoff leaks into the interface — tests reach them through the injectable connect factory (existing seam) plus `fake_async`'s zone (the clock seam Dart already provides).

Deleted: the `StateError` throw (`ha_hub.dart:195-197`), the hidden-error-mode sentence it implied in the interface, and the sleeping crash-loop test (`ha_hub_test.dart:198-220`).

### Before / after shape

```
BEFORE
  main.dart(_HubBadge) --reads--> HubController.connected (bool)
  HubController --listens--> HubClient.connected(bool) + stateChanges
  HaHubClient [deep: 5-member interface over ~320 lines] --implements--> HubClient
  FakeHub [same interface, in-memory, always-true] --implements--> HubClient
  hidden edge (shallow lie in the interface):
    _onFrame(auth_invalid) --throws StateError into--> stream listener zone
                                                       (no catcher; UI sees false)
  ha_hub_test --injects--> connect factory returning ONE single-subscription
    FakeChannel (second listen crashes; "reconnect" test = crash loop)
    and --sleeps 20ms against--> wall clock

AFTER
  main.dart(_HubBadge) --renders--> HubController.status (HubStatus)
                                    up | retrying ("OFFLINE") | gaveUp ("NEEDS NEW TOKEN")
  HubController --listens--> HubClient.status(HubStatus) + stateChanges
  HaHubClient --sets--> gaveUp on auth_invalid (no throw); lifecycle + fold stay internal
  FakeHub --pins--> up
  recovery tests --drive--> FakeHubServer (fresh FakeChannel per connect attempt)
    inside fakeAsync zone [zone = existing clock seam]
    --asserting--> backoff floor/double/clamp · reset on auth_ok ·
                   re-auth + re-snapshot after restart · gaveUp halts retries
  session-module extraction --deferred until--> a second adapter appears
    (heartbeat/ping, message-id correlation)
```

---

## 4. Decision points

Each needs ratification by the user (or a deliberate accept-the-recommendation note in the implementing session).

**D1 — Shape of the widened member.**
Options: (a) `enum HubStatus { up, retrying, gaveUp }` exposed as `ValueListenable<HubStatus> get status`, replacing `connected` outright; (b) keep `connected` as a bool and add a second member (`gaveUp` flag or error stream); (c) a sealed class hierarchy carrying a reason string on gaveUp.
**Recommended: (a).** (b) grows the interface to two members that can contradict each other — the exact bool-plus-exception shape we are removing. (c) buys nothing today: the badge needs three renderable states, not prose; the reason already goes to the log (`hub.auth_invalid reason=...`). Enum + rename keeps the member count at five and makes every `connected` call site fail to compile, which is the migration checklist enforcing itself.

**D2 — A fourth `connecting` state?**
The old candidate text mentions the bool compressing "connecting/up/retrying/gave-up". Options: three states (never-connected-yet folds into `retrying`) vs four.
**Recommended: three.** The wall renders "not up but self-healing" identically whether it is the first attempt or the fortieth; the `was_connected` log field (`ha_hub.dart:155-160`) already separates "the Hub went away" from "it was never there" for the human reading journald. A fourth state is interface with no renderer behind it.

**D3 — gave-up badge rendering (this CHANGES current behavior).**
Today a dead token shows `HUB OFFLINE` (red) forever — indistinguishable from a reboot. After this plan it renders differently. Options for the gaveUp text: (a) `$label NEEDS NEW TOKEN`, red dot unchanged; (b) `$label BAD TOKEN`; (c) amber dot + text.
**Recommended: (a).** It names the action, not the diagnosis — the person at the wall needs to know what to *do*. Keep the red dot: both non-up states mean "readings are stale", and one dot color per severity keeps the across-the-room semantics (green = live, red = not) intact. Record explicitly: a Panel that was showing OFFLINE on a bad token will now show NEEDS NEW TOKEN — that is the point, but it is a visible behavior change.

**D4 — Where `HubStatus` lives.**
Options: `panel/lib/data/hub_client.dart` (next to the interface) vs `panel/lib/domain/` (next to `DeviceState`).
**Recommended: hub_client.dart.** `DeviceState` is house/domain vocabulary the Dollhouse renders; `HubStatus` is a fact about the Panel-to-Hub link — it belongs at the seam that defines that link. Also keeps the diff local.

**D5 — Extract the fake channel harness to a shared test file now?**
Options: keep `FakeChannel`/`_FakeSink` inside `ha_hub_test.dart` and duplicate for the recovery suite, vs extract to `panel/test/fake_channel.dart` together with the new `FakeHubServer`.
**Recommended: extract.** The recovery suite is a second consumer today (two adapters — the seam is real, not hypothetical), and the cross-plan notes say plan 02's contract suite drives `HaHubClient` via `FakeChannel` too — whichever plan lands second reuses this file.

**D6 — `HubController` surface: forward the enum or keep a bool convenience?**
Options: replace `bool get connected` with `HubStatus get status`, vs keep both.
**Recommended: replace.** One fact, one member; `_HubBadge` is the only reader and it needs all three states. (Cross-plan: plan 08 touches the same call site — see section 10.)

**D7 — New golden scene for gave-up?**
Options: pin `hub_gave_up.png` as a fourth stub-driven scene, vs assert the badge text with a widget test only.
**Recommended: golden.** The existing offline scene's doc gives the reason: "The most important scene to be able to recognise at a glance, and the hardest to reach by hand" — that goes double for a dead token, which in real life appears once a decade. Cost: one ~100-200 KB PNG.

---

## 5. Step-by-step implementation

Each step leaves `flutter analyze` and `flutter test` green. All paths relative to `panel/`.

### Step 1 — Widen the interface member (mechanical, compile-driven)

Files modified: `lib/data/hub_client.dart`, `lib/data/ha_hub.dart`, `lib/data/fake_hub.dart`, `lib/ui/hub_controller.dart`, `lib/main.dart`, `test/golden/dollhouse_golden_test.dart`, `test/ha_hub_test.dart`, `test/ha_hub_live_test.dart`.

1. In `hub_client.dart`: add the `HubStatus` enum (doc comments from section 3) and replace `ValueListenable<bool> get connected;` with `ValueListenable<HubStatus> get status;`.
2. `ha_hub.dart`: `connected` → `final ValueNotifier<HubStatus> status = ValueNotifier(HubStatus.retrying);`; in `_reconnect()` the two lines at 144-145 become `final wasConnected = status.value == HubStatus.up;` / `status.value = HubStatus.retrying;`; in `auth_ok` (line 179) `status.value = HubStatus.up;`; in `auth_invalid` (line 192) `connected.value = false;` → `status.value = HubStatus.gaveUp;` **keeping the throw for now** (removed in step 2 so each step changes one thing); in `dispose()` `connected.dispose()` → `status.dispose()`.
3. `fake_hub.dart`: `ValueNotifier(true)` → `ValueNotifier<HubStatus>(HubStatus.up)`, member renamed `status`, `dispose` updated. Keep the "Always up" doc.
4. `hub_controller.dart`: import stays (`../data/hub_client.dart` already imported); getter becomes `HubStatus get status => _hub.status.value;`; listener wiring at lines 15 and 54 renamed.
5. `main.dart`: `_HubBadge(label: ..., status: controller.status)`; `_HubBadge` field `final HubStatus status;`; dot color `status == HubStatus.up ? green : red`; text via the three-arm switch — for THIS step render gaveUp identically to retrying (`'$label OFFLINE'`) so no golden changes yet.
6. `test/golden/dollhouse_golden_test.dart`: `_OfflineHub.connected` → `status = ValueNotifier(HubStatus.retrying)` (import `package:panel/data/hub_client.dart` is already there).
7. `test/ha_hub_test.dart:94` → `expect(hub.status.value, HubStatus.up);` and line 219 → `expect(hub.status.value, HubStatus.retrying);` (test still present until step 5). Import `package:panel/data/hub_client.dart`.
8. `test/ha_hub_live_test.dart:30` → `expect(hub.status.value, HubStatus.up, reason: 'never authenticated');` plus the import.

Green check: `flutter analyze && flutter test`. No golden diffs expected (badge output unchanged for every state reachable in the goldens).

### Step 2 — auth_invalid becomes gaveUp; badge renders it; new golden

Files modified: `lib/data/ha_hub.dart`, `lib/main.dart`, `test/golden/dollhouse_golden_test.dart`. Files created: `test/golden/goldens/hub_gave_up.png` (generated).

1. `ha_hub.dart` `auth_invalid` case: delete the `throw StateError(...)` (three lines, 195-197); the case body is now exactly the four lines quoted in section 3 (log, `_disposed = true`, `status.value = HubStatus.gaveUp`, sink close). Keep the "not worth retrying" comment, extend it per section 3.
2. `main.dart` `_HubBadge`: gaveUp arm becomes `'$label NEEDS NEW TOKEN'` (per D3).
3. Golden test: generalize `_OfflineHub` into `_StubHub` taking the status — `class _StubHub implements HubClient { _StubHub(HubStatus s) : status = ValueNotifier(s); final ValueNotifier<HubStatus> status; ... }` (states/stateChanges/toggle/dispose as today, `dispose` also disposing `status`). Keep the existing doc comment on the class; the "hub unreachable" scene uses `_StubHub(HubStatus.retrying)`, and add the new scene:

   ```dart
   goldenTest('hub gave up: token rejected', (tester) async {
     final house = loadTestHouse();
     await pumpPanel(tester,
         HubController(house: house, hub: _StubHub(HubStatus.gaveUp)));
     await expectLater(find.byType(PanelApp),
         matchesGoldenFile('goldens/hub_gave_up.png'));
   });
   ```

4. Generate: `flutter test --update-goldens test/golden`. Eyeball `hub_gave_up.png` (badge must read `FAKE HUB NEEDS NEW TOKEN`, red dot) and confirm `hub_offline.png` is byte-identical or within tolerance (it should not change).

### Step 3 — Test harness: shared fake channel + session-aware server + fake_async dependency

Files created: `test/fake_channel.dart`. Files modified: `pubspec.yaml`, `test/ha_hub_test.dart`.

1. `pubspec.yaml` dev_dependencies: add `fake_async: ^1.3.3` (already at 1.3.3 in the lockfile via flutter_test; declaring it satisfies `depend_on_referenced_packages`). Run `flutter pub get`.
2. Create `test/fake_channel.dart`: move `FakeChannel` and `_FakeSink` verbatim from `ha_hub_test.dart` (they are lines 12-48 there; keep the doc comments), and add the session-aware factory:

   ```dart
   /// Plays the Hub's side of the socket across reconnects: hands the
   /// client a fresh [FakeChannel] per connect attempt, the way a real
   /// server would — a [FakeChannel]'s stream is single-subscription, so
   /// reusing one across attempts turns every retry into a listen() crash
   /// instead of a session.
   class FakeHubServer {
     final attempts = <FakeChannel>[];

     /// The channel of the latest connect attempt.
     FakeChannel get current => attempts.last;

     WebSocketChannel connect(Uri _) {
       final channel = FakeChannel();
       attempts.add(channel);
       return channel;
     }
   }
   ```

3. `ha_hub_test.dart`: delete the moved classes, `import 'fake_channel.dart';`. Leave the existing `setUp` shape alone (one channel is fine for the never-reconnecting fold tests).

### Step 4 — The recovery suite (sleep-free)

File created: `test/ha_hub_recovery_test.dart`. See section 6 for the case list. Skeleton facts the implementer needs:

- `fakeAsync((async) { ... })` bodies are synchronous; replace `await pumpEventQueue()` with `async.flushMicrotasks()`. Stream events from `FakeChannel`'s controller (including the done event after `serverDrops()`) are delivered on microtasks, so `flushMicrotasks()` after every `serverSays`/`serverDrops` suffices; `async.elapse(d)` fires the retry `Timer`s.
- Construct the client *inside* the fakeAsync zone and `dispose()` it inside too (its Timers live in that zone). Use production-scale durations — `retryFloor: 1s, retryCeiling: 30s` — they cost nothing under a fake clock and pin the real defaults' arithmetic.
- Handshake helper (local to this file):

  ```dart
  void handshake(FakeAsync async, FakeChannel channel,
      {List<Map<String, dynamic>> entities = const []}) {
    channel.serverSays({'type': 'auth_required', 'ha_version': '2026.7'});
    async.flushMicrotasks();
    channel.serverSays({'type': 'auth_ok', 'ha_version': '2026.7'});
    async.flushMicrotasks();
    // The client ignores the echoed id on List results, so any id works —
    // after a reconnect the real id is no longer 1 (_nextId keeps counting).
    channel.serverSays(
        {'id': 0, 'type': 'result', 'success': true, 'result': entities});
    async.flushMicrotasks();
  }
  ```

- Backoff is asserted by attempt counting around `async.elapse`: after a drop, `async.elapse(expected - 1ms)` → `server.attempts.length` unchanged; `async.elapse(1ms)` → incremented. Expected delay sequence with floor 1s / ceiling 30s: `1, 2, 4, 8, 16, 30, 30, 30` (16→32 clamps to 30; `ha_hub.dart:150-154`).

### Step 5 — Delete the sleeping test

File modified: `test/ha_hub_test.dart`: remove `'a dropped connection is retried'` (the whole block, formerly lines 198-220) — the recovery suite supersedes it with real handshake replay. Nothing else in that file references its locals.

### Step 6 — Full verification pass

Section 8. Then update `CONTEXT.md`? No — no new domain terms (HubStatus is design vocabulary at the seam, not house language). No ADR needed (no architectural decision reversed; the verifier confirmed no ADR conflict).

---

## 6. Test plan

### New file: `panel/test/ha_hub_recovery_test.dart`

All cases run inside `fakeAsync`, drive a `FakeHubServer`, and never sleep. Names as they should appear:

1. **`'backs off from the floor, doubles, and holds the ceiling forever'`** — connect, `handshake`, drop; then for each expected delay in `[1s, 2s, 4s, 8s, 16s, 30s, 30s, 30s]`: assert no new attempt just before, a new attempt exactly at, the delay; drop each new channel immediately (no handshake) so the backoff keeps compounding. Pins `ha_hub.dart:150-154` for the first time.
2. **`'auth_ok resets the backoff to the floor'`** — drive the backoff to the ceiling as above; then complete a full `handshake` on `server.current`; drop again; assert the next attempt comes at `retryFloor`, not the ceiling. Pins `_retryIn = Duration.zero` (`ha_hub.dart:178`).
3. **`'a Hub restart replays the handshake and re-seeds the snapshot'`** — `handshake` with entity `light_hall on`; assert `states['light-hall']` on and `status.value == HubStatus.up`; `serverDrops`; assert `status.value == HubStatus.retrying`; `async.elapse(1s)`; on the fresh `server.current` assert the client re-sent `{'type': 'auth', 'access_token': ...}` after `auth_required`, then after `auth_ok` re-sent `get_states` **and** `subscribe_events`; answer the snapshot with `light_hall off`; assert `states['light-hall']` now off and `status.value == HubStatus.up`. Pins re-auth + re-snapshot (`ha_hub.dart:183-188`) — the behavior the old test claimed to cover and never did.
4. **`'auth_invalid gives up: status changes, retries stop, nothing is thrown'`** — first channel: `serverSays auth_required`, flush, `serverSays auth_invalid`, flush. Assert `status.value == HubStatus.gaveUp`, `server.current.closed` is true, and `async.elapse(minutes: 5)` leaves `server.attempts.length == 1`. The absence of an unhandled error inside `fakeAsync` *is* the no-throw assertion (before step 2 this test would blow up the zone). Pins the gave-up contract for the first time.
5. **`'dispose while a retry is pending cancels it'`** — connect, drop, flush (retry timer now pending), `hub.dispose()`, `async.elapse(minutes: 1)`; assert `server.attempts.length == 1`. Pins the dispose-vs-retry race named in the deletion-test reasoning.

### Existing tests that change or die

- **Dies**: `'a dropped connection is retried'` (`ha_hub_test.dart:198-220`) — the crash-loop test; superseded by cases 1 and 3.
- **Changes (step 1, mechanical)**: `ha_hub_test.dart:94`, `ha_hub_live_test.dart:30` → `HubStatus.up`.
- **Changes (steps 2-3)**: golden stub `_OfflineHub` → `_StubHub(HubStatus.retrying)`; `FakeChannel`/`_FakeSink` move to `test/fake_channel.dart`.
- **Untouched**: all fold tests in `ha_hub_test.dart` (97-196), `fake_hub_test.dart`, `dollhouse_test.dart`, `house_loader_test.dart`, `log_test.dart`, `plan_geometry_test.dart` — none reads `connected`.

### Golden impact

Goldens live in `panel/test/golden/goldens/`; update via `cd panel && flutter test --update-goldens test/golden`.

- `hub_offline.png` — expected unchanged (retrying renders exactly the old offline badge). If it diffs, something in step 1/2 changed the retrying render — investigate, don't rubber-stamp.
- `hub_gave_up.png` — **new** (D7): red dot, `FAKE HUB NEEDS NEW TOKEN`.
- `ground_floor.png`, `upstairs_selected.png`, `device_popup.png` — unchanged (FakeHub pins `up`; badge renders the plain label as before).

### Behaviors pinned for the first time

Backoff floor→double→clamp with the real defaults; backoff reset on auth_ok; re-auth and re-snapshot (state re-seed) after a Hub restart; status transitions up→retrying→up across an outage; token rejection halting the client without a throw; gaveUp badge render; dispose cancelling a pending retry.

---

## 7. Verification

```sh
cd panel && flutter analyze && flutter test
```

Both must be clean after every step in section 5. Golden regeneration when steps 2/D7 land:

```sh
cd panel && flutter test --update-goldens test/golden
```

then eyeball the PNGs (and `failures/*_isolatedDiff.png` on any mismatch).

Live check, if wanted: **this Mac has Flutter via brew but NO Xcode** — never `flutter run -d macos`. Use the web build:

```sh
cd panel && flutter run -d chrome
```

(defaults to the FakeHub → badge shows `FAKE HUB`, green; there is no cheap live path to gaveUp — that is what the golden is for). Against the real development Hub, `--dart-define=HUB=ha --dart-define=HA_URL=... --dart-define=HA_TOKEN=...` per `hub/dev/README.md`; a deliberately wrong token is a manual end-to-end check of the NEEDS NEW TOKEN badge. The hermetic live test still runs with `flutter test test/ha_hub_live_test.dart --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"`.

---

## 8. Non-goals

Straight from the verifier's discipline notes, with triggers written down:

- **No session-module extraction.** The reconnect session stays inside `HaHubClient`. Today it would be a one-adapter seam duplicating the clock seam the zone already provides — "one adapter means a hypothetical seam." **Trigger to revisit**: session logic genuinely grows — heartbeat/ping keepalive, or message-id correlation of results to requests. Either lands a second consumer of session mechanics; extract then.
- **No injectable clock in production code.** `fake_async`'s zone hooks Dart `Timer`s already; adding a clock parameter to `HaHubClient` would be interface for nothing.
- **No change to the entity fold** (`_applyEntity`/`_toDeviceState`), to `DeviceState`, or to the fact that `_states` retains last readings while retrying. (Observed in passing: the golden offline stub shows empty states with the comment "every Device unknown rather than frozen on its last reading", while the real `HaHubClient` keeps stale states during an outage. Possibly a real gap — but it is not this plan's, and not this plan's to silently change.)
- **No message-id correlation** of `result` frames (the `result is List` heuristic at `ha_hub.dart:206-208` stands).
- **No FakeHub reachability scripting** — that driving surface belongs to plan 02.
- **No badge-label-as-data refactor of `PanelApp`** — that is plan 08's.
- **No retry-forever policy change**: retrying still never gives up on network failure; only `auth_invalid` gives up, exactly as the code comments intend today.

---

## 9. Cross-plan coordination

Plan numbering follows the eight review candidates (01-08), but not every candidate produced a plan file. At 105610c, `docs/plans/` holds exactly four: this file (`07-hub-status-three-state.md`), `01-device-presentation-module.md`, `05-floor-arrangement-module.md`, and `08-panel-boot-module.md`. Plans 02, 03, 04 and 06 are referenced below by candidate number only and had no file when this was written — `ls docs/plans/` before starting, and read every "plan 02" note as conditional on such a file existing by then. Notes received verbatim, plus discoveries:

- **Plan 02** adds a togglability member to `hub_client.dart` and a driving surface to `FakeHub` — both plans edit the interface; compatible. If 02 landed, its FakeHub reachability scripting should set your three-state status. (Discovery: if 02 lands first, its `FakeHub` surface will be written against the `connected` bool — the step-1 migration table in section 2 then gains rows; re-run the grep.)
- **Plan 02**'s contract suite drives `HaHubClient` via `FakeChannel`; your session-aware fake connect factory (fresh channel per attempt) is shared infrastructure — whichever lands second reuses it. (This plan puts it in `panel/test/fake_channel.dart` as `FakeHubServer` — D5. If 02 landed first and already extracted `FakeChannel` somewhere, reuse its location and just add `FakeHubServer` beside it.)
- **Plan 08** passes the badge label into `PanelApp` as data; you change what `_HubBadge` renders (retrying vs needs-a-new-token) — same widget area in `main.dart` (lines 117-123 and 151-193), coordinate. The changes compose (08 owns where `label` comes from; this plan owns what `status` renders), but land them in separate commits and rebase deliberately. (Discoveries from reading `08-panel-boot-module.md` at 105610c: its own coordination section says to implement 08 last, or rebase; if both plans regenerate `hub_offline.png`, regenerate once, after this plan, with both changes in — this plan expects that golden *unchanged*, so any diff must come from 08's label change, not from step 1/2 here. Plan 08 also assumes `_OfflineHub` still exists in `dollhouse_golden_test.dart`, which this plan's step 2 renames to `_StubHub` — whichever lands second re-points that reference.)
- **`HubController.connected` and `main.dart`'s badge read the bool today — enumerate every consumer you migrate.** Done: the nine-row table in section 2 is that enumeration; verify it against HEAD with `grep -rn "connected" panel/lib panel/test --include="*.dart"` before step 1 (excluding the log-name hits listed under the table in section 2: `log.dart:5`, `log_test.dart:19-22`, `ha_hub.dart:180`, and the `was_connected` field at `ha_hub.dart:155-159`).
- Plan 01 precedent cited in the brief: record kind-keyed affordance changes as behavior changes. This plan's equivalent is D3 — the gaveUp badge text is a deliberate, visible change from today's undifferentiated OFFLINE.

---

## 10. Sources

- `CONTEXT.md` (repo root) — domain language quoted in section 2.
- `docs/adr/0001-plain-linux-kiosk-not-fuchsia-or-chromeos.md`, `docs/adr/0002-home-assistant-headless-hub.md`, `docs/adr/0003-zigbee-z2m-not-matter-thread.md`, `docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md` — constraints quoted in section 2.
- `.claude/skills/codebase-design/SKILL.md` — deep module / interface / seam / adapter / leverage / locality / deletion test, quoted in section 2.
- Originating architecture review: candidate 6 ("The endless-reconnect session inside HaHubClient has no internal seam…") plus its adversarial verification verdict (strength: Worth exploring), which corrected the candidate — the review artifact was a temp HTML page and is ephemeral; everything load-bearing from it is reproduced in sections 1 and 8.
- Code read at 105610c: `panel/lib/data/{hub_client,ha_hub,fake_hub}.dart`, `panel/lib/ui/hub_controller.dart`, `panel/lib/main.dart`, `panel/test/{ha_hub_test,ha_hub_live_test,test_house}.dart`, `panel/test/golden/{dollhouse_golden_test,golden_setup}.dart`, `panel/pubspec.yaml`, `panel/pubspec.lock`.
