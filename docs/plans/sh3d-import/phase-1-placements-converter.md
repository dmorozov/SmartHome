# Phase 1 — placements from the drawing (converter only)

Teach `panel/tool/sh3d_to_yaml.py` to read Device markers out of the Sweet Home 3D drawing — key, kind, name, position, computed Room membership — and emit them as a `devices:` section of the generated `house.yaml`. Mint ADR-0005 superseding ADR-0004's devices-as-furniture-markers rejection. **Python and fixtures only: zero Dart changes, the loader ignores the new section, all four goldens must not move.**

Status: **LANDED 2026-08-02** · Gate: phase 0 complete, V1 favorable — met · Written against `d01f290`, implemented against `e03573c`.

**As-built deltas from the plan:**

- **D-key — key spelling is free-form** (author's decision, 2026-08-02). Any spelling, separator or case; only emptiness and collisions are rejected. The plan's open question about validating against a slug pattern is closed in favour of not validating: Sweet Home 3D constrains nothing, and a rule about punctuation buys consistency this pipeline never uses. `test_key_spelling_is_the_authors_business` pins it.
- **`negative-origin.Home.xml` was regenerated** from the *enriched* placeholder, so it now mirrors all 33 markers rather than geometry alone. The test that replaced §7 case 10 is strictly stronger: the entire emitted House Plan — geometry and all 33 Placements — must be identical between the two drawings, which are the same house 3 m apart.
- **Two behaviours the plan budgeted for already worked** (measured in phase 0): the zero-`<level>` default-Floor synthesis, and the min-shift over negative coordinates. Both now have fixtures rather than new code.
- **Suite grew 10 → 29**, not the estimated ~21, and 9 mutations were used to prove the new tests bite (origin shift skipped, edge allowance removed, duplicate check removed, markers moving the origin, walk not recursing into groups, `shelfUnit` dropped, kind validation removed, empty `devices:` emitted, group child's own level ignored). All 9 caught.

---

## 1. Why

Placing a Device today is the House Plan's worst manual step (`panel/HOUSE-PLAN.md` §5): read the room id out of a generated file, hover the spot in Sweet Home 3D, convert cm→m by hand, subtract the origin-shift line the converter printed, type the meters into `devices.yaml` — and the loader's `_checkPin` exists mostly to catch the mistakes this hand arithmetic invents (position left behind when `room:` changes, positions measured room-relative). The drawing already knows where everything is, in the same coordinate system, with the same origin. This phase makes the drawing own "where" — the converter computes position and Room membership; a person never types meters again.

It is deliberately **additive**: the emitted `devices:` section has no consumer yet. `loadHouse` reads exactly `houseDoc['name']` and `houseDoc['floors']` (`panel/lib/data/house_loader.dart:28-138`), so an extra top-level key is invisible to it. That keeps this phase's blast radius to one Python file, its tests, two fixtures, and one asset regeneration — and gives phase 2 a stable, already-tested producer to cut over to.

## 2. Context a fresh session needs

### Domain terms (CONTEXT.md — use these words)

**Panel** (wall touchscreen; avoid kiosk/dashboard) · **Hub** (Home Assistant broker; Panel is its client) · **Dollhouse** (the Panel's main view) · **House Plan** (the Panel-side geometry description — Floors, Rooms, Walls; the Hub never sees it) · **Floor** (avoid level/story) · **Room** (Rooms tile their Floor completely) · **Wall** (only drawn Walls exist; avoid "opening") · **Device** (avoid "entity" — the Hub's term). This phase mints two terms into CONTEXT.md: **Placement** (a Device marker in the drawing — its key, kind, and position as drawn) and **Key** (the author-controlled identity of a Device, typed once in Sweet Home 3D; everything else references it).

### Design vocabulary (.claude/skills/codebase-design/SKILL.md)

Deep module / interface (everything a caller must know, invariants included) / implementation / seam / adapter / depth / leverage / locality / deletion test. Never component/service/API/boundary.

### The empirical facts this phase is built on (measured, verified — do not re-derive)

- **Angles in Home.xml are RADIANS** (spec §7 says degrees — it is wrong; 1,412 measured values, max 2π). Irrelevant here only because we don't emit orientation (§4 D6), but never add a degrees conversion.
- **Furniture coordinates are absolute** plan cm, including inside `furnitureGroup` children (529/529 verified). Groups don't nest in the wild but recurse anyway; children carry their own `level` (fall back to the group's if absent).
- **The furniture walk must include `<shelfUnit>`** (SH3D 7.4 emits it; a walk keyed on the four legacy tags silently drops pieces) — walk `pieceOfFurniture | doorOrWindow | light | shelfUnit | furnitureGroup` and tolerate unknown siblings.
- **Element tags do not classify Devices** (Blues has zero `<light>` elements for 218 pieces). Recognition keys on the marker property / catalogId, never the tag.
- **catalogId comes in three dialects** (`Creator#id`, flattened `creator-id`, opaque tokens) — match exact strings from a table, never parse the shape.
- **`arcExtent="0.0"` occurs on straight walls** — anywhere the converter inspects it, test `!= 0`, not presence.
- **Negative coordinates are the wild norm**; the shared-origin min-shift (`sh3d_to_yaml.py:281-286`) already handles them; a fixture now pins it (phase 0).
- **Real third-party plans do not convert** (39% unnamed Rooms, duplicate names idiomatic) — by design; this pipeline serves the family's disciplined drawing (ADR-0004's rules are authoring guidance, and the errors say how to fix the drawing).
- The exact `<property>` syntax and V2 propagation behaviour come from **phase 0's results table and its `marker-props.Home.xml` fixture** — read both before writing the parser.

