# Preparing the House Plan

**This is the manual for drawing your house and putting your smart-home devices on it.** When you finish, the wall panel shows your actual floor plan with your actual devices in the right rooms, and tapping them works.

You do not need to know how to program. You need to be able to draw with a mouse and copy a command into a terminal. There are exactly two commands, and this document shows you both.

## The idea in one picture

```
   Sweet Home 3D                    one command                the wall panel
   ┌──────────────┐                                            ┌──────────────┐
   │  you draw:   │        python3 tool/sh3d_to_yaml.py        │              │
   │  • rooms     │  ───────────────────────────────────────▶  │   Dollhouse  │
   │  • walls     │                                            │              │
   │  • devices   │                                            └──────────────┘
   └──────────────┘                        +
                                    bindings.yaml
                              (which Hub switch is which —
                               two lines you type per device)
```

**Everything about where things are gets drawn, never typed.** You drop a little marker where the kitchen light is; the converter works out which room that is and exactly where. Nobody measures anything, and nobody types coordinates.

The only thing you type by hand is which Home Assistant switch each device corresponds to — because that is the one fact a drawing cannot know.

Two files come out of this, and it matters which is which:

| File | Who writes it | What's in it |
|---|---|---|
| `assets/house/house.yaml` | **the converter — never edit this by hand** | everything you drew: floors, rooms, walls, and where each device is |
| `assets/house/bindings.yaml` | **you** | two lines per device: which Hub entity it is, and local or cloud |

Re-running the converter is always safe. It rewrites the first file completely and never touches the second, so you can redraw as often as you like without losing anything you typed.

*(The reasoning behind all this is in [ADR-0004](../docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md) and [ADR-0005](../docs/adr/0005-devices-authored-in-the-drawing.md), if you ever want it.)*

---

# Part 1 — Setting up (once)

## 1.1 Install Sweet Home 3D

Free, and it does everything we need.

```sh
brew install --cask sweet-home3d
```

Or download it from <https://www.sweethome3d.com/download.jsp>. It's Java-based and the installer bundles everything.

You also need Python 3, which is already on the Mac. Check with `python3 --version` if you like; the converter uses nothing you'd have to install.

## 1.2 Build and import the device markers

The markers are the little objects you'll drag into the drawing to say "there is a light here". They come as a *furniture library* you import once.

Build it — from the `panel/` folder:

```sh
python3 tool/sh3d_marker_library.py -o ~/SmartHome.sh3f
```

Then in Sweet Home 3D: **Furniture → Import furniture library…**, and pick `~/SmartHome.sh3f`.

A new **Smart Home** category appears in the furniture list on the left, with one marker per kind of device — Light, Outlet, Thermostat, Camera, and so on.

You only do this once. If you ever add a new *kind* of device to the project, rebuild the library and import it again.

## 1.3 Learn the one habit that matters

> **Always open Sweet Home 3D with `tool/sh3d.sh`. Never with the Dock icon.**

```sh
tool/sh3d.sh
```

Here's why, in plain terms. Sweet Home 3D can show extra fields on a piece of furniture — we use one to hold each device's name-tag. But it only shows those fields when it's started a particular way, and it forgets the setting every time it closes. There is no way to make it remember.

**Nothing breaks if you forget.** Your drawing is safe and the existing tags stay put. The field just becomes invisible, so you can't type a tag for a new device and will wonder where it went. If a device's *Other properties…* button is missing, this is why: quit and reopen with `tool/sh3d.sh`.

The file argument doesn't work — the app opens empty. Use **File → Open** once it's up.

---

# Part 2 — Drawing the house

Work one floor at a time: walls first, then rooms.

If you've never used Sweet Home 3D, open one of the gallery examples first and click around for ten minutes. Don't copy its drawing style, though — those files break most of the rules below on purpose.

## 2.1 Set up the floors

- The plan starts with one level. Add more with **Plan → Add level**.
- **Name every level.** Double-click its tab and type `Ground Floor`, `Upstairs`, and so on. That name becomes the floor's label on the wall panel.
- A basement is just a level with a **negative elevation** — set it in the level dialog and everything else follows automatically.
- All levels share one coordinate system, so the upstairs sits over the right part of the ground floor by construction. Draw it in place. **Plan → Display walls of the level below** helps you trace.

## 2.2 Draw the walls

**Plan → Create walls**, then click corner to corner. Double-click to finish a run. Leave magnetism ON — it snaps to right angles and to existing wall ends, which saves you from most mistakes.

Three rules, each with a reason:

**Right angles only.** Diagonal walls are rejected. Where your house has a 45° corner, draw the two square walls that box it in; the corner belongs to whichever room it flows into.

