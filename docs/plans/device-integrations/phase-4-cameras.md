# Phase 4 — Cameras: Wyze into go2rtc, live video into the Popup

Two halves: (A) getting every Wyze camera restreamed by go2rtc, (B) the
one substantial Panel feature of this plan — real live video in the
Popup. They can proceed in parallel; (B) can start against the phase-3
`ring_doorbell` stream before any Wyze work lands.

## A1. Inventory (10 min, do first)

List every Wyze unit: model (v3? Pan v3? floodlight — and WHICH floodlight
generation), firmware version, mounting location → which `cam-*` Key it
will bind to. The flash decision is per-model; the research (§3.2) only
vouches for v3-class. Record the list in this file when done.

**Full inventory obtained from the owner 2026-08-07** (Wyze app, cross-referenced
against the LAN scan in `appliance/commissioning/05-devices-cloud.md` §2.1 —
IPs match the 2026-08-07 re-measurement exactly, no further drift):

| Name (Wyze app) | MAC | IP | Model | Firmware | `cam-*` Key |
|---|---|---|---|---|---|
| Garage Door Cam | `d0:3f:27:53:25:72` | 192.168.68.54 | Wyze Cam v3 (Floodlight bundle) | 4.36.16.7064 (floodlight 1.0.0.55) | `cam-garage` — name match |
| Living Room Cam | `d0:3f:27:49:b2:f6` | 192.168.68.69 | Wyze Cam v3 | 4.36.16.7064 | `cam-living` — name match |
| Family Room Cam | `d0:3f:27:8d:cc:54` | 192.168.68.57 | Wyze Cam v3 | 4.36.16.7064 | none yet — new `cam-family` Key planned, §A1a |
| Back Yard Cam | `d0:3f:27:4a:95:76` | 192.168.68.62 | Wyze Cam v3 (Floodlight bundle) | 4.36.16.7064 (floodlight 1.0.0.55) | none yet — new `cam-backyard` Key planned, §A1a |
| Back Yard Door Cam | `d0:3f:27:8e:4f:b1` | 192.168.68.63 | Wyze Cam v3 | 4.36.16.7064 | none yet — new `cam-backyard-door` Key planned, §A1a |

**All five are Wyze Cam v3 — the exact model class D1 targets — and all
five are already on firmware 4.36.16.7064, newer than 4.36.16.5654, the
version that promoted RTSP from beta to production on 2026-02-02 (§3.2 of
the research doc). That means D1's premise — "flash one unit" — may not
apply at all: check each camera's Advanced Settings for an RTSP toggle
before flashing anything.** Start with a **plain v3, not a Floodlight
bundle** — Garage Door Cam and Back Yard Cam carry a second firmware
(1.0.0.55) for the floodlight controller itself, extra surface the research
doc flags as untested for this exact combination even though the base
camera RTSP support should be identical. Family Room, Living Room, or Back
Yard Door Cam are the three uncomplicated candidates for the first test.

### A1a. Three new Panel Keys needed — owner action, Sweet Home 3D

Only 2 of 5 cameras have a plausible existing Key (`cam-garage`,
`cam-living`). Family Room, Back Yard, and Back Yard Door have nowhere to
bind. **Owner decision 2026-08-07: add three new placeholder-house Keys now**
(`cam-family`, `cam-backyard`, `cam-backyard-door`) rather than wait for the
real drawing (**F1**) — matching the existing precedent of `outlet-outdoor-a`/`b`
and `light-living` (D5): Keys are stable identities, a marker's *position* in
the drawing is cheap to fix later (§3.3 of `panel/HOUSE-PLAN.md`: "drag the
marker, save, re-run the converter" — no `bindings.yaml` change if the tag
stays the same), so drawing them into the current placeholder floorplan today
costs nothing extra at F1 time beyond a drag.

This needs Sweet Home 3D on the Mac — no Linux path exists (ADR-0005) — so
it's owner-only, not something an agent session can do. Per
`panel/HOUSE-PLAN.md` §3.1, for each of the three:

1. Open the drawing with `tool/sh3d.sh` (not Sweet Home 3D directly — the
   `Placementkey` field is invisible otherwise).
2. Drag a **camera** marker from the Smart Home category into any room —
   position is a placeholder, it will move at F1.
3. Name it what the Panel should show, e.g. `Back Yard Camera`.
4. **Other properties…** → set **Placementkey** to the planned tag
   (`cam-family`, `cam-backyard`, `cam-backyard-door`) — must be unique in
   the house; leave **Kind** alone.
5. Save. Repeat for the other two.
6. From `panel/`: `python3 tool/sh3d_to_yaml.py <path>.sh3d -o assets/house/house.yaml --name "..."` — check the device count in the success line matches expectations (3 more than before).
7. Add one `bindings.yaml` entry per new tag (agent-doable once the tags
   exist) — `stream:` pointing at the eventual go2rtc stream name for each
   camera, `connectivity: local` if the RTSP-firmware path works, `cloud` if
   it ends up going through the bridge (§2.2/§2.3 of
   `appliance/commissioning/05-devices-cloud.md`).

At F1, each marker just moves to its true position — same tag, same
binding, no re-authoring.

