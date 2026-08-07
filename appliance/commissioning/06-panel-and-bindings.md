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
| `entity` must match `^[a-z_]+\.[a-z0-9_]+$` | `bindings_parser.dart` | `the entity: under "<key>" is not a Home Assistant entity id (domain.object_id, lower case …)` |
| `stream` must match `^[A-Za-z0-9._-]+$` | `bindings_parser.dart` | `the stream: under "<key>" is not a go2rtc stream name (one or more of letters, digits, dot, dash and underscore, and nothing else) …` |
| One entity backs at most one Device | `bindings_parser.dart` | `"<a>" and "<b>" both bind to entity "<id>" — one entity, one Device.` |
| `connectivity` is present and is `local`\|`cloud` | `bindings_parser.dart` | `the connectivity: under "<key>" is neither of the two words this field takes (local \| cloud)` — **and no longer names the value**, which it used to. The old message argued that `connectivity:` "is not a field anyone pastes an address into"; it sits one line below `stream:` in the same block, and a paste landing one line off is the identical accident with the identical password in it. Missing entirely gets its own plain line: `"<key>" has no connectivity:` |
| A binding is a block, not a bare value | `bindings_parser.dart` | `"<key>" is not a block of settings …` — checked before any field is read, because `cam-den: something` used to reach `String.operator[]` and escape as a raw `type 'String' is not a subtype of type 'int'` naming neither file nor key |
| Every Placement has a binding | `house_loader.dart` | `no entry for Device "<key>" — add one; connectivity alone is enough until the hardware exists` |
| Every binding has a Placement | `house_loader.dart` | `bindings.yaml binds <keys>, which no longer exist in house.yaml` |
| No duplicate Key in `house.yaml` | `house_loader.dart` | `duplicate Device key "<key>" — … regenerate rather than editing house.yaml` |

Note the domain half of the entity regex allows no digits; the object id does.
`switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0` passes. The stream
regex has no first-character rule: `_ring_doorbell` is a legal key in
`go2rtc.yaml`, and the characters that matter (`:`, `/`, `@`) are excluded in
every position anyway.

**Four of these messages withhold the value they rejected**, and it is on
purpose: this message is written to the journal, and a camera URL carries
`user:password@host` with it. `entity:` and `stream:` are the two fields a URL
gets pasted into; `connectivity:` is one line below `stream:` in the same
block, which makes a paste landing one line off the identical accident; and a
binding that is a bare value could be that same paste with the field name left
off. They name the file, the key and the field so you can open `bindings.yaml`
and look.

The messages that *do* quote the value quote something no credential can hide
in — an entity id that already passed the pattern, or a Key. There is one more
in `bindings_parser.dart` that is not in this table because it is a YAML-shape
complaint rather than a rule: `stream: 007` reads as a **number**, and the
message says `quote it: stream: "007"`, which cannot be written without the
value. It is safe because YAML has already told us the value is not text, and
a URL is always text to YAML. Indent a `url:` line or a `- ` list under
`stream:` instead and it is a *collection*, not a scalar — that shape used to
come through the same message and print the password back twice per line, and
now goes to the withholding one.

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

`HUB`, `HA_URL`, `HA_TOKEN`, `GO2RTC_URL` and `LOG` all resolve **process
environment first**, then the build's `--dart-define`, then the built-in
default (`panel/lib/config/hub_config.dart`; `LOG` via `Log.applyLevel`). An
environment variable that is present but empty counts as absent.

`GO2RTC_URL` is the newest of them and has **no built-in default** — see §6.5a.
(`HA_TOKEN` has none either, but a default secret is not a thing that could
exist; `GO2RTC_URL` is the only *address* the Panel refuses to guess.)

The order is the point: on the appliance the Hub's address is an operational
setting, so a Hub that moves — or a DHCP lease that drifts — costs a restart,
never a Flutter rebuild.

**Web has no process environment.** `-d chrome` is a web build, so an
`HA_URL=…` prefix there is silently discarded and you get FakeHub on
`localhost:8123`. On web, `--dart-define` is the only route. The boot log says
`env=unavailable` when this is happening.

