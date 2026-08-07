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

You also need Python 3, which the devcontainer already has (and most host machines too). Check with `python3 --version` if you like; the converter uses nothing you'd have to install.

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
| Change which camera feed it shows | edit its `stream:` in `bindings.yaml`, nothing else |
| Change the still photo its popup falls back to | edit its `snapshot:` in `bindings.yaml`, nothing else |
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
- **`stream`** — cameras and doorbells only: the **name** of a stream in `hub/go2rtc/go2rtc.yaml`, like `stream: front_door`. It is a name, never a web address — pasting an `rtsp://…` link here would tell go2rtc to go and dial it, and the camera password inside that link would end up in the panel's log. So a stream name may only be letters, digits, dots, dashes and underscores, which is exactly what a `go2rtc.yaml` key looks like and leaves no room for the `:`, `/` and `@` a web address needs; anything else stops the panel at boot. The complaint you get **won't repeat back what you typed** — it is written to the log itself, so printing a mis-pasted address there is precisely how the password would escape. It names this file and the device instead, and you look at the line yourself. Leave the line out until the camera is set up; the pin still appears and its popup says the view isn't available, which is the truth. Two devices may name the same stream — two rooms watching one camera is fine. One more thing to check on the go2rtc side, because it fails without saying anything: that camera's entry there needs **two producers**, the camera's own H.264 line plus an `ffmpeg:<name>#video=mjpeg` line. Without the second, the wall panel — which plays JPEG, not H.264 — gets an empty stream and shows "Live view unavailable" with no error anywhere. [Ch. 6 §6.5b](../appliance/commissioning/06-panel-and-bindings.md) has the one-line check.
- **`snapshot`** — cameras and doorbells only, and optional: the Home Assistant **camera entity** holding a still photo of what that camera sees, like `snapshot: camera.front_door_snapshot`. This is the picture the panel shows when there is no live video — while the stream is starting, and when it fails. It is what stops the doorbell popup being a blank rectangle at the moment somebody wants to see who is at the door. It is always labelled on screen as a still, never passed off as live. Two separate things to know. **It is a different entity from `entity:`, and neither can be worked out from the other** — the doorbell's `entity:` is what it *does* (it rang), and its `snapshot:` is what it *sees*; copy both from Home Assistant's own entity list. And **it must be a `camera.` entity** — the panel fetches it through Home Assistant's camera picture service, so a sensor or a web address pasted here would quietly fail on every attempt rather than at boot, which is why the panel refuses anything that isn't one. Leave the line out if the camera has no still; the popup falls back to its plain "connecting" and "unavailable" wording, exactly as before. Two devices may name the same one.
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
flutter run -d web-server --web-port 8080 --profile
```

— and open `localhost:8080` in the host browser. (`--profile` is required
— a debug web-server build renders nothing without the Dart Debug
extension; `README.md` "Talking to the Hub" explains.)

If the geometry looks wrong, fix the *drawing* and convert again. Never edit `house.yaml` — the next conversion would erase it.

---

# Part 7 — When something goes wrong

Every message names the thing you need to fix, using the name you gave it —
with one deliberate exception, for names and values that could be hiding a
camera password. See *Which messages repeat your value back* below.

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
| `bindings.yaml is not valid YAML at line 4, column 5` | the file's *shape* is wrong before anything in it is read — a duplicated line, a tab instead of spaces, a missing quote. Go to that line and column |
| `no entry for Device "…"` | you drew a device but haven't added its `bindings.yaml` entry |
| `bindings.yaml still has …, and house.yaml no longer does` | you deleted a marker; delete its binding too |
| `both bind to entity "…"` | two devices point at the same Hub entity; one of them is wrong |
| `is neither of the two words this field takes` | `connectivity:` must be exactly `local` or `cloud` |
| `has no connectivity:` | that device has no `connectivity:` line at all; add one |
| `is not a block of settings` | there is a bare value under the device's key instead of indented `entity:`/`stream:`/`connectivity:` lines |
| `is not a Home Assistant entity id` | entity ids look like `light.kitchen`, all lowercase with one dot |
| `is not a go2rtc stream name` | you put a web address in `stream:`; put the stream's **name** from `go2rtc.yaml` there instead |
| `only a camera or a doorbell plays video` | you put `stream:` on something that isn't a camera or doorbell; delete the line, or fix the marker's kind in the drawing (it does not tell you which stream name you typed — see below) |
| `is not a camera entity id` | your `snapshot:` isn't a `camera.` entity. Still photos come from Home Assistant's camera entities — `camera.front_door_snapshot`, not the doorbell's own `event.` or `binary_sensor.` entity, and never a web address |
| `only a camera or a doorbell wears a still-image face` | you put `snapshot:` on something that isn't a camera or doorbell; delete the line, or fix the marker's kind in the drawing (it does not repeat the entity you typed — see below) |
| `which YAML read as a … rather than text` | a value like `007` was read as a number; put quotes around it. **This is the one message that repeats your value back** — see below |
| `is a block of its own rather than one line of text` | you indented something underneath `entity:` or `stream:` (a `url:` line, or a `- ` list). These fields take one value on the same line as the name |

**Which messages repeat your value back, and which do not.** It is worth
knowing before you paste a camera URL into the wrong line, because these
messages get written to the panel's log, which is the file an operator copies
into an issue. The whole list is here, because the gaps in earlier versions of
this list were found by someone driving the code, not by reading it.

- **Your `entity:`, `stream:`, `snapshot:` and `connectivity:` values are not
  repeated.** That covers `is not a Home Assistant entity id`, `is not a go2rtc
  stream name`, `is not a camera entity id`, `only a camera or a doorbell wears
  a still-image face`, `is neither of the two words this field takes`, `is a
  block of its own …` and `is not a block of settings`. They name the file, the
  device and the field only. Open `bindings.yaml` at the device they name and
  look.

  `snapshot:` is withheld for the same reason `stream:` is, and deliberately
  even though it is the stricter field of the two: it must already look like a
  `camera.` entity to get past the parser, so there is less that could be
  hiding in it. The value is kept out anyway, because two messages in one place
  with two different disclosure rules is how the careful one gets loosened by
  someone tidying up later.
- **Your device's *key* is repeated only when it is plainly a name** — starts
  with a letter or a digit, then letters, digits, spaces, dots, dashes and
  underscores, 40 characters at most. That is every key you would actually
  type, so in practice these messages read the way they always did.
  A key that is *not* that shape gets called `the 3rd binding` instead, counted
  down the file from the top. The reason: if your paste lands one column to the
  left, with no indent, YAML reads the whole camera URL as the key — and then a
  message promising not to echo your value was printing it in the same
  sentence. This applies to every message in the list, including
  `bindings.yaml still has …`.
- **`which YAML read as a … rather than text` does repeat the value.** It has
  to: `quote it: stream: "007"` *is* the fix and cannot be written without the
  value. It is safe to print because of what YAML has already told us — a
  *scalar* that came back as something other than text is a number, a bool or a
  date, and none of those can be `rtsp://user:pass@host`; a URL is text to YAML
  and never reaches this message. A `url:` nested underneath, or a `- ` list, is
  not a scalar and goes to the non-echoing message above instead — that shape
  used to come through here and print the password back twice per line.
