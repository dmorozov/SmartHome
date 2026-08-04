# 6 — The Panel, the House Plan, and binding real Devices

The Hub now has real entities. This chapter points the Panel at it, and makes
each pin on the wall correspond to a real thing.

Two facts decide almost every task in this chapter:

1. **Where a Device is** is drawn, never typed (ADR-0005). A new Key is a
   Sweet Home 3D session, not a text edit.
2. **What a Device is wired to** is typed, never drawn. That is
   `bindings.yaml`, and it is the only file in the House Plan you open in an
   editor.

Get those the wrong way round and you either hand-edit a generated file that
the next conversion erases, or you spend an hour looking for a drawing tool
you did not need.

---

## 6.1 Which task is this?

Look the task up before starting it.

| You want to | It is | Where |
|---|---|---|
| Bind a Key to a different Hub entity | **bindings edit** | `panel/assets/house/bindings.yaml` |
| Change `local` ↔ `cloud` on a Device | **bindings edit** | same file |
| Un-bind hardware that went away | **bindings edit** — delete the `entity:` line, keep the entry | same file |
| Add a Device the house did not have | **drawing** | Sweet Home 3D, then convert |
| Move a Device to another Room | **drawing** | drag the marker, then convert |
| Rename what the Panel calls a Device | **drawing** | the marker's *Name* |
| Change a Device's kind (outlet → light …) | **drawing** | delete the marker, drop the right one, re-type the Key |
| Delete a Device | **drawing + bindings** | delete the marker, convert, delete its binding |
| Fix room shape, walls, floors | **drawing** | walls/rooms, then convert |

`panel/assets/house/house.yaml` is generated. Its first line says
`DO NOT EDIT BY HAND`, and it means it: the loader re-validates the geometry
independently and refuses to boot on anything the converter would have
rejected (`panel/lib/data/house_loader.dart`, `_checkFootprint`, `_checkWall`,
`_checkPin`). Editing it buys you nothing and loses your edit on the next
conversion.

### The two files

| File | Owner | Contents | Lifecycle |
|---|---|---|---|
| `panel/assets/house/house.yaml` | `tool/sh3d_to_yaml.py` | floors, rooms, walls, and the Placements (Key, kind, name, room, position) | rewritten whole, every conversion |
| `panel/assets/house/bindings.yaml` | you | per Key: `entity:` and `connectivity:` | the converter never reads or writes it |

Re-running the converter is always safe. That property is the entire point of
the split (ADR-0005), and it is why a re-key after the real drawing lands is a
bindings-file no-op: the Keys are the join.

---

## 6.2 A new Key is drawing work

The Key is typed once, in Sweet Home 3D, into a marker's `placementKey`
property. Nothing else creates one. There is no supported path that starts in
`bindings.yaml` — a binding whose Key has no Placement is a fatal boot error,
by design (§6.4).

The full sequence, in order:

```sh
# 1. On the Mac, with the drawing. The launcher is mandatory — see below.
panel/tool/sh3d.sh

# 2. Drop the marker for the right kind, set Name and Placementkey, save.
#    (Furniture dialog details: ../../panel/HOUSE-PLAN.md §3.1)

# 3. Convert. Runs anywhere the .sh3d file is; stdlib-only Python.
cd panel
python3 tool/sh3d_to_yaml.py ~/Documents/OurHouse.sh3d \
    -o assets/house/house.yaml --name "Our House"

# 4. Add the bindings.yaml entry for the new Key (§6.3).

# 5. Regenerate the dev-Hub stand-ins if the Key is not yet real hardware.
dart run tool/gen_dev_entities.dart

# 6. Check.
flutter test
```

`tool/sh3d.sh` is not a convenience. Sweet Home 3D only renders a
user-defined property in the *Modify furniture* dialog when the **Home**
declares it, and a Home learns its declarations from one system property read
at startup — never saved into the `.sh3d`. Launch from the Dock and the
`Placementkey` field is invisible and uneditable; existing values survive
untouched, so the failure mode is confusion, not data loss. The script hard-
codes the macOS bundle at `/Applications/Sweet Home 3D.app`; override with
`SH3D_APP=…` if it lives elsewhere. There is no Linux path in the repo today —
drawing is Mac work.

The property is spelled `placementKey` in the declaration and displays as
**Placementkey** in the dialog. Same field.

Keys are free-form: any spelling, any separator, any case. Only emptiness and
collisions are rejected (ADR-0005). Keep them boring and consistent anyway —
you will be reading them in `bindings.yaml`, not on the wall.