## A2. The RTSP-flash experiment — ONE unit (D1)

Goal: a camera that serves RTSP locally with no cloud dependency —
`connectivity: local`.

### A2.−1 DONE, 2026-08-15 — all five cameras stream, nothing was flashed

**This section's experiment is over and it succeeded.** Everything below
in A2.0/A2.1 is the state a few hours earlier the same day, kept because
the sequence is what a future reader needs; the outcome is here.

The owner enabled RTSP in the Wyze app on **all five** units. No flash on
any of them — the firmware already carried the feature. All five now serve
H.264 1920×1080 @ 20 fps through go2rtc, on both transports, with clean
teardown. **That includes both Floodlight bundles**, which research §3.2
had flagged UNVERIFIED for this firmware; the caution can be retired.

Three predictions in this plan were wrong, each failing in a way that
looked like a different problem, and all three are corrected in
[Ch. 5 §2.2](../../../appliance/commissioning/05-devices-cloud.md):

1. **The path is `/stream0`, not `/live`.** With the right credentials and
   the wrong path the camera authenticates and then closes in silence —
   indistinguishable from a bad password until you send a deliberately bad
   one and get `401` instead. `hub/tool/wyze-fleet.py rtsp` now runs that
   comparison automatically, because it is the only thing that tells them
   apart.
2. **RTSPS on 322, not RTSP on 554.** 554 is open on all five and answers
   nothing at all, plaintext or TLS.
3. **go2rtc 1.9.10 cannot dial these over TLS.** Both `rtsps://` and its
   `rtspx://` no-verify variant time out; the source needs an `ffmpeg:`
   wrapper with `#video=copy#audio=copy`.

**Five cameras, five streams — not seven.** A "Floodlight bundle" is one
Wyze Cam v3 on a lamp mount: one lens, one stream. The lamp is an LED
fixture with its own PIR sensor that switches itself on locally and has no
video at all, so nothing in `go2rtc.yaml` refers to it. Controlling the
lamp *from the Panel* is a separate, cloud-only job (Wyze publishes no
device-control API; only `ha-wyzeapi` via HACS) that is not started and is
gated on HACS plus a `light-*` Placement being drawn — see Ch. 5 §2.2.1.

One rough edge, characterised rather than filed: the two floodlight units
take **17–18 s** to first frame where the three plain v3s take **4.6–5.2 s**.
Web/MSE just shows `connecting` for longer; the appliance's MJPEG request
returns 200 and **zero bytes** while cold, because go2rtc answers the
internal DESCRIBE before the upstream producer knows its tracks. RF does
not explain the split — which units are slow is measured, why is not.
Full numbers in Ch. 5 §2.2.1.

### A2.0 What the network says today — measured 2026-08-15

Run before touching anything, and re-runnable at any point:

```sh
hub/tool/wyze-fleet.py scan
```

It sweeps this host's own subnet, keeps every neighbour carrying Wyze
Labs' OUI (`d0:3f:27`) and probes each for an RTSP listener. It carries no
inventory table of its own — the A1 table above stays the single source of
the human names, and the script prints MAC so the two can be matched.

**Result, 2026-08-15 (9 s for the whole /22):**

```
192.168.68.54    d0:3f:27:53:25:72  no listener on 554/8554
192.168.68.57    d0:3f:27:8d:cc:54  no listener on 554/8554
192.168.68.62    d0:3f:27:4a:95:76  no listener on 554/8554
192.168.68.63    d0:3f:27:8e:4f:b1  no listener on 554/8554
192.168.68.69    d0:3f:27:49:b2:f6  no listener on 554/8554

5 Wyze unit(s); 0 serving RTSP.
```

Three things follow, and they are the state this phase actually starts from:

1. **All five units are present and every MAC↔IP pair matches A1 exactly**,
   eight days after **C1** reserved them by MAC on the Deco. The drift that
   made §2.1 of Ch. 5 warn against writing IPs down is fixed; an address may
   now go into `go2rtc.yaml`, and the reservation is the reason it may.
2. **Not one of them serves RTSP.** That is not a fault and not evidence
   against the firmware — the feature ships **off** and is enabled per
   camera in the app. It is, however, the proof that **nobody has done step
   1 yet**, which the plan could not previously distinguish from "done and
   not working".
3. **This is as far as anything on this box can get.** Every remaining
   branch — toggle present, toggle absent, RTSP vs RTSPS, the invented
   credentials — is on the other side of a phone. See A2.1.

### A2.1 The owner action this phase is waiting on

Open the Wyze app on a **plain v3** — Family Room (`.57`), Living Room
(`.69`) or Back Yard Door (`.63`); **not** the Garage Door or Back Yard
units, which are Floodlight bundles carrying a second firmware that §3.2 of
the research doc flags as an untested combination — and look for
**Settings → Advanced Settings → RTSP**.