Linux desktop — the appliance/kiosk build, run on the machine that owns the
display (the interim Hub host today, the mini PC later). This is the Panel
running where it lives, not a development flow — development happens in the
devcontainer
([ADR-0009](../../docs/adr/0009-development-in-the-devcontainer-on-the-target-os.md)):

```sh
cd panel
HUB=ha HA_URL=http://127.0.0.1:8123 HA_TOKEN="$(cat ~/.sh_keys/token)" \
  flutter run -d linux
```

Chrome:

```sh
cd panel
flutter run -d chrome \
  --dart-define=HUB=ha \
  --dart-define=HA_URL=http://192.168.68.81:8123 \
  --dart-define=HA_TOKEN="$(cat ~/.sh_keys/token)"
```

`127.0.0.1` works from the Hub host itself because Home Assistant is
host-networked. From the devcontainer (or any machine on the LAN), use
`192.168.68.81:8123`.

The token is the Hub's long-lived access token, kept at `hub/token`
(gitignored, 0600). `$(cat …)` keeps it out of shell history. The Panel logs
`token=set`, never the value.

If an ambient variable beat a `--dart-define` you typed, the Panel says so
rather than leaving you to discover it:

```
[panel] W hub.config_override settings=HA_URL winner=environment
```

---

## 6.5a `GO2RTC_URL` and the camera Popups

Cameras and the doorbell open a Popup that plays live video from go2rtc.
Two independent things have to be true for a picture, and they are set in two
different files on purpose:

| What | Where | Shape |
|---|---|---|
| Where go2rtc is | `GO2RTC_URL`, resolved exactly like `HA_URL` | `http://127.0.0.1:1984` |
| Which stream this Device plays | `stream:` beside `entity:` in `bindings.yaml` | `ring_doorbell` — a **name**, never a URL |

```sh
cd panel
flutter run -d chrome \
  --dart-define=HUB=ha \
  --dart-define=HA_URL=http://192.168.68.81:8123 \
  --dart-define=HA_TOKEN="$(cat ~/.sh_keys/token)" \
  --dart-define=GO2RTC_URL=http://192.168.68.81:1984
```

**Unset is a supported state, not a broken one.** Unlike `HA_URL` there is no
built-in default — `HA_URL`'s is earned because `HUB=fake` gates it, and a
camera is a camera under every Hub, so a `localhost:1984` default would open a
socket to nothing on every run and a *wrong* go2rtc address would be invisible
until somebody tapped a camera. With nothing set, the Panel boots normally,
every pin renders, and one line each says which state it is in:

```
[panel] I hub.config … GO2RTC_URL=absent env=available
[panel] I popup.go2rtc url=absent
[panel] I house.loaded name="Demo House" floors=3 rooms=15 devices=33 bound=33 streams=0
```

`popup.go2rtc` carries the **address** in the clear — scheme, host and port —
and that is deliberate rather than a slip of the "never log a secret" rule:
those parts are what answer "is this Panel pointed at the right go2rtc", and
the camera credentials live in `hub/go2rtc/go2rtc.yaml`, not in the base
address. Those three parts are **built up** into the line; nothing else in the
value survives. A path is reported as `path=set` and never printed — it was
printed until a verifier put a token in one, and a reverse-proxy mount point's
presence is worth a word where its text is not. go2rtc 1.9 has `api.username`/`api.password`, so
`GO2RTC_URL=http://user:pass@host:1984` is a legitimate value, and it logs as
`url=http://host:1984 auth=set` — the address you need, plus the fact that the
Panel did receive the credential, in the same `token=set` vocabulary the token
uses. A value with **no host** in it reads `url=unusable` and is not echoed at
all: if the parts cannot be seen, nothing can promise there is no password
among them, and `admin:hunter2@host:1984` (no scheme) is exactly such a value —
it parses, but as a scheme with the rest as a path, so a rule that only dropped
the userinfo printed the whole thing. That same emptiness is what stops the
Panel dialling, so `url=unusable` also means "and you would get no picture".
`streams=` on `house.loaded` is how many Devices carry a `stream:` at all —
today, zero.

