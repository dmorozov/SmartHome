# Panel deepening plans — index

> **Newer series:** [`sh3d-import/`](sh3d-import/README.md) (2026-08-01, written against `d01f290`) — five phases making the Sweet Home 3D drawing the source of Device placements, derived from the verified critical analysis of `sh3d-dollhouse-spec-final.md`. **Phases 0–3 have landed** (2026-08-02); only phase 4, the user manual, remains. It **supersedes plan 06 in part** (see phase 3) and interacts with plans 07/08 only through `ha_hub.dart`/`main.dart` file-level merges (see its README's coordination section).
>
> This series *is* the document once sketched as `09-sh3d-placements-pipeline.md` — that single file was never written, because splitting it per phase replaced it. There is no plan 09.
>
> Plans 01–08 below have all landed.

Eight self-contained deepening plans from the **2026-08-01 architecture review of `panel/`**, written against commit **`105610c`**. Each plan proposes one deep module (or one deepened interface) at a named seam, with the full evidence, decision points, step-by-step implementation, and test plan a fresh session needs — no plan depends on the review artifact surviving.

**How to use this directory:**

- Each plan is **implementable independently, in its own session**. Read the plan top to bottom before touching code; its section 2 carries all context, and its section 9 tells you how it composes with the others.
- Every plan quotes line numbers as of `105610c`. **Re-verify line references against HEAD before editing** — run the plan's own step-0/preconditions checks, and `ls docs/plans/` plus `git log --oneline -5` first. Several plans have "if plan N landed first…" branches; those are live instructions, not history.
- Use the design vocabulary exactly as the plans do (from `.claude/skills/codebase-design/SKILL.md`): **module / interface / implementation / seam / adapter / depth / leverage / locality / deletion test** — never component, service, API, or boundary. Use CONTEXT.md's domain words (Panel, Hub, Dollhouse, House Plan, Floor, Room, Wall, Device, Popup) — never the "avoid" synonyms.

## The plans

| Plan | Title | Strength | One-line gain | Primary files touched |
|---|---|---|---|---|
| [01](01-device-presentation-module.md) | Device presentation module | **Strong** | The whole kind-by-state matrix (pin face, tap meaning, Popup body, status wording) behind one deep module; mints the domain-side togglability declaration | new `ui/device_presentation.dart`, `domain/device_traits.dart`; `hub_controller.dart`, `floor_view.dart` (`_DevicePin`), `dollhouse_view.dart` (`_onDeviceTap`), `device_popup.dart` |
| [02](02-hubclient-contract-and-scriptable-fakehub.md) | HubClient contract + scriptable FakeHub | **Strong** | One contract suite over both Hub adapters; toggle invariant enforced at the seam (fixes the live thermostat/HVAC toggle bug); FakeHub gains a driving surface that kills the third hand-rolled adapter | `hub_client.dart`, `fake_hub.dart`, `ha_hub.dart`, `dollhouse_view.dart`; new `test/hub_contract_test.dart`, `test/support/fake_channel.dart`; golden suite |
| [03](03-floor-geometry-owner.md) | Floor/House own plan-space geometry + FloorScene | **Strong** | Floor/House grow a geometric interface (`outline`/`roomAt`/`outsideOf`/`planExtent`); the painter renders a fully decided scene; fixes the live plinth-tap-swallowed defect | `domain/house.dart` (+ new `domain/plan_geometry.dart` part), new `ui/dollhouse/floor_scene.dart`; `floor_view.dart` (painter/hitTest/`_handleTap`), `dollhouse_view.dart` (extent swap) |
| [04](04-house-plan-gatekeeper.md) | loadHouse gatekeeper + pure convert() core | **Strong** | `loadHouse` enforces every geometry invariant the Dollhouse assumes; the Python converter gains a pure, tested core; one executable contract ties the two ends of the Python/Dart seam | `house_loader.dart`, `tool/sh3d_to_yaml.py`, fixture XML + regenerated `assets/house/house.yaml`, ADR-0004, `HOUSE-PLAN.md`; new Python tests + `test/house_pipeline_contract_test.dart` |
| [05](05-floor-arrangement-module.md) | Pure floor_arrangement module | **Strong** | The floor-drift arrangement math (scales, drift, height budget, parking, projection) becomes a pure unit-tested module; the hand-derived `0.16` tap fraction dies in two test files | new `ui/dollhouse/floor_arrangement.dart`; `dollhouse_view.dart` (`build`), `dollhouse_test.dart`, `dollhouse_golden_test.dart` |
| [06](06-device-vocabulary-table.md) | Device vocabulary table + shared parser — **SUPERSEDED; shipped as [`sh3d-import/phase-3`](sh3d-import/phase-3-device-vocabulary.md) on 2026-08-02.** The scheduling and conflict rows below still name plan 06; they are history now | ~~Worth exploring~~ — **done** | Kind → slug/state-family/seed in one pure-Dart table; the two divergent devices.yaml parsers collapse into one; the dev-entity generator becomes testable | new `domain/device_vocabulary.dart`, `data/device_parser.dart`, `tool/dev_entities_core.dart`; `house.dart`, `house_loader.dart`, `fake_hub.dart`, `ha_hub.dart`, `tool/gen_dev_entities.dart` |
| [07](07-hub-status-three-state.md) | Three-state Hub status + sleep-free recovery tests | Worth exploring | `connected: bool` widens to `HubStatus {up, retrying, gaveUp}` (dead token ≠ rebooting Hub); the uncatchable `StateError` dies; the whole recovery promise gets deterministic `fake_async` tests | `hub_client.dart`, `ha_hub.dart`, `fake_hub.dart`, `hub_controller.dart`, `main.dart` (`_HubBadge`); new `test/fake_channel.dart` (+ `FakeHubServer`), `test/ha_hub_recovery_test.dart`, new golden `hub_gave_up.png` |
| [08](08-panel-boot-module.md) | Panel boot module | Worth exploring | `bootPanel` makes config validation, token redaction, and boot diagnostics testable; the badge label travels as data, so the production "HUB OFFLINE" scene finally renders | new `lib/boot.dart`, `test/boot_test.dart`, `test/fixtures.dart`; `main.dart`, `golden_setup.dart`, both dollhouse test files, regenerated `hub_offline.png` |

## Recommended implementation order

Every plan can land alone in any order — each carries "if plan N landed first…" branches. But the plans' own coordination sections imply a cheapest path:

1. **01 — Device presentation module.** Mints the shared togglability declaration (`DeviceKindTraits.toggles`, `panel/lib/domain/device_traits.dart`) and does the views-ask-the-presentation-module half of the coordinated end state. Landing it first lets plan 02 skip its declaration-minting and view-rewiring steps entirely.
2. **02 — HubClient contract + scriptable FakeHub.** Consumes 01's declaration; completes the adapter half (both Hub adapters enforce `kind.toggles` at the seam) and deletes the last state-shape copies of the rule. It also fixes the one live production bug in the series (a thermostat tap reaching `homeassistant.toggle`), which argues for landing it early. The shared decision D1 (unknown-state light tap: toggle, not Popup) is ratified once, by whichever of 01/02 lands first — the second must not re-litigate it.
3. **03 — Floor geometry owner.** Mints `House.planExtent` (the union extent), which plan 05 wants to consume; fixes the live plinth-tap defect.
4. **05 — Floor arrangement module.** With 03 landed, `FloorArrangement` calls `House.planExtent` directly (its D3 option c) instead of carrying a private extent copy that 03 would later replace.
5. **04 — House Plan gatekeeper.** Independent of the Hub track and the arrangement track; scheduled before 06 so that when 06 extracts the device parser out of `house_loader.dart`, it moves already-validated code once (both plans keep the device/geometry halves deliberately separable, so the reverse order also works).
6. **06 — Device vocabulary table.** The declared *eventual home* of the togglability declaration: with 01/02 landed, the table absorbs `toggles` as a column (`StateFamilyTraits.togglable` derived from state family) and the standalone `device_traits.dart` dies or delegates — callers keep saying `kind.toggles` either way. Landing 06 before 01/02 would instead force them to consume the table column; workable, but the naming reconciliation (`toggles` vs `togglable`) then lands in the Strong plans instead of the Worth-exploring one.
7. **07 — Hub status three-state.** Edits `hub_client.dart` compatibly beside 02's `togglable` member, reuses 02's `FakeChannel` extraction location (adding `FakeHubServer` beside it), and adapts 02's `setReachable`/contract-case-6 from the bool to the status — a mechanical, compile-driven migration 07 already plans for.
8. **08 — Panel boot module. Last, by its own instruction** ("Implement this LAST (or rebase)"): plans 01, 02, and 07 all touch files 08 reorganizes (tap routing, golden fakes, badge). Its `hub_offline.png` regeneration then happens once, on top of everything, and its `fixtures.dart` consolidates whatever test factories survived 02 and 05.

**Independent and safely parallel:**

- The **Hub track (01 → 02 → 07)** and the **geometry track (03 → 05)** are semantically disjoint and can run in parallel sessions. They share only files, not concerns: 01 and 03 both edit `floor_view.dart` (`_DevicePin` vs painter/hit-test), 01 and 05 both edit `dollhouse_view.dart` (`_onDeviceTap` vs `build`), 02 and 05 both edit the golden test (fakes vs tap lines) — all disjoint regions, textual merges only.
- **04 is parallel to everything except 06** (they restructure different halves of `house_loader.dart`).
- **08 is parallel to nothing** — it goes last.

## Conflict / coordination matrix

One line per pair of plans that touch the same files or share a decision. "Cheaper" = which order avoids rework; "either" = order-independent, expect at most a textual merge.

| Pair | How they compose | Cheaper order |
|---|---|---|
| 01 × 02 | 01 mints the togglability declaration + rewires views; 02 wires both adapters and the contract suite to it. Shared decision D1 (unknown-state light tap) ratified by whichever lands first. | **01 first** — 02 then skips its Step 1 (mint) and Step 4 (view rewiring) |
| 01 × 03 | Same file `floor_view.dart`, disjoint concerns: 01 owns `_pin`/`_DevicePin`; 03 owns `_FloorPainter`/`hitTest`/`_handleTap`. | Either; rebase carefully |
| 01 × 05 | Same file `dollhouse_view.dart`, disjoint regions: 05 owns `build`, 01 owns `_onDeviceTap` (05 keeps it byte-identical). Both add disjoint tests to `dollhouse_test.dart`. | Either |
| 01 × 06 | One togglability declaration must win: 01's `kind.toggles` extension vs 06's table-derived `togglable`. Whichever lands second reconciles the name and deletes the other copy. | **01 first** — 06 absorbs the declaration as a table column |
| 01 × 07 | 01's new `hub_controller_test.dart` pokes `FakeHub.connected` (bool); if 07 landed first, write that case against the status flip instead. | Either (one test-case adjustment) |
| 02 × 06 | Both touch `fake_hub.dart`: 02 adds the driving surface (mutations), 06 replaces the seed switch (initial state) — disjoint aspects. | Either |
| 02 × 07 | Both edit `hub_client.dart` (compatible members: `togglable` vs `status`); both extract `FakeChannel` (02 → `test/support/`, 07 → `test/` + `FakeHubServer`); 02's `setReachable` and contract case 6 assert bool or status depending on order. Whichever lands second reuses the first's location and infrastructure — never two FakeChannels. | Either; **02 first** recommended (Strong, live bug) — 07's migration is compile-driven |
| 02 × 08 | 02 deletes `_OfflineHub` and scripts the offline golden through FakeHub; 08 owns golden fixtures, `hubLabel`, and the `hub_offline.png` regeneration (08 explicitly leaves `_OfflineHub` to 02). | **02 first** (08 goes last); if 08 landed first, 02 passes `hubLabel: 'HUB'` in the rewritten scene |
| 02 × 05 | Both touch `dollhouse_golden_test.dart`: 02 rewrites fake/controller construction, 05 rewrites two tap-point lines. | Either |
| 03 × 04 | Complementary doc corrections (03: `house.dart`'s wrong per-Floor-origin comment; 04: ADR-0004's misattributed orphan-Room sentence). 03's epsilon `Wall.horizontal` and 04's strict axis-alignment gate are compatible — on gatekeeper-validated data they are identical. | Either |
| 03 × 05 | 03 mints `House.planExtent`; 05 consumes the union extent (or carries a private copy 03 later replaces). | **03 first** |
| 04 × 06 | Both restructure `house_loader.dart`: 04 adds geometry validation, 06 extracts the device parser. Both keep the device/geometry halves separable by design. | Either; **04 first** scheduled so 06 moves validated code once |
| 05 × 07 | Both touch `dollhouse_golden_test.dart`: 05 the tap lines, 07 the `_OfflineHub` → `_StubHub` stub and a new scene. | Either |
| 05 × 08 | 08 deletes the `makeController()`/`fakeHub()` factories 05's helper reads `house` from; re-point `floorSlabCentre`'s `house:` argument at 08's rig. | **05 first** (08 goes last) |
| 06 × 07 | Both touch `ha_hub.dart` in disjoint halves (06: `_toDeviceState` fold; 07: session lifecycle) and both may touch `ha_hub_live_test.dart` assertions. | Either; rebase the live-test lines |
| 07 × 08 | Same badge area in `main.dart`: 07 owns what `status` renders (three states), 08 owns where `label` comes from (data). They compose; 08 regenerates `hub_offline.png` once, after 07. 08 assumes `_OfflineHub` exists; 07 renames it `_StubHub` — whichever lands second re-points. | **07 first** (08 goes last) |

**Golden discipline across all plans:** only 07 (new `hub_gave_up.png`) and 08 (regenerated `hub_offline.png`) legitimately change goldens. Plans 01–06 all require the four committed goldens to pass **unchanged** — a golden diff under those plans is a bug in the work, never a golden to rubber-stamp. If two in-flight plans could both explain a diff, regenerate once, from the plan that predicted it.

## Shared decisions registry

Artifacts more than one plan references. Whoever implements second (or third) consumes, never re-mints.

| Artifact | Created by | Consumed by | Final home |
|---|---|---|---|
| **Domain-side togglability declaration** — the single statement of which Device kinds toggle (`kind.toggles`) | Plan 01 (`DeviceKindTraits.toggles` in `panel/lib/domain/device_traits.dart`); plan 02 mints `DeviceKind.togglable` in `house.dart` only if 01 hasn't landed | Plan 01 (views via `DevicePresentation.tapBehaviour`), plan 02 (both Hub adapters + `HubClient.togglable` + contract suite) | Plan 06's vocabulary table, as a column derived from state family (`StateFamilyTraits.togglable`); the standalone extension then delegates or dies. One name must win — never ship both `toggles` and a divergent `togglable` |
| **Ratified D1 answer** — unknown-state tap on a togglable kind attempts a toggle (kind-keyed affordance), not a Popup | Whichever of plan 01 / plan 02 lands first (same decision, same recommendation in both) | The other of 01/02; must not be re-litigated | Pinned by tests in `device_presentation_test.dart` and `dollhouse_test.dart` |
| **Session-aware fake channel infrastructure** — `FakeChannel` extracted from `ha_hub_test.dart`, plus `FakeHubServer` (fresh channel per connect attempt) | Plan 02 (extracts `FakeChannel` to `panel/test/support/fake_channel.dart`) or plan 07 (extracts to `panel/test/fake_channel.dart` and adds `FakeHubServer`) — whichever lands first fixes the path | Plan 02's contract suite (drives `HaHubClient`), plan 07's recovery suite | One file, at whichever path landed first; the second plan adds beside it, never creates a duplicate |
| **House union plan extent** — the box every Floor projects within (one `IsoProjection` for the whole Dollhouse) | Plan 03 (`House.planExtent`, with `Floor.planExtent`, in `domain/house.dart`) | Plan 05 (`FloorArrangement.fit` sizes the projection from it; carries a private `_unionPlanSize` copy only if 03 hasn't landed) | `House.planExtent` in `panel/lib/domain/house.dart` — the domain owns the fact; `_unionPlanSize` dies everywhere else |
| **Badge-label-as-data** — the Hub badge's base text (`'FAKE HUB'`/`'HUB'`) travels as a constructor parameter, not a compile-time const read inside `PanelApp.build` | Plan 08 (`PanelBoot.hubLabel`; `PanelApp` gains `required hubLabel`; `pumpPanel` gains a `'FAKE HUB'`-defaulted parameter) | Plan 02 (its rewritten hub-unreachable golden scene passes `hubLabel: 'HUB'` if 08 landed), plan 07 (its three-state `_HubBadge` renders whatever label arrives as data — orthogonal to status arity) | `lib/boot.dart` computes it; `PanelApp` receives it; only `boot.dart` may know the rule |
| **Shared widget/golden fixture rig** — one `fakeHubRig()` replacing the hand-rolled `makeController()`/`fakeHub()` factories | Plan 08 (`panel/test/fixtures.dart`, assembling at the `HubController` seam — never through `bootPanel`) | Plans 02 and 05 rewrite parts of the same test setups; whatever factories survive them, 08 consolidates | `panel/test/fixtures.dart`; it must compose scenes on FakeHub's driving surface (plan 02) and never resurrect one-off `HubClient` adapters |

## Verifying any plan's work

Every plan's per-step green gate is the same:

```sh
cd panel && flutter analyze && flutter test
```

- **Goldens** live in `panel/test/golden/goldens/`; iterate with `cd panel && flutter test test/golden`. Regenerate **only** when the plan you are executing explicitly predicts a golden change (07's new scene, 08's relabel): `cd panel && flutter test --update-goldens test/golden`, then eyeball the PNGs and `test/golden/failures/*_isolatedDiff.png` — never rubber-stamp.
- **Live checks**: `cd panel && flutter run -d chrome` (web build, FakeHub by default). **This Mac has Flutter via brew but no Xcode — never `flutter run -d macos`.** Against the dev Hub: `--dart-define=HUB=ha --dart-define=HA_URL=... --dart-define=HA_TOKEN=...` per `hub/dev/README.md`.
- Plan 04 additionally runs the Python side: `cd panel && python3 tool/test_sh3d_to_yaml.py` (and its cross-seam contract test must *skip*, not fail, where `python3` is absent).

## Updated plan

Recommended order

┌─────┬───────────────────────┬────────────────────────────────────────────────────────────────────────────────────┬─────────────────────┐
│  #  │         Work          │                                      Why here                                      │         Who         │
├─────┼───────────────────────┼────────────────────────────────────────────────────────────────────────────────────┼─────────────────────┤
│     │                       │                                                                                    │ You — it's a GUI    │
│ 1   │ Phase 0 — experiment  │ Gates phases 1–2 entirely, and decides what phase 3's parser targets. One sitting. │ task in Sweet Home  │
│     │ gate                  │                                                                                    │ 3D; no agent can    │
│     │                       │                                                                                    │ drive it            │
├─────┼───────────────────────┼────────────────────────────────────────────────────────────────────────────────────┼─────────────────────┤
│     │                       │ Independent of the experiment outcome, so it's the right thing to run in an agent  │                     │
│ 2   │ Plan 07 — three-state │ session while phase 0 is pending. Also the last remaining plan with a live         │ agent               │
│     │  Hub status           │ production defect behind it (uncatchable StateError; a wall panel that can't tell  │                     │
│     │                       │ a dead token from a rebooting Hub)                                                 │                     │
├─────┼───────────────────────┼────────────────────────────────────────────────────────────────────────────────────┼─────────────────────┤
│ 3   │ Phase 1 — placements  │ Python + fixtures only, zero Dart blast radius, goldens frozen                     │ agent               │
│     │ converter             │                                                                                    │                     │
├─────┼───────────────────────┼────────────────────────────────────────────────────────────────────────────────────┼─────────────────────┤
│ 4   │ Phase 2 — bindings    │ This is where your manual step actually dies. Everything before it is groundwork   │ agent               │
│     │ cutover               │                                                                                    │                     │
├─────┼───────────────────────┼────────────────────────────────────────────────────────────────────────────────────┼─────────────────────┤
│     │ Phase 3 — Device      │ After phase 2 so the shared parser targets bindings.yaml once instead of being     │                     │
│ 5   │ vocabulary (plan 06's │ written against devices.yaml and re-targeted                                       │ agent               │
│     │  successor)           │                                                                                    │                     │
├─────┼───────────────────────┼────────────────────────────────────────────────────────────────────────────────────┼─────────────────────┤
│ 6   │ Plan 08 — panel boot  │ Last, by its own instruction and more so now — it consolidates main.dart, the      │ agent               │
│     │ module                │ badge, and the test fixture rig that steps 2, 4 and 5 all disturb                  │                     │
└─────┴───────────────────────┴────────────────────────────────────────────────────────────────────────────────────┴─────────────────────┘

If you'd rather not park an agent on plan 07 while you do the experiment, just drop it to position 5 (between phases 2 and 3) — it collides with nothing either way.

Are 06 / 07 / 08 obsolete?

Plan 06 — partly. Its premises are dead (closed vocabulary as sole input, devices.yaml as position source, entity-id binding, the hand-transcribed slug lists). Five deliverables are not, and phase 3 carries them by name — the biggest being the dev-Hub stand-in pipeline, which has zero analogue in the spec and stays load-bearing as long as hardware is in boxes. The document is now phase 3's base, not something to implement from; I've marked it so.

Plan 07 — not obsolete, fully orthogonal. The analysis checked this specifically: the spec's three failure states are per-marker (Unbound/Unavailable/Stale), plan 07's are per-link (up/retrying/gaveUp). Different axes, and the sh3d series explicitly declines the per-marker set. Two stale details to fix when you run it, both caused by plan 02 landing: it still describes _OfflineHub in the golden test (deleted — that scene now scripts through FakeHub.setReachable), and it plans to create test/fake_channel.dart (already exists at test/support/fake_channel.dart — add FakeHubServer beside it, never a second one).

Plan 08 — not obsolete, but genuinely needs re-baselining, and its "go last" instruction is now stronger. Its boot module's stated input contract is "the two House Plan YAML texts" and it cites loadHouse({houseYaml, devicesYaml}) — phase 2 changes exactly that signature and retires that file. Run after phase 2 and the contract becomes houseYaml + bindingsYaml, a one-line adjustment; run before and you write it twice. It also deletes the makeController()/fakeHub() factories that phases 2 and plan 07 both touch, so landing it last means its hub_offline.png regeneration happens once, on top of everything.

The one branch

If E3 fails — stock Sweet Home 3D drops unknown <property> elements on save — phases 1 and 2 are dead, and the honest path is: record it in ADR-0004 as a confirmation of its original rejection, then run plan 07 → phase 3 (targeting devices.yaml as it stands) → plan 08. That still gets you the vocabulary table, the seed-triplication kill, and the testable generator core; you just keep typing positions. Worth knowing before you invest a session in phase 1.