- **Toggle present** (expected — these are v3s on 4.36.16.7064, newer than
  the 4.36.16.5654 that carried RTSP to production): enable it, invent a
  user and password there, and note whether the URL it prints is `rtsp://`
  or `rtsps://`. Nothing external issues those credentials; the app is the
  only place they exist. Then, before they are written into any config:

  ```sh
  WYZE_RTSP_USER=<the user you invented> hub/tool/wyze-fleet.py rtsp 192.168.68.57
  ```

  It prompts for the password, never prints it, and does a real
  `OPTIONS`/`DESCRIBE` handshake with Digest auth. It separates three
  outcomes that a black tile in the Panel cannot: nothing listening, `401`
  (serving, wrong credentials), and `200` with an SDP naming H.264 — only
  the last is worth configuring. `--tls` for RTSPS, which is also a
  different port (322).
- **Toggle absent**: only then does step 1 below — the `demo_V3_RTSP`
  sideload — apply at all, and E3's "flash one and decide the fleet"
  premise comes back with it.

Everything downstream of that tap is a session's work and none of it is
blocked: the go2rtc entries are pre-written and commented, with the
reserved addresses already in them, in `hub/go2rtc/go2rtc.example.yaml`;
the Panel needs no new code, only a `stream:` line per camera (§A4).

1. **Verify the firmware is still obtainable** (2026 status UNVERIFIED —
   this is the experiment's first gate): the official Wyze RTSP firmware
   for v3 (`demo_V3_RTSP` line, last known 4.61.0.3). If Wyze no longer
   hosts it, stop — the fleet goes through wyze-bridge (A3) and the
   experiment is over.
2. Flash per Wyze's procedure: FAT32 microSD, `demo.bin` (v3 naming) in
   root, hold setup while powering. Enable RTSP in the Wyze app
   (Advanced Settings → RTSP appears on this firmware), set stream
   credentials, note the URL: `rtsp://user:pass@<cam-ip>/live`.
3. Known trade-offs to accept knowingly: the RTSP firmware lags mainline
   (no further security updates), loses some app features, and the
   floodlight-bundle applicability was never verified — floodlights are
   NOT candidates until a v3 succeeds and a floodlight is tested
   deliberately.
4. DHCP-reserve the camera, add to `hub/go2rtc/go2rtc.yaml` — **two
   producers, not one** (§B1 says why, and why leaving the second out fails
   silently):

   ```yaml
     wyze_<location>:
       - rtsp://user:pass@<cam-ip>/live       # H.264 -> web MSE
       - ffmpeg:wyze_<location>#video=mjpeg   # -> appliance MJPEG
   ```

   Restart go2rtc, verify at `:1984` (MSE link) **and** that
   `curl -m 8 -o /dev/null -w '%{size_download}\n'
   'http://127.0.0.1:1984/api/stream.mjpeg?src=wyze_<location>'`
   returns something other than `0`.

**Decision gate**: if the flashed unit streams reliably for a few days →
flash the remaining v3-class units one by one. If firmware is
unobtainable or the stream is flaky → wyze-bridge for everything.

## A3. docker-wyze-bridge for the rest (floodlights + any unflashed unit)

Add to `hub/compose.yaml` (bridge network; its RTSP remaps to a free
port — 8554 is go2rtc's, 8556 is ring-mqtt's):

```yaml
  wyze-bridge:
    image: mrlt8/wyze-bridge:latest   # PIN THE EXACT TAG AT FIRST BRING-UP
    container_name: wyze-bridge
    ports:
      - "8557:8554"    # its RTSP, remapped
      - "5000:5000"    # web UI
    environment:
      TZ: ${TZ:-UTC}
      WYZE_EMAIL: …    # via .env (gitignored by hub/.gitignore *.env rule)
      WYZE_PASSWORD: …
      API_ID: …        # Wyze developer API key pair, created in the Wyze
      API_KEY: …       # account portal (required since 2023 for bridges)
    restart: unless-stopped
```

Streams appear as `rtsp://127.0.0.1:8557/<camera-name>`; add each to
`go2rtc.yaml` like the flashed ones — **with the same second `ffmpeg:…#video=mjpeg`
producer** (§B1). Auth model is cloud login + LAN/TUTK transport → these bind
as `connectivity: cloud`.

## A4. Bindings

Each `cam-*` Key (and `cam-garage` for the garage's Wyze if one lives
there) binds to what go2rtc serves; the camera *state* entity in HA is
secondary for now — cameras are Popup-first Devices. If this ring-mqtt/
wyze path created HA `camera.*` entities, bind those; otherwise leave
`entity:` off (pin renders, unknown state) and the Popup still streams —
the stream name, not the entity, is what the Popup consumes. ~~**Open
design point for the implementer**: where the Panel learns the go2rtc stream
name for a Device~~ — **settled and built 2026-08-04**, as recommended: a
`stream:` key in `bindings.yaml` next to `entity:`, parsed by
`bindings_parser.dart`, carried on `Device.streamName`. Validation split in
two, because two different things are checkable at two different times. The
parser refuses anything that is not a bare go2rtc key — letters, digits, dot,
dash and underscore in any position and nothing else, so **`:`, `/` and `@`
cannot get through** — because `?src=` is not a lookup: hand go2rtc something
that looks like a source spec and it *creates* that stream and dials it, so a
pasted `rtsp://user:pass@…` would work by accident and put the camera password
into the Panel's log. Keeping it out of the log took **three** more rules, all
added 2026-08-04, because `boot.dart` hands the `FormatException` to
`E house.invalid`, the one artefact a fatal boot leaves in journald — so
anything a hand-edit can reach that line with is published:

1. the refusal **does not echo the value**. Until this, refusing the paste was
   itself what published the password. The message names the file, the binding
   and the field — enough to find the line in a file the reader has open — and
   `entity:` and `connectivity:` are treated identically, being one line either
   side and just as easy to paste into;
2. **nor the binding's key**, unless the key is plainly a name (`bindingLabel`:
   the stream-name exclusions plus a 40-character bound). A paste landing one
   column to the left makes the whole URL the key, and the message printed it
   in the same sentence that promised not to; anything not name-shaped reads
   `the 3rd binding` instead. Rejected: withholding every key, which costs the
   everyday message its one useful word;