**Consequence for the commissioning you are doing now.** The shipped house is
still the placeholder (`tool/fixtures/placeholder-house.Home.xml`, name
"Demo House", 33 Placements). Real entities get bound to placeholder Keys —
that is decision D5 in
[`../../docs/plans/device-integrations/README.md`](../../docs/plans/device-integrations/README.md).
When the real drawing lands, type the **same Keys** into its markers and
`bindings.yaml` carries over untouched. Any Key that ended up describing a
device in a different real room is a note, not a problem: the drawing fixes
geometry, never identity.

---

## 6.3 `bindings.yaml`

One entry per Placement, keyed by the Key:

```yaml
bindings:
  light-hall:
    entity: light.hallway_ceiling
    connectivity: local
  garage-door:
    connectivity: cloud        # no entity: — hardware not bought yet
```

| Field | Required | Meaning |
|---|---|---|
| `entity` | no | the Hub entity id this Device's state comes from. Omit the line entirely while the hardware does not exist — the pin still renders, with unknown state |
| `connectivity` | **yes** | `local` or `cloud`. No default, deliberately: a planned Ring camera is a Cloud Device before it is ever bound, so guessing `local` would mislabel it. The Popup shows this, so a wrong value is user-visible |

Comments and blank lines are fine. Group by room if it helps.

### Every rule that is fatal at boot

All of these throw `FormatException` out of `bootPanel`, which logs
`[panel] E house.invalid` and rethrows. On a desktop that is a stack trace; on
the appliance it is a restart loop behind a black screen (`Restart=always`,
`StartLimitIntervalSec=0`), and the journal line is the only evidence.

| Rule | Enforced in | The message you get |
|---|---|---|
| `entity` must match `^[a-z_]+\.[a-z0-9_]+$` | `bindings_parser.dart` | `"<key>" has entity "<id>", which is not a Home Assistant entity id (domain.object_id)` |
| One entity backs at most one Device | `bindings_parser.dart` | `"<a>" and "<b>" both bind to entity "<id>" — one entity, one Device.` |
| `connectivity` is present and is `local`\|`cloud` | `bindings_parser.dart` | `"<key>" has connectivity "<c>" (local \| cloud)` |
| Every Placement has a binding | `house_loader.dart` | `no entry for Device "<key>" — add one; connectivity alone is enough until the hardware exists` |
| Every binding has a Placement | `house_loader.dart` | `bindings.yaml binds <keys>, which no longer exist in house.yaml` |
| No duplicate Key in `house.yaml` | `house_loader.dart` | `duplicate Device key "<key>" — … regenerate rather than editing house.yaml` |

Note the domain half of the entity regex allows no digits; the object id does.
`switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0` passes.

The Key sets must match **both ways**. `bindings.yaml` is parsed in full
first, so a malformed entity id or a missing `connectivity` surfaces before
any Key-set mismatch — fix the parse errors, then re-run and fix the
set errors.

A Device with no `entity:` is legal and silent. It is invisible to
`hub.missing_entities` (§6.6) because there is nothing to miss.

### Entities you must not bind

Measured on this fleet; binding these produces a pin that is wrong rather than
broken, which is worse.

| Do not bind | Why |
|---|---|
| `switch.tp_link_smart_plug_722c` (the EP40 **parent**) | it drives **both** outlets at once. Bind the two children, `…_kasa_smart_plug_722c_0` / `_1` |
| any `switch.*_led` | that is the plug's status LED, not the load |
| any `*_cloud_connection` sensor | a connectivity flag, not a Device state |
| `sensor.<wall-connector>_power` | **UNVERIFIED — no such entity is known to exist.** The Tesla Wall Connector at `.52` refuses every TCP port; nobody has seen its vitals key set. Do not write this binding on faith |

---

## 6.4 Togglability, and the refrigerator

Whether a tap flips a Device is answered from the Device's **kind**, never
from live state (ADR-0006). The kind names a state family; the family decides.

| Family | Kinds | Tap flips it? |
|---|---|---|
| `toggle` | `light`, `outlet`, `tv` | **yes** |
| `garageDoor` | `garage-door` | **yes** |
| `thermostat` | `thermostat` | no |
| `power` | `energy-monitor`, `ev-charger` | no |
| `status` | `washer`, `dryer`, `oven`, `litter-robot`, `feeder`, `camera`, `doorbell` | no |

Enforced at the `HubClient` seam, in both adapters, and a refusal is
observable as one `hub.toggle_refused` line rather than a silent no-op.

