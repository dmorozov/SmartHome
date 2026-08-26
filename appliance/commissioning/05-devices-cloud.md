# 5 — The cloud fleet: Ring, Wyze, and the account devices

**Mostly instructions, not an as-built record — three exceptions below are
done and measured.** Every earlier chapter describes something that
exists on this machine and was measured. This one still describes work
that has not been done for most of the fleet: no Wyze camera stream, no
LG / Whisker / Petlibro entity exists in Home Assistant. Three parts of
this chapter *are* as-built, each with its own verified entry: **Ring**
(§1, authenticated 2026-08-05), **HACS** (§3, installed and authenticated
2026-08-07), and **Emporia** (§7, authenticated 2026-08-08). Where a value
has to come off the operator's own device or vendor account, it says so;
where the repo's research left something open, it is marked UNVERIFIED
rather than guessed into a step.

Research base: [`../../docs/research/hub-and-device-integrations.md`](../../docs/research/hub-and-device-integrations.md)
(cited as §3.x). Build plans:
[phase-3-ring.md](../../docs/plans/device-integrations/phase-3-ring.md),
[phase-4-cameras.md](../../docs/plans/device-integrations/phase-4-cameras.md),
[phase-5-cloud-fleet.md](../../docs/plans/device-integrations/phase-5-cloud-fleet.md).
Decisions D1/D2/D3 are from
[the plan README's D-log](../../docs/plans/device-integrations/README.md).

Nothing here needs root. `docker` runs unprivileged for the repo user on
this host (verified 2026-08-04). If a step ever does need `sudo`: **this
host has no passwordless sudo** — hand that step to the operator, it
cannot be automated from an agent session.

---

## Status, 2026-08-04

| Device / integration | Deployed? | Authenticated? | Phase | Local or cloud |
|---|---|---|---|---|
| Ring doorbell (ring-mqtt) | **yes** — container Up | **yes** — authenticated 2026-08-05, 15 entities, bound, video proven (§1.3) | 3 | cloud, permanently (§3.1) |
| Wyze cameras | no | n/a | 4 | mixed, per unit (D1) |
| HACS | **yes** — installed and authenticated 2026-08-07 (§3.1–3.2) | **yes** — entry `01KZDDD6TH4CKTE9FZT1XH102B`, `state: loaded`, `update.hacs_update` entity confirms a healthy startup | 5 | cloud at install time only |
| LG washer + dryer (`lg_thinq`) | no | n/a | 5 | cloud |
| Litter-Robot 5 Pro (`litterrobot`) | no | n/a | 5 | cloud |
| Petlibro One + Granary (HACS) | no | n/a | 5 | cloud |
| Emporia Vue 3 + plugs (HACS) | **yes** — added and authenticated 2026-08-08 (§7) | **yes** — entry `01KZFNVXV01M73F63FS8EQ19S4`, `state: loaded`, 58 entities across 19 devices | 5 | cloud now, local after reflash (D2) |
| SmartThings oven | no | n/a | **none** | cloud — D3, a decision, not a build task |

ring-mqtt 5.9.3 is the only one already running, because phase 1 put it in
[`../../hub/compose.yaml`](../../hub/compose.yaml). **It was authenticated on
2026-08-05 and is now doing real work** (§1.3). Between phase 1 and that day it
sat at its auth gate and said so — quoted because this is what an
*unauthenticated* ring-mqtt looks like, and it is not an error:

```
ring-mqtt State file /data/ring-state.json not found. No saved state data available.
ring-mqtt No refresh token was found in the state file, use the Web UI at http://<host_ip_address>:55123/ to generate a token.
```

If those two lines ever come back, the pairing has been lost and §1.2's cliff
is the thing that happened.

## Credentials the operator must obtain

Every one of these comes from a vendor account or a physical device. None
can be fetched, derived, or reset from this repo.

| Integration | Credential | Where it comes from |
|---|---|---|
| Ring | account email + password, then a **live 2FA code** | Ring's own 2FA channel (SMS/email, per that account's setting) |
| Wyze — bridge path | account email + password **and** API Key ID + API Key | `https://developer-api-console.wyze.com/#/apikey/view` (§3.2) |
| Wyze — RTSP path | an RTSP user/password **you invent** | set in the Wyze app on the camera after flashing; nothing external issues it |
| HACS | a GitHub account | GitHub device-code flow at install time |
| LG ThinQ | a **Personal Access Token** + country | `connect-pat.lgthinq.com`, signed in as the LG account the appliances are registered to |
| Whisker | Whisker/Litter-Robot app account email + password | the app account that owns the robot |
| Petlibro | email + password of a **second, dedicated** Petlibro account | create it, then share the devices to it — see §6 |
| Emporia | Emporia app account email + password | the app account that owns the Vue 3 |
| SmartThings | Samsung account, browser OAuth; **$4.99/mo from Oct 2026** | only if D3 is decided in favour |

---

## 1. Ring doorbell — ring-mqtt (phase 3)

Cloud, permanently. There is no local API for Ring devices at all — a
Ring platform limitation, not an integration gap (§3.1). These bind
`connectivity: cloud` and the Panel says so in the Popup.

### 1.1 The 2FA flow

From any machine on the LAN, open the ring-mqtt web UI:

```
http://192.168.68.81:55123/
```

(`192.168.68.81` is this host's current Wi-Fi address. The Deco serves no
local DNS, so there is no name to use — reserve the address by MAC in the
Deco app if it has not been done.)

Enter the Ring email and password; ring-mqtt asks Ring to send a 2FA code
and prompts for it. The code is time-boxed and arrives out of band, so
**this step cannot be scripted or done ahead of time** — the operator
does it with a phone in hand.

Watch what happens:

```sh
docker logs -f ring-mqtt
```

On success ring-mqtt writes `/data/ring-state.json` — on the host that is
`~/.sh_keys/ring-mqtt/ring-state.json` (was `hub/ring-mqtt-data/` before
ADR-0010 moved it outside the repo entirely) — and begins device discovery.
Because MQTT discovery is on, the doorbell materialises in HA on its own;
no config flow to drive.

### 1.2 The refresh token IS the re-pairing cliff

`ring-state.json` holds the refresh token. It is the only credential in
this stack whose loss costs a human being a live 2FA session, and it
therefore governs three operational rules:

