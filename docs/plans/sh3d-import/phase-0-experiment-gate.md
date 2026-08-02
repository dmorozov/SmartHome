# Phase 0 — the experiment gate

One sitting of Sweet Home 3D experiments that settles every unknown the placements pipeline depends on, plus the missing test fixtures. **No production code changes.** Everything later phases assume is either already measured (recorded below with evidence) or answered here.

Status: **run 2026-08-02 — V1 PASSED, the gate is open** (results in §5) · Gate for: phases 1–2 · Written against commit `d01f290` (2026-08-01).

---

## 1. Why this phase exists

The whole authoring model of phases 1–2 — Devices as typed markers in the drawing, keys typed into an SH3D user property — rests on behaviours of Sweet Home 3D that no documentation answers (the SH3D forum is not web-indexed; every SH3D-side unknown must be settled by experiment). The spec's own working agreement is right: *"B.1 must be empty before geom/ or the binding resolver is started."*

Static forensics on the four real files in `docs/examples/` already answered half the blocking list **for free** — including one answer that inverts the spec (angles are radians, not degrees). What remains genuinely open is exactly what a save/load round-trip in the running application can answer, and nothing else can.

**The stop rule.** If E3 below fails — SH3D drops unknown `<property>` elements when a designer without special configuration saves — then phases 1 and 2 are dead as designed: the only fallback (encoding the key in the piece *name* with a delimiter) is exactly the alternative ADR-0004 rejected ("device metadata doesn't fit a furniture name"), and adopting it would make the rejection's reasoning true again. Record the outcome in ADR-0004 as a confirmation, keep the two-file pipeline, and skip to phase 3 (which does not depend on markers).

## 2. Already answered — do not re-verify, build on it

Measured on `AlpsHotel-compressed.sh3d`, `Blues.sh3d`, `House-based-on-a-factory-compressed.sh3d`, `Industrial_Loft-compressed.sh3d` (all saved by SH3D 7.4, `<home version="7400">`), adversarially re-measured by an independent verifier. Extraction recipe used, for reproduction:

```sh
python3 -c "
import zipfile
z = zipfile.ZipFile('docs/examples/Blues.sh3d')
open('/tmp/Blues.Home.xml','wb').write(z.read('Home.xml'))"
```

