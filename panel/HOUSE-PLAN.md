# House Plan how-to — drawing, converting, adding Devices

The step-by-step runbook for getting the real house into the Panel
(pipeline decided in [ADR-0004](../docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md)).
Two files make up the House Plan:

| File | Who writes it | Contents |
|---|---|---|
| `assets/house/house.yaml` | the converter — **never edit by hand** | everything drawn: Floors → Rooms + Walls, and the Devices you placed as markers |
| `assets/house/bindings.yaml` | **you, by hand** | two lines per Device: which Hub entity it is, and local/cloud |

Re-running the converter is always safe: it rewrites `house.yaml` and never
touches `bindings.yaml`.

**Devices are drawn, not typed** ([ADR-0005](../docs/adr/0005-devices-authored-in-the-drawing.md)).
You drop a marker where the thing is; the converter works out which Room it
is in and where. Nobody measures anything.

## 1. Install the tools (once)

1. **Sweet Home 3D** (free): `brew install --cask sweet-home3d`, or download
   from <https://www.sweethome3d.com/download.jsp>. Java-based; the DMG
   bundles what it needs.
2. **Python 3** — already on the Mac (`python3 --version`); the converter
   uses only the standard library, nothing to install.

To get a feel for the editor first, open the downloaded gallery example
`tool/fixtures/AlpsHotel.sh3d` and click around. (Don't imitate its drawing
style — it breaks most of the rules below.)

## 2. Draw the house

Work floor by floor, walls first, then rooms.

### 2.1 Set up levels (Floors)

- The plan opens with one level. Add the second with **Plan → Add level**.
- **Name every level** (double-click its tab → e.g. `Ground Floor`,
  `Upstairs`). The level name becomes the Floor's id (`Ground Floor` →
  `ground-floor`) and its label in the Dollhouse.
- A basement is just a level whose *elevation* is negative (set it in the
  level dialog); the converter numbers it below zero automatically.
- All levels share one coordinate system — the upper floor sits over the
  right part of the ground floor by construction. Draw it in place (use
  **Plan → Display walls of the level below** style options if you need the
  outline to trace over).

### 2.2 Draw the walls

- **Plan → Create walls**, click corner to corner, double-click to finish a
  run. Leave the default magnetism ON — it snaps to right angles and to
  existing wall ends.
- **Right angles only.** The converter rejects diagonal walls. Where the
  real house has a 45° corner, draw the two square walls that box it in —
  the corner area will belong to one of the two rooms (pick whichever it
  flows into when you draw the rooms).
- **Draw a wall only where reality has one.** An undrawn boundary renders
  as an open passage in the Dollhouse. Open-plan boundary (family ↔
  kitchen)? No wall. Wide passage in a wall? Draw the wall in two pieces
  and leave the gap.
- **Doors and windows are ignored** by the converter — place them if you
  like the look in Sweet Home 3D, but a wall with a door still renders as
  unbroken glass. Don't split walls for ordinary doorways.
- Exact wall thickness doesn't matter (the converter keeps only the
  centerline); the default is fine.

### 2.3 Create and name the rooms

- **Plan → Create rooms**, then **double-click inside any wall-enclosed
  area** — Sweet Home 3D auto-creates the room snapped to the walls. (You
  can also click the corners by hand; magnetism keeps them square.)
- **Rooms must tile the floor**: every bit of floor area belongs to exactly
  one room. Halls, stairwells, the garage — all rooms. Absorb tiny closets
  into the room they open from. No overlaps (error), no enclosed gaps
  (warning).
- **Name every room**: double-click the room → *Name* field. Names become
  ids (`Living Room` → `living-room`) and the labels the Dollhouse draws,
  and they must be **unique across the whole house** — `Guest Bathroom` and
  `Kids Bathroom`, not `Bathroom` twice (error otherwise).
- Renaming a room later changes its id, but nothing references it by hand
  any more: the converter recomputes which Room each Device marker is in.
  Rename freely.

### 2.4 Save