The `stream:` value is a **name from `go2rtc.yaml`**: one or more of letters,
digits, dot, dash and underscore, and nothing else — which excludes the `:`,
`/` and `@` a URL needs. The reason is worth knowing before you type one:
go2rtc's `?src=` is not a lookup. Hand it something that looks like a source
spec and it **creates** that stream and dials it — so a pasted
`rtsp://user:pass@camera/live` would both work by accident and put the camera
password into the Panel's log. Which is why the refusal itself is careful: the
`FormatException` reaches journald as `E house.invalid`, so it names the file,
the binding and the field and **does not echo the value**. Echoing it back is
what would publish the password, in the one line an operator copies into an
issue. Open `bindings.yaml` at the binding it names to see what is there.

Two neighbours of that rule are worth knowing at commissioning time, because
both were found by driving the code rather than reading it:

- **the binding's key is withheld too**, when the key is not plainly a name —
  a letter or digit, then letters, digits, spaces, dots, dashes and
  underscores, 40 characters at most. A paste that lands one column to the
  left makes the whole camera URL the key, and the message then printed it
  while promising not to. Ordinary keys are still quoted; anything else reads
  `the 3rd binding`, counted from the top of the file.
- **a YAML *syntax* error is a different message with a different guarantee.**
  It is raised by the YAML reader before any rule above has looked at
  anything, and the reader's own text quotes the offending source line with a
  caret under it — so a duplicated `stream:` line, a stray tab or a pasted URL
  containing `": "` published the password while the cleaner typo did not. It
  now reads `bindings.yaml is not valid YAML at line 4, column 5`, with the
  line left in the file for you to open. `house.yaml` goes through the same
  door.

A `stream:` on a kind that cannot play video is a fatal boot error, same as any
other line nothing would ever read — and that one message withholds the stream
*name* as well, because on a non-camera the stream is refused, so the message
is the only place the name could ever be published.

Tapping a camera with all of this set gives, on **either** build:

```
[panel] I popup.stream_open name=selftest
[panel] I popup.stream_closed name=selftest reason=popup_closed
```

**Both builds play video, and the kiosk is the one that matters most.** The
Flutter/cage appliance is the primary target — it is the wall — and the web
build is both ADR-0001's fallback and the shape a second in-house touchscreen
is planned to take. Anything you find that says "playback is web-only by
decision" or that `-d linux` shows a placeholder predates 2026-08-04 and is
wrong.

The `-d linux` half is no longer only a development-machine claim either: the
**release bundle** has done it, headless, against this Hub and this go2rtc —
§6.9a, which is also the list of what that run still does not prove.

They reach go2rtc by different roads, and the difference shows up in your
timings, so it is worth knowing which one you are watching:

| Build | What it asks go2rtc for | What to expect |
|---|---|---|
| `-d linux` (the kiosk) | `GET /api/stream.mjpeg?src=…` — multipart JPEG | **"Connecting to the camera…" for 2–4 s**, then the picture; ~186 kB/s |
| `-d chrome` (web) | `/api/ws?src=…` — fMP4 to MediaSource | picture in ~0.1 s; ~26 kB/s |

**The kiosk's two-second pause is not a fault and not your network.** go2rtc
starts the ffmpeg JPEG transcode when the first viewer asks for it; measured
2.10 s warm, 4.10 s cold. It stops again when the last viewer leaves, which is
why the *second* tap after a while is slow again. Do not go looking for a
cause — the Panel says `connecting` honestly rather than flashing
"unavailable" at you, and that phase existing is the whole reason.

**Every camera needs two producers in `go2rtc.yaml`, or the kiosk shows
nothing** — see §6.5b. This is the one configuration mistake in this feature
that produces no error message anywhere.

`popup.stream_unsupported` still exists and means something narrower than it
used to:

```
[panel] I popup.stream_unsupported name=selftest
```

…with **no** `stream_open`/`stream_closed` pair, because nothing was dialled.
It used to be the whole non-web platform saying "I have no player". Now it is
a *browser* with no `MediaSource` in it — so on the appliance you should never
see this line, and if you do, the build is not the one you think it is. The
distinction is the point: on the appliance the journal is the only channel
there is, and "this build cannot play video" has to be tellable from "go2rtc is
healthy and said no", which a `stream_open` for a socket that never existed
made impossible. `panel.start platform=…` cannot stand in for it — it scrolled
past hours ago.

## 6.5b Every camera is one stream with two producers

