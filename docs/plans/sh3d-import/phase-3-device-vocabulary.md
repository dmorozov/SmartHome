# Phase 3 — the Device vocabulary table (plan 06, absorbed and corrected)

One pure-Dart vocabulary module — kind → slug, state-shape family, stand-in seed, togglability — consumed by the loader, FakeHub, HaHubClient's fold, and a purified dev-entity generator core, killing the seed triplication and collapsing seven kind-switch sites to the table plus compiler-policed icon/presentation arms. This is `docs/plans/06-device-vocabulary-table.md` carried forward into the post-cutover world, with the corrections the sh3d analysis forced.

Status: proposed · Gate: none in content (implementable today), but **do it after phase 2** so the parser work targets `bindings.yaml` once instead of twice · Written against commit `d01f290` (2026-08-01) — re-verify everything; plan 06's own line numbers were already stale at this baseline.

---

## 1. What survives from plan 06, what changed, what died

Read plan 06 (`docs/plans/06-device-vocabulary-table.md`) alongside this file: its §1 evidence, §3 module design, §4 decisions, and §6 test plan remain substantially right and are not repeated in full here. This file is the delta sheet a fresh session applies on top of it.

### Corrections to plan 06 (from the verified analysis)

1. **The baseline is stale.** Plan 06 was written at `105610c`; plans 01–05 landed since. Line numbers shifted in `house_loader.dart` (`_kind` now ~`:208`), `fake_hub.dart` (`_initialState` ~`:122-139`), `ha_hub.dart` (`_toDeviceState` ~`:299-330`), `house.dart` (enum ~`:181`); `theme.dart:38-53` and `gen_dev_entities.dart:25-53` were verified unshifted. Re-verify all of them at implementation time.
2. **There is a SEVENTH kind-switch site plan 06 never counted**: `panel/lib/domain/device_traits.dart` (landed with plan 01) — `DeviceKindTraits.toggles`, an exhaustive 14-arm switch consumed by `DevicePresentation.tapBehaviour` and by both Hub adapters via `HubClient.togglable` (landed with plan 02: `fake_hub.dart` and `ha_hub.dart` both answer `kind.toggles`). Plan 06 §9's "if they landed first" branch is now the operative one: **absorb `toggles` into the table** (`StateFamilyTraits.togglable`, derived from family), make `device_traits.dart` delegate or die, and change no observable behaviour.
3. **The parser deliverable re-targets.** Plan 06's `device_parser.dart` parsed devices.yaml (seven fields). After phase 2 the hand file is `bindings.yaml` (key → entity? + connectivity) and placements live in generated `house.yaml`. The deliverable becomes: one pure-Dart parser for **bindings.yaml** (entity regex, one-entity-one-Device clash — which still transfers verbatim, since this repo kept 1 Key : 1 entity — unknown connectivity, unknown/duplicate key detection) shared by `house_loader.dart` and the generator core. Positions stay Flutter-side (`Offset` conversion at the loader edge) exactly as plan 06 designed.
4. **The icon non-goal STANDS** (contrary to the spec's open-vocabulary pressure): this series keeps the closed `DeviceKind` enum, so `deviceIcon`'s exhaustive switch in `theme.dart` remains compiler-policed and untouched. Record the trigger honestly: if the Panel ever renders roles it did not compile against (Hub-derived capability rendering, a second authoring dialect), the enum opens and the icon leg re-enters the table as a total string→icon mapping with a fallback arm. Not today (SR-5's split: geometry and vocabulary are fail-fast at *authoring* time — the phase-1 converter validates kind slugs with the valid list in the error — so the loader's unknown-kind throw means a corrupted generated file, which is exactly when throwing is right).
5. **The generator's byte-identity check re-baselines.** Plan 06 step 5 diffs the regenerated `panel_dev.yaml` against the shipped one; after phase 2's D4 retarget the generator reads `house.yaml`'s `devices:` + emits a bindings-oriented header comment. The byte-identity acceptance stays, against the post-phase-2 shipped file.
6. **The seed-triplication kill now has three verified sites** (unchanged values): `gen_dev_entities.dart:25-53` (slug-keyed maps + thermostat consts, "Seeds match FakeHub" at `:38-39`), `fake_hub.dart` `_initialState` (`PowerState(watts: 812)`, `ThermostatState(currentC: 21.4, targetC: 21.0)`, `'Idle'`, `'Cycle · 32 min left'`), `test/ha_hub_live_test.dart:32-38` (asserts the same literals against the live dev Hub). All three read the table after this phase.
7. **StatusState is load-bearing and stays.** The sh3d spec's capability vocabulary cannot express it (7 of 14 kinds fold to StatusState in `_toDeviceState`); the five sealed `DeviceState` subclasses in `device_state.dart` (SwitchState, ThermostatState, GarageDoorState, PowerState, StatusState) are the Panel's render archetypes, and `StateFamily` mirrors them 1:1 exactly as plan 06 designed. No `role`/`capabilities` strings enter the Panel in this series.

### Died with the premises (do not implement)

- Plan 06's full devices.yaml `ParsedDevice` (roomId + position parsing — the drawing owns those now).
- Decision 6's doc-pinning targets as written (devices.yaml's header kind list is gone). Re-target: pin the slug list in `HOUSE-PLAN.md`'s marker-kind list and in the converter's `MARKER_CATALOG`/valid-slug table — those are the two hand-maintained kind lists that now exist. A five-line Python-side test (or a Dart text test) each.
- Any "if plans 01/02 haven't landed" branch — they landed.

