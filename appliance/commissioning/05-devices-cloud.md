# 5 — The cloud fleet: Ring, Wyze, and the account devices

**None of this is set up. This chapter is instructions, not an as-built
record.** Every earlier chapter describes something that exists on this
machine and was measured. This one describes work that has not been done:
no Ring account is authenticated, no camera streams, HACS is not
installed, and no LG / Whisker / Petlibro / Emporia entity exists in Home
Assistant. Where a value has to come off the operator's own device or
vendor account, it says so; where the repo's research left something
open, it is marked UNVERIFIED rather than guessed into a step.

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
| HACS | no — `/config/custom_components` holds only `README.md` | n/a | 5 | cloud at install time only |
| LG washer + dryer (`lg_thinq`) | no | n/a | 5 | cloud |
| Litter-Robot 5 Pro (`litterrobot`) | no | n/a | 5 | cloud |
| Petlibro One + Granary (HACS) | no | n/a | 5 | cloud |
| Emporia Vue 3 + plugs (HACS) | no | n/a | 5 | cloud now, local after reflash (D2) |
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
`hub/ring-mqtt-data/ring-state.json`, gitignored by the `ring-mqtt-data/*`
rule — and begins device discovery. Because MQTT discovery is on, the
doorbell materialises in HA on its own; no config flow to drive.

### 1.2 The refresh token IS the re-pairing cliff

`ring-state.json` holds the refresh token. It is the only credential in
this stack whose loss costs a human being a live 2FA session, and it
therefore governs three operational rules:

1. **Back it up with the rest of the runtime state.** The migration list
   in [`../../hub/README.md`](../../hub/README.md) names `ha-config/.storage`,
   `z2m-data`, and Mosquitto persistence; `ring-mqtt-data/` belongs on
   that list too, and does not currently appear on it.
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

That is `classifyDing()`'s **word shape** (rules 3–4), not the timestamp
shape, and the difference is a real cost rather than a style point: a press
that is the first thing the Panel hears about this entity after a gap is
**lost**, because `on` restored from before the gap is byte-identical to `on`
from a finger on the button. Only the next press rings.
`panel/lib/domain/doorbell.dart` argues the alternative — ringing on first
sight rings the house on every HA restart, and §1.4's #177014 turns that into
a doorbell that then misses the real press.

**There is a way to buy the timestamp shape back, and it is deliberately not
wired.** `binary_sensor.front_door_ding` carries a `lastDingTime` attribute
(ISO-8601; it read `"2026-08-01T01:33:04Z"` at commissioning). A template
sensor exposing that as its **state** would give the classifier rule 2 —
press-time identity plus a freshness window:

```yaml
# NOT INSTALLED — see the caveat below before you add this.
template:
  - sensor:
      - name: "Front Door Ding At"
        state: "{{ state_attr('binary_sensor.front_door_ding','lastDingTime') }}"
```

**UNVERIFIED:** whether ring-mqtt updates that attribute at the *instant* of
the ding, or on some slower refresh. Only a real button press settles it, and
a template that lags is a doorbell that rings late — worse than one that rings
on a plain `on`. Press the button, watch the attribute, then decide.

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

| IP | MAC |
|---|---|
| 192.168.68.54 | d0:3f:27:53:25:72 |
| 192.168.68.57 | d0:3f:27:8d:cc:54 |
| 192.168.68.62 | d0:3f:27:8e:4f:b1 |
| 192.168.68.63 | d0:3f:27:4a:95:76 |
| 192.168.68.69 | d0:3f:27:49:b2:f6 |

To re-list them at any time (unprivileged; the pings are only there to
populate the neighbour cache):

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
app ≥ 3.9, enabled in the camera's Advanced Settings. So the first check
is not a flash at all:

1. **Look in the Wyze app** for an RTSP option in the target camera's
   advanced settings once it is on current firmware. Whether these
   specific units are already on that firmware is **UNVERIFIED** — read
   it off the app.
2. Only if the toggle is absent does the older sideload path apply
   (FAT32 microSD, `demo.bin` in the root, hold setup while powering).
   Note that phase-4 §A2 still describes that older `demo_V3_RTSP` line
   (4.61.0.3) — it predates the production firmware in §3.2. **If the
   production firmware exposes RTSP, use it and skip the demo build.**
3. Set the stream credentials in the app and note the URL:
   `rtsp://user:pass@<cam-ip>/live`.
4. Reserve the camera's address by MAC in the Deco app, then add it to
   `hub/go2rtc/go2rtc.yaml` (gitignored — stream URLs embed camera
   credentials):

   ```yaml
   streams:
     wyze_<location>: rtsp://user:pass@<cam-ip>/live
   ```

   ```sh
   docker compose -f /home/dmorozov/Work/SmartHome/hub/compose.yaml restart go2rtc
   ```

   Verify at `http://192.168.68.81:1984/` → the stream → **links → MSE**.