**The foot-gun.** An `outlet` Key is togglable with no confirmation step —
one tap, load off. The Panel calls `homeassistant.toggle`, which spans
domains; the Hub does as it is told. Two of the three live Kasa plugs are
`switch.old_fridge` and `switch.aquarium`. Binding either to `outlet-outdoor-a`,
`outlet-outdoor-b` or `outlet-master` puts "kill the fridge" one accidental tap
from a child's hand.

There are exactly three `outlet` Keys in the placeholder house and four live
switchable sockets, so at least one socket has nowhere safe to go anyway.

Your options, with their real costs:

| Option | Cost |
|---|---|
| Bind them to an `outlet` Key | one tap kills the load, with no confirm step. **This is the owner's decision, taken 2026-08-04** — the risk below was put to them explicitly and reaffirmed. Do not re-litigate it; see [7 §7.1](07-device-lifecycle.md) |
| Leave the appliance plugs unbound | the pin shows unknown state. Honest, and safe — but not what was chosen |
| Bind them to a `status`-family Key (`washer`, `oven`, …) | not togglable, and the Popup will render the literal string `on` / `off` as its status text — `_toDeviceState` passes the raw state straight through for that family. Ugly but safe |

**What the decision still costs**: the kitchen has no `outlet` Key, so binding
the fridge and the aquarium needs **new Keys**, which is Sweet Home 3D drawing
work under ADR-0005 — not a `bindings.yaml` edit. That is why they are not
bound yet. The analysis above is kept because it is the reason the call was the
owner's to make, not because the question is still open.

There is no read-only plug kind today. Adding one is a code change in three
places (marker library, `device_vocabulary.dart`, an icon) plus a redraw — a
development task, not a commissioning one.

---

## 6.5 Running the Panel against the real Hub

`HUB`, `HA_URL`, `HA_TOKEN` and `LOG` all resolve **process environment
first**, then the build's `--dart-define`, then the built-in default
(`panel/lib/config/hub_config.dart`; `LOG` via `Log.applyLevel`). An
environment variable that is present but empty counts as absent.

The order is the point: on the appliance the Hub's address is an operational
setting, so a Hub that moves — or a DHCP lease that drifts — costs a restart,
never a Flutter rebuild.

**Web has no process environment.** `-d chrome` is a web build, so an
`HA_URL=…` prefix there is silently discarded and you get FakeHub on
`localhost:8123`. On web, `--dart-define` is the only route. The boot log says
`env=unavailable` when this is happening.

Linux desktop — this laptop, and the kiosk target:

```sh
cd panel
HUB=ha HA_URL=http://127.0.0.1:8123 HA_TOKEN="$(cat ../hub/token)" \
  flutter run -d linux
```

Chrome:

```sh
cd panel
flutter run -d chrome \
  --dart-define=HUB=ha \
  --dart-define=HA_URL=http://192.168.68.81:8123 \
  --dart-define=HA_TOKEN="$(cat ../hub/token)"
```

`127.0.0.1` works from the Hub host itself because Home Assistant is
host-networked. From the Mac, use `192.168.68.81:8123`.

The token is the Hub's long-lived access token, kept at `hub/token`
(gitignored, 0600). `$(cat …)` keeps it out of shell history. The Panel logs
`token=set`, never the value.

If an ambient variable beat a `--dart-define` you typed, the Panel says so
rather than leaving you to discover it:

```
[panel] W hub.config_override settings=HA_URL winner=environment
```

---

## 6.6 The diagnostics that matter

Same lines everywhere: `flutter run`, the browser console (filter on
`[panel]`), and the appliance journal. A healthy start:

```
[panel] I panel.start hub=ha mode=release platform=linux log=info log_from=environment
[panel] I hub.config HUB=environment HA_URL=environment HA_TOKEN=environment env=available
[panel] I house.loaded name="Demo House" floors=3 rooms=15 devices=33 bound=33
[panel] I hub.configured url=http://127.0.0.1:8123 token=set
[panel] I hub.connected url=ws://127.0.0.1:8123/api/websocket devices=33
[panel] I hub.snapshot entities=<n> bound=<m> missing=0
```