3. **nor the YAML parser's own complaint**, which was in front of none of the
   above. `loadYaml` runs first, and `YamlException` is a
   `SourceSpanFormatException` that reproduces the offending source line with a
   caret under it — so the *worse* typo (a duplicated `stream:`, a tab, an
   undefined `*alias`, a URL containing `": "`) published the password while
   the cleaner one was carefully refused without it. `readYaml` is now the only
   door to `loadYaml`, for `house.yaml` too, and reduces it to file, line and
   column. Rejected: catching it in `boot.dart`, which leaves the exception
   object carrying the source text for the rethrow and for every other caller.

One channel is accepted rather than closed: a bare API token typed where a
stream name goes parses (it has the shape of a name) and is then logged as
`popup.stream_open name=…`. Rejected: hashing, truncating, or a length cap —
each costs every honest line its meaning to contain a value that should never
have been typed there. (No
first-character rule: `_ring_doorbell` is a legal `go2rtc.yaml` key, and an
earlier `^[A-Za-z0-9]` opener refused it while the message described it as
conforming.) The loader refuses a `stream:` on a kind that cannot
play video, the same "a hand-written line nothing will ever read" failure it
already makes fatal for an unclaimed binding. Whether the *name* resolves is
knowable only at runtime and stays lazy exactly as sketched: the Popup says
the view is unavailable. Two Devices may name one stream — nothing in the
Panel writes to a camera, so they cannot fight — and `house.loaded streams=`
is the count that makes an accidental duplicate visible.

## B0. The origin — **DECIDED AND LANDED 2026-08-04** (was E8)

**Done. Nothing here is owner work any more.** `api: origin: "*"` is set in
the live `hub/go2rtc/go2rtc.yaml` and mirrored into the tracked
`hub/go2rtc/go2rtc.example.yaml`. This section is kept because the reasoning
is what a future reader needs, and because the setting looks careless without
it.

**What the problem was.** go2rtc 403s any WebSocket upgrade carrying an
`Origin` header it was not configured for. A browser always sends `Origin`, so
a Panel served from anywhere except `:1984` itself never reached the socket —
and what it saw was a bare connection failure with no `{"type":"error"}` frame
to explain it.

**Why `"*"` and not something tighter.** Naming the Panel's exact origin was
measured on the same instance: `api.origin` set to `"http://localhost:8080"`
still 403s that very origin. In 1.9.10 the setting is effectively `"*"` or
same-origin-only — **there is no allowlist**. The choice was never `"*"`
versus a narrow list; it was `"*"` or no live video. Do not "tighten" it to a
hostname later without re-measuring: it will look correct and silently break
every camera.

**Why accepting the exposure was right here (the owner's reasoning,
2026-08-04).** go2rtc on this box is unauthenticated, so with `origin: "*"`
any page loaded in any browser on this LAN can reach every stream in it —
today one synthetic test pattern, after this phase every camera in the house.
That cost is real and is stated beside the setting. It was accepted because
**access to this system is LAN-only or over the VPN, so the network boundary
is the control** — ADR-0008's one box, no port-forward. The origin check was
never what kept strangers off an unauthenticated service, and declining `"*"`
would have bought no protection while costing the Panel its picture. Revisit
when real camera streams land: that is when the exposure stops being
synthetic.

The block, as it stands in both files:

```yaml
api:
  origin: "*"
```

Read the decision back — with `origin: "*"` in place this prints `101` for
every one of the three:

```bash
for O in '' 'http://127.0.0.1:1984' 'http://localhost:8080'; do
  curl -s -o /dev/null -w "${O:-<none>} -> %{http_code}\n" --max-time 2 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    ${O:+-H "Origin: $O"} 'http://127.0.0.1:1984/api/ws?src=selftest'
done
```

Measured on the live daemon (`"version":"1.9.10"`, `revision df95ce3`) after
the change: **101, 101, 101**. The third was `403` before it. `curl` exits
28 on each — it is holding an upgraded socket open until `--max-time`, which
is the point.

`selftest` already exists in the live config, and **as two producers** — see
§B1 below, which is the shape every camera has to copy.

## B1. Every camera needs **two producers**, or the appliance gets nothing

The Panel has two transports (§B), and they want two codecs off the same
camera. That is one `streams:` entry with two producers — **not** two streams
and not a naming convention:

```yaml
  cam_porch:
    - rtsp://user:pass@CAMERA-IP/live      # H.264 -> web MSE
    - ffmpeg:cam_porch#video=mjpeg         # -> appliance MJPEG
```