### Current converter tour (`panel/tool/sh3d_to_yaml.py`, 408 lines, stdlib-only — ADR-0004)

- Docstring `:1-25` — the contract: rules, y-south meters, shared NW origin, "Doors and windows placed in walls are ignored" (stays true).
- Constants `:37-41` — `TOL_AXIS = 0.02`, `GRID = 0.1`, `WALL_NEAR = 0.25`, `COVER_WARN = 0.5`, `CM = 0.01`.
- `load_home_xml` `:44-49`, `slugify` `:52`, `fmt` `:56-58` (trims trailing zeros; whole meters print bare).
- `rectilinearize` `:61-99`, `shoelace` `:102`, `contains` `:110-120` (even-odd point-in-polygon — **reuse this for membership**), `bbox` `:123`.
- `check_overlaps_and_gaps` `:129-181`, `check_wall_coverage` `:184-215`.
- `convert(root, name=None) -> ConvertResult` `:218-341` — the pure core (plan 04's extraction): levels sorted by `(elevation, elevationIndex)` `:239-240`, level-below-zero counting, the no-`<level>` synthetic ground floor `:249-250`, rooms/walls collected per floor via `by_key` `:251,260-274`, shared origin `:281-286`, per-room slug/rectilinearize/shoelace normalize `:288-312`, wall snap/drop-zero-length `:314-330`, per-floor checks `:332-334`, empty floors dropped `:336`.
- `ConvertResult = namedtuple('ConvertResult', 'name floors origin errors warnings')` `:34-35`.
- `emit_yaml(name, floors, source)` `:344-366` — exact text, DO-NOT-EDIT header.
- `main()` `:369-394` — argv/IO/exit only; prints the origin-shift line `:392-394` (**phase 2 deletes that print**; this phase keeps it — devices.yaml still exists).
- Tests: `panel/tool/test_sh3d_to_yaml.py` (10 tests, stdlib unittest): `PlaceholderFixture` (converts the placeholder clean: 3 floors / 15 rooms / 27 walls; golden `test_golden_matches_the_shipped_asset` compares `emit_yaml(...)` **byte-for-byte** against `panel/assets/house/house.yaml`), `AlpsHotelFixture` (must be rejected), `ConvertCore`, `Adapter` (nothing written on error, via subprocess). Helpers `home(*body, name=...)` and `room(name, pts)` build inline XML — extend the same way.
- Fixtures: `placeholder-house.Home.xml` (3 levels, 15 named rooms, cm coordinates, x∈[0,2200] y∈[0,1100], origin (0,0) so cm/100 = emitted meters **exactly** — load-bearing for §5 step 4), `AlpsHotel.Home.xml` (breaks the rules on purpose), plus phase 0's `marker-props.Home.xml`, `no-levels.Home.xml`, `negative-origin.Home.xml`.
- The cross-seam contract: `panel/test/house_pipeline_contract_test.dart` runs the real converter on the placeholder fixture and feeds the output to the real `loadHouse` with the real `devices.yaml` — asserts 3 floors, rooms `containsAll(['hall','garage','attic-storage'])`, 33 devices. **This phase must keep it green untouched** (the extra `devices:` section is unread).
- `panel/assets/house/devices.yaml` — 33 hand-maintained Devices (id, name, kind, connectivity, room, position, entity). This phase **reads it once** to script the fixture markers (§5 step 4) and otherwise leaves it alone.

### ADR constraints

- **ADR-0004 stays binding** for everything geometric: meters, one NW origin, **x east y south (no negation — spec correction)**, rectilinear-only, Rooms tile Floors, Walls first-class centerlines, converter rejects diagonals/overlaps, never invents geometry, stdlib-only single script, generated-vs-hand two-lifecycle split, Room ids = slugified names (phase 0 E6 ratified: SH3D has no room-property mechanism).
- **ADR-0004's one superseded clause**: "Devices-as-furniture-markers in the drawing was rejected because device metadata doesn't fit a furniture name and regeneration would own hand data." Superseded by ADR-0005 (§6 below) — typed `<property>` metadata (V1-verified) answers the first objection; the key/bindings split (phase 2) answers the second: the converter regenerates placements freely because the hand-owned half (entity, connectivity) lives in a file it never touches.

## 3. Target design

### Schema addition (generated `house.yaml` gains one top-level section)

```yaml
# ... existing header + name + floors: unchanged ...
devices:
  - key: light-den
    name: "Den Light"
    kind: light
    room: den
    position: [2, 1.5]
```

- `key` — from the piece's `placementKey` user property (phase 0 E2 syntax). Author-controlled, unique across the house (duplicate = error naming **both** locations, since copy-paste preserves properties per V4 and is the common accident). In phase 2 this becomes `Device.id` — the spec's ephemeral-id-beside-key split is deliberately not adopted (README correction #7).
- `name` — the piece's `name` attribute (display; the family renames pieces in-tool). Absent name → error naming the key.
- `kind` — from the marker's `kind` user property (V2-propagated from the library), else from the catalogId table (below). Validated against the loader's exact slug list — the converter is the authoring-time gate, so a typo dies here with the valid list printed, not at Panel boot.
- `room` — computed membership (below). Emitted so the membership decision has exactly one home (this file); the loader's `_checkPin` stays as the cross-check and passes by construction.
- `position` — `[x, y]` meters from the shared origin, same `fmt` as footprints. **No angle** (D6), **no z** (D7).

Ordering: document order of the pieces in Home.xml — deterministic for an unchanged file (the SI-9 answer the spec never wrote down), and stable under regeneration.

### Marker recognition (the interface with the drawing)

A furniture element (any of the five walk tags, at root or inside a group) is a **Placement** iff it carries a `placementKey` property **or** its `catalogId` is in the marker table:

```python
# catalogId -> kind, for markers placed from the SmartHome library
# (dialect per phase 0 E2 — do not assume 'SmartHome#light' until observed)
MARKER_CATALOG = {'SmartHome#light': 'light', 'SmartHome#thermostat': 'thermostat', ...}
```

- `placementKey` present, no `kind` property, catalogId in table → kind from table.
- `placementKey` present, catalogId unknown, no `kind` property → error: name the piece, list the two ways to fix (set `kind` property / place from the library).
- catalogId in table but **no `placementKey`** → error: a marker with no Key ("type placementKey on the piece: …"). Zero-typing via per-device catalogIds is deferred (README correction #6).
- Everything else — all ordinary furniture — is not a Placement and is ignored exactly as today.

### Membership (computed, replacing the runbook arithmetic)

For each Placement, on its Floor (own `level` attr, else enclosing group's): the Room whose polygon `contains` the position, else the Room with the nearest edge within **0.05 m** (mirror the loader's `_pinEps` — same constant, same reason: on-the-wall pins are what HOUSE-PLAN.md tells the family to do, and even-odd is ambiguous on the boundary; segment distance is trivial for axis-aligned edges). Rooms tile the Floor (ADR-0004), so containment is unique; an eps-tie across a shared boundary picks the containing Room first, then the smaller-area Room, deterministically. **No match → error** naming the key and position — not the spec's legal `room: null` (README correction #13); a marker outside every Room is a drawing mistake and this converter is a gatekeeper.

### What deliberately does not change

`convert()`'s signature and `ConvertResult` shape (floors gain nothing; a new `devices` field is added to the namedtuple — additive), all existing errors/warnings and their wording, `emit_yaml`'s existing sections byte-for-byte, the origin computation (**rooms and walls only** — a stray marker must not move the origin every other coordinate hangs from; a marker outside all rooms errors anyway), stdlib-only, single file.

## 4. Decision points

**D1 — where placements land.** (a) `devices:` in house.yaml (one generated artifact) — **recommended**: one converter run, one file, the schema mirrors devices.yaml's shape so phase 2's loader change is minimal; (b) separate generated placements.yaml — a second artifact and a second asset for no isolation gain (both are generated; the two-lifecycle split is generated-vs-hand, not geometry-vs-devices).

**D2 — key uniqueness.** (a) duplicate `placementKey` is an **error naming both pieces and their rooms** — recommended (copy-paste preserves the property, so this is the #1 expected accident; the spec's duplicate-keys-legal cardinality was cut, README correction #7); (b) warn and suffix — invents identity the author didn't write.

**D3 — kind validation site.** (a) converter validates against the loader's slug list and errors with the valid list — **recommended** (authoring-time, names the piece; the loader's throw then only ever means a corrupted file); (b) emit raw and let the loader throw at Panel boot — moves the failure two modules downstream from the person who can fix it.

**D4 — Room/Floor identity.** Slug-of-name stays (phase 0 E6: SH3D has no room/level property mechanism — the spec's authored roomKey was unimplementable, SI-3). Rename cost stays the documented loud-failure chore; phase 2's bindings orphan check keeps it loud.

**D5 — unnamed marker pieces.** Error (the name feeds the Popup and pin labels). The family names three dozen markers once.

**D6 — angle.** Not emitted. The Dollhouse has no orientation seam (pins are circles), so carrying it is speculation. Trigger to revisit: a directional pin rendering (camera view cones). When it comes: **radians**, sign flipped only if the renderer needs it — never a degrees conversion.

**D7 — z / elevation.** Not emitted; `_point` in the loader (correctly) rejects 3-element positions. Trigger: per-Floor vertical placement in a future 3D-ish Dollhouse.

## 5. Step-by-step implementation

Each step leaves `python3 panel/tool/test_sh3d_to_yaml.py` OK and `cd panel && flutter analyze && flutter test` green.

**Step 0 — re-verify the ground.** `git log --oneline -5`; confirm phase 0's results table is filled and V1 = favorable; read `marker-props.Home.xml` and copy its literal `<property>` syntax into the parser tests. Re-check the line references in §2 against HEAD.

**Step 1 — the furniture walk + marker extraction (pure).** In `sh3d_to_yaml.py`: a `_walk_furniture(root_or_group, inherited_level)` generator over the five tags (recursing into `furnitureGroup`, child `level` overriding the group's); `extract_placements(root, by_key, errors)` producing raw placements (key, kind, name, x·CM, y·CM, floor) with the D2/D3/D5 errors. Wire into `convert()` after walls: origin-shift the positions, compute membership (reuse `contains`; add the 12-line axis-aligned segment-distance helper mirroring the loader's `_segmentDistance`), append the D2 duplicate check and the no-room error, store on the result. Add `devices` to `ConvertResult`.

**Step 2 — emission.** `emit_yaml` gains the `devices:` section (same `fmt`, document order). The placeholder fixture has no markers yet, so the golden test needs the section to be **omitted entirely when there are no placements** — decide that explicitly: an empty drawing emits no `devices:` key (cleaner for the phase-2 loader: absent = old-style file, phase 2 can then require it or default `[]`).

**Step 3 — converter tests.** Extend `test_sh3d_to_yaml.py` (§7 test list) using the `home()`/`room()` helpers plus a `marker()` helper built from the phase-0 property syntax. Run against `marker-props.Home.xml` too (the real-app output, not just synthetic XML).

**Step 4 — enrich the placeholder fixture with the 33 real Devices.** Script it (scratchpad one-off, not committed): read `panel/assets/house/devices.yaml`, for each device emit a `<pieceOfFurniture id="pf-<id>" name="<name>" x="<position.x·100>" y="<position.y·100>" level="<its floor's level id>" width="10" depth="10" height="10">` with `<property name="placementKey" value="<id>"/>` and `<property name="kind" value="<kind>"/>` children (exact syntax from phase 0), placed into `placeholder-house.Home.xml`. Positions ×100 is exact because the placeholder's origin is (0,0) — the converter must emit back **exactly** the devices.yaml positions. Add a fixture comment noting the markers mirror devices.yaml at phase 1 and become the source of truth at phase 2.

**Step 5 — regenerate the shipped asset.**
```sh
cd panel && python3 tool/sh3d_to_yaml.py tool/fixtures/placeholder-house.Home.xml \
    -o assets/house/house.yaml --name "Demo House"
```
The diff must be exactly: `+ devices:` and 33 placement blocks whose `key/name/kind/room/position` match devices.yaml's `id/name/kind/room/position` line for line (membership computed = declared, since the shipped devices.yaml already passes `_checkPin`). Any other diff is a bug. Update the Python golden's expectations; `test_golden_matches_the_shipped_asset` pins the new bytes.

**Step 6 — the equivalence gate.** `cd panel && flutter analyze && flutter test` — **all suites, all four goldens, and `house_pipeline_contract_test.dart`, unmodified and green**: the loader never reads `devices:`, so any Dart-side change is a phase-1 bug by definition. Never `--update-goldens`.

**Step 7 — ADR-0005 + docs.** Create `docs/adr/0005-devices-authored-in-the-drawing.md` (§6). CONTEXT.md: mint **Placement** and **Key** (§2 wording). `panel/HOUSE-PLAN.md`: add a short "coming: markers" note only if desired — the full §5 rewrite belongs to phase 2 (devices.yaml is still the operative path today). `panel/README.md` pipeline section: mention the emitted `devices:` section and that the Panel ignores it until the bindings cutover.

## 6. ADR-0005 draft (create at step 7)

> # Devices are authored in the House Plan drawing
>
> ADR-0004 rejected devices-as-furniture-markers because "device metadata doesn't fit a furniture name and regeneration would own hand data." Both objections are now answered, and the rejection is superseded — narrowly; every other ADR-0004 decision stands.
>
> Metadata no longer rides the name: Sweet Home 3D user-defined `<property>` elements survive save/load round-trips in stock SH3D 7.4 (verified by experiment, `docs/plans/sh3d-import/phase-0-experiment-gate.md` results), so a marker carries `placementKey` and `kind` as typed data. A small SmartHome furniture library (.sh3f) pre-seeds `kind`; the designer types one `placementKey` per placement. Regeneration owns no hand data: the converter emits Placements (key, kind, name, room, position) into the generated `house.yaml`, while everything hand-owned — which Hub entity a Key binds to, `local|cloud` connectivity — lives in `bindings.yaml`, which the converter never reads or writes (the two-lifecycle rule of ADR-0004, with the hand file's schema shrunk from seven fields to a binding).
>
> Positions and Room membership are therefore computed, not typed: the converter assigns each marker the Room whose footprint contains it (0.05 m edge allowance, matching the loader), and errors on a marker outside every Room, a duplicate key, an unknown kind, or a nameless marker — authoring-time failures naming the piece, in the tool where the fix happens. The loader keeps its independent gatekeeper checks; the Panel's pins land exactly where the drawing put them.
>
> Rejected again, with reasons: keys derived from catalogId (per-class, cannot distinguish two lights; and a per-device registry library would put Hub ids inside the artifact); orientation/z emission (no Dollhouse seam consumes them — radians, when ever needed); the Hub's entity ids as identity (they churn; they are call targets, bound per-Key in bindings.yaml); tolerance for unnamed rooms or duplicate room names (this pipeline serves one disciplined drawing, not arbitrary imports — measured: 39% of rooms in public example plans are unnamed and would need invented identity).

## 7. Test plan (converter suite)

New cases in `panel/tool/test_sh3d_to_yaml.py`:

1. `test_marker_with_property_key_is_extracted` — synthetic home, one marker: key/kind/name/room/position all correct, position origin-shifted.
2. `test_marker_inside_a_group_uses_absolute_coords_and_own_level` — group at one spot, child marker elsewhere; child's coordinates used verbatim (V11), child `level` wins over group's.
3. `test_shelfunit_and_light_markers_are_walked` — markers on non-`pieceOfFurniture` tags are found (EX-1/EX-5).
4. `test_kind_from_catalog_table_when_property_absent` — and the unknown-catalogId + no-kind error.
5. `test_duplicate_key_errors_naming_both_locations` (D2; message contains both room names).
6. `test_marker_with_no_key_errors` · `test_unknown_kind_errors_listing_valid_slugs` · `test_nameless_marker_errors` (D3/D5).
7. `test_marker_outside_every_room_errors` and `test_marker_on_room_edge_within_eps_is_assigned` (0.05 m — mirror the loader's boundary case).
8. `test_ordinary_furniture_is_ignored` — a plan full of non-marker pieces emits no `devices:` key at all (step 2 decision).
9. `test_marker_props_fixture_round_trips` — the real `marker-props.Home.xml` from phase 0.
10. `test_negative_origin_fixture_shifts_markers_too` — phase 0's negative-origin fixture with one marker: origin from rooms/walls only, marker shifted by it.
11. Golden updated: placeholder → 33 placements byte-for-byte; AlpsHotel still rejected (unchanged).

Dart side: **no test changes**. The contract test and all goldens pass untouched — that is the phase's equivalence proof.

## 8. Verification

```sh
python3 panel/tool/test_sh3d_to_yaml.py            # converter suite (was 10, grows to ~21)
cd panel && flutter analyze && flutter test        # all green, zero golden updates
python3 tool/sh3d_to_yaml.py tool/fixtures/placeholder-house.Home.xml -o /tmp/regen.yaml --name "Demo House" \
  && diff /tmp/regen.yaml assets/house/house.yaml  # idempotent
```

(Use the scratchpad for temp output if running under an agent; `flutter run -d chrome` for a live look — never `-d macos` on this Mac.)

## 9. Non-goals

- **No Dart changes of any kind** — the loader, domain, and Panel are untouched; phase 2 owns the cutover.
- **No devices.yaml changes** — it remains the operative source until phase 2; the origin-shift print in `main()` stays for it.
- **No goldens move.** Any golden diff is a phase-1 bug.
- **No openings, no angle, no z, no third-party-plan tolerance, no registry library** (triggers recorded in D6/D7 and README corrections #6/#8).
- **No new dependencies** — stdlib only, one file (SR-17; the parse/walk/membership split is sections within it, like plan 04's pure-core split).
