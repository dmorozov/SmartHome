# Phase 2 — the bindings cutover

Flip the seam: `loadHouse` consumes the converter's generated Placements joined with a new hand-maintained `bindings.yaml` (Key → Hub entity + connectivity), and `devices.yaml` dies. Keys become Device identity everywhere. The equivalence gate is brutal on purpose: **all four goldens byte-identical**, because the placeholder markers were built to mirror devices.yaml exactly in phase 1.

Status: **LANDED 2026-08-02** · Gate: phase 1 landed — met.

**The equivalence gate held: all four goldens byte-identical, no `--update-goldens`.** 134 tests green (was 132 mid-phase, 124 before phase 1). `flutter build web` confirms the bundle now carries `house.yaml` + `bindings.yaml` and no stale `devices.yaml` — the one path no test reaches.

**As-built deltas:**

- **The generator retarget produced exactly one line of diff** in `hub/dev/ha-config/packages/panel_dev.yaml` — the `# Source:` path. All 33 stand-ins, all entity ids, all ordering identical, which is the proof that reading `key` out of `house.yaml`'s `devices:` is the same three fields it read out of `devices.yaml`.
- **D5's drift test landed as two tests, not one.** `every binding resolves against the dev Hub stand-ins` (the silent-rename hazard, with the empty `_integrated` ledger) plus `every Placement has exactly one binding` — the second is the pair of orphan checks the loader enforces at boot, asserted in `flutter test` instead of on the wall. Both mutation-verified: renaming a stand-in entity and adding a ghost binding each turn exactly one of them red.
- **`_checkPin` was kept and is now unreachable through the pipeline** — the converter computes membership, so it can only fire on a hand-mangled `house.yaml`. Its test moved into a "mangled generated file" group that says so, rather than being deleted; plan 04's mutation evidence still stands behind it.
- **The origin-shift print is gone** from `main()` (step 6), along with HOUSE-PLAN.md's "keep this line" instruction and the whole cm→m arithmetic runbook. Nothing computes a position by hand any more.
- **`pubspec.yaml` needed no edit**, as predicted: `assets/house/` is declared as a directory.

---

## 1. Why