`bindings.yaml` then names `cam_porch` once, and both builds play it. Rejected:
a `_mjpeg` suffix convention, which would push a transport detail into the
house's configuration and make every camera two entries that can drift apart.

**Leave the second line out and the failure is silent.** go2rtc will **not**
transcode on demand for a format no producer offers. Measured against the live
1.9.10 daemon: a stream carrying only the H.264 producer answers
`GET /api/stream.mjpeg?src=…` with **HTTP 200 and zero bytes** in 94 ms, then
holds the connection open. Not a 404, not an error frame — a successful empty
stream. The appliance's stall watchdog eventually calls it `failed`, and
whoever reads that journal line has no reason to suspect a missing line in
`go2rtc.yaml`; they will check the camera, the network and the kiosk build
first. Add the producer when you add the camera.

The transcode **only runs while somebody is watching**, which is what makes it
affordable to declare on every camera rather than on the ones expected to be
viewed. With no consumer, `/api/streams` shows both producers as bare `url`
stubs and `consumers: []`, and no ffmpeg process exists. Closing the Popup
returns it to exactly that — visible in the timings: a viewer arriving after
the teardown pays the **4.1 s cold** start, one arriving while it is still
warm pays **2.1 s**.

**How fast "returns to that" is depends on when you close.** Measured against
the live server: a Popup closed while it was *playing* drops `consumers` to
`[]` in under a second. A Popup closed **during** the ~2 s connect does not —
`consumers` *rises* after the Panel's own socket is gone and takes **2–10 s**
to reach `[]`, because the on-demand `ffmpeg:<name>#video=mjpeg` producer is
itself counted as a consumer and finishes spinning up regardless. Nothing is
done about it: the Panel does not own that process and go2rtc idles it out. It
costs a few seconds of transcode after a doorbell Popup dismissed before it
ever showed a picture, and it does not touch the #177014 argument, which is
about how old a *Ring* session may get.

## B. Live video in the Popup (Panel feature)

Target: tap a camera pin (or doorbell ding, phase 3) → Popup plays live
video in ≤ 2 s → closing the Popup tears the stream down (the #177014
rule, and battery-cam courtesy generally).

- **Two targets, both of which must play** — owner decision, 2026-08-04, and
  it replaces this section's original "MSE on web, placeholder everywhere
  else". The **Flutter/cage appliance is the primary target**: it is the wall,
  and a wall that cannot show the front door is not a smart-home panel. The
  **web build is not merely ADR-0001's if-the-spike-fails fallback** any more
  — it is that *and* the shape a second, in-house touchscreen is planned to
  take, so it is a shipping target held to the same bar. Any sentence
  elsewhere that reads "playback is web-only by decision" predates this.
- **Transport, web: MSE over WebSocket** (`ws://<hub-ip>:1984/api/ws?src=<stream>`
  consumed via MediaSource) — TCP, no ICE/candidate complexity, fine on LAN.
  An `HtmlElementView` hosting a `<video>` element fed by a package-free
  JS-interop shim; go2rtc's own `/video-rtc.js` is the reference to crib the
  codec list from, and it was. WebRTC is the latency upgrade, deferred until
  MSE proves insufficient. **Measured in real Chrome against the live server:
  `playing` 101 ms after open; ~26 kB/s** for the 640×480 synthetic H.264.
- **Transport, appliance: multipart JPEG over HTTP** (`GET
  /api/stream.mjpeg?src=<stream>`), decoded frame by frame and painted by a
  `CustomPainter`. Chosen because the alternatives are worse where it counts:
  MSE needs a browser, and there is none in a cage kiosk; WebRTC needs ICE and
  a `libwebrtc` dependency for a link that never leaves the LAN; and a
  `video_player`/GStreamer route trades this problem for a platform-channel
  and codec-plugin problem. MJPEG needs `dart:io`, `dart:ui` and nothing else.
  **Measured against the live server: first byte at 2.10 s warm / 4.10 s cold,
  then ~186 kB/s at 25 fps (~7.4 kB a frame)** — and, since 2026-08-04, the
  choice is vindicated on the target itself: the compiled Linux release binary
  painted these frames in the Popup with no plugin, no browser and no codec
  beyond `dart:ui` (phase-0 item 14).
- **What that costs, plainly:** the appliance pays roughly **seven times the
  bandwidth and twenty times the time-to-picture** for the same camera. On a
  LAN 186 kB/s is 1.5 Mbit and nobody notices; the 2.1 s is the number that
  shapes the UI, and it is why `LiveVideoPhase.connecting` has to be an honest
  phase rather than a cosmetic one. It is also a *transcode* spin-up and adds
  to Ring's own 2–5 s cloud spin-up rather than hiding inside it.