The two builds want two codecs off the same camera, and they ask for the same
stream **name**. So one entry in `hub/go2rtc/go2rtc.yaml` carries two
producers:

```yaml
streams:
  cam_porch:
    - rtsp://user:pass@CAMERA-IP/live      # H.264 -> web MSE
    - ffmpeg:cam_porch#video=mjpeg         # -> appliance MJPEG
```

`bindings.yaml` writes `stream: cam_porch` once, and both builds play it.
Rejected: naming the MJPEG one `cam_porch_mjpeg`, which would put a transport
detail into the house's own configuration and make every camera two entries
that can drift apart.

**Leave the second producer out and the kiosk gets nothing, with no error
anywhere.** go2rtc does not transcode on demand for a format no producer
offers. Measured against this box's 1.9.10, a stream with only the H.264 line:

```
$ curl -m 8 -o /dev/null -w 'code=%{http_code} bytes=%{size_download}\n' \
    'http://127.0.0.1:1984/api/stream.mjpeg?src=<name>'
code=200 bytes=0
```

`200 OK` and nothing in it. Not a 404, not an error frame — a successful empty
stream, which go2rtc then holds open. The Panel's watchdog gives up after
fifteen seconds and says "Live view unavailable"; nothing in the journal, the
go2rtc UI or the camera points at the missing line. **So run that `curl` when
you add a camera.** Anything other than `bytes=0` means the appliance can play
it.

Declaring it on every camera costs nothing while nobody is watching: with no
consumer, `/api/streams` shows both producers as bare `url` stubs with
`consumers: []`, and no ffmpeg is running. That is also how you verify teardown
after closing a Popup, and it is a stricter check than watching the consumer
count.

**Give it ten seconds before you call teardown broken.** Close a Popup that was
*playing* and `consumers` is `[]` within a second. Close one **during** the 2 s
"Connecting to the camera…" and the count *goes up* after the Panel has already
gone, taking 2–10 s to reach `[]` — the JPEG transcode counts as a consumer of
its own source and finishes starting regardless of who left. Measured; expected;
not a leak, and not something the Panel can cancel.

---

## 6.6 The diagnostics that matter

Same lines everywhere: `flutter run`, the browser console (filter on
`[panel]`), and the appliance journal. A healthy start:

```
[panel] I panel.start hub=ha mode=release platform=linux log=info log_from=environment
[panel] I hub.config HUB=environment HA_URL=environment HA_TOKEN=environment GO2RTC_URL=absent env=available
[panel] I popup.go2rtc url=absent
[panel] I house.loaded name="Demo House" floors=3 rooms=15 devices=33 bound=33 streams=0
[panel] I hub.configured url=http://127.0.0.1:8123 token=set
[panel] I hub.connected url=ws://127.0.0.1:8123 devices=33
[panel] I hub.snapshot entities=<n> bound=<m> missing=0
```

