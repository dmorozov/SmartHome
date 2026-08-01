# loadHouse as House Plan gatekeeper + pure convert() core in the converter

One line: make `loadHouse` enforce every geometry invariant the Dollhouse assumes (it enforces none today), split the converter's pure convert step from its I/O shell so it becomes testable, and tie the two ends of the Python/Dart seam together with one executable contract check.

Status: proposed · Strength: Strong · Written against commit 105610c (2026-08-01) — re-verify line numbers before editing.

---

## 1. Why this refactor

`loadHouse`'s interface promises a valid House Plan — its doc comment cites ADR-0004, and `main.dart` deliberately dies loudly on a malformed one:

```dart
// panel/lib/main.dart:52-57
} catch (error, stack) {
  // A malformed House Plan is fatal, and on the kiosk nobody is standing
  // in front of the red screen. Leave one greppable line on the way out.
  Log.error('house', 'invalid', error: error, stack: stack);
  rethrow;
}
```

But every geometry invariant the Dollhouse painters assume — rectilinear footprints, axis-aligned Walls, unique Room ids, Device pins inside their Room — is enforced only in the converter (`panel/tool/sh3d_to_yaml.py`), while ADR-0004 explicitly keeps hand-written YAML as the escape hatch ("hand-written YAML was rejected only as the primary path (it remains the escape hatch)") and `devices.yaml` is hand-edited routinely by design. Converter-bypassing YAML reaching the loader is a designed-for path, and when it happens, bugs surface at paint time, two modules away from the data.

The evidence, all verified against commit 105610c:

- **The loader is deep on its Device half but shallow on geometry.** `house_loader.dart:56-83` parses footprints and Walls with zero geometry checks. Contrast the five Device checks that earn their keep (duplicate device id :20-22, entity-id shape :25-29, entity clash :30-37, unknown connectivity :42-48, unknown kind :96-113) — deleting those would resurface complexity in `main.dart` and every Hub adapter. Deleting the geometry validation half today loses nothing, because there is none. The complexity already lives downstream in the painters as garbage-in-garbage-out.

- **Silent paint-time garbage for diagonals.** `plan_geometry.dart:46` classifies every non-horizontal edge as vertical — the only split is:

  ```dart
  final horizontal = (a.dy - b.dy).abs() <= _eps;
  ```

  (same split again at `plan_geometry.dart:105` in `wallOutsideSide`). A diagonal footprint edge silently yields a garbage Floor outline; nothing throws.

- **Exact double equality on a hand-writable value.** `house.dart:50`:

  ```dart
  bool get horizontal => a.dy == b.dy;
  ```

  consumed by `floor_view.dart:286` (`wall.horizontal ? const Color(0xFFE2E7F0) : ...`) to pick wall face shading. A Wall that is nearly-but-not-exactly axis-aligned renders with the wrong face and a skewed quad, silently.

- **Duplicate Room ids pass silently.** `house_loader.dart:65-66`:

  ```dart
  final id = r['id'] as String;
  roomIds.add(id);
  ```

  The `Set.add` return value is ignored, so a duplicate room id loads without complaint and attaches one device list to two Rooms.

- **The pin-inside-Room rule is delegated to a human.** `Room.contains` (an even-odd point-in-polygon test, `house.dart:84-95`) is never called at load time. Instead `HOUSE-PLAN.md:182-184` warns: "Moving one between rooms = change `room:` *and* `position:` (position is house-global, not room-relative — a stale position renders the pin outside its room)." The failure mode is documented instead of prevented.

- **Degenerate footprints reach the painters.** A 2-point footprint loads; an empty one crashes in `Room.bounds` (`footprint.first` on an empty list) at paint time, far from the data.

- **The schema crossing the seam is written three times with no executable tie, and it has already drifted once.** The three copies: the converter's emit strings (`sh3d_to_yaml.py:332-351`), the loader's parse expressions (`house_loader.dart:56-83`), and the HOUSE-PLAN.md table. The documented drift: ADR-0004 claims "the converter warns when `devices.yaml` references a missing room" — false. `sh3d_to_yaml.py` never reads `devices.yaml`; grep shows only prose mentions at lines 12, 295, and 363. The check actually lives at `house_loader.dart:85-91`, and it *errors* rather than warns. A written-three-times schema description drifted in the project's own ADR within days of being written.

- **No Python tests at all; both fixtures referenced by nothing executable.** `find` confirms zero Python test files in the repo; grep over `panel/test/` and `panel/tool/` confirms neither `tool/fixtures/AlpsHotel.Home.xml` nor `tool/fixtures/placeholder-house.Home.xml` is referenced by any test — even though `HOUSE-PLAN.md` describes AlpsHotel as breaking "most of the rules below", a ready-made negative fixture. The converter is a ~150-line `main()` (`sh3d_to_yaml.py:215-363`) interleaving XML parsing, origin shifting, validation ordering, hand-formatted YAML emission, `argparse`, file writing, and `sys.exit` — deep implementation, no interface, untestable except through argv.

- **The only implicit cross-seam check is frozen.** `test_house.dart:9-12` loads the checked-in generated assets — the sole executed agreement between emit strings and parse expressions, and it never re-runs the converter, so converter drift goes undetected until someone regenerates and eyeballs the Dollhouse.

### Corrections from the adversarial verification pass (these win over the original finding)