- **Config**: the Panel needs the go2rtc base URL — a new `GO2RTC_URL`
  alongside `HA_URL`, ~~logged at startup as `panel.start … go2rtc=set`~~.
  Add it to `resolveHubConfig` (`panel/lib/config/hub_config.dart`) rather
  than as a bare `--dart-define`, so it resolves environment-first like the
  others and one more address does not re-bake the binary.
  **`go2rtc=set` was rejected when this was built**: `set`/`absent` is the
  vocabulary for withholding a *secret*, and this is not one — go2rtc is
  unauthenticated and the camera credentials live in `go2rtc.yaml`, not in the
  base address. Borrowing it would have thrown away the one fact worth having,
  and "pointed at the wrong go2rtc" is otherwise invisible until somebody taps
  a camera. The line is `[panel] I popup.go2rtc url=http://…` (or
  `url=absent`), mirroring `hub.configured`'s `url=`. **Amended 2026-08-04**:
  "go2rtc is unauthenticated" is a fact about *this deployment's*
  `go2rtc.yaml`, not about the URL shape the setting accepts — go2rtc 1.9 has
  `api.username`/`api.password`. So the line reports `auth=set` when there was
  a credential, and prints the address itself as a **named list of parts kept**
  — scheme, host and port — rather than the whole value with `userInfo`
  taken out. **Corrected again the same day**, because the strip was wrong
  twice over: `?password=…` and `#…` rode straight through it, and
  `Uri.tryParse('admin:hunter2@hub:1984')` yields a scheme with the rest as a
  *path* and an empty `userInfo`, so the whole thing was printed verbatim. A
  named list excludes the next URL part somebody invents by default instead of
  publishing it by default. **The `path` came off that list on the third
  pass**, after a verifier measured `http://10.0.0.5:1984/hunter2/` publishing
  `hunter2`; a path is a reverse-proxy mount point, so its presence is now
  reported as `path=set` — and only when it is not a bare `/` — while its text
  is not. That the list could be shortened by one word with nothing else
  touched is the argument for the shape. A value with no host is
  `url=unusable` and is
  never echoed — the same emptiness `VideoConfig.urlFor` refuses to dial, so
  one fact reported once. That keeps the host, which was the whole objection to
  `go2rtc=set`, and still never logs a credential.
- **Diagnostics**: `[panel] I popup.stream_open name=wyze_porch` /
  `popup.stream_closed` / `W popup.stream_failed reason=…` — a wall
  panel's video failure must be greppable, not a black rectangle. Built as
  specified, plus `D popup.stream_skipped device=… reason=…` for the three
  ways nothing gets dialled at all, and
  `I popup.stream_unsupported name=…` for a build that cannot play. That last
  one was not in the sketch and is not decoration: the `open`/`closed` pair was
  being logged for a socket that never existed, which made "this build cannot
  play video" indistinguishable from "go2rtc is healthy" in the only channel
  the kiosk has. An `unsupported` Popup now logs that one line and neither half
  of the pair. **What reaches it changed with the second transport**: it was
  the appliance's whole-platform answer, and it is now a *browser* with no
  `MediaSource` in it — the web player checks before it dials, because `failed`
  would send an operator to a healthy go2rtc for a fault in the browser.
- **Tests**: widget test that the Popup requests the stream URL for the
  Device's `stream:` and tears down on close (fake the shim); ~~golden of
  the Popup's chrome around a solid-color stand-in frame~~.
  **The golden was deliberately not added.** Five goldens are already red on
  this host for font reasons (phase-0 open item 13), so a new one baked here
  would take item 13's decision inside an unrelated feature and guarantee that
  *no* machine can be green. Everything that golden would have covered is
  text, and the widget tests assert it directly. The unconfigured Popup body
  was kept byte-identical for the same reason, so the existing
  `device_popup.png` stayed valid.

### What landed 2026-08-04, and what did not

**Landed** — the whole Panel side, both transports:

- `GO2RTC_URL` through `resolveHubConfig`, environment-first, with **no
  built-in default** (`HA_URL`'s default is earned by `HUB=fake` gating it;
  video has no such gate, so a `localhost:1984` default would dial nothing on
  every hermetic run and a wrong address would stay invisible until somebody
  tapped a camera). Delivered on the appliance as
  `panel_go2rtc_url` → `Environment=GO2RTC_URL=`.
- `stream:` in `bindings.yaml` → `Device.streamName`, validated as above.
- `panel/lib/ui/video/live_video.dart`: a pure interface plus a conditional
  export, the same seam `config/runtime_env.dart` uses. Behind it,
  `live_video_mjpeg.dart` (appliance) and `live_video_mse.dart` (web), with
  `mjpeg_frames.dart` holding the multipart framing so it can be tested with
  no socket in the way. `liveVideoIsAvailable` is `true` on **both** sides and
  is asserted by a seam test, so re-stubbing either file fails a test rather
  than quietly costing a target its picture — it was `false` on the non-web
  side while the files were called `live_video_stub.dart` and
  `live_video_web.dart`, which was the wrong half of the seam to leave empty.
- The Popup's five honest bodies, its session lifetime (opened in
  `initState`, closed in `dispose()` — the only hook that also runs when a
  route leaves without a pop), the deadline, and every diagnostic above.
  Only four of the five phases are ever *answered* by an opener: `unconfigured`
  is decided before anything is dialled, where the session is null and the
  reason is logged as `popup.stream_skipped`. The enum value names the body,
  not an answer anything gives.
- Phase-3 §4's doorbell auto-Popup, which is the second consumer this seam was
  shaped for, plus the ceiling on its deadline that §4 describes.