**File → Save** as e.g. `MyHouse.sh3d`. Keep it out of `panel/tool/fixtures/`
(that's for test fixtures) — anywhere convenient; it is your drawing of
record, so back it up.

## 3. Convert to house.yaml

From the `panel/` directory:

```sh
python3 tool/sh3d_to_yaml.py ~/path/to/MyHouse.sh3d \
    -o assets/house/house.yaml --name "Our House"
```

`--name` sets the title the Panel header shows (defaults to the name stored
in the file).

On success you get a summary like:

```
wrote assets/house/house.yaml: 2 floor(s), 14 room(s), 27 wall(s), 12 device(s), 1 warning(s)
```

### 3.1 If it errors

Nothing is written until the drawing is clean. Each error names the room or
wall and the floor:

| Error | Fix in Sweet Home 3D |
|---|---|
| `unnamed room on …` | double-click the room, fill in *Name* |
| `rooms "A" and "B" both get id …` | rename one of them to something distinct |
| `… diagonal edge …` / `diagonal wall …` | redraw that edge/wall square (delete, re-draw with magnetism on) |
| `rooms "A" and "B" overlap` | select each room, drag its corner points apart so they only touch |
| `two levels named …` | rename one level tab |

### 3.2 Warnings — read, then decide

Warnings don't block the write; they exist to catch mistakes:

- `boundary … is mostly unwalled — open passage, or a forgotten wall?` —
  fine if it really is an open passage; otherwise go draw the missing wall
  and re-run.
- `… enclosed space belong to no room …` — some floor area isn't covered by
  any room (often a gap between hand-drawn room corners). Double-click the
  area to re-create the room snapped to the walls.

Re-run the converter after any drawing change — it's idempotent and never
touches `bindings.yaml`.

## 4. Look at it

```sh
flutter test                      # loader + geometry + widget tests still pass
flutter run -d chrome             # or: flutter build web and serve build/web
```

The Dollhouse renders whatever the YAML describes — wrong-looking geometry
means a drawing fix, then reconvert.

## 5. Add a Device (or move one)

You do this in the drawing, not in a text file.

**Once, before the first Device:** build and import the marker library.

```sh
python3 tool/sh3d_marker_library.py -o ~/SmartHome.sh3f
```

In Sweet Home 3D: **Furniture → Import furniture library…** → pick that
file. A **Smart Home** category appears in the catalog with one marker per
kind of Device.

**Always open the drawing with `tool/sh3d.sh`**, never the Dock icon:

```sh
tool/sh3d.sh
```

Sweet Home 3D can only show the Device fields when it is started this way,
and it does not remember the setting. Opened normally, the drawing is still
safe — the fields are just invisible, so you cannot type a Key.

### Adding one

1. **Drag the marker** for the right kind out of the *Smart Home* category
   and drop it where the thing actually is. Inside a room — if it belongs
   on a wall (a TV, a thermostat), on the wall is fine.
2. **Double-click it → Other properties…** and set **Placementkey** to a
   name that is yours alone, e.g. `light-office`. Spelling is up to you —
   hyphens, underscores, capitals all work — it only has to be unique in
   the house, and you will type it once more in step 4.
3. **Name the piece** (the *Name* box at the top of the same dialog): this
   is what the Panel shows on the pin and in the popup, e.g. `Office Light`.
4. **Save**, re-run the converter (§3), then add one entry to
   `assets/house/bindings.yaml`:

   ```yaml
     light-office:
       entity: input_boolean.light_office   # omit until the hardware exists
       connectivity: local                  # local | cloud (see CONTEXT.md)
   ```

   `connectivity` is required — `local` means it works with no vendor cloud.
   `entity` is optional: leave it out while the hardware is still in a box
   and the pin renders with unknown state instead.
5. **Check it**: `flutter test`. The loader reads the real files and says
   plainly what is wrong — a marker with no binding, a binding whose marker
   you deleted, an unknown kind.

### Moving, renaming, deleting

- **Moving** a Device: drag the marker, save, re-run the converter. That is
  all — the Room and the position are recomputed. Dragging it into a
  different room is the same gesture.
- **Renaming** what the Panel displays: change the piece's *Name*.
- **Changing which Hub entity it uses**: `bindings.yaml`, nowhere else.
- **Deleting**: delete the marker, re-run the converter, delete its
  `bindings.yaml` entry. The loader will refuse to start if you forget the
  second half, naming the leftover.

### Kinds

`light` `outlet` `thermostat` `camera` `doorbell` `oven` `tv` `washer`
`dryer` `litter-robot` `feeder` `garage-door` `ev-charger` `energy-monitor`

Each has its own marker in the library, so the kind is set for you. They map
1:1 to `DeviceKind` in `lib/domain/house.dart` — a genuinely new kind of
hardware means adding it there, plus an icon in `lib/ui/theme.dart` and a
row in `tool/sh3d_marker_library.py`, before it can be drawn.

### What the converter refuses

All of these name the piece as you see it in Sweet Home 3D, and nothing is
written until the drawing is clean:

- a marker with no Placementkey (did you open the drawing with `sh3d.sh`?)
- two markers with the same Placementkey — copy-paste keeps the Key, so
  retype it on the copy
- a marker with no name
- a marker sitting outside every room
- an unknown kind