| Line | Read it for |
|---|---|
| `hub.config` | which origin won, per setting. `env=unavailable` means you are on web and any environment you exported was discarded |
| `popup.go2rtc` | where the camera Popups will look, or `absent`. Scheme, host and port are in the clear; a path is reported only as `path=set`, a credential in the value only as `auth=set`, and a value with no host reads `url=unusable` and is not echoed — §6.5a. `absent` is a supported state |
| `house.loaded` | `devices=` is Placements, `bound=` is how many have an `entity:`. The gap is your unbound Devices. `streams=` is how many carry a `stream:` |
| `hub.configured` | what `HA_URL` actually resolved to, cut to scheme/host/port by the same rule as `popup.go2rtc` — Home Assistant behind a reverse proxy with basic auth makes this value a secret, so a mount point reads `path=set`, a credential `auth=set`, an `?api_password=` `query=set`, and a value with no host `url=unusable` |
| `hub.connected` | the socket authenticated. `devices=` here is the count of **bound** entities the client is watching. The address only — its path is `/api/websocket`, which the Panel appended itself; `hub.configured` above is where the operator's own value is characterised |
| `hub.snapshot` | `missing=` is the headline number. Zero means every `entity:` you wrote exists on the Hub |
| `hub.missing_entities` | the ids the Hub has never heard of. Capped at 8 ids with `more=<n>`; `hub.snapshot` carries the true count |
| `hub.state_unusable` | the entity exists but reports `unavailable`/`unknown`, or a reading would not parse. One line per entry into that state, not per message |
| `hub.toggle_refused` | a tap hit a non-togglable kind (§6.4) |
| `hub.auth_invalid` | the token is wrong. Terminal — the Panel does not retry past this (ADR-0007) |
| `popup.stream_*` | one Popup's live view: `_open`, `_closed`, `_failed` (go2rtc's own words, verbatim), `_skipped` at debug with the reason nothing was dialled, and `_unsupported` on any non-web build. `_open`/`_closed` come as a pair and only for a socket that really was opened — an `_unsupported` Popup logs neither, because a pair for a connection that never existed is the log inventing one. Always the stream **name**, never the URL |
| `popup.doorbell*` | the unprompted Popup: `_extended` (a second ding restarted the 30 s deadline), `_held` (a person already had that doorbell up), `_deferred` (the previous one was still closing its stream; it is re-offered once it is gone), `_dismissed` (it went away, and this line deliberately does not guess why) |
| `popup.deadline_ceiling` | a doorbell Popup hit `open_s=120` — something kept extending it for two solid minutes. The one dismissal that names its own reason |
| `popup.dismiss_blocked` | a Popup's deadline fired while another route sat on top of it. It re-arms at `retry_s=` rather than losing the deadline and holding its stream open |
| `ui.ding*` | the doorbell rule's verdict per report. `ui.ding` rang; `ui.ding_suppressed` did not and says which rule silenced it (`unchanged`, `stale` with `age_s`, or `first_sight`); `ui.ding_stale` means a press time *changed* and still read too old — the clocks disagree and the feature is silently dead; `ui.ding_unreadable` names a state string neither shape could read |

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
| `GO2RTC_URL` | `Environment=GO2RTC_URL={{ panel_go2rtc_url }}` | not a secret — go2rtc is unauthenticated here and the camera credentials live in `go2rtc.yaml`, not in this base address |
| `LOG` | `Environment=LOG={{ panel_log_level }}` | not a secret; raising the level on a Panel already on a wall must not mean rebuilding it |
| `HA_TOKEN` | `EnvironmentFile=-/etc/smarthome/panel.env`, 0600, owned by the kiosk user | `systemctl show -p Environment` hands every `Environment=` value to any local user without authentication, and the unit file is 0644. `EnvironmentFile=` exposes only the path |

Source: `appliance/ansible/roles/kiosk/templates/cage@.service.j2` and
[`../ansible/README.md`](../ansible/README.md).

The leading `-` on `EnvironmentFile=` is deliberate. Without it systemd fails
the service when the file is missing — which on a default `HUB=fake` box would
turn "no Hub yet" into a restart-looping black screen.

### The empty-by-default rule

`panel_hub_kind`, `panel_ha_url`, `panel_go2rtc_url` and `panel_log_level` all
default to `""` in `appliance/ansible/group_vars/all.yml`, and **must stay
that way**. Resolution is environment-first, so any value set there beats a
`--dart-define` compiled into the bundle. Writing the apparently harmless
defaults (`fake`, `http://localhost:8123`) would silently force a Panel built
with `--dart-define=HUB=ha` back onto the fake Hub. Empty emits no
`Environment=` line at all, which is what makes "a converge changes nothing
until someone asks it to" actually true.

`panel_go2rtc_url` has an extra reason on top of that one: the Panel has **no
built-in default** for it at all, so a value here would not be re-stating a
default, it would be inventing the setting. Left empty the Panel says
`GO2RTC_URL=absent`, which is the truth — nobody has told it where go2rtc is.

### Delivering the token

The token lives in `hub/token` on whichever machine runs the playbook, and
reaches the converge through the controller's environment. Never as
`-e panel_ha_token=…` — extra-vars land in `ps` output.

```bash
cd appliance/ansible
PANEL_HA_TOKEN="$(cat ~/.sh_keys/token)" \
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

`panel/README.md` used to say `journalctl -u panel`; there is no such unit,
and that line was corrected 2026-08-04. If it comes back, this is why it is
wrong: the Panel has no unit of its own — it is whatever `cage@<tty>` launches.

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
PANEL_LIVE_HUB=1 HA_URL=http://192.168.68.81:8123 HA_TOKEN="$(cat ~/.sh_keys/token)" \
  flutter test test/ha_hub_live_test.dart
```