Known limits, to accept knowingly: **no RTSP for Cam v4** (a firmware
change actually broke bridge RTSP there), and whether the Feb-2026
firmware covers the v3-based Floodlight bundle is **UNVERIFIED** —
floodlights are not candidates until a plain v3 succeeds and a floodlight
is tested deliberately.

**Gate:** one flashed unit streaming reliably for a few days → flash the
remaining v3-class units one at a time. Firmware unobtainable or stream
flaky → everything goes through the bridge.

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

Credentials go in a gitignored `hub/*.env` (the `*.env` rule in
`hub/.gitignore` already covers it), never in `compose.yaml`: Wyze email,
password, and the API Key ID / API Key pair from the Wyze developer
console.

Pin camera firmware and **disable auto-update** on every bridge-dependent
unit. Wyze's firmware churn broke every bridge fork for months in 2025;
treat it as a standing reliability risk, not a one-off.

### 2.4 There are three camera Keys and up to five cameras

`house.yaml` has exactly three `cam-*` Keys — `cam-garage`, `cam-living`,
`cam-office` — plus `doorbell`. If four or five of the Wyze units turn
out to be cameras worth showing, **the extra ones have nowhere to bind**.
Per ADR-0005 a new Key is authored in the drawing (Sweet Home 3D on the
Mac → `tool/sh3d_to_yaml.py` → `dart run tool/gen_dev_entities.dart`), not
by editing `bindings.yaml`. Plan for that session, or decide deliberately
that two cameras stay off the Panel.

---

## 3. HACS — prerequisite for the phase-5 group

Three integrations in this chapter come from HACS rather than HA core:
`petlibro` (covers both feeders), `ha-emporia-vue`, and — optionally, if
Wyze *device* control is ever wanted beyond video — `ha-wyzeapi`.

Install on HA Container by running the upstream script inside the
container. The redirect resolves and returns 200 as of 2026-08-04
(`get.hacs.xyz` → `raw.githubusercontent.com/hacs/get/main/get`); `bash`
and `wget` are both present in the image:

```sh
docker exec -it homeassistant bash -c "wget -O - https://get.hacs.xyz | bash -"
docker compose -f /home/dmorozov/Work/SmartHome/hub/compose.yaml restart homeassistant
```

Then add the HACS integration in HA and complete **GitHub device-code
auth** (HA shows a code; you enter it on GitHub in a browser). Exact HA
menu wording is **UNVERIFIED** — it is the normal "add an integration"
flow, searching for HACS.

**Watch where it lands.** `compose.yaml` bind-mounts
`hub/custom_components` to `/config/custom_components`, and that
directory **is tracked in git** (it holds our own extensions slot — see
`hub/custom_components/README.md`). The installer writes a full
`hacs/` tree there, so it will show up in `git status` as several
thousand untracked files. Decide before committing anything: either
gitignore `custom_components/hacs/` or accept vendoring it. Right now the
directory contains only `README.md` (verified inside the container),
so the diff is unambiguous.

HACS's own updates are manual. That suits the Hub's pinned-and-deliberate
version policy — it is not a defect to work around.

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

## 7. Emporia Vue 3 + Emporia plugs — HACS, cloud for now (D2)

Emporia publishes no API and **no Vue device has any local network
interface** on stock firmware — the vendor says so itself (§3.4). So the
stock path is cloud, at 1-minute granularity.

**D2: take the cloud path now; the ESPHome reflash is a separate bench
day, deliberately deferred.** It needs the case open and a wired UART
flash — it must not block this plan.

The integration is `magico13/ha-emporia-vue`, and per §3.4 it is **not in
the HACS default store** — add it as a custom repository. Credentials are
the Emporia app account's email and password. Vue 3 arrives as per-circuit
power sensors; Emporia smart plugs arrive as switches with power readings.

```yaml
  energy-monitor:
    entity: sensor.<vue3>_total_power     # W-valued; PowerState kind
    connectivity: cloud
```

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

No credential in this chapter belongs in a tracked file. For reference,
by path:

| Secret | Path | Notes |
|---|---|---|
| Ring refresh token | `hub/ring-mqtt-data/ring-state.json` | 0600, gitignored; the only unrecoverable one |
| ring-mqtt's broker password | `hub/ring-mqtt-data/config.json` | gitignored; the `ring` broker user |
| Broker user passwords | `hub/.broker-passwords.env` | 0600, gitignored (`*.env`) |
| Panel's long-lived HA token | `hub/token` | 0600, gitignored |
| Wyze bridge account + API key | a new `hub/*.env` | gitignored by the `*.env` rule |
| LG PAT, Whisker / Petlibro / Emporia logins | `hub/ha-config/.storage` | typed into the HA UI only; gitignored |
| Camera RTSP credentials | `hub/go2rtc/go2rtc.yaml` | gitignored — stream URLs embed them |

Whatever backup covers `hub/ha-config/.storage` must cover
`hub/ring-mqtt-data/` too, for the reason in §1.2.

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
