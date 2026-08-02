# House Plan how-to — drawing, converting, adding Devices

The step-by-step runbook for getting the real house into the Panel
(pipeline decided in [ADR-0004](../docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md)).
Two files make up the House Plan:

| File | Who writes it | Contents |
|---|---|---|
| `assets/house/house.yaml` | the converter — **never edit by hand** | geometry: Floors → Rooms (footprint polygons) + Walls |
| `assets/house/devices.yaml` | **you, by hand** | every Device: id, kind, room, position |

Re-running the converter is always safe: it rewrites `house.yaml` and never
touches `devices.yaml`.

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
- Renaming a room later changes its id — every `room:` reference in
  `devices.yaml` must be updated to the new slug (the loader will name the
  orphans if you forget).

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
wrote assets/house/house.yaml: 2 floor(s), 14 room(s), 27 wall(s), 1 warning(s)
origin shift: yaml (x, y) = Sweet Home 3D (x, y) in cm / 100 minus (0, 0) m — ...
```

**Keep the `origin shift` line** — you need it in step 5 to place devices.

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
touches `devices.yaml`.

## 4. Look at it

```sh
flutter test                      # loader + geometry + widget tests still pass
flutter run -d chrome             # or: flutter build web and serve build/web
```

The Dollhouse renders whatever the YAML describes — wrong-looking geometry
means a drawing fix, then reconvert.

## 5. Add a Device (or move one)

Open `assets/house/devices.yaml`. Each entry:

```yaml
  - id: light-office          # unique, kebab-case, never reuse after deleting
    name: "Office Light"      # what the Popup and labels show
    kind: light               # see the list below
    connectivity: local       # local | cloud  (see CONTEXT.md)
    room: office              # a room id from house.yaml
    position: [8.5, 8.5]      # meters from the house NW corner, x east, y south
```

Step by step:

1. **Pick the room id**: open `assets/house/house.yaml`, find the room, copy
   its `id:`. (Never edit that file — just read it.)
2. **Pick the position** — two ways:
   - *From the footprint*: the room's `footprint:` lists its corners in
     meters; pick a point inside (e.g. mid-room for a ceiling light, near a
     wall for a TV).
   - *From Sweet Home 3D*: hover the spot in the plan and read the
     coordinates in the tool, convert cm → m (divide by 100), then subtract
     the `origin shift` the converter printed.
3. **Pick the kind** — one of:
   `light` `outlet` `thermostat` `camera` `doorbell` `oven` `tv` `washer`
   `dryer` `litter-robot` `feeder` `garage-door` `ev-charger`
   `energy-monitor`
   (they map 1:1 to `DeviceKind` in `lib/domain/house.dart` — a new kind of
   hardware means adding it there + an icon in `lib/ui/theme.dart` first).
4. **Set `connectivity`**: `local` = works with no vendor cloud; `cloud` =
   grandfathered vendor-cloud device.
5. **Check it**: `flutter test` — the loader runs over the real asset files
   and fails loudly on an unknown room id, duplicate device id, unknown
   kind, or a position outside the declared room. Then run the app; with
   the `FakeHub` the device gets a plausible fake state automatically
   (seeded by kind), so the pin is live immediately.

Deleting a device is just deleting its block. Moving one between rooms =
change `room:` *and* `position:` (position is house-global, not
room-relative — a stale position is rejected by the loader, so the Panel
tells you rather than drawing the pin in the wrong room).

When the real Home Assistant `HubClient` lands, each entry will also carry
its HA entity id — that mapping belongs in this file too, which is why
devices stay out of the drawing.