**Draw a wall only where reality has one.** The panel treats an undrawn boundary as an open passage — no glass drawn. Open-plan kitchen and family room? Don't draw a wall between them. Wide cased opening? Draw the wall in two pieces and leave the gap.

**Don't split walls for doorways.** Doors and windows are ignored by the converter. Place them if you like how they look in Sweet Home 3D; the panel draws the wall unbroken either way.

Wall thickness doesn't matter — only the centre line is kept — so the default is fine.

## 2.3 Create and name the rooms

**Plan → Create rooms**, then **double-click inside any area enclosed by walls**. Sweet Home 3D creates the room and snaps it to the walls for you. (You can click corners by hand instead; magnetism keeps them square.)

**Every bit of floor belongs to exactly one room.** Halls, stairwells, the garage — all rooms. Absorb small closets into the room they open from. Overlapping rooms are an error; a gap that belongs to no room is a warning.

**Name every room, and make every name unique in the whole house.** Double-click the room → *Name*. Use `Guest Bathroom` and `Kids Bathroom`, never `Bathroom` twice. The name becomes the room's label on the panel.

You can rename rooms freely later — nothing else points at the old name.

## 2.4 Save

**File → Save** somewhere convenient, e.g. `~/Documents/OurHouse.sh3d`. Don't put it in `panel/tool/fixtures/`, which is for test files.

**This drawing is the original.** Everything else is regenerated from it, so back it up like you'd back up a photo album.

---

# Part 3 — Placing devices

This is the part that used to involve arithmetic. It doesn't any more.

## 3.1 Add a device

1. **Drag a marker in.** Open the **Smart Home** category in the furniture list, find the right kind, and drop it where the thing actually is. Inside the room it belongs to. If it lives on a wall — a TV, a thermostat — putting it on the wall is fine and expected.

2. **Give it a name.** Double-click the marker; the *Name* box is at the top. This is what appears on the panel, so write it the way you'd say it: `Kitchen Ceiling Light`, `Nursery Camera`.

3. **Give it a tag.** In the same dialog, click **Other properties…** at the bottom. A small table appears with **Placementkey** and **Kind**. Set *Placementkey* to something short and unique — `kitchen-ceiling`, `nursery_cam`, `light1`, whatever you like. Leave *Kind* alone; it's already correct because you picked the right marker.

   The tag is how the drawing and your Hub settings find each other. It only has to be **unique in the house** — spelling, capitals and dashes-vs-underscores are entirely up to you.

4. **Save.**

> **If there's no "Other properties…" button,** you opened Sweet Home 3D without `tool/sh3d.sh`. Quit and reopen with it. See §1.3.

## 3.2 Copy-paste needs care

Copying a marker copies its tag too, so two devices end up claiming the same one. The converter catches it and names both, but you'll save yourself a round trip by retyping the tag right after pasting.

## 3.3 Moving, renaming, deleting

| You want to | Do this |
|---|---|
| Move a device (including to another room) | drag the marker, save, re-run the converter |
| Change what the panel calls it | change the marker's *Name* |
| Change which Hub switch it uses | edit `bindings.yaml`, nothing else |
| Delete it | delete the marker, re-run the converter, delete its `bindings.yaml` entry |

If you delete a marker but forget its binding, the panel refuses to start and tells you exactly which leftover to remove. That's deliberate — a silent leftover would be a device that quietly never works.

## 3.4 The kinds of device available

`light` · `outlet` · `thermostat` · `camera` · `doorbell` · `oven` · `tv` · `washer` · `dryer` · `litter-robot` · `feeder` · `garage-door` · `ev-charger` · `energy-monitor`

Each has its own marker, so you never type the kind. Anything genuinely new needs a developer to add it in three places first — the marker library, the panel's vocabulary, and an icon.

---

# Part 4 — Converting

One command, from the `panel/` folder:

```sh
python3 tool/sh3d_to_yaml.py ~/Documents/OurHouse.sh3d \
    -o assets/house/house.yaml --name "Our House"
```

`--name` is the title shown at the top of the panel.

Success looks like this:

```
wrote assets/house/house.yaml: 2 floor(s), 14 room(s), 27 wall(s), 12 device(s), 0 warning(s)
```

**Check those numbers.** If you drew 14 devices and it says 12, two markers are missing their tags and the converter will have said so.

**Nothing is written unless the drawing is clean.** If there are errors you get a list and the old file is untouched, so a broken drawing can never half-break the panel.

---

# Part 5 — Telling it about your Hub

Open `assets/house/bindings.yaml`. Add one entry per device, keyed by the tag you typed in the drawing:

```yaml
bindings:
  kitchen-ceiling:
    entity: light.kitchen_ceiling
    connectivity: local
```

