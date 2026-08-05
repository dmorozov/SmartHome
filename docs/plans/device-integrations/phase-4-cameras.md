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

## A2. The RTSP-flash experiment — ONE unit (D1)

Goal: a camera that serves RTSP locally with no cloud dependency —
`connectivity: local`.

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
  and codec-plugin problem on a target that has never been compiled here.
  MJPEG needs `dart:io`, `dart:ui` and nothing else. **Measured against the
  live server: first byte at 2.10 s warm / 4.10 s cold, then ~186 kB/s at 25
  fps (~7.4 kB a frame).**
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

1. **No camera.** Every measurement above is against go2rtc's synthetic
   `selftest` pattern. Ring is **B2**, the Wyze fleet **B3**, and the risk
   they carry is stated in §B: a real Ring stream takes 2–5 s to start,
   *on top of* the MJPEG transcode's 2.1 s.
2. **The appliance build has never been compiled.** `flutter build linux`
   needs clang, cmake, ninja and the GTK dev headers and this host has none
   of them (phase-0 open item **G4**). The MJPEG player is exercised by the
   suite on the Dart VM and has been driven end-to-end against the live
   server from here — but the cage kiosk it ships to has never rendered a
   frame of it.
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

Status re-read 2026-08-04, after the origin decision and both players landed.
**E8 is closed.** What is left is owner-blocked on hardware — **B3** for the
Wyze inventory, **B2** for Ring — plus one agent item that cannot be done on
this host at all (**G4**: no Linux toolchain, so the appliance build has never
been compiled).

- ⬜ **Open — owner-blocked (B3).** Every Wyze unit either serves RTSP locally
  (flashed) or restreams via wyze-bridge; all visible in the go2rtc UI; the A1
  inventory table in this file records which path each took. **A1 is still
  empty**: five `D0:3F:27` MACs is not five cameras, and the model per unit is
  what E3's flash decision branches on. Nothing here can start until the
  owner reads the Deco and Wyze apps.
- ⬜ **Open — owner-blocked (B3/B2), and one thing this host cannot do.** Popup
  plays live video for at least: one Wyze camera and the Ring doorbell; close =
  stream teardown (verify in go2rtc UI: consumer count drops to 0). Of the
  three blockers this bullet used to list, two are gone: the **players** are
  built and the **origin** is decided. What remains is the **streams** (owner —
  B3 for Wyze, B2 for Ring) and **G4**, the missing Linux toolchain, which is
  why no frame of the appliance player has ever been rendered by the cage
  kiosk. Both halves are already provable against `selftest` and were: `playing`
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