1. **Back it up with the rest of the runtime state.** Since ADR-0010,
   `~/.sh_keys/` (which now holds `ring-mqtt/ring-state.json`) is its own
   backup unit, separate from the `hub/ha-config/.storage` /
   `z2m-data` / Mosquitto-persistence archive named in
   [`../../hub/README.md`](../../hub/README.md) — Ch. 2 §8 gives both
   tarball recipes. Neither is on a repeatable schedule yet (TODO, "a
   repeatable backup step" in `COMMISSIONING.md`'s Status).
2. **Never restore a stale copy over a newer one, and never run a second
   ring-mqtt against the same Ring account.** ring-mqtt refreshes the
   token in place; a rolled-back or duplicated state file is expected to
   invalidate the session and drop you back at the 2FA prompt. (The exact
   rotation/invalidation semantics in 5.9.3 are **UNVERIFIED** this
   session — the operational rule is the same either way, because the
   failure mode is unrecoverable without a human.)
3. **A Ring password change or a session revoked from the Ring app ends
   the pairing.** Recovery is §1.1 again, by hand. The exact wording of
   the Ring app's authorized-device screen is **UNVERIFIED** — do not
   quote a menu path at the operator.

### 1.3 What arrived, and what is bound — AS-BUILT 2026-08-05

Authenticated 2026-08-05. ring-mqtt 5.9.3 published **15 entities** on one
device, "Front Door":

```
binary_sensor.front_door_ding          switch.front_door_live_stream
binary_sensor.front_door_motion        switch.front_door_event_stream
camera.front_door_snapshot             switch.front_door_motion_detection
button.front_door_take_snapshot        switch.front_door_motion_warning
select.front_door_event_select         number.front_door_snapshot_interval
select.front_door_snapshot_mode        number.front_door_motion_duration
sensor.front_door_info                 number.front_door_ding_duration
sensor.front_door_wireless
```

**No `event.*` entity, at all.** The advice above used to read "prefer
`event.*_ding` if this version offers both" — measured against the live
registry, the `event` domain is empty and this version offers one shape:

```yaml
  doorbell:
    entity: binary_sensor.front_door_ding
    stream: ring_doorbell
    connectivity: cloud
```

~~That is `classifyDing()`'s **word shape** (rules 3–4), not the timestamp
shape~~ — **superseded 2026-08-05 by phase 7 §A**: the Panel no longer binds
the binary_sensor at all. An HA MQTT-event entity minted over ring-mqtt's own
ding topic (`hub/ha-config/mqtt.yaml`, gitignored; tracked example beside it)
gives the classifier the **timestamp shape** (rule 2), which closes both word-
shape losses — the first press after a gap, and a second press inside the
ding window. `doorbell` binds `event.front_door_ding`. As part of the same
change, **`number.front_door_ding_duration` was lowered 180 → 60 s** (set via
`number.set_value`, 2026-08-05): nothing binds the binary_sensor any more,
and the shorter window shrinks the one replay hole the event shape still has
(an HA restart *during* an active window — phase-7 §A2, "two holes").

**The template-sensor escape hatch below is buried, not just unused.** It was
"deliberately not wired" pending verification; research
(`docs/research/ring-events-and-recording.md` §1) then confirmed ring-mqtt
*does* write `lastDingTime` at the instant of the push — but also that the
startup history-refetch can republish it in a different string format, so an
attribute trigger can false-fire once per ring-mqtt restart. The event entity
needs none of that reasoning and strictly dominates. Kept for the record:

```yaml
# SUPERSEDED by the MQTT event entity (phase 7 §A) — do not install.
template:
  - sensor:
      - name: "Front Door Ding At"
        state: "{{ state_attr('binary_sensor.front_door_ding','lastDingTime') }}"
```

Not published, and worth knowing: **no battery entity**, so this unit is
hardwired. Sizing anything on battery drain from live view is unnecessary
here; the #177014 event-suppression argument is unaffected and still governs.

### 1.4 The #177014 rule

An open Ring live stream suppresses ding and motion events (HA core issue
#177014). This is why the Panel opens live view on tap only, closes it
with the Popup, and never holds a stream open in the background. It is
also why ring-mqtt's maintainer refuses to support 24/7 streaming or
NVR/Frigate use of Ring cameras at all: it drains batteries, overheats
devices, and suppresses the events the doorbell exists to deliver (§3.1).
Do not plan Ring recording. Drive automations from *events*.

Live-view plumbing is **done, 2026-08-05**. `hub/go2rtc/go2rtc.yaml` carries:

```yaml
  ring_doorbell:
    - rtsp://127.0.0.1:8556/90486cf35236_live
    - ffmpeg:ring_doorbell#video=mjpeg
```

The port remap to 8556 is in `compose.yaml` because go2rtc owns 8554 — and
note that the placeholder in `go2rtc.example.yaml` said `8554` until this
landed, which would have pointed go2rtc at itself. The device id is **read off
the Hub, never typed**: `sensor.front_door_info` → `attributes.stream_Source`
reports ring-mqtt's own in-container address
(`rtsp://172.21.0.3:8554/90486cf35236_live`); take the id from it, not the
address, because go2rtc is host-networked and dials the published port.

**Measured end to end the same day.** `GET /api/stream.mjpeg?src=ring_doorbell`
— the exact endpoint the appliance build consumes — returned **5,330,367 bytes
containing 54 JPEG frames in 8 s**. That is the second producer doing its job:
the RTSP source is H.264, and without the `ffmpeg:…#video=mjpeg` line the same
request would have returned 200 OK with **zero bytes** and held the connection
open (see the note in `go2rtc.example.yaml`).

**And the #177014 teardown was measured, not assumed**, because that is the
part that can quietly break the doorbell: pulling the stream flipped
`switch.front_door_live_stream` to `on`, and **within 5 s** of the pull ending
it was back `off` with go2rtc reporting `consumers: []`. The Ring session does
not outlive the viewer. Re-check this if the Panel ever seems to stop ringing.

---

## 2. Wyze cameras (phase 4)

### 2.1 The five unidentified hosts are Wyze hardware

Five LAN hosts share the OUI `D0:3F:27`, which the IEEE registry assigns
to **Wyze Labs Inc** (looked up locally 2026-08-04):

```sh
grep -i D03F27 /usr/share/ieee-data/oui.txt
# D0-3F-27   (hex)		Wyze Labs Inc
```

| IP (2026-08-04) | IP (re-measured 2026-08-07) | IP (2026-08-15) | MAC |
|---|---|---|---|
| 192.168.68.54 | 192.168.68.54 | 192.168.68.54 | d0:3f:27:53:25:72 |
| 192.168.68.57 | 192.168.68.57 | 192.168.68.57 | d0:3f:27:8d:cc:54 |
| 192.168.68.62 | **192.168.68.63** | 192.168.68.63 | d0:3f:27:8e:4f:b1 |
| 192.168.68.63 | **192.168.68.62** | 192.168.68.62 | d0:3f:27:4a:95:76 |
| 192.168.68.69 | 192.168.68.69 | 192.168.68.69 | d0:3f:27:49:b2:f6 |

**Two of the five drifted IPs in three days** — `.8e:4f:b1` and `.4a:95:76`
swapped between `.62` and `.63` between the first two columns. That was the
live proof for why identification must key on **MAC**, never IP, and it is
also what **C1** then fixed: since 2026-08-07 all five hold Deco address
reservations made by MAC, and the third column is those reservations holding
eight days later, unchanged. So an IP may now be written into
`go2rtc.yaml` — but it is still read *back* by MAC, and the reservation is
the only reason the address is allowed to appear anywhere.

To re-list them at any time — unprivileged, no table to keep in step, and it
also answers the question §2.2 turns on:

```sh
hub/tool/wyze-fleet.py scan
```

It sweeps this host's own subnet, keeps every neighbour carrying the Wyze
OUI, and probes each for an RTSP listener. **Measured 2026-08-15: five units,
none serving RTSP** — 554 and 8554 both refused on all five, which is what a
v3 looks like before anyone enables the toggle, not a fault. The two-liner it
replaces still works and needs nothing but coreutils:

```sh
for i in 54 57 62 63 69; do ping -c1 -W1 192.168.68.$i >/dev/null 2>&1; done
ip neigh | grep -i d0:3f:27
```

**UNCONFIRMED, and it decides everything downstream:** the vendor is
known, the *devices* are not. Wyze cameras, plugs, bulbs and sensor hubs
all carry Wyze OUIs, so "five Wyze MACs" is not "five cameras", and the
camera **model** (v3 / Pan v3 / v4 / OG / Floodlight / Floodlight Pro)
per unit is exactly what D1 branches on. Identify them by matching MACs
in two places:

- **The Deco app's client list** — the only naming source on this LAN.
  The Deco serves no local DNS and every PTR lookup fails, so there are
  no hostnames to resolve; the app is where a MAC gets a human name, and
  it is also where each unit's DHCP reservation must be made (by MAC).
- **The Wyze app's own device list** — each camera's Device Info shows
  model and firmware version. Match on MAC, write the result into the A1
  inventory table in
  [phase-4-cameras.md](../../docs/plans/device-integrations/phase-4-cameras.md),
  which is where that table is supposed to live.

### 2.2 Path A — official RTSP firmware, one unit (the D1 experiment)

Goal: a camera serving RTSP with no cloud in the video path —
`connectivity: local`, the only genuinely local outcome available
anywhere in this chapter.

Per §3.2, Wyze promoted RTSP/RTSPS from beta to **production firmware on
2026-02-02** for Cam v3 (4.36.16.5654) and Cam Pan v3 (4.50.16.5654),
app ≥ 3.9, enabled in the camera's Advanced Settings. **B3 read the
firmware off every unit on 2026-08-07 and all five are Cam v3 on
4.36.16.7064 — newer than the build that carries RTSP.** So the first
check is not a flash at all, and on this fleet a flash is unlikely to be
needed anywhere:

1. **Look in the Wyze app** for an RTSP option in the target camera's
   advanced settings. Do a **plain v3 first** — Family Room (`.57`),
   Living Room (`.69`) or Back Yard Door (`.63`); the Garage Door and
   Back Yard units are Floodlight bundles and carry a second firmware for
   the light controller, which §3.2 flags as an untested combination.
   **This is the step nothing else can be done without, and it is
   owner-only** — it is a phone, an account and a tap, none of which a
   session on this box has.
2. Only if the toggle is absent does the older sideload path apply
   (FAT32 microSD, `demo.bin` in the root, hold setup while powering).
   Note that phase-4 §A2 still describes that older `demo_V3_RTSP` line
   (4.61.0.3) — it predates the production firmware in §3.2. **If the
   production firmware exposes RTSP, use it and skip the demo build.**
3. Set the stream credentials in the app — you invent them there, nothing
   external issues them — then **tap Generate URL and read the whole URL
   off that screen**. Do not reconstruct it from memory or from this
   document. On the firmware this fleet runs it is
   `rtsps://user:pass@<cam-ip>:322/stream0`, and **all three of scheme,
   port and path differ from what this chapter said until 2026-08-15**:

   - **`/stream0`, not `/live`.** `/live` belonged to the old sideloaded
     demo firmware. `/stream1` is the substream.
   - **RTSPS on 322, not RTSP on 554**, whenever the app's RTSPS toggle is
     on — which is its default. Turning it off is offered on the same
     screen (with a security warning to accept) and is defensible here:
     ADR-0008 puts this on a LAN with no port-forward. It would also let
     go2rtc dial the camera natively — see step 5.
   - **554 stays open and mute.** All five accept a TCP connection there
     and answer nothing at all, plaintext or TLS. A port scan reads that
     as success; every client hangs on it.
4. **Ask the camera before you write the password down anywhere.** The
   address is already reserved by MAC (**C1**, 2026-08-07 — that step used
   to live here and is done):

   ```sh
   WYZE_RTSP_USER=<the user you invented> \
     hub/tool/wyze-fleet.py rtsp 192.168.68.57 --tls
   ```

   It prompts for the password, never echoes it, and DESCRIBEs the stream
   — one request per connection, because these cameras close the socket
   after answering and a client that pipelines reads EOF and blames the
   credentials. Outcomes it separates, which a black tile in the Panel
   cannot:

   | what you see | what it means |
   |---|---|
   | `connect FAILED` | nothing listening on that port — wrong transport, or the toggle is off |
   | `DESCRIBE 401` | serving, credentials wrong |
   | `DESCRIBE 200` + an SDP naming H.264 | good — configure it |
   | **connection closed, no reply** | **ambiguous, and this is the trap** |

   That last one is why the tool then re-runs with a **deliberately wrong**
   password. A camera that answers `401 Invalid Authorization` to nonsense
   but closes silently on your real password has *accepted* the login and
   objected to something else — nearly always the path. Without that
   comparison, a wrong path is indistinguishable from a wrong password, and
   on 2026-08-15 it cost several rounds of chasing the wrong thing.
5. Add it to `~/.sh_keys/go2rtc/go2rtc.yaml` — outside the repo, because
   stream URLs embed camera credentials (ADR-0010) — as **two producers,
   not one**. The second line is not optional and leaving it out fails
   *silently*: go2rtc will not transcode for a format no producer offers,
   so the appliance build's `/api/stream.mjpeg` gets HTTP 200 and zero
   bytes (phase-4 §B1). The five entries are pre-written, commented, with
   their reserved addresses already in them, in
   [`hub/go2rtc/go2rtc.example.yaml`](../../hub/go2rtc/go2rtc.example.yaml) —
   copy the one you enabled and add the password:

   ```yaml
   streams:
     wyze_family_room:
       - ffmpeg:rtsps://user:pass@192.168.68.57:322/stream0#video=copy#audio=copy
       - ffmpeg:wyze_family_room#video=mjpeg
   ```

   **The `ffmpeg:` wrapper is required, not stylistic.** go2rtc 1.9.10's
   own RTSP client cannot talk TLS to these cameras — plain `rtsps://` and
   the `rtspx://` prefix (its documented skip-verification variant, meant
   for UniFi) both time out reading the socket, logging
   `read tcp …: i/o timeout` while the camera is perfectly healthy.
   ffmpeg has no such trouble, and `#video=copy#audio=copy` remuxes rather
   than transcodes, so it costs a process, not CPU. If you turn RTSPS off
   in the app instead, the wrapper is unnecessary and a bare
   `rtsp://user:pass@<ip>:554/stream0` works natively.

   **One RTSP session per camera.** Do not give the mjpeg producer the
   camera URL directly to save a hop: measured 2026-08-15, two producers
   dialling the same camera make *both* return nothing. The second reads
   from go2rtc's own stream name, exactly as above.

   ```sh
   docker compose -f /home/dmorozov/Work/SmartHome/hub/compose.yaml restart go2rtc
   ```

   Verify at `http://192.168.68.81:1984/` → the stream → **links → MSE**,
   and verify the *second* producer separately, because the UI does not
   show it:

   ```sh
   curl -m 8 -o /dev/null -w '%{size_download}\n' \
     'http://127.0.0.1:1984/api/stream.mjpeg?src=wyze_family_room'
   ```

   Anything other than `0` is a pass. `0` means the `ffmpeg:` line is
   missing or misspelled — or the camera is one of the two floodlights,
   see the defect below.
6. Bind it on the Panel: one `stream:` line in
   `panel/assets/house/bindings.yaml` next to the camera's `entity:`,
   naming the go2rtc key and nothing else (`wyze_family_room` — never a
   URL; the parser refuses `:`/`/`/`@` precisely so a pasted RTSP password
   cannot reach the Panel's log). Only `cam-garage` and `cam-living` have
   a Key to bind to today — see §2.4.

### 2.2.1 Result — all five, 2026-08-15

Enabled in the app and measured from the Hub host the same day. **Nothing
was flashed**: the firmware already had it.

| Camera | H.264 (web/MSE) | MJPEG (appliance) |
|---|---|---|
| Family Room `.57` | ✅ | ✅ |
| Living Room `.69` | ✅ | ✅ |
| Back Yard Door `.63` | ✅ | ✅ |
| Garage Door `.54` *(floodlight)* | ✅ | ⚠️ cold-start defect |
| Back Yard `.62` *(floodlight)* | ✅ | ⚠️ cold-start defect |

Stream format is **H.264 1920×1080 @ 20 fps** plus PCM mu-law audio.
Teardown is clean — every consumer returns to 0 and every producer to an
idle stub when the last viewer leaves, so the #177014 discipline the Ring
doorbell needs holds for these too.

**The floodlight question is settled: the Feb-2026 RTSP firmware DOES
cover the v3-based Floodlight bundle.** Research §3.2 marked that
UNVERIFIED and this chapter told you not to try one until a plain v3 had
succeeded. Both floodlights serve H.264 exactly like the plain v3s.

#### What a "Floodlight bundle" actually is — one camera, one lamp

Owner clarification, 2026-08-15, and worth stating because the phrase
invites the wrong reading. A Floodlight bundle is **one Wyze Cam v3 on a
lamp mount**:

| Half | What it is | In the video path? |
|---|---|---|
| **Camera** | a Wyze Cam v3 — one lens, one RTSP stream | yes: `wyze_garage_door`, `wyze_back_yard` |
| **Floodlight** | LED fixture + its own PIR sensor | **no** — it has no video at all |

So **five cameras, five streams — not seven.** The second firmware version
in the A1 table (`1.0.0.55`) is the light controller's, not a second
camera's. The lamp switches itself on from its own onboard motion sensor,
entirely locally, with no involvement from the Hub, go2rtc or the Panel —
it worked before any of this and keeps working if the Hub is off.

**Controlling the lamp from the Panel is a separate, cloud-only job that
has not been started.** Wyze publishes no device-control API (§3.0 of the
HACS table below); the only path is `SecKatie/ha-wyzeapi` via HACS, which
reverse-engineers the Wyze app's cloud API. So the same physical unit
would be **`local` for its video and `cloud` for its light** — the video
path earned `local` here, and nothing about that transfers to the lamp.
Two further gates: HACS is not installed yet, and there is no `light-*`
Key drawn for either lamp, so a Placement would have to be authored in
Sweet Home 3D first (ADR-0005, same session as **F1a**).

#### ⚠️ The two floodlight units are slow to start

Not a defect in this config — a property of those two units. Measured
cold, time to first frame on the H.264 path:

| Unit | Cold start |
|---|---|
| Family Room, Living Room, Back Yard Door | **4.6 – 5.2 s** |
| Garage Door, Back Yard *(floodlight)* | **17.0 – 17.9 s** |

No overlap between the groups, and **RF does not explain it** — Family
Room has *worse* ping latency (17.2 ms avg) than Back Yard (12.6 ms) and
still starts in 5 s. Which units are slow is measured; *why* is not. The
lamp fixture is the only known difference between the groups, so the
correlation is stated and the causation is not.

**What that costs, per transport:**

- **Web (H.264/MSE)** — works on all five; the floodlights just take ~18 s
  to picture instead of ~5 s. Well inside the Popup's 30 s deadline, but
  `LiveVideoPhase.connecting` will be on screen a long time, which is
  exactly why §B insists that phase be honest rather than cosmetic.
- **Appliance (MJPEG)** — a **cold** request to either floodlight returns
  HTTP 200 and **zero bytes**. The mjpeg producer reads from go2rtc's own
  stream name, and go2rtc answers that DESCRIBE before the upstream
  producer has established what tracks exist, so ffmpeg gets an empty SDP
  and exits with `Output file does not contain any stream`. Warm the
  source — pull `/api/stream.mp4` for a few seconds — and the same camera
  serves MJPEG normally (12.25 MB, first byte at 6.5 s). The three plain
  v3s start inside the race and never hit it. This is the silent
  zero-bytes failure §B1 warns about, arriving from a direction §B1 did
  not anticipate.

**Tried and does not work:** `#timeout=30` on the mjpeg producer. That
param sets the RTSP *input* timeout and this is not a timeout — ffmpeg
connects fine and finds nothing to map. Measured 2026-08-15; recorded so
the next reader does not spend the same hour.

#### 2.2.2 Five cameras at once needs the substream — this is a Wi-Fi house

The finding that shaped the Cameras view, measured 2026-08-15 after all five
were streaming individually:

| How they are opened | Result |
|---|---|
| One at a time | **all five work**, every time |
| All five at once | 1–2 fail, and *which* ones changes per run |
| Staggered 2 s apart | still 1–2 fail, a different pair again |

The error is ffmpeg's `Host is unreachable` — an *immediate* network
failure, not a timeout, so no deadline anywhere can fix it. The cause is the
topology:

- **Wyze Cam v3 is 2.4 GHz only.** The Hub host is on **5 GHz at −66 dBm**.
  So every frame crosses the air **twice** — camera→AP on 2.4, AP→host on 5.
- Packet loss to the cameras is **10–20% even at idle**, and it moves around.

**There is no cable coming.** Owner constraint, stated 2026-08-15: this
environment is **Wi-Fi only, permanently**. The Hub host has an `enp162s0`
and it will never be plugged in. Anyone reading a `Host is unreachable` here
and reaching for Ethernet is reaching for something that does not exist.

So the fix is to spend less airtime, and the cameras already offer the means:
**`/stream1` is 640×360** against `/stream0`'s 1920×1080 — about a ninth of
the pixels. Both can be pulled from one camera *simultaneously* (measured).
The Panel therefore:

- plays the **substream in every Cameras-view tile** (`substream:` in
  `bindings.yaml`, `wyze_*_sub` in `go2rtc.yaml`) — a tile is ~400 px wide
  and has no use for 1080p;
- plays the **full stream only when one camera fills the screen** — tapping a
  tile zooms it, which replaces the grid and so stops the other four.

Measured after the change: **all five substreams opened at once, all five
delivered.** That is the difference between the Cameras view working here and
not.

**Bandwidth, measured:** H.264 ~100 kB/s per camera; MJPEG ~1.3 MB/s.
That MJPEG figure is **7× what phase-4 §B measured** against the 640×480
selftest pattern, because these are 1080p — five tiles of it is roughly
50 Mbit, which is the number to size the Cameras view against.

Known limit that still stands: **no RTSP for Cam v4** (a firmware change
actually broke bridge RTSP there). Not relevant to this fleet — all five
units are v3.

**Gate: passed.** All five stream, so nothing here goes through the
bridge (§2.3) and no unit is ever flashed. Path B stays written down for
a future non-v3 camera, not for these.

### 2.3 Path B — docker-wyze-bridge for the rest

Cloud auth, local-ish transport: streams pull over LAN/TUTK but the
cameras need internet to initialise, so these bind `connectivity: cloud`.

Two corrections to the compose snippet in phase-4 §A3, both from §3.2 —
apply them before pasting it:

- **Use the IDisposable fork, not mrlt8 upstream.** Upstream is dormant
  (last release v2.10.3, 2024-09-13); the maintained successor is
  `idisposablegithub365/wyze-bridge` (v4.5.0, 2026-07-02). Pin the exact
  tag at first bring-up, like every other image in this stack.
- **`network_mode: host` is mandatory** since Wyze's 2025 auth change
  (bridge issue #1517), which means the snippet's `8557:8554` remap
  cannot work — under host networking there is nothing to remap, and
  8554 already belongs to go2rtc on this host. The bridge's RTSP port
  must therefore be moved via its own configuration. **The env var name
  for that is UNVERIFIED** — read it off the fork's README at build time
  rather than guessing; getting it wrong means go2rtc or the bridge
  silently loses its listener.

Credentials go in `~/.sh_keys/wyze.env`, outside the repo entirely (ADR-0010
— superseded the earlier plan of a gitignored `hub/*.env`), never in
`compose.yaml`: Wyze email, password, and the API Key ID / API Key pair from
the Wyze developer console. **The API Key ID / API Key half is done,
2026-08-07** — obtained from `developer-api-console.wyze.com` and stored at
`~/.sh_keys/wyze.env`. The Wyze *account* email/password for the bridge's own
login still needs adding alongside it once the bridge path (rather than the
RTSP-flash path) is actually chosen for a given unit.

Pin camera firmware and **disable auto-update** on every bridge-dependent
unit. Wyze's firmware churn broke every bridge fork for months in 2025;
treat it as a standing reliability risk, not a one-off.

### 2.4 Three camera Keys, five cameras — and only two of them line up

`house.yaml` has exactly three `cam-*` Keys — `cam-garage`, `cam-living`,
`cam-office` — plus `doorbell`. B3 settled what they have to cover, and the
conditional this section used to be written as is now a fact: **all five
Wyze units are cameras**, and the fit is worse than a shortfall of two.

| Camera (A1) | Key |
|---|---|
| Garage Door Cam | `cam-garage` — name match |
| Living Room Cam | `cam-living` — name match |
| Family Room Cam | **none** |
| Back Yard Cam | **none** |
| Back Yard Door Cam | **none** |
| — | `cam-office`: a Key with **no camera behind it** |

So **two** cameras can be bound today, three have nowhere to go, and one
Key points at a camera this house does not own. Do not be tempted to spend
`cam-office` on one of the homeless three: a Key carries the Placement it
was drawn at, so binding the Family Room camera to `cam-office` puts its
pin in the Office and makes the Dollhouse lie about where the picture comes
from — the one thing the Dollhouse is for.

Per ADR-0005 a new Key is authored in the drawing (Sweet Home 3D on the
Mac → `tool/sh3d_to_yaml.py` → `dart run tool/gen_dev_entities.dart`), not
by editing `bindings.yaml`. That session is **F1a** in TODO.md, which names
the three tags to draw (`cam-family`, `cam-backyard`, `cam-backyard-door`)
and is owner-only. It does not block §2.2: enable RTSP and bind the two
that fit, and the other three land the moment their tags exist.

---

## 3. HACS — prerequisite for the phase-5 group

### 3.0 Why this house needs it at all

HACS (Home Assistant Community Store) is a distribution channel for
integrations that aren't in HA core — not a marketplace HA runs, just a
package manager pointed at GitHub repos, with no vetting bar beyond what a
maintainer chooses to publish. Nothing in this house *needs* HACS as a
concept; three specific devices need it because their only HA integration
happens to live outside core, each for a different reason (verified against
[`../../docs/research/hub-and-device-integrations.md`](../../docs/research/hub-and-device-integrations.md),
this repo's own vendor-by-vendor survey):

| Device | Why it isn't in HA core | HACS integration |
|---|---|---|
| Petlibro One + Granary feeders | A small, recent vendor with no official HA relationship — the integration is community-written, explicitly "Alpha/WIP but active" | `jjjonesjr33/petlibro` |
| Emporia Vue 3 (cloud path) | **Emporia has no public API at all.** Their own support article acknowledges community projects exist but states they are unsupported — there is no vendor-sanctioned interface for HA core to build against, so this can only ever be a reverse-engineered community project, in HACS, forever, regardless of how well-maintained it gets | `magico13/ha-emporia-vue` (not even in HACS's default store — added as a custom repository, §7) |
| Wyze cameras, *device control only* — optional, not camera video | Wyze issues no official device-control API for third parties; `ha-wyzeapi` reverse-engineers the Wyze app's own cloud API. (Wyze camera **video** does not need this at all — the official RTSP firmware feeds go2rtc directly, no HACS, no Wyze account touches HA) | `SecKatie/ha-wyzeapi` |

Contrast with the Ecobee and Rachio (§4.2, §4.3): both have official,
HA-core-maintained integrations because both vendors publish something HA's
maintainers can build against and keep working. HACS exists for the devices
where that vendor-side prerequisite is simply absent.

### 3.1 Install — DONE 2026-08-07, agent work, no owner needed

The install itself needs no credentials and no sudo — `docker` runs
unprivileged for the repo user on this host. Run the upstream script inside
the container (the redirect resolves and returns 200:
`get.hacs.xyz` → `raw.githubusercontent.com/hacs/get/main/get`; `bash` and
`wget` are both present in the image), then restart:

```sh
docker exec homeassistant bash -c "wget -O - https://get.hacs.xyz | bash -"
docker restart homeassistant
```

**Use `docker restart`, not `docker compose restart`, if you're doing this
from inside the devcontainer.** `docker compose` needs to resolve
`hub/compose.yaml`'s path, which is where ADR-0010's devcontainer-vs-host
hazard lives (see `COMMISSIONING.md`, "Two Home Assistants on one box," for
the related trap); a plain `docker restart <container>` sidesteps that
entirely for a simple restart. Verified: HA came back with `We found a
custom integration hacs which has not been tested by Home Assistant` in the
log (expected — that warning fires for every custom component, not a
problem) and `/config/custom_components/hacs/config_flow.py` present.

**Watch where it lands.** `compose.yaml` bind-mounts
`hub/custom_components` to `/config/custom_components`, and that
directory **is tracked in git** (it holds our own extensions slot — see
`hub/custom_components/README.md`). The installer writes a full
`hacs/` tree there — it now shows up in `git status` as several thousand
untracked files. **Decide before committing anything:** either gitignore
`custom_components/hacs/` or accept vendoring it. Nothing in this repo
policy decides that for you, and nothing has been staged either way.

HACS's own updates are manual. That suits the Hub's pinned-and-deliberate
version policy — it is not a defect to work around.

### 3.2 Complete the setup — GitHub device-code auth, owner action — DONE 2026-08-07

This is the part that needs you: a GitHub account and a browser. Quoted
verbatim from the installed `hacs/translations/en.json` and
`hacs/config_flow.py` — not from memory, and re-verified against this
Hub's actual install, not HACS's public docs.

1. Settings → Devices & services → Add integration → search **"HACS"**.
   (`single_instance_allowed` is enforced — if a HACS entry already exists,
   this card won't offer itself again; that's not a bug, use Reconfigure
   on the existing entry instead.)
2. **Four checkboxes, all required** — the form's own description reads
   *"Before you can setup HACS you need to acknowledge the following"*:
   - "I know how to access Home Assistant logs"
   - "I know that there are no add-ons in HACS"
   - "I know that everything inside HACS including HACS itself is custom
     and untested by Home Assistant"
   - "I know that if I get issues with Home Assistant I should disable all
     my custom_components"

   Leaving any one unchecked shows *"You need to acknowledge all the
   statements before continuing"* and re-shows the same form — there's no
   partial credit. Check all four, submit.
3. HA immediately contacts GitHub's device-registration API and shows a
   progress screen, titled **"Waiting for device activation"**, with this
   exact template filled in: *"1. Open {url} — 2. Paste the following key
   to authorize HACS: `{code}`"*, where `{url}` is
   **`https://github.com/login/device`** and `{code}` is a short code
   generated fresh for this attempt (different every time — don't reuse
   one from a doc example or a previous try).
4. On your phone or another tab, open `https://github.com/login/device`,
   sign in to GitHub if needed, and paste the code shown on the HA screen.
   GitHub will ask you to authorize the app.
5. Back on the HA screen: it's polling in the background, no further
   action needed there. Once GitHub confirms the authorization, the flow
   completes on its own and creates the HACS entry — no explicit "submit"
   step after pasting the code on GitHub's side.
6. If something goes wrong contacting GitHub at step 3 (network, GitHub
   outage), HA aborts with *"Could not authenticate with GitHub, try again
   later"* — retry by starting the Add Integration flow again, not by
   waiting on the same stuck screen.

No password ever touches Home Assistant in this flow — the device-code
exchange is GitHub's own OAuth mechanism; HA only ever sees the resulting
access token, stored in the config entry.

**Verified against the running Hub, not just "the form closed without an
error":** config entry `01KZDDD6TH4CKTE9FZT1XH102B`, domain `hacs`,
`state: loaded`, on **production** (port 8123 — not `hub/dev`'s 18123, see
`COMMISSIONING.md`'s "Two Home Assistants"). The `update.hacs_update` entity
exists, which only gets created once HACS's coordinator actually
initializes — a stub or failed entry wouldn't produce it. No errors in the
log after restart, just the one expected "untested custom integration"
warning every custom component logs once at load.

---

## 4. LG washer + dryer — core `lg_thinq` (phase 5)

Cloud push, officially sanctioned API, no local path in existence (§3.10).

**Credential:** a Personal Access Token from `connect-pat.lgthinq.com`
(reachable, HTTP 200 checked 2026-08-04), created while signed in as the
LG account the appliances are actually registered to. Then in HA: add the
**LG ThinQ** integration, paste the PAT, pick the country.

Caveats worth knowing before you bind anything:

- **PAT lifetime is UNVERIFIED.** Treat it as a re-pairing cliff of
  unknown length: record the issue date somewhere durable, and expect
  laundry entities to go stale rather than error loudly if it lapses.
- Legacy models poll every 5 minutes instead of pushing; energy data is
  historical (through yesterday), not live.
- Open HA issue #172035: on at least one washer model remote start
  switches the program to Cotton, and the power entity fails to update on
  some models. Do not build a Panel affordance on remote start.
- Remote start only works when the machine is physically armed for it —
  a vendor safety behaviour, not something HA can bypass.

Bindings (`washer` and `dryer` Keys both exist, both `StatusState`):

```yaml
  washer:
    entity: sensor.<washer>_run_state     # exact ids from HA
    connectivity: cloud
  dryer:
    entity: sensor.<dryer>_run_state
    connectivity: cloud
```

The HACS alternative `ollo69/ha-smartthinq-sensors` exposes more entities
on some models via the older unofficial API — it is a fallback if a
specific entity is missing, not the default choice.

---

## 5. Litter-Robot 5 Pro — core `litterrobot` (phase 5)

Cloud only; Whisker publishes no API and no local one exists (§3.7). The
integration is branded **Whisker (Litter-Robot)** in HA and takes the app
account's email and password — nothing else.

Arrives as a vacuum entity plus sensors (litter level, waste-drawer
level, pet weight, cycle counts), switches (night light, panel lockout,
sleep mode) and buttons.

**The LR5 Pro camera is not exposed in HA.** The underlying library
supports it (REST + WebRTC since pylitterbot 2025.5.0); HA does not wire
it in. Camera on the Panel means the Whisker app or custom code — not a
binding. Do not plan it.

```yaml
  litter-robot:
    entity: sensor.<litter_robot>_status
    connectivity: cloud
```

---

## 6. Petlibro One + Granary feeder — HACS `petlibro` (phase 5)

One HACS integration (`jjjonesjr33/petlibro`) covers both feeders.
Cloud-based against Petlibro's own API — **not** Tuya, so no Tuya or
LocalTuya path exists (§3.9). Polls every 60 s. Self-described alpha/WIP
but actively developed.

**The account quirk is the whole story here: Petlibro allows one login
per account.** Sign HA in with the family's account and the phone app
gets logged out. So: create a **second Petlibro account** for the Hub and
share the devices to it. Do this before touching HA.

Whether the integration appears in the HACS default store is
**UNVERIFIED**. If a search for "Petlibro" finds nothing, add
`https://github.com/jjjonesjr33/petlibro` as a custom repository in the
Integration category, then install, restart HA, and add the integration.

Model coverage is the other UNVERIFIED bit (§3.8–3.9): PLAF301 (One RFID)
is explicitly on the supported list and PLAF203 (Granary camera feeder)
is listed too, but the Granary's **camera feed is upstream WIP and is not
expected to stream**. After setup, record which entities each model
actually produced in
[phase-5-cloud-fleet.md](../../docs/plans/device-integrations/phase-5-cloud-fleet.md).

```yaml
  feeder-petlibro:
    entity: sensor.<petlibro_one>_<best-status-entity>
    connectivity: cloud
  feeder-granary:
    entity: sensor.<granary>_<best-status-entity>
    connectivity: cloud
```

If a model turns out unsupported, leave its `entity:` off entirely — the
pin renders with unknown state, which is the honest representation — and
file an upstream issue. Do not substitute a stand-in.

---

## 7. Emporia Vue 3 + Emporia plugs — HACS, cloud for now (D2) — DONE 2026-08-08

Emporia publishes no API and **no Vue device has any local network
interface** on stock firmware — the vendor says so itself (§3.4). So the
stock path is cloud, at 1-minute granularity.

**D2: take the cloud path now; the ESPHome reflash is a separate bench
day, deliberately deferred.** It needs the case open and a wired UART
flash — it must not block this plan.

### 7.1 What was done

1. **Custom repository, added via HACS's own dialog** (three-dot menu →
   **"Custom repositories"** — label quoted from the live, installed
   `hacs_frontend` bundle, not guessed): URL
   `https://github.com/magico13/ha-emporia-vue`, category **Integration**
   (`common.type.integration` in the same bundle). Per §3.4 this
   integration is **not in HACS's default store**, so this step is
   mandatory, unlike a normal HACS install.
2. **Download**, then the HACS-raised **Repairs** issue ("Restart
   required… click submit to restart now") worked through, or a plain
   `docker restart homeassistant` — same devcontainer path caveat as the
   HACS install itself (§3.1).
3. **Settings → Devices & Services → Add Integration → "Emporia Vue"** —
   the owner typed the Emporia app account's **email and password** into
   the HA UI directly; nothing was pasted into an agent session.

### 7.2 What it produced — verified against production, not assumed

`config_entries/get` against **production** (port 8123, not 18123 — see
the two-instances warning up top): entry `01KZFNVXV01M73F63FS8EQ19S4`,
domain `emporia_vue`, `state: loaded`, `title: "den.morozov@gmail.com
(208781)"`.

**58 entities** landed, across **19 devices** in the registry — 16 CT
channels on the Vue 3 itself, plus the two channels the owner has already
named (`A/C`, `Balance`), plus one separate physical Emporia smart plug
(`Computer`) — grouped below by what they represent rather than listed
device-by-device, since 16 of the 19 currently share one vendor-default
name (`config/device_registry/list`, cross-referenced by `device_id`; the
entity list alone doesn't distinguish them):

| Device | Model | What it is | Entities |
|---|---|---|---|
| Home Main Panel | `VUE003` (the Vue 3 itself) | The whole panel's own reading — the **only one of the 16 numbered channels that carries the real total**, not a per-circuit tap | `sensor.home_main_panel_power_minute_average` (768.5 W live) + 15 more identically-named siblings (`_2`…`_16`) for the other 15 CT channels, none yet renamed off the Emporia default in the vendor app |
| A/C | `VUE003` (a channel on the same Vue 3) | A branch circuit the owner has already named in the Emporia app | `sensor.a_c_power_minute_average`, `_energy_this_month`, `_energy_today` |
| Balance | `VUE003` (a channel on the same Vue 3) | Another owner-named branch circuit | `sensor.balance_power_minute_average`, `_energy_this_month`, `_energy_today` |
| Computer | `SSO001` (an Emporia smart plug, a separate physical device) | A switched outlet with its own power reading | `switch.computer` (currently `on`), `sensor.computer_power_minute_average`, `_energy_this_month`, `_energy_today` |

**Picking `sensor.home_main_panel_power_minute_average` for the
`energy-monitor` Key was not a naming guess.** The 16 numbered
`home_main_panel_power_minute_average*` entities are 16 **separate**
devices in the registry (`config/device_registry/list` — each its own
`device_id`, all model `VUE003`), every one still carrying the vendor's
default device name, `Home Main Panel` — so the registry alone says only
"this is a Vue 3 channel," not which channel is the whole-panel total.
That took an arithmetic check instead: the unsuffixed entity
(768.544044494629 W) equals the sum of the other 15 numbered channels
(744.304109… W) **plus** `sensor.balance_power_minute_average`
(24.239935… W) to within floating-point noise (`4.5e-13`) — i.e. "Balance"
is Emporia's own computed remainder, mains total minus every individually
clamped branch, and the unsuffixed channel is the only one whose value is
consistent with being that mains total rather than one more branch.

```yaml
  energy-monitor:
    entity: sensor.home_main_panel_power_minute_average   # W-valued; PowerState kind
    connectivity: cloud
```

**Not yet done, and it blocks anything below the whole-house total:** the
16 main-panel channels are still on Emporia's default naming — only two
circuits (`A/C`, `Balance`) have been named by the owner in the Emporia
app so far. Binding any individual breaker to a Panel Key needs that
channel named first; until then `energy-monitor` is the only usable pin
out of this integration.

**Foot-gun before binding an Emporia plug to an `outlet-*` Key:** per
ADR-0006 togglability follows from the Device kind, so an `outlet` Key is
togglable from the Panel with no confirmation step. Only three outlet
Keys exist (`outlet-outdoor-a`, `outlet-outdoor-b`, `outlet-master`), and they
are already contended for by the local Kasa sockets. Bind a plug there
only if a stranger tapping it can do no harm.

The reflash, when that day comes: `emporia-vue-local` ESPHome fork,
**`vue3` branch** (the component is not in upstream ESPHome), official
flashing docs, **back up the stock firmware first** — flashing removes
the Emporia app and cloud until restored. GPIO0 grounded at power-on, a
strong 3.3 V supply (brownouts are reported), Vue 3 needs different I²C
calibration than Vue 2, and bricking reports exist. The payoff is 5-second
local data. When it lands, entity ids change and `connectivity` flips to
`local` — a `bindings.yaml`-only edit, which is exactly what the seam is
for.

---

## 8. SmartThings oven — D3, a decision, not a build task

**Do not build this.** It is on the repo's calendar, not in any phase.

The facts that make it a decision:

- Samsung limited newly created Personal Access Tokens to 24-hour
  validity on 2024-12-30, so the old token path is dead. HA's rewritten
  `smartthings` integration uses browser OAuth account-linking instead
  (exact flow mechanics **UNVERIFIED** this session).
- Cloud Push; **no local option exists** for SmartThings appliances.
- Free SmartThings API access begins phasing out in **October 2026**,
  replaced by a $4.99/mo "Personal Plan". Rate limits and any free tier
  are unpublished.
- What the oven would give you is **monitoring plus a Stop button**:
  `ovenMode`, `ovenOperatingState` (job state, completion time),
  `ovenSetpoint`, temperatures, a cavity binary sensor. Not remote
  cooking control.

The `oven` Key exists in `house.yaml` and is bound to a dev stand-in. If
D3 goes the other way, it stays bound to a stand-in or gets its `entity:`
removed — an unknown-state pin is the honest rendering of a device the
Hub cannot see. The dated warning also lives in
[`../../hub/README.md`](../../hub/README.md); keep the two in agreement.

---

## 9. Where the credentials land

No credential in this chapter belongs in a tracked file. Since ADR-0010,
that means `~/.sh_keys/` outside the repo for anything this stack owns the
path for; everything a vendor issues through an HA config-flow UI (Ring,
LG, Whisker, Petlibro, Ecobee, Emporia) lives in HA's own
`hub/ha-config/.storage` instead, deliberately not moved there — see
[ADR-0010](../../docs/adr/0010-secrets-consolidated-outside-the-repo.md)
for why. For reference, by path:

| Secret | Path | Notes |
|---|---|---|
| Ring refresh token | `~/.sh_keys/ring-mqtt/ring-state.json` | 0600; the only unrecoverable one (was `hub/ring-mqtt-data/`, ADR-0010) |
| ring-mqtt's broker password | `~/.sh_keys/ring-mqtt/config.json` | the `ring` broker user (was `hub/ring-mqtt-data/`, ADR-0010) |
| Broker user passwords | `~/.sh_keys/broker-passwords.env` | 0600 (was `hub/.broker-passwords.env`, ADR-0010) |
| Panel's long-lived HA token | `~/.sh_keys/token` | 0600 (was `hub/token`, ADR-0010) |
| Wyze bridge account + API key | `~/.sh_keys/wyze.env` | ADR-0010; the API key pair is in, the bridge account itself is not yet (only needed if the docker-wyze-bridge path is chosen over RTSP-flash) |
| Ring, LG PAT, Whisker / Petlibro / Ecobee / Emporia logins | `hub/ha-config/.storage` | typed into the HA UI only; gitignored — HA owns this format internally, so it stays out of `~/.sh_keys` on purpose |
| Camera RTSP credentials | `~/.sh_keys/go2rtc/go2rtc.yaml` | stream URLs embed them (was `hub/go2rtc/go2rtc.yaml`, ADR-0010) |

Whatever backup covers `hub/ha-config/.storage` must cover `~/.sh_keys/`
too, for the reason in §1.2 — as two separate tarballs (Ch. 2 §8), since
ADR-0010 moved the latter fully outside `hub/`.

---

## 10. What binding any of this breaks in the Panel

Three consequences that the phase plans do not all mention:

1. **`panel/test/bindings_drift_test.dart` goes red.** It holds
   `const _integrated = <String>{};` — the ledger of Keys whose bindings
   have moved to real hardware and are therefore expected not to resolve
   against the dev-Hub stand-ins. Every Key rebound in this chapter must
   be added to that set in the same commit.
2. **Bindings are validated fatally at boot.** `bindings_parser.dart`
   requires `^[a-z_]+\.[a-z0-9_]+$` for entity ids, exactly one entity
   per Device, a mandatory `connectivity:` of `local` or `cloud`, and the
   Key sets in `house.yaml` and `bindings.yaml` to match exactly both
   ways. A typo'd entity id does not degrade — the Panel refuses to boot.
3. **Nothing in this chapter may claim `connectivity: local`** except a
   successfully RTSP-flashed Wyze camera (§2.2) and, later, a reflashed
   Emporia (§7). Everything else is cloud and is displayed as such —
   second-class by design, not by oversight.