| Line | Read it for |
|---|---|
| `hub.config` | which origin won, per setting. `env=unavailable` means you are on web and any environment you exported was discarded |
| `house.loaded` | `devices=` is Placements, `bound=` is how many have an `entity:`. The gap is your unbound Devices |
| `hub.connected` | the socket authenticated. `devices=` here is the count of **bound** entities the client is watching |
| `hub.snapshot` | `missing=` is the headline number. Zero means every `entity:` you wrote exists on the Hub |
| `hub.missing_entities` | the ids the Hub has never heard of. Capped at 8 ids with `more=<n>`; `hub.snapshot` carries the true count |
| `hub.state_unusable` | the entity exists but reports `unavailable`/`unknown`, or a reading would not parse. One line per entry into that state, not per message |
| `hub.toggle_refused` | a tap hit a non-togglable kind (§6.4) |
| `hub.auth_invalid` | the token is wrong. Terminal — the Panel does not retry past this (ADR-0007) |

**What `missing_entities` does not catch.** It compares the entity ids in
`bindings.yaml` against the Hub's `get_states` snapshot. That is the whole of
its knowledge. It cannot see:

- a Device with **no `entity:` line** — nothing to look up, so it is excluded
  by construction and reports nothing, forever;
- a **real device with no Key at all** — the fourth switchable socket, the
  Rachio, the Roku. The Panel has never heard of it, so it is not missing,
  it is absent. `missing=0` says nothing about coverage;
- an entity id that exists but is the **wrong one** — the LED instead of the
  load, the parent instead of the child. It resolves, so it is not missing.
  This is why §6.3's do-not-bind list matters.

`missing=0` means "everything I was told to look for is there". Coverage is a
question you answer by counting the fleet yourself.

---

## 6.7 The appliance delivery path

On the appliance the settings arrive from systemd, not from a shell.
Non-secrets ride `Environment=` lines in the templated unit; the token rides a
file.

| Setting | Delivery | Why |
|---|---|---|
| `HUB` | `Environment=HUB={{ panel_hub_kind }}` | not a secret |
| `HA_URL` | `Environment=HA_URL={{ panel_ha_url }}` | not a secret |
| `LOG` | `Environment=LOG={{ panel_log_level }}` | not a secret; raising the level on a Panel already on a wall must not mean rebuilding it |
| `HA_TOKEN` | `EnvironmentFile=-/etc/smarthome/panel.env`, 0600, owned by the kiosk user | `systemctl show -p Environment` hands every `Environment=` value to any local user without authentication, and the unit file is 0644. `EnvironmentFile=` exposes only the path |

Source: `appliance/ansible/roles/kiosk/templates/cage@.service.j2` and
[`../ansible/README.md`](../ansible/README.md).

The leading `-` on `EnvironmentFile=` is deliberate. Without it systemd fails
the service when the file is missing — which on a default `HUB=fake` box would
turn "no Hub yet" into a restart-looping black screen.

### The empty-by-default rule

`panel_hub_kind`, `panel_ha_url` and `panel_log_level` all default to `""` in
`appliance/ansible/group_vars/all.yml`, and **must stay that way**. Resolution
is environment-first, so any value set there beats a `--dart-define` compiled
into the bundle. Writing the apparently harmless defaults (`fake`,
`http://localhost:8123`) would silently force a Panel built with
`--dart-define=HUB=ha` back onto the fake Hub. Empty emits no `Environment=`
line at all, which is what makes "a converge changes nothing until someone
asks it to" actually true.

### Delivering the token

The token lives in `hub/token` on whichever machine runs the playbook, and
reaches the converge through the controller's environment. Never as
`-e panel_ha_token=…` — extra-vars land in `ps` output.

```bash
cd appliance/ansible
PANEL_HA_TOKEN="$(cat ../../hub/token)" \
  ansible-playbook site.yml -l laptop -e panel_hub_kind=ha
```

The role asserts `panel_hub_kind=ha` has a token somewhere — either
`PANEL_HA_TOKEN` on the controller or a non-empty `/etc/smarthome/panel.env`
already on the host — and fails the converge rather than shipping a
crash-looping screen. The token task is `no_log: true`; the env file is
created empty with `force: false`, so a converge without the variable never
clobbers a token already on the box.

Writing the token notifies the `Restart cage` handler. systemd (PID 1) reads
`EnvironmentFile=` at every **start**, so a rotated token needs a restart, not
a `daemon-reload`.

### Still open

`kiosk_app` in `group_vars/all.yml` still points at the spike bundle
(`/home/cage/spike_app/bundle/spike_app`), which ignores all of these
variables. They are inert until it points at the Panel. `flutter build linux`
produces `panel/build/linux/x64/release/bundle/panel`; **where that bundle is
staged on the appliance is not decided in the repo — UNVERIFIED.** The two
changes were decoupled on purpose.

Reading the journal: the unit is `cage@tty1.service` (`kiosk_tty: tty1`), so

```bash
journalctl -u cage@tty1.service -f | grep '\[panel\]'
```