## 2. Context a fresh session needs (beyond plan 06 §2)

- **Post-phase-2 file map**: `house.yaml` (generated: floors + devices/placements) + `bindings.yaml` (hand: key → entity?/connectivity) + `loadHouse({houseYaml, bindingsYaml})`. The generator reads `house.yaml`'s devices + derives stand-ins; `bindings_drift_test.dart` (phase 2 D5) asserts stand-in freshness with an `integratedDevices` allowlist (empty until real hardware lands).
- **The togglable safety contract is landed interface, not aspiration** (`hub_client.dart`): *"Answered from the House, never from live state — a light whose state is unknown still toggles."* The comment on `toggle` records why: nothing else protects the thermostat — the Hub's own `homeassistant.toggle` would flip the real HVAC. The sh3d spec's capabilities-are-runtime-state posture directly contradicts this; the analysis verdict (P6-4): **the contract wins.** `togglable` derives from `StateFamily` (toggle | garageDoor ⇒ true), a House-side fact, availability-independent. Any future capability-driven refinement may only ever *narrow* togglability using a cached resolved snapshot — never live-state flicker. Pin this sentence in the vocabulary module's doc comment.
- **Five-family fold shape** (plan 06 §3.3, verified current): toggle → `SwitchState(on: raw == 'on')`; garageDoor → `GarageDoorState(open: raw == 'on' || raw == 'open')`; thermostat → from `current_temperature`/`temperature` attrs, null if either missing; power → `_number(raw)` → `PowerState`; status → `StatusState(device.id, raw)`. Bodies move verbatim; `_toDeviceState` becomes a 5-arm family switch.
- **FakeHub liveliness decision (plan 06 D1a) re-ratified**: lights keep `_random.nextBool()` (`Random(7)`; only lights consume the draw sequence, iteration order unchanged) so **all four goldens stay byte-identical**. The table still carries `light → SwitchState(on: false)` because the generator needs a deterministic seed.
- Plan 07 (unlanded) touches `ha_hub.dart`'s session lifecycle and explicitly leaves `_toDeviceState` alone — disjoint; either order, textual merge.

## 3. Deliverables (plan 06 §3, re-targeted)

1. **`panel/lib/domain/device_vocabulary.dart`** — `StateFamily` (5 values), `StateFamilyTraits.togglable`, `KindSpec {slug, family, seed}`, exhaustive `specOf(kind)` (a new DeviceKind without a row is a compile error), `kindFromSlug` (null for unknown — callers own the error), 14 rows with plan 06 §3.1's exact seed values. `DeviceKind`/`Connectivity` move here; `house.dart` re-exports (plan 06 D3a — zero import churn).
2. **`panel/lib/data/bindings_parser.dart`** — the shared pure-Dart parser (correction #3): `ParsedBinding {key, entityId?, connectivity}` + validation with `bindings.yaml:`-prefixed FormatExceptions moved verbatim from the loader; the loader and the generator core both consume it.
3. **`device_traits.dart` absorbed** — `toggles` delegates to `specOf(kind).family.togglable` (or the extension moves wholesale); `hub_client.dart`'s doc comment updated to name the vocabulary as the declaration's home. Zero behaviour change; `hub_contract_test` pins it.
4. **`fake_hub.dart`** `_initialState` → two-liner (lights random, else `specOf(kind).seed(id)`).
5. **`ha_hub.dart`** `_toDeviceState` → 5-family switch, bodies verbatim.
6. **`panel/tool/dev_entities_core.dart`** — the generator's pure core (plan 06 §3.4: `DevPackage {text, binding, summary}`, `generateDevPackage(...)`, seeds via the table, name-clash as FormatException); `gen_dev_entities.dart` shrinks to the argv/IO shell. Byte-identity against the shipped `panel_dev.yaml` is the acceptance test.
7. **`ha_hub_live_test.dart`** literals → table lookups (plan 06 step 6 verbatim).
8. **Tests**: plan 06 §6's three new files, re-targeted — `device_vocabulary_test.dart` (totality, seed-shape↔family agreement, slug uniqueness/round-trip, togglability by family), `bindings_parser_test.dart`, `dev_entities_core_test.dart` (including the upgraded drift test replacing phase 2's reduced version, if D5 took the reduced form). Doc-pinning per correction #1's re-target.

## 4. Verification

```sh
cd panel && flutter analyze && flutter test        # goldens byte-identical (D1a)
dart run tool/gen_dev_entities.dart -o /tmp/panel_dev.regen.yaml \
  && diff /tmp/panel_dev.regen.yaml ../hub/dev/ha-config/packages/panel_dev.yaml
python3 tool/test_sh3d_to_yaml.py                  # untouched
# optional, dev Hub up:
flutter test test/ha_hub_live_test.dart --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"
```

Decisive technique, as in plans 04/05: mutation-test the table (wrong family for one kind → the fold test and seed-shape test both fail; drop a row → compile error — that *is* the design working).

## 5. Non-goals

- **No open vocabulary, no role/capability strings Panel-side** — trigger recorded in correction #4.
- **No icon column** (stands, correction #4), no video-affordance column (plan 06 §8's triggers unchanged).
- **Nothing writes bindings.yaml** — derive and assert only.
- **No new kinds, no schema changes, no UI changes** — behaviour-preserving throughout; goldens and the generator byte-diff are the proof.
- **After landing: retire plan 06** — mark it superseded by this file (its history and evidence stay referenced from here).