| Question | Answer | Evidence |
|---|---|---|
| **V5** — angle unit in Home.xml | **RADIANS** (the spec §7 asserts degrees — inverted). Optional attribute; absent = 0 | 1,412 piece angles: max 6.2832 = 2π, zero > 6.3, clusters at float32 π-multiples (1.5707964 / 3.1415927 / 4.712389 / 6.283185); arbitrary sub-2π values (0.4808, 5.5865…); compass `northDirection="3.1415925"` |
| **V11** — group child coordinates | **Absolute** plan coordinates, not group-relative | 529/529 children of 120 `furnitureGroup`s in plan range; AlpsHotel group at (165.29846, 288.83868) has a child at exactly (165.29846, 288.8387). Groups never nested in corpus; a group may lack `angle`; every child carries its own `level` = the group's |
| **V12** — ids written by 7.x | Yes, on 100% of rooms/walls/pieces/levels/labels; legacy (`wall0`) and uuid dialects coexist in one file ⇒ ids survive re-saves | 95/95 rooms, 411/411 walls, 1,724/1,724 furniture elements |
| **V14** — objects without `level` in a leveled home | Zero in the wild (0/95 rooms, 0/411 walls, 0/1,191 top-level pieces) | all four files |
| **V16** — archive without Home.xml | No counterexample; all four carry Home.xml + legacy `Home` + `ContentDigests`; no DOCTYPE anywhere | zip listings |
| **V19** — arcExtent | Sign still unknown, **but**: `arcExtent="0.0"` occurs on straight walls — presence ≠ arc; test `!= 0` | 2 occurrences in 411 walls, both `"0.0"` |
| **V20** — absent wall height | Zero in the wild (0/411). Sloped tops real (39× `heightAtEnd`); wall height may exceed its Floor's (390 on a 250 level) | Factory `wall0` |
| **V1/V2** — `<property>` round-trip | **OPEN — this phase's core experiment.** Zero property children on ~1,700 placed pieces (mechanism unused in the wild). Positive signal: the `<home>` root carries 14–23 `<property>` children preserved across saves | e.g. `com.eteks.sweethome3d.SweetHome3D.PlanScale` |
| **V3** — catalogId on imported pieces | Present on 96–100% incl. user-imported, in three dialects: `Creator#id`, `creator-id` (flattened), opaque 20-char tokens. Missing only on in-app geometry (Shape/Roof/Beam). **Round-trip through a fresh user .sh3f still unproven** | `Artist373#shelves`, `eteks-doublehungwindow80x122`, `FP7oy8H1jlqexh2MwXxY` |
| **V4** — copy-paste preserves catalogId | Suggestive yes: runs of 8 identical catalogIds under distinct ids | Loft: `1BgCsjC5YwYOKF7ojf1k` ×8 |
| **V6** — y increases downward | **OPEN** — not encoded in the XML; only weak y-down convention evidence (dimension lines at y < plan minimum) | AlpsHotel dimensionLine y=−23.36 vs plan min −13.1 |
| **V13** — elevationIndex | All 13 levels carry `"0"`, even a real mezzanine stack — same-elevation semantics unexercised | Factory levels 0/260/402/604 |
| Parse-seam drift (V7) | 7.4 emits `<shelfUnit>` (4 in Loft), `license`, `widthInPlan`, `widthDepthDeformable`, `<transformation>` under doorOrWindow — none in the 5.4-era vocabulary | Loft |
| Element tags vs Devices | Blues has **zero `<light>` elements** for 218 pieces; Loft has 29. Tag-keyed classification is unreliable | root tag census |
| Real-file conversion | Current converter aborts on all four (28/18/14/6 errors): 39% of Rooms unnamed (37/95), duplicate names idiomatic across and within Floors, diagonals ordinary | `convert()` run on each |
| Coordinates | Negative x/y is the norm (3 of 4 files, to −700 cm); Loft all-positive but far from origin | ranges per file |
| Doors ↔ walls | No wall IDREF anywhere (162 doorOrWindow; `boundToWall` false/absent) — spec §12's geometric-association premise confirmed; we defer openings instead | all four files |
| cutOutShape (V15) | Two dialects: bare SVG path data AND full embedded SVG document (XML prolog + DOCTYPE) | Blues/Factory/Loft |

## 3. The experiments

**The gate is survival, not authoring.** Whether Sweet Home 3D offers a tidy UI for typing a key is an ergonomics question with cheap answers (a launcher alias, a one-off injection script, a marker library) — and there is exactly one designer here. Whether SH3D *destroys* a property it does not understand when someone re-saves is the question that decides whether the whole authoring model is safe. So the primary experiment injects the property into the XML directly and re-saves with a stock install: no Furniture Library Editor, no `.sh3f`, no UI hunting, ~15 minutes.

Instrument: **`docs/plans/sh3d-import/sh3d-lab.py`** (stdlib, self-tested against all four example files; delete it when this phase closes).

```sh
python3 docs/plans/sh3d-import/sh3d-lab.py inspect  FILE.sh3d   # the report
python3 docs/plans/sh3d-import/sh3d-lab.py inject   FILE.sh3d -o OUT.sh3d
```

`inspect` accepts a `.sh3d` archive or a bare `Home.xml` and prints levels, rooms (with property children), walls, every furniture element **that carries user properties**, coordinate ranges, and an angle-unit verdict. `inject` writes `placementKey` + `kind` properties onto pieces and rewrites the archive, preserving every other entry.

### E1 — the test drawing (5 minutes)

Sweet Home 3D (`brew install --cask sweet-home3d` if absent). One level is enough:

1. **Plan → Create walls**: draw two adjoining rectangular rooms, one north of the other. Double-click to end each run; leave magnetism on.
2. **Plan → Create rooms**: double-click inside each enclosed area. Double-click each created room → set *Name* to `North Room` and `South Room`.
3. Drop **three pieces of furniture** from the catalog — one clearly inside the north room, one inside the south room, one anywhere. Their kind does not matter; they stand in for Device markers.
4. **File → Save as** `~/sh3d-lab/test-house.sh3d`.
5. `python3 …/sh3d-lab.py inspect ~/sh3d-lab/test-house.sh3d` → **paste output (baseline).**