The devcontainer terminal runs it fine — outbound LAN routing works from
in-container, so `192.168.68.81` is reachable there like from any machine on
the network.

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
| No binding carries a `stream:`, and `panel_go2rtc_url` is empty | `house.loaded` reports `streams=0` and every camera Popup shows the unconfigured placeholder. Not a fault — no go2rtc stream exists for any `cam-*` yet (**B3**), and `selftest` is the only stream on the box |
| Both builds have a real player; go2rtc's `origin: "*"` is set | and on **2026-08-04 the Linux release build opened a Popup by itself and rendered live MJPEG inside it** — first light, §6.9a. Read that section before quoting this row anywhere: what it verifies is narrow, and it is easy to over-read in both directions |
| `flutter build linux --release` **succeeds on this host** (**G4** done) | clang/clang++ 21.1.8, cmake 4.2.3, ninja 1.13.2, pkg-config 2.5.1, gtk+-3.0 3.24.52, liblzma 5.8.3, xkbcommon 1.13.1; the bundle is at `panel/build/linux/x64/release/bundle/panel` with `libapp.so` and `libflutter_linux_gtk.so` beside it. **A converge did not put it there and would not reproduce it unaided** — the toolchain was installed by hand, and `flutter_toolchain_packages` does not yet describe the host that builds. That reconciliation is [1 §1.7a](01-host-and-network.md)'s, not this chapter's |
| Nothing has run under `cage`, and no touchscreen is attached to this host | first light was **Xvfb**. The kiosk half is untouched: `cage` is not installed (**G6**) and **A7** is the hands-on-glass session. §6.9a's table is the full list of what is still open |

### 6.9a First light — and exactly how far it goes

**On 2026-08-04 the `flutter build linux --release` bundle — the same binary the
appliance will run — opened a doorbell Popup unprompted and played live video
in it.** Every document in this repo previously said the appliance's player had
never drawn a frame. That sentence is wrong wherever it survives.

It is also the single easiest result in this repo to over-read, so the procedure
and the disclaimers are given together, and neither is optional.

**The procedure, reproducible.**

```sh
Xvfb :99 -screen 0 1280x800x24 +extension GLX +render &

cd panel
DISPLAY=:99 GDK_BACKEND=x11 WAYLAND_DISPLAY= \
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
HUB=ha HA_URL=http://127.0.0.1:8123 HA_TOKEN="$(cat ~/.sh_keys/token)" \
GO2RTC_URL=http://127.0.0.1:1984 LOG=debug \
  build/linux/x64/release/bundle/panel
```

**`GDK_BACKEND=x11` is the line that will otherwise cost you an hour.** Without
it GTK finds the host's own Wayland session and prefers it: the window opens on
the operator's real desktop, Xvfb's root window is left with **zero children**,
and a screenshot of `:99` is black. Nothing errors, nothing warns. It looks
exactly like a Flutter build that cannot render — which is the wrong conclusion,
and an expensive one to chase. `WAYLAND_DISPLAY=` emptied is the same
instruction said a second way, deliberately.

The two GL variables are because this box has no usable GPU under Xvfb, so
llvmpipe soft-renders the whole app. Under `cage` on the wall neither should be
needed; that is an expectation, not a measurement.

**The ding was injected, not rung.** There is no Ring entity on this Hub
(**B2**), so the doorbell's bound `sensor.ring_doorbell` was written directly:

```sh
cd <repo>
# off, then on — two POSTs, and the reason is in the log below
curl -s -X POST -H "Authorization: Bearer $(cat ~/.sh_keys/token)" \
  -H 'Content-Type: application/json' -d '{"state":"off"}' \
  http://127.0.0.1:8123/api/states/sensor.ring_doorbell
```

**And `stream: selftest` was added to the `doorbell` binding before the build,
then reverted.** See the last row of the table below — this is the part that
decides what a Panel built from the repo *today* does.

**The log, verbatim:**