`panel/README.md` says `journalctl -u panel`; there is no such unit. The
README is stale on that one line.

The host has **no passwordless sudo** — the operator runs any privileged step
themselves.

---

## 6.8 Tests that must be updated when bindings change

Two of them fail on correct work, and neither is mentioned in the integration
phase plans. Budget for both.

### `panel/test/bindings_drift_test.dart` — the `_integrated` set

The test asserts every `entity:` in `bindings.yaml` names something the **dev
Hub** stand-ins actually serve. Its ledger is one line:

```dart
const _integrated = <String>{};
```

Every Key you repoint at real hardware must be added to that set, or the suite
goes red — real entity ids are not in `hub/dev/ha-config/packages/panel_dev.yaml`
and never will be. Adding a Key to `_integrated` is the deliberate act of
saying "this one is real now".

The test exists because `gen_dev_entities.dart` derives stand-in ids from each
Device's *name*: renaming "Reading Lamp" in the drawing regenerates
`input_boolean.reading_light` while `bindings.yaml` still points at
`input_boolean.reading_lamp`. Nothing throws, the pin is blank forever, and
the only evidence is one log line on a wall nobody is watching.

Its second test asserts the Placement/binding sets match both ways, in
`flutter test` rather than on the wall.

### `panel/test/ha_hub_live_test.dart` — seeds vs. a real house

This one talks to a real Home Assistant **and toggles a real light**, so it is
opt-in:

```sh
cd panel
PANEL_LIVE_HUB=1 HA_URL=http://192.168.68.81:8123 HA_TOKEN="$(cat ../hub/token)" \
  flutter test test/ha_hub_live_test.dart
```

It loads the real `bindings.yaml` through `test/test_house.dart` and asserts
Device readings against the **Device vocabulary's seed values** — the dev
Hub's generated `initial:` values. Among them:

- `thermostat.currentC ≈ 21.4` — breaks the moment `thermostat` binds to a
  real Ecobee reporting the actual room;
- `energy-monitor` watts `= 812`, `washer` status `= "Idle"`,
  `light-hall` starts off, and the toggle round-trip flips it.

Every one of those assertions is a statement about the dev Hub, not about a
real house. The test is not wrong — it is aimed at a different Hub. Decide per
Key as you bind it: point the run at the dev Hub, or rework the assertion to
something true of real hardware (a `climate.*` entity reporting *some*
plausible temperature, not 21.4). Do not leave it asserting a seed nothing
produces.

`PANEL_LIVE_HUB` is a dedicated name so an `HA_TOKEN` that merely happens to
be exported in someone's shell cannot reach out to a live house and flip a
switch.

### The rest

Goldens will legitimately change once pins carry real state shapes.
Regenerate deliberately and look at the diff images — matching is near-exact
on purpose, and a rubber-stamped failure hides a whole moved pin.

```sh
cd panel
flutter test                                 # full suite
flutter test --update-goldens test/golden    # then EYEBALL the diffs
python3 tool/test_sh3d_to_yaml.py            # the converter's own suite
```

---

## 6.9 Where this surface actually stands

Measured, so nothing here is rediscovered as a surprise.

| Fact | Consequence |
|---|---|
| `house.yaml` is generated from the placeholder, name "Demo House", 33 Placements | Keys are placeholder Keys; D5 says bind against them anyway |
| All 33 bindings still point at `input_boolean.*` / `sensor.*` dev stand-ins | against the real Hub every one is `missing` until repointed |
| Exactly three `outlet` Keys (`outlet-outdoor-a`, `outlet-outdoor-b`, `outlet-master`), four live switchable sockets | one socket has no Key, and two of the four are a fridge and an aquarium (§6.4) |
| `_integrated` is `{}` | first real binding turns the suite red until it is updated |
| `kiosk_app` is the spike bundle | the `Environment=` delivery path is wired but inert |

Further reading: [`../../panel/HOUSE-PLAN.md`](../../panel/HOUSE-PLAN.md) is
the full drawing manual, written for whoever draws the house;
[`../../panel/README.md`](../../panel/README.md) covers the Panel's own
internals; [ADR-0005](../../docs/adr/0005-devices-authored-in-the-drawing.md)
and [ADR-0006](../../docs/adr/0006-togglability-is-decided-by-the-house.md)
carry the reasoning behind §6.2 and §6.4;
[`../../docs/plans/device-integrations/phase-6-bindings-sweep.md`](../../docs/plans/device-integrations/phase-6-bindings-sweep.md)
is the closure checklist this chapter feeds.