### E2 — the V1 round-trip (THE GATE)

```sh
python3 docs/plans/sh3d-import/sh3d-lab.py inject \
    ~/sh3d-lab/test-house.sh3d -o ~/sh3d-lab/test-keyed.sh3d
python3 docs/plans/sh3d-import/sh3d-lab.py inspect ~/sh3d-lab/test-keyed.sh3d
```

The inspect must now report properties on the pieces. Then, in Sweet Home 3D:

6. **File → Open** `test-keyed.sh3d`. *(If SH3D refuses to open it, re-run `inject` with `--props-first`; if it opens but the properties are gone at step 9, re-run with `--drop-legacy` — the archive also holds a legacy Java-serialized `Home` entry that may win over `Home.xml` on load.)*
7. **Move one piece of furniture** a few centimetres — anything that makes the file dirty.
8. **File → Save** (not Save as — overwrite).
9. `…/sh3d-lab.py inspect ~/sh3d-lab/test-keyed.sh3d` → **paste output.**

**Properties still listed ⇒ V1 PASSES, phases 1–2 are alive.** Gone ⇒ the stop rule fires (§1).

### E3 — y-direction (closes V6, free)

Read the baseline inspect from E1: the piece in the **north** room versus the one in the **south** room. Smaller `y` on the north piece ⇒ **y increases southward**, ADR-0004's convention maps 1:1 and no negation is needed anywhere (the expected result; it also confirms the spec's §7 Y-flip must be dropped, README correction #2). Inverted ⇒ stop and escalate: everything about the axis convention reopens.

### E4 — copy-paste (closes V4)

10. In the keyed file: select a keyed piece, ⌘C ⌘V, drag the copy elsewhere, **Save**, inspect → **paste output.**