- **`entity`** — what Home Assistant calls this device. **Leave the line out entirely** if the hardware doesn't exist yet; the device still appears on the panel, showing unknown state, which is exactly right for something still in a box.
- **`connectivity`** — `local` if it works without the manufacturer's cloud, `cloud` if it doesn't. This is required and has no default, because guessing would mislabel every planned device.

Blank lines and `#` comments are fine — group entries by room if it helps you find them.

---

# Part 6 — Checking your work

```sh
flutter test
```

This reads your real files and checks everything fits together: every device has a binding, every binding has a device, every device sits inside its room. It tells you plainly what's wrong.

Then look at it:

```sh
flutter run -d chrome
```

If the geometry looks wrong, fix the *drawing* and convert again. Never edit `house.yaml` — the next conversion would erase it.

---

# Part 7 — When something goes wrong

Every message names the thing you need to fix, using the name you gave it.

### The drawing is refused

| Message | What to do |
|---|---|
| `unnamed room on …` | double-click that room, fill in *Name* |
| `rooms "A" and "B" both get id …` | two rooms have the same name; rename one |
| `… diagonal edge …` / `diagonal wall …` | redraw it square — delete it and draw again with magnetism on |
| `rooms "A" and "B" overlap` | drag their corners apart so they only touch |
| `two levels slugify to …` | two floors share a name; rename one tab |
| `is a Device marker with no key` | that marker has no *Placementkey* — see §3.1 (and check you opened with `tool/sh3d.sh`) |
| `two Device markers share the key …` | a copy-paste leftover; retype the tag on one of them |
| `has no name` | give the marker a *Name* |
| `has unknown kind …` | it isn't a Smart Home marker; delete it and drag in a real one |
| `is not in any room` | the marker is outside every room — drag it inside one |

### The panel refuses to start

| Message | What to do |
|---|---|
| `no entry for Device "…"` | you drew a device but haven't added its `bindings.yaml` entry |
| `bindings.yaml binds …, which no longer exist` | you deleted a marker; delete its binding too |
| `both bind to entity "…"` | two devices point at the same Hub entity; one of them is wrong |
| `has connectivity "…"` | must be exactly `local` or `cloud` |
| `is not a Home Assistant entity id` | entity ids look like `light.kitchen`, all lowercase with one dot |

### Warnings — read them, then decide

Warnings don't stop anything. They exist to catch the mistakes that look fine:

- **`boundary … is mostly unwalled`** — fine if that really is an open passage. Otherwise you forgot a wall.
- **`enclosed space belongs to no room`** — a patch of floor isn't covered by any room, usually a small gap between hand-drawn corners. Double-click the area to re-create the room snapped to the walls.

---

# Part 8 — Advice worth having

Things learned the hard way while building this.

**Draw the house before you place a single device.** Devices are attached to rooms by *where they are*, so moving a wall after the fact can silently move a device into the next room. Get the shape right, then furnish it.

**Name devices the way you'd say them out loud.** The name is what appears on the wall, in front of guests. `Kitchen Ceiling Light`, not `light-kitchen-1`.

**Keep the tags boring.** They're plumbing, not labels. Pick one style — all lowercase with dashes is a good default — and stick to it. Nothing forces this; consistency is purely for your own sanity when reading `bindings.yaml` later.

**Squaring off a 45° corner is not a compromise you'll notice.** The panel is a 2.5D dollhouse seen from above at a distance. Fighting for an exact angle costs a lot and shows nothing.

**Bias toward too few walls, not too many.** A missing wall shows as an open passage, which usually looks right anyway. A wall that isn't really there shows as a sheet of glass in the middle of your open-plan living room, and that reads as broken.

**Re-run the converter after every drawing change, however small.** It takes under a second, and it's the only way the panel learns anything. Getting into the habit avoids the "why isn't it updating" ten minutes.

**Back up the `.sh3d` file.** It is the original. Everything else in this pipeline can be rebuilt from it in one command, and nothing can rebuild it.

**Add devices in small batches.** Draw three, convert, add three bindings, run `flutter test`, look at it. Doing thirty at once means reading thirty error messages at once.

**Leave `entity:` out for hardware you haven't bought yet.** Draw the device where it will go, give it a tag, set `connectivity`, and skip the entity line. It appears on the panel greyed out with unknown state — which is a genuinely useful view of what's planned versus what's live.

**If a device shows unknown state forever,** its `entity:` almost certainly doesn't match what the Hub actually calls it. Check the exact spelling in Home Assistant's developer tools; entity ids get renamed more often than you'd expect.

**Don't hand-edit `house.yaml`, ever.** Not even to fix one number. The next conversion overwrites it, and the loader will refuse to start rather than paint something it can't verify.