- Both players, and the `api:` block of §B0 — the last two things this list
  used to end by saying were missing.

**Not landed, and this is the honest list.**

1. ~~**No camera.**~~ **Half closed 2026-08-05/06.** B2 landed, so there is a
   real camera: `ring_doorbell`. The **web/MSE** player has since played it
   through the real Popup in Chromium (2026-08-06 — cold open plus three
   reopens, decoded frames 103 → 405, `currentTime` tracking wall-clock). The
   **appliance/MJPEG** player has still only rendered `selftest`; the 54 real
   JPEG frames in TODO **B2** were pulled from `/api/stream.mjpeg` by hand, not
   through `MjpegLiveVideoSession`. The Wyze fleet (**B3**) is untouched.
   The start-up risk §B states is now measured, and it is worse and more
   specific than "2–5 s": ring-mqtt relaunches its cloud session per connect,
   and a relaunch following a quick close/reopen can deliver an elementary
   stream with no keyframe — a producer gap of 2.8 s decoded **2 frames**,
   4.8 s decoded **none**, 25 s was clean six times out of six. That is
   [issue #1](https://github.com/dmorozov/SmartHome/issues/1); it is bounded by
   a keep-alive and an honest snapshot fallback, not cured.
2. ~~**The appliance build has never been compiled.**~~ **Closed
   2026-08-04 (README G4, phase-0 item 14).** `flutter build linux --release`
   now succeeds on this host and the resulting **Linux release binary** has
   rendered live MJPEG from go2rtc inside the doorbell Popup: run headless
   under `Xvfb` against the real Hub and real go2rtc, a doorbell state change
   opened the Popup unprompted, video appeared (screenshot captured; go2rtc
   saw `user_agent: Dart/3.12 (dart:io)`, 931 kB), and Close tore the stream
   down to `consumers: []`. What that run did **not** cover, and what
   therefore stays open: it was **Xvfb, not cage** — `cage` is not installed
   on this box (README **G6**) and the kiosk half of the spike (**A7**) is
   untouched; there was **no touch input**, because no touchscreen is
   attached; and the source was the synthetic `selftest` pattern with a
   fabricated `sensor.ring_doorbell` state, not a camera and not a Ring —
   which is item 1 above. Also note the bundle was built from a
   `bindings.yaml` carrying `stream: selftest` on `doorbell`; the tracked
   file has no `stream:` line there, so wiring a real doorbell stream is
   still an uncommitted config change.
3. **`MseLiveVideoSession.view` was never mounted.** The Chrome probes had no
   widget tree, so `HtmlElementView.fromTagName` and the reparenting of the
   `<video>` element into it are argued for and untested.
4. **The browser probes are not in the suite.** They need a go2rtc on
   `127.0.0.1:1984`, and a test that fails on every machine but one is a test
   nobody trusts. What is in the suite is the framing, the phases, the
   lifetime and the leak rules — the parts that hold without a server.

**Protocol notes, now confirmed by a working player.** Measured against the
live instance during the design pass and then relied on, 2026-08-04. Kept
because none of it is asserted by any test and none of it can be — re-verify
if go2rtc is upgraded:

1. `ws.binaryType = 'arraybuffer'` before open, and **the client speaks
   first**: the server sends nothing until a `{"type":"mse","value":"<codec
   list>"}` frame goes out.
2. Codec list = `CODECS.filter(MediaSource.isTypeSupported)`, joined with `,`.
   Do not hardcode the superset; go2rtc picks `avc1.640029` from any subset
   containing it.
3. The first text frame back is a **complete MIME type** ready for
   `addSourceBuffer()`, e.g. `video/mp4; codecs="avc1.640029"`. The init
   segment (`ftyp`+`moov`) arrived **0.1 ms** later — a staging buffer is
   mandatory, flushed on `updateend`; appending while `sb.updating` throws.
4. `{"type":"error","value":"…"}` on the **first** text frame means failure —
   and **the socket stays open forever with no close frame** (still open after
   30 s). Parse it, render `failed`, log the value verbatim, close the socket
   yourself. Never branch on the string.
5. **No keepalives in either direction** (0 pings over 35 s). A watchdog — "no
   binary frame in N seconds" — is the only liveness signal, and an open
   timeout is needed for the case where even the error never arrives.
6. `muted = true` before `play()`: a doorbell Popup opens with no user gesture
   and autoplay policy will otherwise reject it.
7. Teardown is immediate — closing the WebSocket drops the consumer and tears
   the producer back to a bare `url` stub within 50 ms. That is what makes the
   #177014 rule enforceable rather than aspirational.
8. `HtmlElementView.fromTagName`, **not** `registerViewFactory`: the latter
   needs a globally-unique `viewType` registered once with **no unregister**
   in the API, and the doorbell Popup can open unprompted at any moment for
   any stream. `dart:html` is forbidden (deprecated in favour of
   `package:web` + `dart:js_interop`); `web:` has to move from transitive to a
   declared dependency in `panel/pubspec.yaml`.

And one budget correction: **the ≤ 2 s target above is a camera-wakeup
budget, not a transport budget** — on web. The measured MSE protocol floor is
an init segment at +80 ms and a first media segment at +125 ms; the finished
player reaches `playing` in 101 ms. A real Ring stream takes 2–5 s because
ring-mqtt starts the cloud session only when an RTSP client connects. Do not
tune the Panel against the 80 ms number.

**On the appliance the ≤ 2 s target is not met, and cannot be by tuning.**
MJPEG's 2.10 s to first byte is go2rtc starting an ffmpeg transcode, and it is
paid *before* the camera has woken up, not instead of. The honest budget there
is "the wall says `connecting` for two to seven seconds, truthfully". Two
things follow: the phase enum has to be real rather than cosmetic, and the
doorbell Popup's 30 s deadline has to be comfortably longer than the worst
case — it is.

## Done when

Status re-read **2026-08-15**. **B3 is closed** (2026-08-07): the A1 table
above is filled in for all five units, and **C1** reserved every one of their
addresses by MAC the same day. Re-measured from this host on 2026-08-15
(§A2.0): all five present at exactly those addresses, **none serving RTSP**.
So what gates this phase is no longer an inventory and no longer a purchase —
it is **one tap in the Wyze app on one plain v3**, written out in §A2.1, and
everything on this side of it is ready for it.

Status re-read **2026-08-07**. **E8 is closed. G4 is closed** — the Linux
release binary builds, runs, and has rendered live video from go2rtc in the
doorbell Popup under Xvfb (phase-0 item 14 has the full evidence and the four
things it does not prove). **B2 is closed too** (2026-08-05), so the "entirely
owner-blocked on hardware" reading below is overtaken: there is a real camera,
the web player has played it, and doing so surfaced
[issue #1](https://github.com/dmorozov/SmartHome/issues/1) — a producer-side
mid-GOP race that no synthetic pattern could have shown. What is left that is
owner-blocked is **B3** for the Wyze inventory — i.e. a camera to
point at. Separately, the *kiosk* claim is still unproven: that needs `cage`
installed (**G6**) and the **A7** spike day, neither of which phase 4 gates on.

- ⬜ **Open — owner-blocked on one tap (E3/D1).** Every Wyze unit either serves
  RTSP locally or restreams via wyze-bridge; all visible in the go2rtc UI; the
  A1 inventory table in this file records which path each took. **A1 is no
  longer empty** — it was filled in on 2026-08-07 and the five units are named,
  modelled and firmware-versioned, which is what E3's decision branches on.
  What is left is §A2.1: enable RTSP in the app on one plain v3, prove it with
  `hub/tool/wyze-fleet.py rtsp`, then two config lines per camera. Measured
  2026-08-15, none of the five serves RTSP yet, so the count of units on
  *either* path is still zero.
- ⬜ **Open — owner-blocked (B3/B2), and one thing this host cannot do.** Popup
  plays live video for at least: one Wyze camera and the Ring doorbell; close =
  stream teardown (verify in go2rtc UI: consumer count drops to 0). Of the
  three blockers this bullet used to list, **all three are now gone**: the
  **players** are built, the **origin** is decided, and **G4** is closed — the
  appliance player has been observed rendering real frames from the live
  go2rtc (Xvfb, not cage; synthetic stream, not a camera). What remains is
  only the **streams** (owner — B3 for Wyze, B2 for Ring). The separate
  question of whether the *cage kiosk* renders them is **A7**, gated on **G6**
  and on a touchscreen existing, and it is not a phase-4 gate.
  Both halves are already provable against `selftest` and were: `playing`
  with real pixels on both transports, and on Close, `producers` back to bare
  `url` stubs with `consumers: []` — stricter than counting consumers, and note
  `consumers` is `[]` for a configured stream but `null` for a dynamically-
  created one. **Drop the ≤ 2 s clause for the appliance**: 2.10 s is the
  transcode spin-up alone (§B), so that target was never reachable there and
  keeping it would make an honest player look broken.
- ⬜ **Open — owner-blocked (B2).** Doorbell ding while no stream is open
  still arrives (re-run the phase-3 check with video now real). The Panel side
  of the rule is built and tested (phase-3 §4); "still arrives" is a statement
  about Ring's cloud and needs real hardware.
- ✅ **Done 2026-08-04 — and the runner does not say "green", so neither does
  this.** `flutter test` reports **`+285 ~1 -5`**, and `flutter analyze` reports
  *No issues found!*. **The five failures are exactly the five that were
  already failing before any of this work started**, all in
  `panel/test/golden/dollhouse_golden_test.dart`: `device popup over the
  dollhouse`, `ground floor selected`, `hub gave up: token rejected`, `hub
  unreachable`, `upstairs selected`. They are host font drift from the Ubuntu
  25.10 → 26.04 upgrade, tracked as phase-0 open item 13, and **no golden was
  updated, added or re-toleranced** — the deliberate part. Baking a new golden
  here would take item 13's decision inside an unrelated feature and guarantee
  that no machine can be green; the unconfigured Popup body was kept
  byte-identical so `device_popup.png` stayed valid for the same reason.
  This bullet said "green" until 2026-08-04, which was never what the runner
  printed. The count and the named five are what a reader can check; "green" is
  what makes them stop reading and inherit somebody else's five failures as
  their own.