1. The loader is **not** "far shallower than its assigned role" across the board — only on geometry. Its Device half is genuinely deep (five checks that pass the deletion test). The deepening is one-sided.
2. The inside-Room check **needs a boundary epsilon**. Current data passes strict checks (e.g. the doorbell at `[14, 10.6]` sits 0.4 m inside the hall's footprint `[[11,6],[17,6],[17,11],[11,11]]`), but a pin placed exactly on a Wall coordinate — which `HOUSE-PLAN.md` §5 actively suggests ("near a wall for a TV") — hits even-odd point-in-polygon ambiguity on the boundary.
3. The convert-then-loadHouse contract test **must skip cleanly when `python3` is absent** (CI/dev machines).
4. No ADR conflict: ADR-0004's pipeline decision stands untouched — this plan strengthens the escape hatch rather than re-litigating it. The ADR needs a one-sentence factual correction (maintenance, not reopening), and it is worth recording there that the contemplated 45° upgrade now touches converter + loader + renderer instead of converter + renderer, with the executable contract test keeping that dual enforcement honest.

### Fresh findings from writing this plan (verified against the live tree, 2026-08-01)

- **The escape hatch has already been used inside this repo, on the DO-NOT-EDIT file.** Commit `40fb0fe` ("create house plan instructions") hand-appended the 7-line attic block (`id: attic` … `attic-storage`) to `panel/assets/house/house.yaml`, whose own header says "DO NOT EDIT BY HAND (ADR-0004)". Running the converter today confirms it: `python3 tool/sh3d_to_yaml.py tool/fixtures/placeholder-house.Home.xml -o /tmp/out.yaml --name "Demo House"` exits 0 with `2 floor(s), 14 room(s), 27 wall(s), 1 warning(s)`, and the diff against the shipped asset is exactly the attic block. The shipped asset and its declared source have drifted — a second documented drift across this seam, and a live decision for this plan (Decision D4).
- **The converter's placeholder run emits exactly one warning** — `Ground Floor: boundary of "Family Room" along x=13 (0..6) is mostly unwalled` — usable as a pinned expectation (pre-D4; Step 6's wall-less attic adds four expected "Attic Storage … mostly unwalled" warnings, so pin the Family Room warning's presence, never the count).
- **AlpsHotel fails conversion with 28 errors** (22 `unnamed room`, 5 `diagonal edge`, 1 `diagonal wall`), exit code 1, `nothing written`. The negative fixture works exactly as advertised and its error classes can be pinned.
- **Seven test files cross the `loadHouse` seam** and inherit any deepening for free: `house_loader_test.dart` (direct, inline YAML) plus `test_house.dart` (defines `loadTestHouse` over the shipped assets) and its five consumers `dollhouse_test.dart`, `fake_hub_test.dart`, `ha_hub_test.dart`, `ha_hub_live_test.dart`, `golden/dollhouse_golden_test.dart`.
- **`tool/gen_dev_entities.dart` is a second, independent parser of `devices.yaml`** (pure Dart, no `dart:ui`) — relevant to plan 06 coordination, not to this plan's scope.

### The deletion test, rerun

The converter's validators cannot be deleted — they are the only enforcement of the hard invariants; complexity would reappear as corrupted assets. What fails the deletion test sits on both ends of the seam: deleting `loadHouse`'s (nonexistent) geometry-validation half loses nothing — proof the module is shallower than the role ADR-0004 assigns it — and deleting the I/O shell around a pure convert step costs nothing (one adapter would remain), which is exactly what blocks Python tests today.

### Why now (YAGNI check, from the verifier)

Churn signal is weak — the repo is days old, the pipeline landed in 3 commits (`163b618` pipeline, `40fb0fe` instructions, `e49dd24` hub) — but the seam's heaviest planned use is imminent and documented: the family regenerating from the real drawing per the `HOUSE-PLAN.md` runbook, routinely hand-editing `devices.yaml`, plus ADR-0004's named deferred converter work (furniture on the Plan).

---

## 2. Context a fresh session needs

### Domain terms (CONTEXT.md — use these words, never the "avoid" synonyms)

- **Panel**: "The wall-mounted touchscreen running the custom dollhouse UI." (avoid: kiosk, dashboard, screen)
- **Hub**: "The headless smart-home broker (Home Assistant) that owns device state, integrations, and automations. The Panel is its client, never its replacement." (avoid: server, backend, HA)
- **Dollhouse**: "The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms." (avoid: floor plan, map, 3D view)
- **House Plan**: "The Panel-side description of the house's geometry — Floors with their Rooms and Walls, authored by the family. The Dollhouse renders it; the Hub never sees it." (avoid: blueprint, map, layout)
- **Floor**: "One level of the house in the Dollhouse … A Floor need not span the whole house footprint."
- **Room**: "A named area on a Floor. Rooms tile their Floor completely — every point belongs to exactly one Room … Rooms display aggregate state (lit, occupied) and hold pinned Devices."
- **Wall**: "A boundary segment drawn on the House Plan. Only drawn Walls exist: where none is drawn, the boundary is an open passage."
- **Device**: "A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse." (avoid: entity — that is the Hub's internal term)

### Design vocabulary

This plan uses the vocabulary of `.claude/skills/codebase-design/SKILL.md` exactly: a **module** is anything with an **interface** (everything a caller must know: signatures *plus invariants, error modes, configuration*) and an implementation; a module is **deep** when a lot of behaviour sits behind a small interface; a **seam** is where an interface lives, and an **adapter** is what satisfies it there; depth buys **leverage** for callers and **locality** for maintainers; the **deletion test** asks whether removing a module makes complexity vanish (pass-through) or reappear across callers (earning its keep). Never say component/service/API/boundary.

### Binding ADR constraints

From ADR-0004 (`docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md`), the sentences this plan is built on:

- "hand-written YAML was rejected only as the primary path (**it remains the escape hatch**)."
- "`house.yaml` (Floors → Rooms → Walls) is **generated and never hand-edited** — re-running the converter is always safe; `devices.yaml` … is **hand-maintained and never touched by the converter**."
- "Room footprints are rectilinear polygons — right angles only … (**overlapping rooms are forbidden**; upgrading to true 45° edges later costs only converter validation plus one renderer shading case…)."
- "Rooms tile each Floor completely — every point in exactly one Room."
- "Walls are first-class data taken from what is drawn: no wall drawn = open passage."
- "The converter rejects diagonals and overlaps, and warns on unwalled room boundaries and non-tiling floors — it never invents geometry."
- The stale sentence this plan corrects: "the converter warns when `devices.yaml` references a missing room." (It does not; the loader errors — `house_loader.dart:85-91`.)

ADR-0002 constrains the Panel to "a pure view/command layer" — geometry validation at load is view-side configuration checking, not Hub territory. ADR-0001/0003 are not touched.

### Current-architecture tour

- **`panel/lib/data/house_loader.dart`** (121 lines) — the one-function module at the Dart end of the seam:

  ```dart
  /// Builds the [House] from the two House Plan files (ADR-0004): …
  /// Throws [FormatException] with an actionable message on mismatch.
  House loadHouse({required String houseYaml, required String devicesYaml}) {
  ```

  Parses `devices.yaml` first (with the five deep Device checks), then builds Floors/Rooms/Walls from `house.yaml` with **zero geometry checks** (lines 56-83; `roomIds.add(id)` return ignored at :66), then the orphan-Room check (:85-91). Private helpers `_kind` (:96) and `_point` (:115).

- **`panel/lib/domain/house.dart`** — pure domain: `House`, `Floor`, `Wall` (with `bool get horizontal => a.dy == b.dy;` at :50), `Room` (with `bounds` :71 and even-odd `contains` :84), `Device`, `DeviceKind`, `Connectivity`. Note its class doc (:6-8) wrongly claims "Each Floor has its own plan origin" — plan 03 fixes that, not this plan.

- **`panel/lib/ui/dollhouse/plan_geometry.dart`** — plan-space math over Rooms: `outlineSegments` (Floor outline = room edges minus collinear far-side edges; the `:46` horizontal-else-vertical split) and `wallOutsideSide` (:102, same split at :105). `const _eps = 0.005; // m — converter emits mm-rounded coords` (:34).

- **`panel/lib/ui/dollhouse/floor_view.dart`** — the painter that trusts everything upstream: slab as union of footprints (:195-198), plinth from `outlineSegments` (:205), glass walls shaded by `wall.horizontal` (:286) and `wallOutsideSide` (:288).

- **`panel/lib/main.dart`** — loads the two assets via `rootBundle`, wraps `loadHouse` in the fatal-loud `_loadHouse` (:38-58 quoted above).

- **`panel/tool/sh3d_to_yaml.py`** (377 lines, stdlib only per ADR-0004) — the Python end of the seam. Pure-ish helpers at top (`slugify`, `fmt`, `rectilinearize`, `shoelace`, `contains`, `bbox`, `check_overlaps_and_gaps`, `check_wall_coverage`); then `main()` (:215-363) fusing argparse, `load_home_xml` (file/zip I/O), floor/room/wall extraction, the one-shared-origin shift (:269-273), slug collision checks, validation, hand-formatted YAML emission (:332-351), file write, and summary prints; `report_and_exit` (:366) does `sys.exit(1)` with "nothing written".

- **`panel/tool/fixtures/`** — `placeholder-house.Home.xml` (hand-crafted, 2 levels, 14 rooms, converts clean; the source of the shipped `house.yaml` per its own header) and `AlpsHotel.Home.xml` (Sweet Home 3D gallery example; 28 conversion errors). Referenced by no test today.

- **`panel/assets/house/house.yaml`** — generated asset, header "Generated by sh3d_to_yaml.py from tool/fixtures/placeholder-house.Home.xml — DO NOT EDIT BY HAND (ADR-0004)". Contains a hand-added attic Floor (commit `40fb0fe`) not present in that fixture. **`panel/assets/house/devices.yaml`** — hand-maintained, 33 Devices.

- **`panel/test/test_house.dart`** — `loadTestHouse()` loads the real shipped assets from disk; used by five test files. **`panel/test/house_loader_test.dart`** — the inline-YAML pattern the new tests extend (a valid `_house`/`_devices` pair, plus `rejects a device pointing at a missing room` and `rejects an unknown device kind`).

- **`panel/HOUSE-PLAN.md`** — the family runbook: draw → convert → look → add Devices; §5 step 5 documents what `flutter test` currently catches ("unknown room id, duplicate device id, or unknown kind" — no geometry, no position).

---

## 3. Target design

Deepen both ends of the one seam without changing either interface.

### Dart end: `loadHouse` becomes the House Plan gatekeeper

Module: `loadHouse` in `panel/lib/data/house_loader.dart` — same seam, same one-function interface:

```dart
House loadHouse({required String houseYaml, required String devicesYaml})
```

The interface (in the full sense: signature + invariants + error mode) grows only in its documented guarantee. New doc comment:

```dart
/// Builds the [House] from the two House Plan files (ADR-0004):
/// `house.yaml` — converter-generated geometry, never hand-edited — and
/// `devices.yaml` — hand-maintained Device declarations referencing rooms
/// by id. Throws [FormatException] with an actionable message on mismatch.
///
/// The returned [House] carries the full House Plan guarantee the Dollhouse
/// assumes: every Room footprint is a closed rectilinear polygon (>= 3
/// corners, axis-aligned edges), every Wall is axis-aligned, Room and Floor
/// ids are unique across the house, and every Device references an existing
/// Room with its position inside (or on the edge of) that Room's footprint.
/// Geometry that the converter would reject therefore also dies here — the
/// escape hatch of hand-written YAML (ADR-0004) gets the same enforcement.
```

What hides inside (implementation, private to the file — internal seams for its own tests only):

```dart
const _pinEps = 0.05; // m — a pin on its Room's edge is legal (D2)

/// house.yaml: every footprint edge exactly horizontal or vertical (D3),
/// at least 3 corners. Throws FormatException naming room + edge.
void _checkFootprint(String roomId, List<Offset> footprint)

/// house.yaml: wall exactly axis-aligned and non-degenerate.
void _checkWall(String floorId, Offset a, Offset b)

/// devices.yaml x house.yaml: pin inside its Room, or within _pinEps of
/// the footprint boundary (even-odd is ambiguous exactly on edges).
void _checkPin(Room room, Device device)

/// Distance from p to the axis-aligned segment a-b (exact via clamp).
double _segmentDistance(Offset a, Offset b, Offset p)
```

Plus two id-uniqueness fixes inline in the existing loops: `if (!roomIds.add(id))` throws (`house.yaml: duplicate room id "$id" — room ids must be unique across the whole house (devices.yaml references them)`), and a parallel `floorIds` set for Floor ids. Error messages keep the loader's established actionable style, in Panel vocabulary (the converter keeps its authoring-time diagnostics in Sweet Home 3D vocabulary — two audiences, two voices, one invariant set). Examples to implement verbatim:

- `house.yaml: room "den" footprint edge (4, 0)→(2, 3) is diagonal — right angles only (ADR-0004); regenerate with the converter, or fix the hand-written coordinates`
- `house.yaml: room "den" footprint has fewer than 3 corners`
- `house.yaml: wall (0, 0)→(4, 3) on floor "ground-floor" is diagonal — right angles only (ADR-0004)`
- `devices.yaml: device "doorbell" position [14, 10.6] is outside its room "hall" — positions are meters from the house NW corner, not room-relative (HOUSE-PLAN.md §5); recompute from the converter's origin-shift line`

Keep the Device-side checks (existing five + the new `_checkPin`) textually separable from the geometry checks (`_checkFootprint`/`_checkWall`/id uniqueness): plan 06 moves the Device-side parsing out of this file, and the split must stay cheap.

Callers: unchanged. `main.dart` and all seven test files crossing the seam inherit the full guarantee with zero interface change — that is the leverage. Geometry violations now die at load with a named culprit instead of surfacing as silent paint-time garbage two modules away in `plan_geometry` and `floor_view` — that is the locality. Nothing is deleted on the Dart side (there is nothing to delete; that was the finding); what dies is the painters' *unstated precondition*, which becomes a guaranteed postcondition of `loadHouse`. `Wall.horizontal`'s exact `==` and `plan_geometry`'s horizontal-else-vertical split become legitimate assumptions instead of silent failure modes.

### Python end: pure `convert()` core, `main()` reduced to an adapter

Same file, `panel/tool/sh3d_to_yaml.py` (stdlib only — no new deps, per ADR-0004). The seam moves off the filesystem. New shape:

```python
ConvertResult = collections.namedtuple(
    'ConvertResult', 'name floors origin errors warnings')

def convert(root, name=None):
    """Pure step: parsed Home.xml Element -> ConvertResult.

    floors: [{'slug', 'name', 'level', 'rooms': [{'id', 'name', 'pts'}],
              'walls': [[[x, y], [x, y]], ...]}]
    origin: (min_x, min_y) — the shared-NW-corner shift, for the
            origin-shift line main() prints.
    Never reads or writes files, never exits.
    """

def emit_yaml(name, floors, source):
    """Pure: the exact house.yaml text (str), header naming `source`."""

def main():
    # adapter only: argparse, load_home_xml (file/zip I/O), convert,
    # report_and_exit on errors, emit_yaml, write file, summary prints.
```

Everything now inside `main()` between XML load and emission moves into `convert()` unchanged: level sorting and Floor numbering, floor-slug collision errors, room/wall extraction, the shared-origin shift, `rectilinearize`, shoelace orientation, room-slug collision errors, wall snapping/diagonal errors, `check_overlaps_and_gaps`, `check_wall_coverage`, empty-floor filtering. The emission loop (:332-351) moves into `emit_yaml` with `args.input` becoming the `source` parameter. `report_and_exit`, argv handling, `open(...).write`, and the two summary `print`s stay in `main()` — the whole shell is the one adapter the deletion test says may remain. `load_home_xml` stays as the I/O helper the adapter calls; tests parse fixtures with `ET.parse` directly and call `convert` through its real interface instead of argv.

### The executable contract across the seam

One new Dart test (`panel/test/house_pipeline_contract_test.dart`) converts the placeholder fixture by invoking `python3 tool/sh3d_to_yaml.py` and feeds the freshly-emitted YAML plus the real `devices.yaml` through `loadHouse`. Emit strings and parse expressions can no longer drift silently: the three hand-synchronized schema descriptions (emit strings, parse expressions, HOUSE-PLAN.md table) collapse into one executed agreement, protecting exactly the regenerate-after-edit path the runbook tells the family to take. It skips cleanly when `python3` is absent.

### Before / after dependency sketch

```
BEFORE
main.dart ──calls──▶ loadHouse (deep on Device checks, ZERO geometry checks)
loadHouse ──builds──▶ domain/house.dart (Room.contains unused at load;
                       Wall.horizontal exact ==, trusted by floor_view:286)
plan_geometry + floor_view ──silently assume──▶ rectilinear / axis-aligned /
                       unique-id / pin-inside invariants nobody enforces
tool/sh3d_to_yaml.py ──owns──▶ all geometry enforcement, inside a ~150-line
                       main() fused with argv/unzip/emit/sys.exit; no tests
fixtures (AlpsHotel, placeholder-house) ──referenced by──▶ nothing executable
test_house.dart ──loads──▶ frozen generated assets (only implicit seam tie)
ADR-0004 ──misattributes──▶ orphan-Room check to the converter

AFTER
main.dart + 7 test files ──unchanged──▶ loadHouse
loadHouse  = GATEKEEPER: same one-function interface (two YAML strings in,
             House out, FormatException with actionable message) hiding
             parse + ALL House Plan invariants: rectilinear, axis-aligned
             Walls, unique Room/Floor ids, pin-inside-Room. Genuinely deep.
painters   ──assume invariants legitimately──▶ guaranteed upstream
sh3d_to_yaml.py: convert(root, name) -> ConvertResult   (pure, deep)
                 emit_yaml(name, floors, source) -> str (pure)
                 main() = adapter: argv, unzip, write, exit — nothing else
tool/test_sh3d_to_yaml.py ──exercises──▶ convert/emit_yaml
             (AlpsHotel negative, placeholder-house golden, origin shift,
              slug collisions, nothing-written-on-error via subprocess)
house_pipeline_contract_test.dart: convert(placeholder) ──pipes──▶ loadHouse
             (one executed schema agreement; skips when python3 absent)
ADR-0004 ──corrected──▶ loader named as enforcer of devices-reference-Rooms
```

---

## 4. Decision points

Each needs ratification by the user before or during implementation. Recommendations are marked.

**D1 — Pin-outside-Room becomes a load-time error (BEHAVIOUR CHANGE).**
Today a stale `position:` renders the pin visibly outside its Room and the Panel runs on. After this plan, `loadHouse` throws, and per `main.dart`'s fatal-loud policy the Panel refuses to start until `devices.yaml` is fixed. (Same kind of behaviour-change flag as plan 01's unknown-state light-tap decision — toggle vs Popup — record the choice.)
- Option A (recommended): error. Matches the existing orphan-Room precedent (`house_loader.dart:85-91` errors, not warns), matches `main.dart:53-55`'s stated policy, and the failure is caught by `flutter test` before it ever reaches the wall (HOUSE-PLAN.md §5 step 5 already says "Check it: flutter test").
- Option B: `Log.warning` and load anyway. Rejected because the Panel has no authoring-time audience for warnings — nobody is standing in front of the kiosk log, which is exactly why `main.dart` chose fatal-loud.

**D2 — Boundary epsilon for the pin check.**
- Option A (recommended): accept `room.contains(p)` OR distance-to-footprint-boundary ≤ `_pinEps = 0.05` m. Rationale: even-odd is ambiguous exactly on edges (verifier's correction); HOUSE-PLAN.md tells humans to place pins "near a wall"; 5 cm is generous against typed coordinates yet tiny against room scale, and all 33 shipped Devices pass with ≥ ~0.4 m margin.
- Option B: strict `contains` only — rejects legal on-edge pins nondeterministically; rejected.
- Option C: larger eps (0.25 m) — starts accepting genuinely wrong pins; rejected.

**D3 — Axis-alignment: exact equality, or tolerance-plus-snap?**
- Option A (recommended): strict — an edge is horizontal iff `a.dy == b.dy`, vertical iff `a.dx == b.dx`, else FormatException. The converter already snaps near-axis edges onto the axis (`rectilinearize`, `sh3d_to_yaml.py:78-81`; walls :308-311) and `fmt` emits identical decimal strings, so converter output is exactly axis-aligned; hand-written YAML authors type literal coordinates, and identical literals parse to identical doubles. Strict keeps `Wall.horizontal`'s exact `==` (house.dart:50) sound with zero added machinery, and keeps snapping where it belongs — the authoring side (locality).
- Option B: validate within 0.005 m (plan_geometry's `_eps`) and snap in the loader. More forgiving to hypothetical hand-written mm drift, but duplicates converter logic on the Panel side and mutates input geometry at load. Adopt only if strict rejection ever bites a real hand-edit.

**D4 — Resolve the house.yaml/fixture drift (the hand-added attic).**
- Option A (recommended): add an Attic level + `Attic Storage` room to `tool/fixtures/placeholder-house.Home.xml` and regenerate `assets/house/house.yaml` with the converter. Restores the DO-NOT-EDIT header's truth and lets the Python golden test compare `emit_yaml(convert(fixture))` against the shipped asset itself — the strongest possible tie. Cost: the regenerated file gains one `    walls:` line under attic (the converter always emits the key; the loader already tolerates it via `(f['walls'] as YamlList?) ?? YamlList()` at house_loader.dart:79), and goldens must be verified unchanged (geometry is identical, so they will be).
- Option B: leave the shipped asset as-is and golden-compare against a new checked-in `tool/fixtures/placeholder-house.expected.yaml`. Keeps the repo's own DO-NOT-EDIT violation in place; the golden chain is weaker.

**D5 — Ratify the scope cut: overlap/tiling checks stay converter-only.**
The original finding listed "no overlapping Rooms" among the invariants; the verified solution deliberately drops overlap/gap detection from the loader (grid-sampling at Panel startup, warning-vs-error semantics, painters tolerate overlap without crashing). Recommended: yes, keep them converter-only, with the written-down trigger in Non-goals. Say so explicitly so the narrower loader guarantee is a decision, not an oversight.

---

## 5. Step-by-step implementation

Each step leaves `cd panel && flutter analyze && flutter test` green.

**Step 1 — id uniqueness in the loader.**
Modify `panel/lib/data/house_loader.dart`: change `roomIds.add(id);` (:66) to throw on duplicate; add a `floorIds` set with the same treatment around the Floor construction (:56-58). Add to `panel/test/house_loader_test.dart`: `rejects a duplicate room id` (two rooms with `id: den` on the same floor, expect message containing `duplicate room id "den"`), `rejects a duplicate floor id`. Messages per §4 examples.

**Step 2 — footprint and Wall geometry checks.**
Same file: add `_checkFootprint` (>= 3 corners, then per-edge strict axis-alignment per D3) called inside the Room construction loop (:70-73 region), and `_checkWall` (axis-aligned, non-degenerate: `a != b`) called in the Wall loop (:78-81 region). Add tests: `rejects a diagonal footprint edge` (footprint `[[0,0],[4,0],[2,3]]`-style, message contains `diagonal`), `rejects a footprint with fewer than 3 corners`, `rejects a diagonal wall`, `rejects a zero-length wall`. The existing `_house` const in the test file is already clean and passes unchanged; `loadTestHouse`-based suites prove the shipped assets pass.

**Step 3 — pin-inside-Room check.**
Same file: after the orphan check (:85-91), walk floors → rooms → devices calling `_checkPin` (D1/D2: `contains` OR `_segmentDistance ≤ _pinEps`, implemented with `clamp` per axis — exact for axis-aligned edges, which Step 2 now guarantees). Needs `dart:math` import for min/max or use `num.clamp`. Update the `loadHouse` doc comment to the full-guarantee version (§3). Tests: `rejects a device pinned outside its room` (position `[10, 10]` for the den, message contains `outside its room "den"`), `accepts a device pinned exactly on its room boundary` (position `[0, 2]` on den's west edge loads fine).

**Step 4 — extract the pure Python core (no behaviour change).**
Restructure `panel/tool/sh3d_to_yaml.py` into `convert(root, name=None) -> ConvertResult`, `emit_yaml(name, floors, source) -> str`, and the `main()` adapter, per §3. Move code, don't rewrite it; keep every message string byte-identical. Verify by re-running the converter on the placeholder fixture and diffing against the pre-refactor output (must be byte-identical, still exactly 1 warning).

**Step 5 — Python fixture tests.**
New file `panel/tool/test_sh3d_to_yaml.py` (stdlib `unittest`; resolve fixtures via `pathlib.Path(__file__).parent / 'fixtures'` so cwd doesn't matter). Cases in §6. Run with `cd panel && python3 tool/test_sh3d_to_yaml.py`.

**Step 6 — heal the fixture/asset drift (D4 Option A).**
Insert into `panel/tool/fixtures/placeholder-house.Home.xml`, just before the closing `</home>` tag:

```xml
  <level id="level2" name="Attic" elevation="524.0" floorThickness="12.0" height="250.0" elevationIndex="0"/>
  <room id="r-attic" level="level2" name="Attic Storage">
    <point x="600" y="0"/><point x="1100" y="0"/><point x="1100" y="600"/><point x="600" y="600"/>
  </room>
```

(update the fixture's header comment from "2 levels" accordingly). Regenerate: `cd panel && python3 tool/sh3d_to_yaml.py tool/fixtures/placeholder-house.Home.xml -o assets/house/house.yaml --name "Demo House"`. Expected output (verified against this exact snippet on 2026-08-01): exit 0, `3 floor(s), 15 room(s), 27 wall(s), 5 warning(s)` — the original Family Room warning plus **four new "Attic Storage … mostly unwalled" warnings, which are correct and expected** (the attic has no drawn Walls; no wall drawn = open passage, ADR-0004). Confirm `git diff assets/house/house.yaml` shows only the added `    walls:` line under attic (verified: the regenerated body is otherwise byte-identical, including the attic footprint `[[6, 0], [11, 0], [11, 6], [6, 6]]`); confirm `flutter test` (including goldens) passes unchanged. Enable the golden case in the Python tests (emit output == shipped asset, byte for byte).

**Step 7 — the cross-seam contract test.**
New file `panel/test/house_pipeline_contract_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/house_loader.dart';

/// The executable schema agreement across the Python/Dart seam (ADR-0004):
/// what the converter emits, loadHouse must accept. Skips where python3 is
/// absent — the agreement is then checked wherever python3 exists.
void main() {
  final hasPython = _python3Available();
  test(
    'converter output loads through loadHouse (cross-seam contract)',
    () async {
      final tmp = Directory.systemTemp.createTempSync('house-contract-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final out = '${tmp.path}/house.yaml';
      final run = await Process.run('python3', [
        'tool/sh3d_to_yaml.py',
        'tool/fixtures/placeholder-house.Home.xml',
        '-o', out, '--name', 'Demo House',
      ]);
      expect(run.exitCode, 0, reason: 'converter failed:\n${run.stderr}');
      final house = loadHouse(
        houseYaml: File(out).readAsStringSync(),
        devicesYaml: File('assets/house/devices.yaml').readAsStringSync(),
      );
      expect(house.floors, hasLength(3)); // ground, upstairs, attic
      expect(house.floors.expand((f) => f.rooms).map((r) => r.id),
          containsAll(['hall', 'garage', 'attic-storage']));
    },
    skip: hasPython ? false : 'python3 not on PATH — contract not checked here',
  );
}

bool _python3Available() {
  try {
    return Process.runSync('python3', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
```

(`flutter test` runs with cwd = package root, the same assumption `test_house.dart` already relies on. If D4 Option B is chosen instead, expect 2 floors and drop `attic-storage`.)

**Step 8 — documentation corrections.**
- `docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md`: replace "the converter warns when `devices.yaml` references a missing room" with "the loader (`panel/lib/data/house_loader.dart`) rejects a `devices.yaml` entry referencing a missing room — the converter never reads `devices.yaml`". Append one sentence recording the new state: "The loader independently enforces the geometry invariants at Panel startup (rectilinear footprints, axis-aligned walls, unique ids, pins inside their rooms), so the hand-written-YAML escape hatch gets the same guarantees; the contemplated 45° upgrade therefore touches converter + loader + renderer, kept honest by the cross-seam contract test in `panel/test/house_pipeline_contract_test.dart`."
- `panel/HOUSE-PLAN.md`: §5 step 5 list of what `flutter test` catches gains "a position outside the declared room"; the §5 closing line "a stale position renders the pin outside its room" becomes "a stale position is rejected by the loader"; §3.1's error table gains the loader's geometry errors only if hand-editing is being described there (it is not — leave §3.1 alone).

**Step 9 — full verification pass** (§7 commands), then commit.

Files created: `panel/tool/test_sh3d_to_yaml.py`, `panel/test/house_pipeline_contract_test.dart`, this plan's doc updates. Files modified: `panel/lib/data/house_loader.dart`, `panel/test/house_loader_test.dart`, `panel/tool/sh3d_to_yaml.py`, `panel/tool/fixtures/placeholder-house.Home.xml` (D4), `panel/assets/house/house.yaml` (D4, regenerated), `docs/adr/0004-…md`, `panel/HOUSE-PLAN.md`. Files deleted: none.

---

## 6. Test plan

### New Dart cases in `panel/test/house_loader_test.dart` (inline-YAML one-liners, existing pattern)

1. `rejects a duplicate room id`
2. `rejects a duplicate floor id`
3. `rejects a diagonal footprint edge`
4. `rejects a footprint with fewer than 3 corners`
5. `rejects a diagonal wall`
6. `rejects a zero-length wall`
7. `rejects a device pinned outside its room`
8. `accepts a device pinned exactly on its room boundary`

Each asserts `FormatException` whose message contains the named culprit (matching the two existing rejection tests' `.having((e) => e.message, …)` style). Behaviours pinned for the first time: every geometry invariant the Dollhouse assumes, previously "tested" only as visual corruption.

### New Dart file `panel/test/house_pipeline_contract_test.dart`

- `converter output loads through loadHouse (cross-seam contract)` — full source in Step 7. Skips without python3. Pins for the first time: the emit-strings/parse-expressions agreement, i.e. the regenerate-after-edit path of the runbook.

### New Python file `panel/tool/test_sh3d_to_yaml.py` (stdlib unittest)

1. `test_placeholder_converts_clean` — `convert(ET.parse(placeholder).getroot())`: `errors == []`; 3 floors / 15 rooms / 27 walls after D4 (2/14/27 before); the known warning `'Family Room' along x=13` present (assert presence, not warning count — after D4 the wall-less attic legitimately adds four "mostly unwalled" warnings).
2. `test_placeholder_golden_matches_shipped_asset` — `emit_yaml(name='Demo House', floors, source='tool/fixtures/placeholder-house.Home.xml')` equals `panel/assets/house/house.yaml` byte-for-byte (D4 Option A; against a checked-in expected file under Option B).
3. `test_alpshotel_is_rejected` — errors non-empty; at least one each containing `unnamed room`, `diagonal edge`, `diagonal wall` (verified today: 22 + 5 + 1 = 28 errors; assert classes, not the exact count, so converter message tweaks don't break it).
4. `test_origin_shift_applied` — inline XML with a room offset from (0,0); converted footprint starts at the origin; `result.origin` equals the shift.
5. `test_slug_collision_error` — two rooms slugifying identically → error naming both.
6. `test_near_axis_edge_snapped` — an edge 0.01 m off-axis (< TOL_AXIS 0.02) converts clean and lands exactly on-axis; 0.5 m off-axis errors as diagonal.
7. `test_nothing_written_on_error` — `subprocess.run([sys.executable, 'sh3d_to_yaml.py', <AlpsHotel>, '-o', <tmp>])`: returncode 1, output file absent, stderr contains `nothing written`. (The one adapter-level test; everything else goes through the real `convert`/`emit_yaml` interface.)

Behaviours pinned for the first time on the Python side: the whole composition — origin shift, slug collisions, floor numbering, nothing-written-on-error — plus both fixtures finally referenced by something executable.

### Existing tests that change or die

None die. The three existing `house_loader_test.dart` cases pass unchanged (their `_house`/`_devices` constants already satisfy every new check). The five `loadTestHouse` suites double as proof the shipped assets satisfy the new gatekeeper (all 33 pins verified ≥ ~0.4 m inside their Rooms — closest are the doorbell and garage-door at exactly 0.4 m).

### Golden impact

None expected. Goldens live in `panel/test/golden/goldens/` (update via `cd panel && flutter test --update-goldens test/golden`). Loader validation adds no rendering change; D4's regeneration is geometry-identical (one extra empty `walls:` key, which the loader normalizes to `const []`). If any golden fails after Step 6, that is a bug in the step, not a golden to rubber-stamp — `test/golden/failures/*_isolatedDiff.png` will show what moved.

---

## 7. Verification

```sh
cd panel && flutter analyze && flutter test          # Dart: loader, contract, widgets, goldens
cd panel && python3 tool/test_sh3d_to_yaml.py        # Python: converter core
cd panel && python3 tool/sh3d_to_yaml.py tool/fixtures/placeholder-house.Home.xml \
    -o assets/house/house.yaml --name "Demo House"   # (Step 6 only) regenerate
git diff --stat                                       # confirm only intended files moved
```

Live look, if wanted: `cd panel && flutter run -d chrome`. **This Mac has Flutter via brew but NO Xcode — never `-d macos`;** the web build is the verification path (see memory: Mac dev toolchain). The cross-seam contract test must pass here (python3 3.14.6 is on PATH) and must *skip*, not fail, where python3 is absent.

---

## 8. Non-goals

Taken from the verifier's discipline notes, each with its written-down trigger:

- **No overlap or floor-tiling checks in the loader** (D5). Grid-sampling is authoring-time work; the painters tolerate overlap without crashing. Trigger to revisit: an overlap actually reaching the Dollhouse through the escape hatch, or plan 06's shared parser making an exact rectilinear-overlap check natural.
- **No change to `Wall.horizontal` (house.dart:50) or `plan_geometry`'s `_eps` split.** They become legitimate under the gatekeeper's guarantee. Trigger: the 45° upgrade ADR-0004 already contemplates — which now touches converter + loader + renderer, and gets caught by the contract test if the ends drift.
- **No extraction of `devices.yaml` parsing into a shared pure-Dart module** — that is plan 06's job (note `tool/gen_dev_entities.dart` is its second consumer). This plan only keeps Device-side checks and geometry checks in separable private helpers so that move stays cheap.
- **No fix to `house.dart:6-8`'s wrong per-Floor-origin doc comment** — plan 03.
- **No YAML round-tripping dependency, no schema-definition files.** The executable contract test *is* the schema tie; ADR-0004 already rejected round-tripping YAML machinery.
- **No converter warning-system changes, no furniture support, no multi-Panel concerns.**
- **No renaming or splitting of `sh3d_to_yaml.py`** — the pure core lives in the same file; one tool, one file, stdlib only, per ADR-0004.

---

## 9. Cross-plan coordination

There are 8 plans in this series: `01-device-presentation-module.md`, `02-hubclient-contract-and-scriptable-fakehub.md`, `03-floor-geometry-owner.md`, this one (`04-house-plan-gatekeeper.md`), `05-floor-arrangement-module.md`, `06-device-vocabulary-table.md`, `07-hub-status-three-state.md`, `08-panel-boot-module.md` — all in `docs/plans/`. Coordination notes received verbatim, plus discoveries:

- **Plan 06** (`06-device-vocabulary-table.md`) extracts a shared pure-Dart `devices.yaml` parser out of `house_loader`. Either order works: if 06 lands first, this plan's geometry invariants go in `loadHouse` on top of the shared parser; if this plan lands first, 06 moves code that now includes the pin-inside-Room validation. Keep Device-side checks and geometry checks separable to make that move cheap (this plan's `_checkPin` vs `_checkFootprint`/`_checkWall` split, §3). Discovered: `tool/gen_dev_entities.dart` already parses `devices.yaml` independently — plan 06's second adapter.
- **Plan 03** (`03-floor-geometry-owner.md`) fixes `house.dart`'s wrong origin doc comment ("Each Floor has its own plan origin at its north-west corner" contradicts ADR-0004's one shared origin); this plan corrects ADR-0004's misattributed orphan-Room sentence — both land regardless of order; they touch different files and different sentences.
- **The cross-seam contract check invokes `python3`; it must skip cleanly when python3 is absent** (CI/dev machines) — implemented via the `skip:` probe in Step 7.
- Discovered overlap to watch: if another plan regenerates or reorders `assets/house/house.yaml` or edits `placeholder-house.Home.xml`, Step 6's byte-for-byte golden must be re-run last-writer-wins; the golden test makes any silent divergence loud immediately.

---

## 10. Sources

- `CONTEXT.md` (repo root) — domain glossary quoted in §2.
- `docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md` — the pipeline decision this plan enforces (plus 0001-0003 for the wider frame).
- `.claude/skills/codebase-design/SKILL.md` — the design vocabulary (module, interface, seam, adapter, depth, locality, leverage, deletion test).
- Originating architecture review: candidate 4 ("What a valid House Plan is lives only on the Python side of the seam…") and its adversarial verification verdict — temp HTML artifact, ephemeral; the load-bearing facts are reproduced in §1 of this document.
- Empirical runs against commit 105610c (2026-08-01): placeholder conversion (exit 0, 2/14/27, 1 warning, diff vs shipped = attic block only), AlpsHotel conversion (exit 1, 28 errors: 22 unnamed-room, 5 diagonal-edge, 1 diagonal-wall, nothing written), `git show 40fb0fe` (hand-added attic block + origin-shift print).
