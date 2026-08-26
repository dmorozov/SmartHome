# Phase-8 handoff — the defect-fix record and the remaining work

Written 2026-08-25 for a fresh Claude Code session with no conversation
context. Two halves: **§1–§3** are the record of the six defects an
adversarial review confirmed in the phase-8 code and the fixes that are
**already applied and green** in this working tree — read them to verify,
or to re-apply if the tree is ever reset. **§4** is the implementation
plan for every remaining item from the phase-8 architecture review, each
with its trigger, steps, files, and decision points.

> **Status when written:** all six fixes applied; `flutter analyze` clean;
> `flutter test` = **541 passed, 2 skipped** (the two skips are the opt-in
> live suites, expected). Everything is UNSTAGED — CLAUDE.md forbids
> staging/committing without the owner. Four of five Wyze cameras still
> awaited a power-cycle (their RTSP daemons dead; Living Room self-recovered).
>
> **Updated 2026-08-25 (later the same day):** N6 implemented — see its
> section, now a record rather than a plan. Suite = **551 passed, 2
> skipped**; §0's expected counts read 541 and are superseded by this line.

---

## 0. Orientation for a fresh session

Read these before touching anything, in this order:

1. `CONTEXT.md` — the domain language; **Stream Director** and **Camera
   Health** entries were added by phase-8.
2. `docs/plans/device-integrations/phase-8-cameras-streaming.md` — the
   phase's diagnosis (§A), the applied Hub config (§B), the Panel
   architecture (§C), deferred items (§D), done-when (§E).
3. `panel/lib/ui/video/stream_director.dart` — the module itself; its file
   doc explains where it sits (above the player seam, wrapping the
   keep-alive pool's opener, exactly the pool's own precedent).
4. `panel/lib/ui/video/camera_health.dart` — the probe-entity adapter.
5. `panel/lib/ui/cameras/cameras_view.dart` — tiles/zoom as feed renderers.

Environment facts the session needs:

- **Flutter on the host works**: `/home/dmorozov/Java/Flutter/flutter/bin/`
  is on PATH; `flutter test` and `flutter analyze` run clean from
  `/home/dmorozov/Work/SmartHome/panel` (always `cd` there first — a stale
  cwd from `panel/assets/house` once made the test runner resolve the wrong
  path). ADR-0009 prefers the devcontainer for development; the host
  toolchain proved sufficient for test/analyze.
- **Docker needs no sudo** (the user is in the docker group). The Hub host
  has **no passwordless sudo** — hand privileged commands to the owner as
  `! <command>` suggestions.
- **Secrets**: the live go2rtc config is `~/.sh_keys/go2rtc/go2rtc.yaml`
  (mode 0600; its producer URLs embed camera credentials and the Ring
  token — NEVER print its contents; edit via a script that outputs only
  names/counts; a pre-phase-8 backup exists at
  `~/.sh_keys/go2rtc/go2rtc.yaml.bak-20260825-phase8`). The HA long-lived
  token is `~/.sh_keys/token` — use it in an `Authorization: Bearer`
  header without ever echoing it.