```
[panel] I panel.start hub=ha mode=release platform=linux log=debug
[panel] I house.loaded name="Demo House" floors=3 rooms=15 devices=33 bound=33 streams=1
[panel] I hub.connected url=ws://127.0.0.1:8123 devices=33
[panel] I hub.snapshot entities=55 bound=4 missing=29
[panel] D ui.ding_suppressed device=doorbell reason=first_sight
[panel] D ui.ding_suppressed device=doorbell reason=unchanged
[panel] I ui.ding device=doorbell entity_state=on
[panel] I popup.doorbell device=doorbell reason=ding
[panel] I popup.stream_open name=selftest
... 30 s later ...
[panel] I popup.stream_closed name=selftest reason=popup_closed
[panel] I popup.doorbell_dismissed device=doorbell
```

Read it as the chain it is — three parts of it get misread:

- `streams=1` is the temporary `stream:` line, and is why the row above says
  `streams=0` for the repo as it stands.
- `missing=29` is **not a fault of this run.** It is the dev stand-ins that do
  not exist on the real Hub — the first row of §6.9 — and it is what binding
  work will remove. `bound=4` is what the client actually watches.
- the two `ding_suppressed` lines are why the injection needs **two** POSTs:
  `first_sight` silences whatever state the Panel finds on connect, `unchanged`
  silences a repeat of it, and only a genuine off→on transition rings (§6.6).

Then `popup.doorbell` — the Panel put a Popup on screen that nobody asked for,
off a state change, which is the behaviour that has no other way of being
tested.

**go2rtc is the independent witness.** While the Popup was up, its consumer on
`selftest` read:

```
format_name: mjpeg, protocol: http, user_agent: "Dart/3.12 (dart:io)",
bytes_send: 931189
```

`Dart/3.12 (dart:io)` is the Flutter binary's own HTTP client — not a browser,
not `curl` — and 931 kB is a picture that actually moved. `consumers: []` after
the Popup closed, which is the teardown check §6.5b describes, on the run that
matters. (Re-measured while writing this: still `consumers: []`, both producers
idle.) A screenshot shows the dollhouse with the Popup over it and the test
pattern rendering inside.

**What this does NOT prove.** Five things, and every one of them is still open:

| Not proven | Because | Tracked as |
|---|---|---|
| The **kiosk** works | It ran under **Xvfb, with the X11 GDK backend and software GL** — not under `cage` on a Wayland seat. `cage` is not installed on this box at all | **G6**, then **A7** |
| **Touch** works | Nothing was tapped. No touchscreen is attached to this host; every input in the run was a state push over HA's REST API | **A7** |
| A **camera** plays | The stream was go2rtc's synthetic `ffmpeg:selftest#video=mjpeg` test pattern. A real RTSP camera adds its own start-up on top of the 2–4 s transcode wait in §6.5a | **B3** |
| A **doorbell** rings | The ding was a fabricated `sensor.ring_doorbell` state POSTed to HA. Ring is not authenticated and that entity does not otherwise exist here | **B2** |
| **A Panel built from this repo does any of it** | The binary was built from a working tree carrying `stream: selftest` on the `doorbell` binding. **That edit was reverted** — the tracked `panel/assets/house/bindings.yaml` has no `stream:` line and is clean against `HEAD` (verified) — so a Panel built today opens that same Popup with **no video in it** | an uncommitted config change, still open |

The one-line summary for anyone quoting this elsewhere: **the appliance's video
path is proven end to end against synthetic inputs, and nothing about the wall,
the glass, or the house's own hardware is.** Say all of that or none of it.

Further reading: [`../../panel/HOUSE-PLAN.md`](../../panel/HOUSE-PLAN.md) is
the full drawing manual, written for whoever draws the house;
[`../../panel/README.md`](../../panel/README.md) covers the Panel's own
internals; [ADR-0005](../../docs/adr/0005-devices-authored-in-the-drawing.md)
and [ADR-0006](../../docs/adr/0006-togglability-is-decided-by-the-house.md)
carry the reasoning behind §6.2 and §6.4;
[`../../docs/plans/device-integrations/phase-6-bindings-sweep.md`](../../docs/plans/device-integrations/phase-6-bindings-sweep.md)
is the closure checklist this chapter feeds.