After phase 1 the drawing owns "where", but the Panel still reads `devices.yaml` — seven hand-maintained fields per Device, five of which (`name`, `kind`, `room`, `position`, and the id that doubles as the key) are now duplicated by the generated `devices:` section. Duplication across a generated/hand seam is exactly the drift the pipeline contract test exists for. What is genuinely hand-owned is two facts per Device: **which Hub entity it binds to** (churns as hardware integrates — devices.yaml's own header says stand-ins get replaced one by one) and **`connectivity: local|cloud`** (a CONTEXT.md-mandated domain fact the Panel renders — the analysis found the spec left it homeless, SR-16; it lives here). Two facts, one file: `bindings.yaml`.

This also lands the spec's one genuinely right identity idea at home scale (README corrections #5–#7): the author-controlled **Key** is Device identity; entity ids are call targets that may churn (HA has been changing entity-id generation); an unbound Key renders as a pin with unknown state — never dropped, never a crash. And it does so without the spec's five-tier resolver: every one of the 33 current stand-ins is a helper/template entity with **no Hub device id**, so the registry tier could not bind a single one of them — the binding table isn't the fallback here, it's the whole mechanism.

## 2. Context a fresh session needs

### Domain terms

CONTEXT.md's language plus phase 1's minted **Placement** and **Key**. Avoid "entity" outside Hub-adapter internals. **Local Device** = no vendor cloud; **Cloud Device** = grandfathered second-class; the Popup renders the distinction (`device_popup.dart` uses `connectivity`).

### What already exists (tour, at `d01f290` + phase 1)

- **`panel/assets/house/house.yaml`** (generated) — after phase 1: `name`, `floors:` (3 Floors, 15 Rooms, 27 Walls), and `devices:` — 33 placements whose `key/name/kind/room/position` mirror devices.yaml exactly.
- **`panel/assets/house/devices.yaml`** (hand) — 33 Devices: `id, name, kind, connectivity, room, position, entity`. Header documents the stand-in-replacement lifecycle. **Dies this phase.**
- **`panel/lib/data/house_loader.dart`** — `loadHouse({required String houseYaml, required String devicesYaml})`. Device half (`:32-70`): duplicate-id check, entity regex `^[a-z_]+\.[a-z0-9_]+$`, one-entity-one-Device clash map, `_kind` slug switch (`:208-225`, throws on unknown), connectivity switch (`:59-65`, throws on unknown), `_point` (`:227-233`, rejects non-`[x,y]`), grouping by `room:`. Geometry half (plan 04's gatekeeper): `_checkFootprint`/`_checkWall` + unique Room/Floor ids (`:72-121`), orphaned-room check (`:123-129`), `_checkPin` walk (`:130-136`, 0.05 m `_pinEps`). **The geometry half is untouched by this phase.**
- **`panel/lib/domain/house.dart`** — `Device { id, name, kind, connectivity, position, entityId }`; `entityId` null = "no Hub counterpart yet — it still renders, with unknown state" (`:172-175`). That existing behaviour IS the unbound-Key rendering; nothing new to paint.
- **`panel/lib/main.dart`** — loads both assets via `rootBundle`, `loadHouse(houseYaml: …, devicesYaml: …)`; logs `house.loaded … devices=33 bound=33`. `pubspec.yaml` lists `assets/house/` (directory — a renamed file needs no pubspec edit; verify).
- **`panel/test/test_house.dart`** — `loadTestHouse()` reads the two asset files from disk. **Nine test files consume it** (dollhouse, fake_hub, ha_hub, ha_hub_live, dollhouse_golden, hub_contract, floor_arrangement, house_geometry, hub_controller) — they get the change for free through this one helper.
- **`panel/test/house_loader_test.dart`** — the loader's own suite: `_house`/`_devices` string fixtures, device-side cases (orphan room, unknown kind, dup id, entity clash…), the plan-04 geometry group, the pin boundary case. Device-side fixtures all rewrite this phase.
- **`panel/test/house_pipeline_contract_test.dart`** — converter → loader over the real fixture; asserts 3 floors / 33 devices; skips without python3. Rewires this phase (the loader now takes bindings, and the placements come from the converter output itself — the contract gets *stronger*: the generated `devices:` is finally consumed).
- **`panel/tool/gen_dev_entities.dart`** — generates `hub/dev/ha-config/packages/panel_dev.yaml` (33 stand-ins) from devices.yaml via its own weak parser `_readDevices` (id/name/kind only, `:225-248`); derives each binding and emits it **as a YAML comment** that devices.yaml's `entity:` lines were hand-copied from. Retargets this phase (minimal); its deep refactor is phase 3.
- **`panel/lib/data/ha_hub.dart`** — `_byEntity[entityId] = device` index, `get_states` + `state_changed` fold, `hub.missing_entities` warning (`:242`), toggle by entity id. **Unchanged**: it already consumes `Device.entityId`, which now arrives via bindings.
- **`panel/HOUSE-PLAN.md`** — §5 is the manual-position runbook this phase deletes; its closing line "which is why devices stay out of the drawing" was superseded by ADR-0005.
- Goldens: 4 PNGs at 1280×800 over `FakeHub(house, driftEvery: Duration.zero)`; FakeHub seeds by kind with `Random(7)` — seeding order is house iteration order, which is unchanged when positions/kinds/ids are unchanged. Hence the byte-identical gate is achievable and mandatory.

### Facts from the analysis this phase leans on

- **SR-6/SR-14**: entity_id as identity is the thing being retired; `key` maps onto `Device.id` — the repo's id fields are the stable join keys (states map, `stateChanges`, toggle, `ValueKey('pin-…')`, logs, goldens), so by making Key the id, *nothing downstream changes*.
- **SR-16**: connectivity is not derivable from the Hub; it must live in the hand file.
- **SI-6 (fixed here)**: the binding table gets what the spec never gave it — a schema, an owner (the family), a parser with named-culprit errors, and tests.
- **P6-2/P6-5**: the parser + the hermetic drift test are two of plan 06's five carried-forward deliverables; they land here. The clash check does NOT invert — this repo keeps 1 Key : 1 entity (README correction #7), so `one entity, one Device` transfers verbatim.
- **SR-10**: per-link Hub status (plan 07) is orthogonal; the spec's per-marker Unavailable/Stale tri-state is not adopted. Unbound = `entityId == null`, exactly today's semantics.

## 3. Target design

### `panel/assets/house/bindings.yaml` (hand-maintained; the only hand file left)

```yaml
# Hand-maintained Key -> Hub bindings (ADR-0005) — the converter NEVER
# touches this file. Every Placement in house.yaml MUST have an entry here.
# entity: the Hub entity this Device's state comes from. Stand-ins from
#   hub/dev/ today; replace each with the real entity id as hardware is
#   integrated. Omit the line while the Hub knows nothing — the pin renders
#   with unknown state.
# connectivity: local | cloud   (CONTEXT.md — the Popup shows it)
bindings:
  garage-door:
    entity: input_boolean.garage_door
    connectivity: cloud   # ratgdo retrofit planned
  ev-charger:
    entity: sensor.tesla_wall_connector
    connectivity: cloud
  # … 33 entries, derived 1:1 from devices.yaml (id -> key, entity, connectivity,
  #   comments preserved) …
```

- **A map keyed by Key**, not a list: duplicate Keys are a YAML-level impossibility (the parser still detects duplicate map keys if the yaml package reports them — it silently last-wins, so keep an explicit sorted-uniqueness expectation in the drift test), lookup is the natural shape, and each entry is two lines.
- **Every Placement must have an entry** — even a bare `connectivity: local` with no `entity:`. Rationale: connectivity is a mandated domain fact with no default that isn't a lie (a planned Ring camera is cloud before it's bound). One line per new Device is the entire remaining hand cost.
- `entity:` optional (hardware in boxes) → `Device.entityId = null` → unknown-state pin. Loud at boot via the existing `house.loaded … bound=N` log line, which now doubles as the unbound count.
- Extra binding with no matching Placement → error (the mirror of today's orphaned-room check; catches a deleted marker leaving a stale binding).

### `loadHouse` (same file, same gatekeeper posture)

```
House loadHouse({required String houseYaml, required String bindingsYaml})
```

- Placements come from `houseDoc['devices']` (absent → no Devices — an old-format house.yaml without the section is not an error; log-visible via `devices=0`). Per placement: `key` (unique — throw on dup; the converter already enforces it, this is the corrupted-file backstop), `name`, `kind` via the existing `_kind` switch (unknown kind here now means a corrupted/hand-mangled generated file — message updated to say "regenerate with the converter"), `room`, `position` via `_point`.
- Bindings: entity regex, one-entity-one-Device clash check, connectivity switch — **moved verbatim** from the device half, error strings updated from `devices.yaml:` to `bindings.yaml:`.
- Join: `Device(id: key, name:, kind:, connectivity: binding.connectivity, position:, entityId: binding.entity)`. Missing binding entry → throw naming the key ("add an entry to bindings.yaml — even connectivity-only"). Orphan binding → throw naming it.
- Geometry half, `_checkPin`, orphan-room check: untouched. `_checkPin` now cross-checks the converter's membership instead of hand arithmetic — it passes by construction and stays as the corrupted-file backstop (delete nothing; plan 04's mutation evidence still holds).

### Everything downstream: no changes

`Device.id` is the Key; `HubController`, `FakeHub`, `HaHubClient`, pins, Popup, logging, tests key on `Device.id`/`entityId` exactly as before. That is the payoff of README correction #7 (key ≡ id): the cutover stops at the loader.

## 4. Decision points

**D1 — bindings shape.** Map keyed by Key (recommended, above) vs list of `{key: …}` blocks. The map wins on hand-editing ergonomics and structural key-uniqueness; the list wins only if per-entry comments prove awkward — they don't (YAML comments sit above map entries fine).

**D2 — entry-required vs optional.** Required for every Placement (recommended): connectivity has no honest default, the check catches marker/binding drift in both directions, and it's one line. Optional-with-default-local would silently mislabel planned cloud hardware.

**D3 — asset file names.** `bindings.yaml` beside `house.yaml` (recommended); keep `devices.yaml` name? No — the name change IS the migration signal, and grep confirms nothing else reads it (`gen_dev_entities` retargets this phase).

**D4 — gen_dev_entities input.** (a) Minimal retarget (recommended): `_readDevices` reads `house.yaml`'s `devices:` (key/name/kind — same three fields it reads today) and the derived-binding comment is emitted as before, now hand-copied into `bindings.yaml`; (b) full pure-core refactor — that is phase 3's deliverable (P6-3), don't do it twice.

**D5 — the hermetic drift test now, or with phase 3?** Now (recommended): `test/bindings_drift_test.dart` — parse the real `bindings.yaml` + run the generator's derivation (via `Process.run('dart', ['run', 'tool/gen_dev_entities.dart', …])` into a temp file, or by reading the emitted comment block) and assert every Key **not in an explicit `integratedDevices` allowlist (empty today)** binds to exactly its derived stand-in. Plan 06 Decision 2(a) verbatim: the allowlist doubles as the ledger of really-integrated hardware. If wiring through the CLI is awkward pre-phase-3, a reduced version (every `entity:` in bindings.yaml appears in `hub/dev/ha-config/packages/panel_dev.yaml`) still turns the silent-rename hazard red in CI; upgrade it in phase 3.

## 5. Step-by-step implementation

Each step leaves `flutter analyze && flutter test` and the Python suite green.

**Step 0 — re-verify.** Phase 1 landed (house.yaml has `devices:` 33 blocks); line refs in §2 against HEAD; `grep -rn "devicesYaml\|devices.yaml" panel/ hub/ docs/` for the full consumer list (expect: loader, main, test_house, loader tests, contract test, gen_dev_entities, HOUSE-PLAN.md, README.md, hub/dev/README.md, devices.yaml itself).

**Step 1 — derive bindings.yaml.** Script (scratchpad): read devices.yaml, emit the map — key = id, `entity` + `connectivity` + inline comments preserved, section comments (`# Garage`, `# Family Room`) preserved for the family's muscle memory. Add the header from §3. Do not delete devices.yaml yet.

**Step 2 — the loader.** Rewrite the device half per §3 (signature `bindingsYaml`; move validations; new join; error wordings per §3 — keep every existing error's *shape*: file-prefix, culprit, fix hint). Update `house_loader_test.dart`: `_devices` fixture becomes a `_bindings` fixture + placements move into `_house`'s `devices:`; every device-side case re-targets (dup key, unknown kind → "regenerate", entity regex, clash, unknown connectivity, missing binding entry, orphan binding, absent `devices:` section); geometry group and pin cases untouched except the pin fixtures gaining their placements via `_house`.

**Step 3 — callers.** `main.dart`: load `bindings.yaml`, pass `bindingsYaml:`; the `house.loaded` log gains nothing (bound/unbound already counted). `test_house.dart`: same two-line change (nine consumer files follow for free). Contract test: converter output + real `bindings.yaml` → assert 3 floors / 33 devices / `bound == 33` — the generated `devices:` section is now exercised end-to-end, which closes the loop phase 1 deliberately left open.

**Step 4 — the equivalence gate.** `flutter test` — **101+ tests green and all four goldens byte-identical, no `--update-goldens`**. Positions, kinds, ids, and seeding order are unchanged by construction (phase 1 step 4 mirrored devices.yaml exactly), so any golden diff means the join or the fixture mirror is wrong — fix the code, never the golden.

**Step 5 — retire devices.yaml.** Delete `panel/assets/house/devices.yaml`. Retarget `gen_dev_entities.dart` per D4(a) (its `--devices` arg / default path now points at house.yaml + reads the `devices:` section; the emitted header comment now says "hand-copy into bindings.yaml"). Regenerate `hub/dev/ha-config/packages/panel_dev.yaml` and diff — must be byte-identical (same 33 key/name/kind in the same order); any diff is a retarget bug. Add the D5 drift test.

**Step 6 — docs.** `HOUSE-PLAN.md` §5 rewritten: *add a Device = place a SmartHome marker in the drawing, type its `placementKey`, re-run the converter, add one `bindings.yaml` entry; move a Device = drag it; delete = delete marker + entry.* Delete the origin-shift instructions (and remove the origin-shift print from `sh3d_to_yaml.py main()` + its "Keep the origin shift line" callout — nothing needs it anymore). Update `panel/README.md` (pipeline + layout + tests sections), `hub/dev/README.md` (generator source), ADR-0004's two-file sentence gets a pointer to ADR-0005's reshaped split (one-line edit, the ADR itself already says devices.yaml holds "later the Hub entity-id mapping" — bindings.yaml IS that file, renamed and shrunk).

**Step 7 — sweep.** `grep -rn "devices.yaml" panel/ hub/ docs/ --include="*.dart" --include="*.py" --include="*.md"` — every survivor is either historical (ADRs, old plans — fine) or a bug. Full verification block.

## 6. Test plan

- **`house_loader_test.dart`** re-targeted device cases (step 2 list) + new: `rejects a placement with no bindings entry`, `rejects a binding for a key with no placement`, `accepts a binding without entity (unknown-state Device)`, `loads a house.yaml with no devices section as zero Devices`.
- **Contract test** now asserts `bound == 33` through the real bindings file.
- **`bindings_drift_test.dart`** (D5): stand-in freshness with the empty `integratedDevices` allowlist.
- **Goldens: byte-identical, all four.** This phase's D6-style hard gate.
- Behaviour pinned for the first time: Key-is-identity join, both orphan directions, connectivity-only bindings, the absent-section path.

## 7. Verification

```sh
cd panel && flutter analyze && flutter test          # all green, 0 golden diffs
python3 tool/test_sh3d_to_yaml.py                    # unchanged from phase 1
dart run tool/gen_dev_entities.dart -o /tmp/panel_dev.regen.yaml \
  && diff /tmp/panel_dev.regen.yaml ../hub/dev/ha-config/packages/panel_dev.yaml
flutter run -d chrome                                # live look; never -d macos
```

## 8. Non-goals

- **No registry, no resolver tiers, no per-marker Unavailable/Stale states** (SR-10; unbound = entityId-null, exactly today's render). Trigger: real hardware with Hub registry entries *and* a demonstrated need to bind by device id.
- **No multi-entity Keys** (SR-13/SI-11 — the spec has no aggregation rule either). 1 Key : 1 entity stands; trigger: the first real fan-with-light, which then needs a composite DeviceState design first.
- **No vocabulary changes** — `DeviceKind`, `_kind`, FakeHub seeds, `_toDeviceState` untouched (phase 3).
- **No HubClient/ha_hub changes** — plan 07's territory and phase 3's fold are both elsewhere.
- **Nothing ever writes bindings.yaml** — single-writer rule carried over from ADR-0004 verbatim; the generator derives and the drift test asserts, neither writes.