- **`both bind to entity "…"` repeats the entity id**, and only it. The id got
  that far by looking like `light.kitchen`, so there is nowhere in it for a
  password to be; which entity is duplicated *is* the complaint.
- **`only a camera or a doorbell plays video` does not repeat the stream
  name**, and it is the only stream message that withholds it. On a light the
  `stream:` is refused, so this message is the one and only place that name
  could ever be published — whereas a name on a real camera appears in
  `popup.stream_open` every time the popup opens, and has to.
- **`… is not valid YAML at line 4, column 5` gives you a position and nothing
  else.** This one is the reason the list above got rewritten. It comes from
  the YAML reader itself, before any rule in this document has looked at
  anything, and the reader's own message quotes the line it choked on, with a
  caret under it. So the *worse* typo — a duplicated `stream:` line, a tab, an
  undefined `*alias`, a pasted URL containing `": "` — published the password
  the whole time, while the *cleaner* one was carefully refused without it.
  Now you get the file, the line and the column, and you read the line
  yourself. It applies to `house.yaml` too.

One thing is published on purpose, so you know before you type it: a stream
name that looks like a name is written to the log every time its popup opens.
If you paste an **API token** where a stream name goes, it will parse — a token
has the shape of a name and nothing can tell them apart — and it will be
logged. `stream:` takes a name from `go2rtc.yaml`, nothing else.

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