- **The Ring doorbell may never be probed or consumed through go2rtc**
  outside a person-opened view: any go2rtc consumer on its stream opens a
  real Ring cloud session and suppresses dings (HA core #177014).

Verify-everything in ~90 seconds:

```bash
cd /home/dmorozov/Work/SmartHome/panel
flutter analyze --no-pub            # expect: No issues found!
flutter test                        # expect: +541 ~2, All tests passed!
# The fixes' own suites specifically:
flutter test test/stream_director_test.dart   # 33 tests
flutter test test/camera_health_test.dart     # 5 tests
flutter test test/cameras_view_test.dart      # 19 tests
```

---

## 1. The defect-fix record

Provenance: a 17-agent adversarial review (3 finder lenses → per-finding
skeptics told to refute) over the new phase-8 code found 14 candidates,
refuted 4 (§2), and confirmed 10 — which deduplicate to the **six distinct
defects** below. Line numbers are as of 2026-08-25 and will drift; the
symbol names and grep anchors will not.

### D1 (MAJOR) — health-recovery dial bypassed the viewport/overlay gates

- **Where:** `_Feed.onHealth`, `panel/lib/ui/video/stream_director.dart`
  (~line 788; anchor: `A policy feed's recovery goes through the same gates`).
- **Mechanism:** the recovery branch called `_requestDial()` directly,
  skipping the `!_visible || director._overlaid` gate that `_resume()`
  applies. Because `FeedPhase.offline` is not `isActive`, `_armStop` had
  armed **no** stop timer for the feed while it was hidden — and the
  `visible` setter dedupes repeats, so no later event would arm one.
- **Failure trace:** tile attaches while its camera daemon is down → born
  `offline`, nothing dialled → user scrolls it below the fold (mounted
  inside cacheExtent; `visible=false` recorded, no timer since not active)
  → daemon recovers → health flips → blind dial → invisible tile goes
  `playing`, `wantKeepAlive` pins it against unmount → **streams unwatched
  indefinitely** on the 2.4 GHz air the whole feature exists to protect.
  Same hole via `overlaid`.
- **Fix (applied):** person-origin feeds keep the unconditional recovery
  dial (that is `start()`'s documented promise); policy feeds park at
  `idle` and go through `_resume()`, which applies both gates and
  re-admits on scroll-in / overlay-pop:

  ```dart
  if (_phase.value == FeedPhase.offline) {
    _retryAttempt = 0;
    if (personOrigin) {
      _requestDial();
    } else {
      setPhase(FeedPhase.idle);
      _resume();
    }
  }
  ```

- **Regression tests:** `test/stream_director_test.dart` —
  `'recovery respects the viewport: a hidden tile parks at idle and dials
  only on scroll-in'` (~331) and `'recovery respects the overlay: parked
  until the Popup goes'` (~351). The pre-existing
  `'recovery re-dials an offline policy feed on the flip, not a timer'`
  still passes because a visible, un-overlaid feed dials synchronously
  through `_resume → _requestDial → _admit`.
- **Verify applied:** `grep -n "recovery goes through the same gates" lib/ui/video/stream_director.dart`

### D2 (MAJOR) — health listeners leaked one closure per watch epoch

- **Where:** `StreamDirector._watchHealth` / `_unwatchHealth` /
  `dispose`, `stream_director.dart` (~458/478/390; anchor:
  `A named closure, stored`).
- **Mechanism:** `_watchHealth` registered a fresh lambda
  (`() => _onHealth(id)`) on the health source's per-device
  `ValueNotifier`; `_unwatchHealth` removed only the `_healthWatch` map
  entry — the original comment even admitted the lambda could not be
  removed by identity. `HubCameraHealth`'s notifiers are process-lifetime
  (`putIfAbsent`, pinned by test), so **every Cameras-view visit orphaned
  one listener per camera, forever** — ~7 closures per visit, each
  retaining the Director, on an appliance that never restarts.
- **Fix (applied):** `_healthWatch` became
  `<String, (ValueListenable<Reachability>, VoidCallback, int)>` — the
  registered callback is stored, `removeListener`ed when the refcount
  reaches zero and again defensively in `dispose()` for entries whose
  refcount never drained.
- **Regression test:** `'health listeners come off with the last feed…'`
  (~410) — uses `ProbeNotifier` (a `ValueNotifier` subclass exposing the
  protected `hasListeners`) to assert attach→listened, release→not,
  re-attach→exactly one again.
- **Verify applied:** `grep -n "VoidCallback, int" lib/ui/video/stream_director.dart`

### D3 (MINOR) — a stale stop timer rewrote `offline` to `idle`

- **Where:** `_Feed._armStop`, `stream_director.dart` (~754; anchor:
  `Re-checked at fire time`).
- **Mechanism:** the linger/overlay timer callback checked only
  `released || personOrigin` at fire time. A linger armed over `playing`
  could fire after the feed had failed and been parked `offline` by
  Health — `_stop` then `setPhase(idle)`, the **one badge-wearing phase**,
  over a camera that is off the air ("Tap for live" over a dead daemon).
- **Fix (applied):** the callback re-checks
  `!_phase.value.isActive` and stands down — a feed that settled at
  offline/unconfigured/unsupported (or already idle) has nothing to stop
  and the verdict outranks a timer armed in another life.
- **Regression test:** `'a stale stop timer must not rewrite offline to
  idle…'` (~367): playing → `visible=false` (linger armed) → session
  fails → health unreachable → offline → elapse 45 s → still offline.
- **Verify applied:** `grep -n "Re-checked at fire time" lib/ui/video/stream_director.dart`

### D4 (MINOR) — the doorbell was registered as a probed camera

- **Where:** `HubCameraHealth` constructor,
  `panel/lib/ui/video/camera_health.dart` (~39; anchor:
  `Cameras only, NOT every video kind`).
- **Mechanism:** the constructor registered every `specOf(kind).video`
  Device — doorbell included. The doorbell's `entity:` is its **ding
  event**, not a daemon probe; a doorbell integration reporting in the
  binary word shape would read `off` at rest and fold a resting bell into
  `Reachability.unreachable`, gating a dial that would have worked.
  (Today's `event.front_door_ding` folds to a timestamp-ish string →
  `unknown`, so the bug was latent, not live.)
- **Fix (applied):** filter `device.kind == DeviceKind.camera` with a
  comment naming the escalation path if a second probed kind ever exists
  (a KindSpec fact or a `probe:` bindings key — never a wider filter).
- **Regression test:** `test/camera_health_test.dart` — `'the doorbell is
  never probed…'` (~50): push `StatusState('doorbell','off')`, assert
  `unknown`.
- **Verify applied:** `grep -n "NOT every video kind" lib/ui/video/camera_health.dart`

### D5 (MINOR) — a synchronous dial failure cascaded the queue unspaced

- **Where:** `StreamDirector._admit` and `_drainQueue`,
  `stream_director.dart` (~413/442; anchor: `Gate armed BEFORE the dial`).
- **Mechanism:** both dialled first and armed the spacing gate after. A
  born-failed settled session closes inside `dial()`, and that close
  re-enters `_drainQueue` — which found `_gate == null` and dialled the
  next queued feed in the same tick, recursively: one dead camera dragged
  the whole queue out as the exact burst the 400 ms spacing exists to
  prevent (and each failed open costs the camera two connections,
  measured).
- **Fix (applied):** `_armGate()` **before** `feed.dial()` in both call
  sites; the reentrant drain now hits the `_gate != null` early-return and
  the gate's own fire drains the next feed a spacing later.
  `dialSpacing: Duration.zero` policies are unaffected (`_armGate` no-ops).
- **Regression test:** `'one bad camera does not cascade the queue out
  unspaced…'` (~249): three failing tiles → dials go 1 / +400 ms → 2 /
  +400 ms → 3, never 3-at-once.
- **Verify applied:** `grep -n "Gate armed BEFORE the dial" lib/ui/video/stream_director.dart`

### D6 (MINOR) — the closing census counted the ghost of a zoomed-away grid

- **Where:** `_CamerasViewState._zoomIn` / `_zoomOut` and `ZoomedCamera`,
  `panel/lib/ui/cameras/cameras_view.dart` (~266/277; ZoomedCamera gained
  a required `onWent` at ~804).
- **Mechanism:** tiles deliberately skip their census drain in `dispose()`
  (children unmount before the parent — the view-teardown rule), but tiles
  ALSO unmount at **zoom-in**, and the zoom feed never reported itself. So
  while zoomed, `_live` still held the pre-zoom grid entries and omitted
  the one feed actually streaming; a view closed from a zoom logged a
  census of streams the teardown never released. (Faithfully inherited
  from the pre-Director code — pre-existing, not a regression.)
- **Fix (applied):** `_zoomIn` clears `_live` before replacing the grid
  (the condemned tiles skip their own drain by design); `ZoomedCamera`
  reports through the same `onWent` wire as tiles (born-active + `isActive`
  edge transitions, no drain in its `dispose`); `_zoomOut` removes the
  zoom's entry — the remounting tiles re-report via `initState`, born
  active off the pool's kept sessions.
- **Regression test:** `test/cameras_view_test.dart` — `'a view closed
  FROM a zoom counts the zoom, not the ghost of the grid it replaced'`
  (~531): one live tile, zoom into the not-wired `cam-office`, non-tap pop
  of the whole view → `closed live: 0`. The pre-existing grid-close census
  test (`live: 1`) still passes untouched.
- **Verify applied:** `grep -n "_live.clear()" lib/ui/cameras/cameras_view.dart`

---

## 2. Refuted findings — do NOT re-fix these

The review's skeptics killed four findings. A future reviewer will likely
re-find them; this section is the record of why they are not defects.

- **R1 — "person dials should arm the spacing gate."** Deliberate design:
  the gate paces policy storms; a human tap is one dial, and arming the
  gate on it would make the grid's own re-attaches after a zoom-and-back
  wait behind it (which is a pinned test). The stale doc sentence on
  `_admit` that still claimed the opposite was fixed 2026-08-25.
- **R2 — "the `idle` doc says it alone earns the badge, but `queued` wears
  it too."** Behavior is correct (a queued tile's picture is equally
  deliverable and the wait is sub-second-to-~2 s); the enum doc was
  amended 2026-08-25 to match the code.
- **R3 — "a session born `LiveVideoPhase.unconfigured` would map to a
  connecting feed whose listener never fires."** Unreachable by
  construction: `urlFor` null-checks settle the feed at
  `FeedPhase.unconfigured` above the opener, and no player is ever born
  `unconfigured` (that phase means "nothing was dialled").
- **R4 — "a below-the-fold auto-live tile dials at build."** Real but
  bounded and moot: feeds are born `_visible = true` and dial at attach;
  if the tile is actually off-screen, the VisibilityDetector reports
  `0` within ~0.5 s and the 45 s `offscreenLinger` stops it. On today's
  house the one below-the-fold tile is the **doorbell** (`autoLive:
  false`), so nothing dials at all. **Revisit trigger:** the grid order or
  fleet changes so an auto-live camera sits below the fold; the fix
  direction would be deferring the first dial until the first visibility
  report — rejected for now because it costs first-paint latency on every
  tile to save 45 s of stream on a hypothetical one.

---

## 3. Invariants any future change must keep

Pinned by `cameras_view_test.dart`, `stream_director_test.dart`,
`device_popup_test.dart`, `live_video_keepalive_test.dart` — and by
argument in the module docs:

1. `LiveVideoPhase` is never extended — Director-level facts live in
   `FeedPhase`.
2. A `LiveVideoOpener` may not throw; every layer that receives one
   defends anyway (settled failed session, never an exception).
3. Every session closes exactly once per consumer, by every route out;
   `close()`/`release()` idempotent.
4. A `SettledLiveVideoSession` never fires its phase listener — every
   open path checks the born phase synchronously.
5. `view` identity is stable within one dial; never wrap it per rebuild.
6. The doorbell's `autoLive` stays `false` (HA #177014) and its stream is
   never consumed through go2rtc except by a person-opened surface; its
   still stays HA-held (`camera.front_door_snapshot`), never
   `frame.jpeg`.
7. LIVE badge ⇔ `FeedPhase.isLive` (connecting | playing), nothing else.
8. Failure strings never contain URLs; stream names are the loggable
   half; never log secrets (`diagnostics/log.dart`).
9. No `Timer` outlives its owner: feeds cancel on `release()`, the
   Director on `dispose()`; the view-owned Director dies with the view.
10. Person-origin exemptions: no viewport stop, no overlay pause, no
    automatic retry, no admission spacing.
11. Tiles dial `DirectorPolicy.tileStream` (substream-first), zoom/Popup
    dial the main stream; zoom-replaces-grid stays a mode, not a route.
12. go2rtc stays the ONLY RTSP client of any camera (Wyze serves ~3–4
    sessions); the web build consumes go2rtc only.

---

## 4. The remaining work — implementation plans

Ordered roughly by when their triggers fire. Each item names its trigger,
its steps, and any owner decision it must not proceed without.

### N1 — Camera recovery, then the stagger re-run *(DONE 2026-08-26 — record below; the protocol is kept for future re-runs)*

**Recovery record:** the four dead cameras had **lost their RTSP
configuration outright** (Wyze app: "Not Set") — app restarts did nothing
because there was no daemon to start. The owner re-entered RTSP per camera
with the original credentials (`~/.sh_keys/wyze.env`; ground truth is the
live go2rtc.yaml's producer URLs). All five daemons then listened on 322,
one authenticated verification pull delivered a frame in 6.2 s, and all
five `binary_sensor.wyze_*_rtsp` flipped `on` within their minute.

**Experiment record (2026-08-26 ~03:04–03:07 UTC), seconds to first
frame, every pull ok:**

| Round | Mode | living | family | garage | back_yard | back_yard_door |
|---|---|---|---|---|---|---|
| 1 | Simultaneous | 4.1 | 5.4 | 7.2 | 5.0 | 7.0 |
| 2 | Staggered-2s | 4.0 | 5.4 | 5.2 | 5.0 | 5.4 |
| 3 | Simultaneous | 4.1 | 4.3 | 4.7 | **9.9** | **12.2** |
| 4 | Staggered-2s | 4.1 | 6.0 | 5.6 | 5.6 | 6.0 |

Log correlation: exactly two go2rtc warnings in the whole window, both in
round 3 — first-dial `EOF` on `.62` and `.63`, absorbed by go2rtc's retry;
they are round 3's two tail times. Staggered rounds logged nothing.

**Verdict (per the decision rule):** no failures in either mode →
**`dialSpacing` stays 400 ms as documented hygiene**. Simultaneity does
not cause the flakiness (the diagnosis stands: config-loss/daemon death +
Wi-Fi blackouts). The one real simultaneous cost — an occasional
first-attempt EOF that a retry absorbs at ~2× time-to-first-frame — is
exactly the class 400 ms of spacing cheaply damps; nothing here justifies
raising it toward 2 s. Recorded in the phase-8 doc §D/§E.

The original protocol, for any future re-run:

1. Confirm from the host:
   `for ip in 57 69 63 54 62; do timeout 3 bash -c "echo > /dev/tcp/192.168.68.$ip/322" 2>/dev/null && echo $ip: LISTENING || echo $ip: down; done`
2. Re-run the load experiment (the original protocol, all rules intact):
   pulls are `docker exec go2rtc timeout 28 ffmpeg -v error -stats
   -rtsp_transport tcp -i rtsp://127.0.0.1:8554/<name>_sub -map 0:v:0
   -frames:v 1 -f null -` against the five `wyze_*_sub` streams ONLY
   (never `ring_doorbell`); alternate rounds Simultaneous / Staggered-2s,
   ≥2 of each, 45 s cool-downs (poll redacted `/api/streams` until
   consumers drain); record per-round per-stream ok/fail +
   seconds-to-first-frame; correlate with `docker logs go2rtc --since 30m`
   piped through `sed -E 's#://[^@/ ]+@#://REDACTED@#g'`.
3. **Decision rule:** if simultaneous rounds fail where staggered succeed →
   spacing is real; consider raising `dialSpacing` toward the measured
   safe gap. If identical → spacing stays at 400 ms as documented hygiene.
   Either way, record the verdict in `phase-8-cameras-streaming.md` §D/§E
   (the "stagger verdict" row closes).

### N2 — Monitor-data review *(trigger: ~7 days of probe history)*

The five probe sensors chart daemon uptime in HA's recorder. Query without
printing the token:

```bash
TOKEN=$(tr -d '[:space:]' < ~/.sh_keys/token)
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8123/api/history/period/<ISO-week-ago>?filter_entity_id=binary_sensor.wyze_family_room_rtsp,binary_sensor.wyze_living_room_rtsp,binary_sensor.wyze_back_yard_rtsp,binary_sensor.wyze_back_yard_door_rtsp,binary_sensor.wyze_garage_door_rtsp&minimal_response" \
  | python3 -c "…compute per-camera: uptime %, deaths/day, mean time-to-recover, self-recovery rate…"
```

Facts this feeds: **N3** (preload-all go/no-go), **N4** (`wyze://`
go/no-go), and whether daemon death correlates with streaming activity
(the 2026-08-25 session saw Living Room die ~40 min after serving the
load experiment, then self-recover — one data point, not a pattern).

### N3 — Preload all five substreams *(trigger: N2 says daemons are stable and the airtime budget tolerates it)*

- Edit `~/.sh_keys/go2rtc/go2rtc.yaml`'s `preload:` section to add the
  five `wyze_*_sub` names with value `"video"` (keep the two floodlight
  MAINS already there — they serve the zoom path). Mirror the shape in
  `hub/go2rtc/go2rtc.example.yaml`'s phase-8 section.
- `docker compose -f hub/compose.yaml restart go2rtc`, verify via
  redacted `/api/streams` that the five sub producers hold connections.
- Cost to state honestly: ~5 × substream bitrate held on the 2.4 GHz cell
  24/7. Benefit: tile-open becomes pure attach (no per-open DESCRIBE, no
  cold start), and go2rtc's own reconnect owns liveness.
- Rollback: remove the lines, restart.

### N4 — Native `wyze://` source experiment *(trigger: N2 shows chronic daemon death)*

The RTSP daemon is the thing that dies; go2rtc 1.9.14's experimental
`wyze://` source (local TUTK P2P) bypasses it entirely on stock firmware.
One-camera trial, owner in the loop (needs a Wyze account + API-key login
through the go2rtc WebUI, which auto-generates the source URLs):

1. Pick a plain v3 (living room — the historically healthiest).
2. Add a parallel TEST stream (`wyze_living_room_tutk:`) rather than
   touching the production one; `subtype=hd|sd` maps onto the
   main/substream split.
3. Compare over days: uptime vs the RTSPS path (the port-322 probe only
   monitors the RTSP daemon — TUTK health would need its own signal, e.g.
   a periodic `frame.jpeg` pull on the test stream).
4. **Caveat carried from the config docs:** go2rtc rewrites its own yaml
   on some API calls (ADR-0011 noted it) — diff the live file against the
   backup after any WebUI login flow.
5. Only after weeks of parity: swap producers per camera, keep RTSPS
   commented as the fallback shape.

### N5 — The H.264/RTSP appliance adapter *(trigger: owner wants it; now unblocked — the Director gives it ONE call site)*

The big appliance win from the architecture review: delete the per-stream
ffmpeg MJPEG transcode on the Hub, the ~7× bytes, the per-frame JPEG
decode in Flutter, and the cold-floodlight zero-byte race, by playing
go2rtc's RTSP restream (`rtsp://127.0.0.1:8554/<name>`) directly.

**Step 1 — prototype (throwaway, a day):** two candidates, both rendering
to Flutter Textures (ordinary clippable widgets — no platform-view tap
workaround on this path):
- `fvp` 0.38.1 (libmdk; actively shipped Aug 2026; `'lowLatency': 1`,
  NVDEC relevant on the Legion's NVIDIA) — the safer-maintenance bet.
- `media_kit` 1.2.6 (libmpv from the distro — `apt install libmpv-dev
  mpv`, an owner `!` action; pinned "Limited Maintenance" upstream but
  `NativePlayer.setProperty` gives full mpv control:
  `profile=low-latency`, `cache=no`, `demuxer-readahead-secs=0`,
  `rtsp-transport=tcp`, `untimed` is safe for muted tiles).

Acceptance gauntlet, measured not vibed: 6 simultaneous 640×360 players
against the live substreams; CPU vs the MJPEG path on the appliance;
time-to-first-frame warm/cold (incl. a floodlight — the RTSP client should
simply wait out the 17 s warm-up instead of the zero-byte race);
teardown → go2rtc consumer count drains; texture clips under
`PanelTheme`'s rounded corners; a multi-hour soak for leaks.

**Step 2 — the adapter behind the seam:** the conditional import in
`live_video.dart` selects by *platform* (VM/web), so a second VM player is
a *runtime* choice at the composition root, which the seam already
supports (`VideoConfig.open` is injected):
- New file `panel/lib/ui/video/live_video_rtsp.dart`: a
  `LiveVideoSession` implementation over the chosen player. It must keep
  every contract in §3: never throw from the opener; phases honest
  (`connecting` until a real first frame — the player's "buffering ended"
  signal, never bytes); the 25 s open / 15 s stall watchdog pair (reuse
  the constants' arguments, constructor-injectable); `failure` strings
  redacted by type-name discipline; `view` stable per dial; `close()`
  actually tears the RTSP session down.
- URL mapping lives inside the adapter, exactly as
  `mjpegEndpointFor` does: seam URL `ws://host:1984/api/ws?src=X` →
  `rtsp://host:8554/X` (note the PORT change — 8554 is a different
  listener than 1984; derive host from the seam URL, port is the
  adapter's own constant).
- `main()` selects: `--dart-define=VIDEO_TRANSPORT=rtsp|mjpeg`, default
  `mjpeg` until the soak passes. The MJPEG adapter and its 665-line
  real-socket suite (the best-proven code in the feature) stay as the
  fallback the seam makes cheap to keep.

**Step 3 — tests:** hermetic seam-contract tests (the adapter against the
`LiveVideoSession` interface obligations, fake clock for watchdogs); an
opt-in live test against the dev go2rtc `selftest` stream, patterned on
`live_video_keepalive_live_test.dart`. The whole widget suite is
unaffected: it injects `FakeGo2rtc` above the seam.

**Step 4 — config retirement (later):** once RTSP is the shipped
transport, the `#video=mjpeg/…` wrapper producers in the live go2rtc.yaml
become dead lines; retire them one camera at a time (stills survive —
`frame.jpeg` grabs keyframes off the H.264 producer). Not before: the web
build never used them (MSE), but a `VIDEO_TRANSPORT=mjpeg` rollback needs
them.

**Non-goals:** flutter_webrtc/WHEP on the kiosk (an ICE/DTLS/SRTP stack to
reach localhost buys nothing); touching ADR-0011's talk path (separate
`TalkConfig`, unaffected).

### N6 — go2rtc-direct stills for the Wyze tiles *(IMPLEMENTED 2026-08-25 — the record below; prereq for N7 now satisfied)*

What was built (all unstaged, alongside the phase-8 tree):

- **`Go2rtcStillsConfig`** in `lib/ui/video/snapshot.dart`, beside
  `SnapshotConfig` — `urlFor(streamName)` →
  `http://host:1984/api/frame.jpeg?src=<name>&cache=45s`, the same
  null-instead-of-throw guards as its siblings, tokenless by design (its
  doc carries the why). Verified against the live go2rtc 1.9.14: a repeat
  fetch inside the cache window is **byte-identical in <1 ms with no
  camera dial**; a cold miss starts the producer (~3 s).
- **Both fetchers hardened** (`snapshot_io.dart` / `snapshot_web.dart`):
  an empty token now sends **no Authorization header** (on web this also
  keeps the request CORS-simple — no preflight for go2rtc to fail), and a
  **zero-byte 200 is refused** with status `empty` — measured live: that
  is exactly what `frame.jpeg` answers for a camera whose RTSP daemon is
  dead, and `Image.memory` over zero bytes throws in the tile.
- **`CameraTile` two-source preference** (`cameras_view.dart`): the
  HA-held JPEG where `snapshotEntityId` exists (the doorbell — costs no
  device session, fetched regardless of phase as before), else the frame
  grab over `substream ?? streamName` — **`_grabStream` returns null for
  every kind but `DeviceKind.camera`**, which is the doorbell's wall
  (#177014). The grab is phase-gated (`_grabAllowed`): only
  idle/queued/unconfigured/unsupported. Live buys nothing, failed/retrying
  belongs to the retry ladder, offline is Camera Health's verdict — a grab
  IS a dial when the producer is cold, and recovery detection is the
  monitor's job.
- **Threading**: `PanelApp.stills` (required) → `showCamerasView` →
  `CamerasView` → tile; `main()` builds it from the same `GO2RTC_URL` the
  video seam uses; `test/fixtures.dart` defaults it to unconfigured (and
  `panelApp` gained a `director:` pass-through; `houseWithStream` gained
  `clearSnapshot:` for the one scene `??`-keep cannot spell).
- **Tests (+10, suite now 551+2)**: `snapshot_test.dart` — the URL rule
  group, no-header-on-empty-token, zero-byte-200-refused;
  `cameras_view_test.dart` — the grab bills the substream tokenless on the
  60 s cadence and paints; **the doorbell canary** (wired for video, NO
  snapshot binding, stills configured — the kind check is the only wall,
  and nothing is fetched); a pursued tile (live, then failing under the
  ladder) never grabs.

Still open under this heading:
- The **offline** arm of `_grabAllowed` is exercised by no widget test
  (staging it needs a health-injected Director in the view suite —
  `FakeHealth` lives in `stream_director_test.dart`; move it to
  `test/support/` if that test is ever wanted). The arm is one case in one
  switch the other arms pin.
- Cadence: 60 s with `cache=45s` means every steady-state tick is a cache
  miss — but under today's **auto-live** policy the grab loop almost never
  runs steady-state (auto-live tiles sit in pursued phases; idle happens
  at viewport-stop and brief queue moments, where the cache makes remounts
  free). The pair becomes load-bearing only with the N7 stills-first flip
  — re-derive the cadence/cache numbers there, with N3's preload state in
  hand.

### N7 — Stills-first flip *(trigger: owner wants the airtime headroom; N6 is done, so this is now ~an evening)*

The policy-as-data payoff. Mechanics:
- The wall: `main.dart`'s `StreamDirector(policy: DirectorPolicy(autoLive:
  DirectorPolicy.never), …)`. **Detail that bites:** the view-owned
  fallback Director (hermetic tests, and any surface not handed the
  global one) constructs `const DirectorPolicy()` — auto-live. That is
  correct for tests; just be aware the flip lives in `main()` only.
- UI: idle tiles then wear the N6 stills + "Tap for live"; a tap today
  ZOOMS (it does not start the tile) — decide with the owner whether
  stills-first changes the tap to `feed.start()` (tile goes live in
  place; `CameraFeed.start` exists and is tested) or keeps tap-to-zoom.
  Record the choice in the phase-8 doc.
- Paperwork: phase-7 §B3's auto-live ruling is superseded — amend the
  phase-8 doc (§C already frames stills-first as the held-in-reserve
  policy) and consider an ADR if the owner wants it durable.

### N8 — Fold dial outcomes into Camera Health *(low priority; trigger: probes prove insufficient alone)*

`HubCameraHealth.dialOutcome` deliberately drops outcomes today (its doc
says why: outcomes need decay rules — one failed dial during a Wi-Fi blip
must not mark a camera offline for a minute). If N2's data shows probe
lag matters (deaths between probe ticks), design: outcomes as a
short-lived overlay verdict (e.g. two consecutive failed dials within
30 s → `unreachable` until the next probe tick contradicts), never
outranking a fresh probe. Pure-Dart testable beside the existing suites.

### N9 — Web second-screen items *(trigger: web Panel work resumes)*

- **Platform-view overlay ceiling (live risk):** Flutter web caps
  compositing overlays at 7 and silently drops later ones. Six playing
  MSE tiles + a ding-Popup video = 8 for up to `overlayLinger` (45 s).
  Options when this becomes real: a shorter overlay linger on web (policy
  is per-Director — the web build can construct its own), or detaching
  grid platform views without closing streams. Measure first: it needs a
  browser and the real wall layout.
- **Idle-return dedup:** the third copy of the warn/fire/prompt/
  route-guard machinery would arrive with a web-specific surface — that is
  the trigger the review set for extracting the `IdleReturn` module
  (candidate 6 of the architecture report; CamerasView and DevicePopup
  hold the two existing copies).
- **MSE stays the web transport** (Frigate's own convergence); go2rtc's
  WHEP endpoint is the fallback if MSE latency ever matters (port 8555
  must then be reachable alongside 1984).

### N10 — Small ops follow-ups

- **VAAPI:** blocked on the standard image (no Intel libva driver;
  `/dev/dri` IS mapped and the probe command is
  `curl -s http://127.0.0.1:1984/api/ffmpeg/hardware`). The one-line
  option is the `alexxit/go2rtc:1.9.14-hardware` image variant — an owner
  pin decision (bigger image, different contents). Moot if N5 retires the
  MJPEG transcodes.
- **Camera status text cosmetics (verify, then decide):** the entity swap
  means camera Devices fold `StatusState('on'/'off')`. Check whether that
  string surfaces anywhere user-visible (Dollhouse pin popups/status
  rows) — if it does, prettify per-kind in the presentation layer or
  accept it. Not asserted as a problem; nobody has looked yet.
- **HA log noise:** after a few days, skim `hub/ha-config/home-assistant.log`
  for `command_line` warnings (a timing-out probe exits non-zero by
  design — `|| echo OFF` keeps the sensor honest, but HA may still log
  the non-zero exit). If noisy, wrap the command to always exit 0.
- **Wall deployment:** the wall build must pick up the Panel changes when
  the kiosk finally exists (no cage/touchscreen yet as of 2026-08-25 —
  commissioning 06 stops at Xvfb first-light).

---

## 5. Command appendix

```bash
# --- Panel (always from panel/) ---
cd /home/dmorozov/Work/SmartHome/panel
flutter analyze --no-pub
flutter test                                  # full: 541 + 2 skipped
flutter test test/stream_director_test.dart   # the Director machine
flutter test test/camera_health_test.dart     # the probe adapter
flutter test test/cameras_view_test.dart      # the pinned view invariants

# --- Camera daemon truth (host, credential-free) ---
for ip in 57 69 63 54 62; do timeout 3 bash -c \
  "echo > /dev/tcp/192.168.68.$ip/322" 2>/dev/null \
  && echo "192.168.68.$ip: LISTENING" || echo "192.168.68.$ip: down"; done

# --- Probe sensors (token stays in the variable, never echoed) ---
TOKEN=$(tr -d '[:space:]' < ~/.sh_keys/token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8123/api/states \
  | python3 -c "import json,sys; [print(s['entity_id'],s['state']) \
    for s in json.load(sys.stdin) if 'rtsp' in s['entity_id']]"

# --- go2rtc (output must be redacted before reading) ---
curl -s http://127.0.0.1:1984/api          # version (1.9.14) — safe
curl -s http://127.0.0.1:1984/api/streams | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(len(d), sorted(d))"  # names only
docker logs go2rtc --since 1h 2>&1 | sed -E 's#://[^@/ ]+@#://REDACTED@#g' | tail -20
docker compose -f /home/dmorozov/Work/SmartHome/hub/compose.yaml restart go2rtc

# --- Live config safety ---
# NEVER cat ~/.sh_keys/go2rtc/go2rtc.yaml. Pre-phase-8 backup:
ls -la ~/.sh_keys/go2rtc/   # go2rtc.yaml.bak-20260825-phase8
```
