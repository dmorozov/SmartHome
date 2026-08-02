# Phase 0 — the experiment gate

One sitting of Sweet Home 3D experiments that settles every unknown the placements pipeline depends on, plus the missing test fixtures. **No production code changes.** Everything later phases assume is either already measured (recorded below with evidence) or answered here.

Status: proposed · Gate for: phases 1–2 · Written against commit `d01f290` (2026-08-01).

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

- **(a) Native fields.** Launch SH3D with the additional-properties system property and see whether the *Modify furniture* dialog grows editable rows:
  ```sh
  JAVA_TOOL_OPTIONS="-Dcom.eteks.sweethome3d.additionalFurnitureProperties=placementKey,kind" \
      open -a "Sweet Home 3D"
  ```
  (If `open -a` does not pass the environment through, run the binary inside the bundle directly: `"/Applications/Sweet Home 3D.app/Contents/MacOS/SweetHome3D"`.) Report whether the fields appear and whether typing into them writes `<property>` children — that is V8, and it makes authoring a one-line alias.
- **(b) Marker library.** Furniture Library Editor (same download page): three entries — SmartHome Light / Thermostat / Camera — each carrying `kind` as a catalog property, creator `SmartHome`. Import, place, save, inspect: do the catalog properties land on the *placed* piece (**V2**), and what `catalogId` dialect appears (**V3**)? Also unzip the `.sh3f` and paste its `PluginFurnitureCatalog.properties` (**V9**). Per EX-V3 never assume the `Creator#id` shape — three dialects exist in the wild.
- **(c) Injection script.** What E2 already does, kept as a permanent tool: name pieces in SH3D, run one command, keys land. Zero UI work, zero library maintenance — the honest fallback if (a) and (b) are both awkward.

Phase 1 only needs *one* of these to work, and it reads the key from the same place regardless.

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

All under `panel/tool/fixtures/`, hand-written or produced by the experiments — these close coverage holes the corpus proved (no repo fixture exercises any of them today):

1. **`marker-props.Home.xml`** — the E2/E3 output (trimmed: the two rooms, three markers with properties). Phase 1's primary parser fixture; its exact `<property>` syntax is the ground truth phase 1 codes against.
2. **`no-levels.Home.xml`** — a single-storey home with **zero `<level>` elements** (rooms/walls/furniture without `level` attributes). The spec §8 is right that this is what anyone tests first; no example or fixture has it. Easiest made by drawing a one-level home in SH3D and checking whether 7.4 even omits `<level>` — if 7.4 always writes one, record that and the fixture instead pins the one-level path.
3. **`negative-origin.Home.xml`** — a copy of the placeholder fixture translated by (−300 cm, −200 cm) (script it; every `x`/`y`/`xStart`… attribute shifts). Pins the shared-origin min-shift against the wild norm (EX-3).

Do not modify `placeholder-house.Home.xml` in this phase — phase 1 owns its marker enrichment.

## 5. Recording the results

Fill the table below **in this file** (it is the series' verification record, mirroring the spec's Appendix A discipline: every answer with its method):

| Item | Experiment | Result | Evidence |
|---|---|---|---|
| **V1 property round-trip (stock save)** | E2 | *pending* | |
| V6 y-direction | E3 | *pending* | |
| V4 copy-paste preserves key | E4 | *pending* | |
| Room/level property mechanism (SI-3) | E5 | *pending* | |
| V8 additional-properties fields | E6a | *pending* | |
| V2 catalog→piece propagation | E6b | *pending* | |
| V3 catalogId dialect on own library | E6b | *pending* | |
| V9 .sh3f property syntax | E6b | *pending* | |
| Chosen authoring path | E6 | *pending* | |
| V23 subscribe_entities snapshot | E7 | *pending* | |
| V19 arcExtent sign | E8 | *pending* | |
| Zero-`<level>` case exists? | E8 | *pending* | |

Then update `docs/plans/sh3d-import/README.md`'s stop-rule status, and — if V1 passed — phase 1 is unblocked.

## 6. Verification

No production code changes, so: `cd panel && flutter analyze && flutter test` must be untouched-green, and `python3 tool/test_sh3d_to_yaml.py` still `OK` (the new fixtures are inert until phase 1 references them). This Mac verifies via `flutter run -d chrome` if needed — never `-d macos`.

## 7. Non-goals

- No converter changes, no schema changes, no Dart changes.
- No third-party-plan tolerance work (EX-2 is recorded, not fixed).
- No registry library / zero-typing path — deferred permanently until real hardware has registry device ids AND V3-roundtrip proves out (and note the purity conflict, README correction #6).