Does the copy carry the same `catalogId` *and* the same `placementKey`? Expected yes (EX-V4's runs of identical catalogIds). A yes makes duplicate keys the *common* accident, which is why phase 1's duplicate-key error must name both locations rather than warn.

### E5 — Room/level properties (closes the gap the spec never noticed — SI-3)

11. Double-click a **room** in the plan: is there any field for custom/additional properties — not *Name*, not the display toggles? Then double-click the **level tab**: same question.
12. The E2/E4 inspect output already answers the file side: `ROOMS`/`LEVELS` lines print `props={…}`.

Expected: **no mechanism** — SH3D user properties are furniture-only. That ratifies slug-of-name identity for Rooms and Floors (ADR-0004 unchanged, phase 1 decision D4) and records the spec's authored `roomKey`/`levelKey` as unimplementable in the authoring tool. If a mechanism *does* exist, note it — phase 1's D4 reopens in a good way.

### E6 — authoring ergonomics (V2, V8, V9 — only worth doing if E2 passed)

Now that survival is known, pick how keys get typed. In rough order of cost:

- **(a) Native fields — the launch flag, and it is required.** *Settled 2026-08-02, after one wrong turn in each direction.* SH3D 7.5 does ship the editor — `HomeFurniturePanel.additionalPropertiesButton.text=Other properties...` opening an `AdditionalPropertiesPanel` (a Name/Value table titled *Modify properties*) — but it renders `home.getFurnitureAdditionalProperties()`, a list that lives on the **Home** and is populated at startup from

  ```sh
  panel/tool/sh3d.sh            # wraps the flag below
  JAVA_TOOL_OPTIONS="-Dcom.eteks.sweethome3d.additionalFurnitureProperties=placementKey,kind" \
      "/Applications/Sweet Home 3D.app/Contents/MacOS/SweetHome3D"
  ```

  Declaring the properties in a catalog entry is *not* enough — measured, not reasoned: with `SmartHome.sh3f` imported and a marker placed, the dialog has no such button. The catalog sets property **values** on the piece; only the flag tells the Home the properties exist. The two are complementary, so the authoring setup is **library + launcher**, and (c) survives only for pieces from someone else's catalog.

  Use **bare names**. `fromDescription` defaults displayable/modifiable/exportable to true, and its attribute parser is off by one (`substring("modifiable=".length() + 1)` → `"rue"`), so writing `modifiable=true` sets it false.
- **(b) Marker library — CHOSEN, and built.** No Furniture Library Editor needed: `panel/tool/sh3d_marker_library.py` generates `SmartHome.sh3f` directly, because V9's syntax was read out of the 7.5 sources rather than guessed. Fourteen entries, one per Device kind, category *Smart Home*, creator `SmartHome`, `id#i=SmartHome#<kind>`. Each declares two additional properties:

  ```properties
  placementKey#1\:STRING=
  kind#1\:STRING=light
  ```

  Because catalog-declared properties are modifiable by construction, the *Modify furniture* dialog grows an **Other properties…** button holding an editable `placementKey`, and the property also becomes available under *Furniture → Display column*. `kind` arrives pre-filled, so the author types exactly one thing per Device. Eleven tests cover it (`tool/test_sh3d_marker_library.py`), including a drift test that reads `house_loader.dart`'s `_kind()` switch — the failure mode nothing else catches is a marker kind the Panel's loader rejects.
- **(c) Injection script.** Demoted to a bootstrap: `sh3d-lab.py inject` still keys pieces that were placed before the library existed, and remains the only path for a piece from someone else's catalog.

Phase 1 reads the key from the same place regardless, and additionally gains a second, independent way to recognise a marker: `catalogId` beginning `SmartHome#`. That is strictly better than a property-presence test, since it cannot be produced by accident.

### E7 — V23, the one Hub-side unknown (10 minutes, dev Hub)

Phases 1–2 don't consume capabilities, but closing V23 now costs nothing while the dev Hub is running (`hub/dev/README.md` to start it):

```sh
python3 - <<'EOF'
import asyncio, json, websockets  # pip: websockets; or use wscat
async def main():
    async with websockets.connect('ws://localhost:8123/api/websocket') as ws:
        print(json.loads(await ws.recv())['type'])          # auth_required
        token = open('hub/dev/token').read().strip()
        await ws.send(json.dumps({'type':'auth','access_token':token}))
        print(json.loads(await ws.recv())['type'])          # auth_ok
        await ws.send(json.dumps({'id':1,'type':'subscribe_entities'}))
        msg = json.loads(await ws.recv())                    # result
        msg = json.loads(await ws.recv())                    # first event
        one = next(iter(msg['event']['a'].values()))
        print('snapshot entity keys:', sorted(one.keys()))   # has 'a' (attributes)?
asyncio.run(main())
EOF
```

Record whether the initial `subscribe_entities` snapshot carries attributes (`a` key with `supported_features` etc.) or only state. (Never print the token — `token=set` discipline applies to experiments too.)

### E8 — opportunistic, if time remains

- Draw two arc walls curving opposite ways; save; inspect the `arcExtent` signs (V19).
- Add a level to the test drawing *after* the furniture exists; save; check whether pre-existing objects gained `level` attributes (the real V14 mechanism).
- Save a one-level drawing and check whether 7.4 writes a `<level>` element at all — the answer decides whether fixture #2 in §4 pins the zero-level path or the one-level path.

## 4. Fixtures to land in the repo (the phase's code deliverable)

**LANDED 2026-08-02**, all three under `panel/tool/fixtures/`, each carrying a comment header recording its provenance. They close coverage holes the corpus proved, and none of them existed before:

1. **`marker-props.Home.xml`** — 2 rooms, 3 markers, zero levels. The first `<pieceOfFurniture>` is **verbatim from `~/sh3d-lab/test-markers.sh3d`**: a marker dragged from `SmartHome.sh3f`, keyed in the Modify properties dialog, saved by the application. That is the ground truth phase 1 codes against, and it fixes four details at once — `<property>` children sort alphabetically, `catalogId='SmartHome#light'` carries the creator prefix, an unrotated piece has **no `angle` attribute at all**, and `width='9.8425'` is our declared 10 cm rounded to the nearest ⅛ inch (the display unit — sizes are advisory, positions are not). The Camera/Thermostat markers and the Hall were added by hand in the same shape so membership across two rooms is exercised; the Kitchen is the authentic L-shaped six-point room (rectilinear, not rectangular).
2. **`no-levels.Home.xml`** — the drawn one-storey home, injected properties stripped so it has one subject. **Zero `<level>` elements and no `level` attribute anywhere.** Also keeps a zero-length wall (a mis-click SH3D saved without complaint) — 8 walls in, 7 out, dropped silently.
3. **`negative-origin.Home.xml`** — `placeholder-house.Home.xml` translated by (−300 cm, −200 cm), every `x`/`y`/`xStart`… on the only two elements here that carry coordinates.

**Measured while landing them, and it revises an assumption in this series:** today's converter already handles **both** zero-level fixtures — `1 floor(s), 2 room(s)` for each — so the synthesize-a-default-Floor path was *untested*, not missing. And converting `negative-origin` produces YAML **identical to the original's, except the provenance comment naming the source file**; the min-shift genuinely erases the offset. Phase 1 inherits two working behaviours it was budgeting to build.

Do not modify `placeholder-house.Home.xml` in this phase — phase 1 owns its marker enrichment.

## 5. Recording the results

Fill the table below **in this file** (it is the series' verification record, mirroring the spec's Appendix A discipline: every answer with its method):

Run on 2026-08-02 against Sweet Home 3D 7.4 (`<home version="7400">`) on macOS, drawing `~/sh3d-lab/test-house.sh3d`: two named rooms (North/South), 8 walls, 13 furniture elements (7 `pieceOfFurniture`, 6 `doorOrWindow`), one level.

| Item | Experiment | Result | Evidence |
|---|---|---|---|
| **V1 property round-trip (stock save)** | E2 | **PASS — the gate is open.** SH3D 7.4 preserves unknown `<property>` children through open → edit → Save | 13/13 keyed pieces kept both `placementKey` and `kind`. Order flipped (`placementKey,kind` in → `kind,placementKey` out) ⇒ SH3D parsed them into its own model and re-serialised, rather than passing bytes through — stronger than mere preservation. `Bed.x` 587.8 → 581.8 proves `Home.xml` itself was rewritten. The legacy `Home` entry was present all along and did **not** shadow it; neither retry knob (`--props-first`, `--drop-legacy`) was needed |
| V6 y-direction | E3 | **PASS — y increases southward.** ADR-0004 maps 1:1; no negation anywhere; the spec's §7 Y-flip is dropped (README correction #2) | North Room y ∈ [7.37, 416.31], South Room y ∈ [423.93, 1094.49] |
| **UI→file round trip (the E6 gate)** | E6 | **PASS.** `placementKey` typed into *Modify properties*, saved, read back out of `Home.xml`: `PROPS {'kind': 'light', 'placementKey': 'light_kitchen_1'}` on a piece carrying `catalogId='SmartHome#light'`. This is E2's proof in reverse — E2 showed SH3D preserves what we write, this shows it writes what the author types | `~/sh3d-lab/test-markers.sh3d`, now the basis of `marker-props.Home.xml` |
| Key spelling is unconstrained | E6 | The author naturally typed `light_kitchen_1` — **underscores**, where every id in `devices.yaml` and ADR-0004 is kebab-case (`light-hall`). Nothing in SH3D constrains the field. **Phase 1 decision:** accept both, normalise, or reject with a message. Cheapest defensible answer is to validate against the same slug pattern the loader already requires, so the failure lands in the drawing rather than in the Panel | user-typed value, first use |
| V4 copy-paste preserves key | E4 | *not run — and largely moot.* Duplicate keys are the **default**, not an accident | SH3D names each piece after its catalog entry, so 13 pieces yielded 6 distinct slugs: 4× `kitchen-cabinet`, 4× `fixed-window`, 2× `door`. Phase 1's D2 (error naming both locations) is reinforced, not weakened — copy-paste was never needed to produce the collision |
| Room/level property mechanism (SI-3) | E5 | **NONE — closed, both sides.** Slug-of-name identity for Rooms and Floors is ratified (phase 1 D4); the spec's authored `roomKey`/`levelKey` is unimplementable in the authoring tool | File side: both rooms report `props={}` across all three inspects, and there is no `<level>` element to carry properties at all. UI side (SH3D 7.5): the Modify rooms dialog offers no additional-properties control |
| **Zero-`<level>` case exists?** | E8 | **YES — confirmed.** A one-level 7.4 drawing writes **no `<level>` element**, and no object carries a `level` attribute | `LEVELS 0`; `level=None` on both rooms and all 13 pieces. Fixture #2 (`no-levels.Home.xml`) pins the zero-level path as written, and the synthesize-a-default-Floor path is real |
| V5 angle unit (re-confirmed) | E1 | **RADIANS**, on a file authored fresh rather than mined from the corpus | 10 angles, min 1.5708 = π/2, max 6.2832 = 2π. Three pieces carry **no `angle` attribute at all** (unrotated ⇒ absent, not `"0"`) — the optional-attribute default is now witnessed, not inferred |
| `<home name>` is the *file* name | E2 | Confirmed, and it **follows the file**: the re-save rewrote it | `name='test-house.sh3d'` → `name='test-keyed.sh3d'` after Save. The converter already strips `.sh3d` and offers `--name` (`sh3d_to_yaml.py:234`); this is why that override is not optional cosmetics — renaming the drawing would otherwise rename the House |
| Room ids | E1 | Auto-generated `room-<uuid>`, stable across saves but opaque | `room-ad7c9827-…`; unusable as a human key, corroborating D4 |
| **V8 additional-properties fields** | E6a | **YES — confirmed in the UI 2026-08-02** (screenshot: *Other properties…* opens *Modify properties* listing `Placementkey` empty and `Kind` = `light`). Via the launch flag, and *only* via it. `-Dcom.eteks.sweethome3d.additionalFurnitureProperties=placementKey,kind`, split on `,\s*` and parsed by `ObjectProperty.fromDescription`. The dialog renders `this.home.getFurnitureAdditionalProperties()` filtered to `isModifiable()` — the list lives on the **Home**, is set only by `SweetHome3D` at startup from that flag, and is **not persisted** to the .sh3d (neither `HomeXMLExporter` nor `HomeXMLHandler` mentions it), so it must be set on every launch. Wrapped in `panel/tool/sh3d.sh` | `SweetHome3D.class` constant pool: the property name adjacent to the split regex `,\s*`; `HomeFurnitureController:380–391` |
| ~~Catalog declaration alone surfaces the fields~~ | E6a | **NO — measured, and it corrects an earlier reading of the code.** Importing `SmartHome.sh3f` and placing a marker gives a dialog with *no* "Other properties…" button (screenshot, 7.5), even though the catalog entry's `description#1` visibly reached the piece. The catalog path sets property **values** on the piece; it never adds to the Home's declaration list, which is what the UI reads. Library and flag are complementary, not alternatives | user screenshot; `DefaultFurnitureCatalog.getCatalogAdditionalProperties` feeds `CatalogPieceOfFurniture`, not `Home` |
| Description/attribute parser bug | E6a | `fromDescription` reads `substring("modifiable=".length() + 1)` — one character too far, yielding `"rue"`. Writing `modifiable=true` therefore sets it **false**. Use bare names (all three flags already default true); `:STRING` is safe | `ObjectProperty.fromDescription`, SH3D 7.5 |
| Additional properties as furniture-list columns | E6a′ | **NO.** *Furniture → Display column* on the keyed home offers only built-ins: Name, Description, Creator, License, Width, Depth, Height, Abscissa, Ordinate, Elevation, Angle, Level, Model Size, Color, Texture, Movable, Door/Window, Visible. No `placementKey`, no `kind` | `HomePane`'s dynamic `DISPLAY_HOME_FURNITURE_ADDITIONAL_PROPERTY_*` actions are built from `getFurnitureAdditionalProperties()`, which returns catalog-declared properties — not properties carried by home pieces |
| **Does SH3D's UI surface externally-written properties at all?** | E6a + E6a′ + E5 | **NO — closed on three independent surfaces.** Properties written from outside are *preserved perfectly* (V1) and *invisible entirely*. The two facts together define the authoring problem: SH3D is a faithful courier for our data and never an editor of it, unless a catalog entry declares the property | Modify furniture (no button), Modify rooms (no control), Display column (built-ins only) — all on a home whose 13 pieces each carried two properties |
| **V9 .sh3f property syntax** | E6b | **ANSWERED from source, no experiment needed.** Any resource-bundle key `<name>#<index>` whose name is not a built-in becomes an additional property of entry `<index>`; an optional `:<TYPE>` suffix sets the type, and **the colon must be escaped `\:`** or `java.util.Properties` ends the key there and swallows the type into the value. Built with `new ObjectProperty(name, type)`, which delegates to `(name, null, type, true, true, true)` — **displayable, modifiable, exportable, unconditionally**. Editability needs no extra key | `DefaultFurnitureCatalog.getCatalogAdditionalProperties` and `ObjectProperty`'s constructors, SH3D 7.5 |
| **V2 catalog→piece propagation** | E6b | **YES, from source.** `FurnitureController.createHomePieceOfFurniture` copies *every* catalog property name onto the placed piece, dropping only `modelPresetTransformations*`. Pending only empirical confirmation | `FurnitureController.java:589–609` |
| V3 catalogId dialect on own library | E6b | `SmartHome#<kind>` via the optional `id#<index>` key — the `Creator#id` dialect, chosen deliberately so phase 1 can recognise a marker by catalogId alone | `tool/sh3d_marker_library.py`; confirm in the saved `Home.xml` |
| Mandatory catalog keys | E6b | `name`, `category`, `icon`, `model`, `width`, `depth`, `height`, `movable`, `doorOrWindow` — all read with `resource.getString`. Indexes start at 1 and **must be contiguous**: `readFurniture` stops at the first absent `name#`, so a gap truncates the catalog silently | `readPieceOfFurniture`, `readFurniture` |
| **Chosen authoring path** | E6 | **(b) marker library + (a) launcher — both, since neither works alone.** `tool/sh3d_marker_library.py` generates `SmartHome.sh3f` (14 markers, one per Device kind, `kind` preset, `catalogId=SmartHome#<kind>`); `tool/sh3d.sh` launches SH3D with the declaration flag so `placementKey` is editable. Authoring is then: drag a marker, type one key. The injection script drops to a bootstrap for pieces from other catalogs | Confirmed end to end in 7.5. 11 tests on the library, incl. a drift test reading `house_loader.dart`'s own `_kind()` switch |
| **Standing discipline this introduces** | E6a | The House Plan must be opened via `tool/sh3d.sh`, never the Dock icon: the flag is per-session and unsaved, so a normal launch silently hides the key fields (values survive — they just become uneditable and invisible) | `HomeXMLExporter`/`HomeXMLHandler` never mention `furnitureAdditionalProperties` |
| V23 subscribe_entities snapshot | E7 | *pending* — phase 3 only, does not gate phases 1–2 | |
| V19 arcExtent sign | E8 | *not run* — arcs are cut from scope (README correction #8) | |
| Native `description`/`information` as a fallback carrier | E2 | *untested and now unnecessary* — V1 passed, so the fallback question never arose | `carrying native text: 0` on every inspect |

**Stop rule: did not fire.** Phase 1 is unblocked. The two remaining pending rows (E5's UI side, E6a) affect *authoring ergonomics only* — phase 1 reads the key from the same place regardless (§3 E6 closing line), so neither gates it.

## 6. Verification

No production code changes, so: `cd panel && flutter analyze && flutter test` must be untouched-green, and `python3 tool/test_sh3d_to_yaml.py` still `OK` (the new fixtures are inert until phase 1 references them). This Mac verifies via `flutter run -d chrome` if needed — never `-d macos`.

## 7. Non-goals

- No converter changes, no schema changes, no Dart changes.
- No third-party-plan tolerance work (EX-2 is recorded, not fixed).
- No registry library / zero-typing path — deferred permanently until real hardware has registry device ids AND V3-roundtrip proves out (and note the purity conflict, README correction #6).
