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
    admission spacing. *The no-automatic-retry exemption was retired
    2026-08-26 (N11): person-origin cameras ride the ladder; only a
    person-origin NON-camera (the doorbell) rests at `failed` — that
    narrowing is itself pinned (#177014).*
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
**2026-08-26 additions:** during sustained streaming (the N5 soak plus the
owner's live Panel session), Garage and Living Room daemons died within a
minute of each other (~03:52 UTC, ~20 min into the soak) and **both
self-recovered ~5 min later** (probes `off` 03:52/03:53 → `on`
03:57/03:58). Three deaths so far, all during-or-after sustained serving,
all self-recovering — the correlation is firming and the owner watched
the whole loop work: honest "Camera offline" faces on the probe flip,
automatic re-dial on recovery, no restart, no interaction.

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

**Step 1 — prototype: RUN 2026-08-26, fvp PASSES.** Throwaway app in the
session scratchpad (`rtsp_probe/`, argv: `[seconds] [stream...]`), fvp
0.38.1 over `video_player`, `lowLatency: 1`, RTSP/TCP (fvp's own default),
pulling go2rtc's restream on host port 8554 (published; go2rtc stays the
only RTSP client of the cameras). Measured, headless under Xvfb
(software GL — real-GPU numbers will be better):

- **6 simultaneous players** (5 live Wyze subs + selftest): all played,
  camera first-frames at **3.9–5.1 s**, zero failures, 60 s steady.
- **App cost:** ~55 % of one core, 459 MB RSS — including Xvfb software
  rendering of six textures.
- **Hub cost, the headline:** go2rtc at **35 % CPU / 117 MiB** serving six
  RTSP copies (selftest's own ffmpeg pattern included) vs **52 % CPU /
  573 MiB** for today's five `mjpeg/tiles` transcodes. The Panel-side
  saving (no per-frame JPEG decode) is on top and unmeasured.
- **Cold floodlight main:** 1080p first frame in **3.9 s** — the RTSP
  client waits out the producer start; no 17–18 s pathology, no
  zero-byte race on this path.
- **Teardown:** consumer count drained to 0 both runs.
- **Soak verdict (two runs, 2026-08-26): no leak.** Run 1 (five live
  cameras + selftest) was cut short at ~20 min deliberately (two Wyze
  daemons died mid-soak — N2's pattern — while the owner live-tested):
  zero failures, sustained ~55 % CPU decode, RSS 453 → 490 MB across its
  one sampled interval. Run 2 (`selftest` ×6, camera-free) went the full
  2 h: zero failures, clean teardown, and **RSS dead flat at 383 MB for
  110 minutes across 11 samples** — the plateau answer. Caveat stated
  honestly: run 2's CPU collapsed to ~0.6 % after the first minutes and
  only one player ever advanced `position` (the known selftest anomaly),
  so its decode load was light-or-stalled — sustained-heavy-decode
  evidence rests on run 1's 20 clean minutes plus the owner's live
  `VIDEO_TRANSPORT=rtsp` session. go2rtc's log was silent throughout run
  2 (no producer events), so the quiet is fvp-side handling of the
  synthetic pattern, not a server fault; on the wall the adapter's 15 s
  stall watchdog turns any real stall into a ladder re-dial by design.
  (Ops note from run 1: never let the app's `>` redirect and a monitor's
  `>>` share one log file.)
- **Still open from the gauntlet:** the soak re-run (above), texture
  clipping under `PanelTheme` rounded corners (needs a real GPU session —
  the owner's live `VIDEO_TRANSPORT=rtsp` run is exactly that), and the
  anomaly that `selftest` INIT'd but never advanced `position` past zero
  (cameras all did; check whether position is the right first-frame
  signal per stream type before trusting the adapter's watchdogs on
  unusual streams).

media_kit was not exercised — fvp met the gauntlet without system deps,
so the tie-breaker (`apt install libmpv-dev`, an owner action) was never
needed. Candidates, for the record:
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

**Step 2 — the adapter behind the seam: BUILT 2026-08-26** (unstaged, with
everything else). What landed, against the plan below it:

- `lib/ui/video/live_video_rtsp.dart` (conditional shell) →
  `live_video_rtsp_io.dart` (the adapter) / `live_video_rtsp_web.dart`
  (web stub: delegates to the platform player with one
  `video_transport_fallback` warning — browsers do not speak RTSP, and a
  misconfigured define must cost nothing).
- `RtspLiveVideoSession` over fvp 0.38.1 via `video_player`
  (`fvp.registerWith({'lowLatency': 1})` once, lazily, in the opener):
  never-throwing opener; **position-advance is the first-frame and
  liveness signal** (fvp's `isInitialized` is metadata, before any
  picture — the honest-phases rule); the seam's own deadlines reused
  (`kRtspFirstFrameTimeout`/`kRtspStallTimeout` alias the MJPEG pair —
  "the branches are kept equal deliberately"); failure strings type-only,
  platform error text never repeated; `view` built once per dial;
  `close()` idempotent, disposes the player (which drains the go2rtc
  consumer).
- `rtspEndpointFor`: `ws(s)://host:1984/api/ws?src=X` →
  `rtsp://host:8554/X`, always cleartext `rtsp` (8554 has no TLS
  listener), **userInfo stripped** (GO2RTC_URL may carry API credentials;
  they never reach a native player whose error strings we do not control).
- `main()` selection, environment-first like every Hub setting
  (`VIDEO_TRANSPORT` env, then the dart-define, default `mjpeg`) —
  rollback is a systemd restart, not a rebuild; logged as
  `panel.video_transport`, unknown values warn and fall back to mjpeg.
  The keep-alive pool wraps the selected opener
  (`LiveVideoKeepAlive(opener: rawOpen)`).
- `pubspec`: + `video_player`, + `fvp`. Both builds verified compiling
  (web 21 s; linux — after clearing a stale devcontainer CMake cache in
  `build/linux`, an environment quirk, not a code fact).
- Tests: `test/live_video_rtsp_test.dart`, 11 hermetic cases — URL rule
  (incl. the credential-strip and no-TLS-invention), metadata-is-not-a-
  picture, open/stall watchdogs, error redaction, typed init failure,
  idempotent close with no timers left. **No opt-in live suite**: fvp's
  native library is not built for VM test runs (the MJPEG live suite is
  pure `dart:io`) — the live proof is the `rtsp_probe` prototype run and
  the wall itself under `VIDEO_TRANSPORT=rtsp`.
- **Default FLIPPED to `rtsp` 2026-08-26** (owner decision, after the
  soak verdict and a live session): `main()` resolves
  `VIDEO_TRANSPORT` environment-first with `rtsp` as the fallthrough on
  the appliance; the web build never consults it (its transport is MSE,
  stated in `main()` rather than routed through the stub's
  misconfiguration warning). **Both transports are first-class peers by
  the same decision** — the owner switches in production with
  `VIDEO_TRANSPORT=mjpeg` + restart, no rebuild — which means **step 4
  below (retiring the `mjpeg/tiles`/`mjpeg/zoom` wrapper producers from
  the live go2rtc config) is OFF the table**: the fallback needs them
  serving. Revisit only if the owner ever demotes MJPEG outright.

**Step 2½ — the frozen wall (2026-08-27, hunt OPEN).** The gauntlet item
"texture clips under `PanelTheme`'s rounded corners (needs a real GPU
session)" turned out to be the whole ballgame: **the RTSP wall has never
played on the appliance stack** — five tiles show a never-updated texture
(uninitialized-FBO confetti or one stale frame) while decode advances,
the engine draws 60 fps, and only scrolling refreshes the picture. MJPEG
unaffected; the commit-bisect that seemed to show a regression was
measuring the transport default flip (`f43c52f` "worked" because it was
silently on MJPEG; forced to RTSP it freezes too).

What the bisect campaign established, each line carrying its method:

- **Exonerated** (probe apps, `CAMERAS_GRID` arms `nodrag`/`legacy`/
  `probe`/`probepool`, `VIDEO_TILE` arms, zoom behaviour): the grid
  skeleton and drag rewrite, decoders both ways, `lowLatency`, the frame
  pulse, texture count per se (a clean-room probe plays
  N=5), the app shell (the transplanted probe grid plays inside the full
  Panel), the Stream Director and keep-alive pool (`probepool` plays;
  `raw` — bare early-mounted tiles through the full Director — plays).
- **Convicted:** **the full shell — the rounded clip its prime suspect.**
  Every arm carrying the clip froze in every observation (`full`,
  `early`, `rawclip`, `rawshadow`, `rawbar`, `rawrrect`, `rawhard`,
  `rawcard`: 2026-08-27 single runs, plus `full`×3 and `early`×3 hard
  0/6 on 2026-08-28); every no-clip arm plays (17+ rig runs, one
  wall-wide exception below). Failure ages differ: under the shell,
  tiles are **born dead** — blank faces or uninitialized-FBO confetti
  under LIVE badges, no frame ever drawn — where the no-clip card's one
  freeze drew good frames first and stopped wall-wide.
- **REFUTED 2026-08-28 (mount order, issue #6): mount-after-frames is
  not a factor.** The 2×2 factorial {shell, view-mount order}, three
  rig runs per cell, stalled-stream cells discounted by their burned-in
  clocks: `raw` (no shell, view from birth) healthy 3/3; `bare` (no
  shell, view at playing) healthy 3/3 — the 2026-08-27 bare-vs-raw
  split was a single-run artifact; `early` (shell, view from birth)
  0/6×3; `full` (shell, view at playing) 0/6×3. Mount order changes
  nothing in either direction. The dial-after-mount arm issue #6
  proposed is moot twice over: the admission gate already dials every
  queued tile after its mount (only the first tile dials synchronously
  in `initState`), and mount order is measured irrelevant.
- **REFUTED 2026-08-28** (the full sweep, issue #5): the 2026-08-27
  "combination load threshold" was an artifact — the `fixcorners` arm sat
  behind a `startsWith('raw')` gate it could never pass and silently
  measured the FULL design (the fourth arm of this hunt to test nothing;
  caught by the rig's own grab — the doorbell wore the full design's
  still face). With the gate fixed and the arm pinned by a widget test:
  every pair and every triple of {shadow, radius, notch, bar} plays, and
  the four-piece no-clip card plays too (`rawmix` all-four 3/3 runs,
  `fixcorners` 2/3). The one exception is the finding: one `fixcorners`
  run stopped WHOLE — five textures at one instant, synchronized
  burned-in camera clocks, pixel-identical 3 s later — so the sever is a
  **wall-wide, probabilistic event** whose odds grow with paint load,
  not a guilty widget. Corollaries: (a) single-run verdicts near the
  boundary are insufficient — repeat, and read the burned-in clocks: a
  cell whose clock LAGS its neighbours is a stalled stream (roving Wyze
  daemon stalls polluted five sweep runs), one whose clock MATCHES while
  pixels hold still is a severed texture; (b) the no-clip four-piece
  card is the leading design candidate, carrying a wall-stop risk
  observed once in three runs that the mechanism/patch tickets (#10,
  #13) must retire.
- **CONVICTED 2026-08-28 (the renderer, issues #10/#12): the freeze is
  Impeller's.** The release bundle had been running Impeller all along
  ("Using the Impeller rendering backend (OpenGLESSDF)" in every rig
  log — the Flutter 3.47 Linux default), so every conviction above
  reads "…under Impeller". A release-valid runner knob
  (`PANEL_RENDERER=skia` → `fl_dart_project_set_enable_impeller(FALSE)`,
  pinned by a `panel.renderer` stderr line) flips the same build to
  Skia: the complete shipped design — clip, shadows, bars — renders
  healthy 3/3, and the Impeller-only edge-confetti bands vanish. The
  earlier "Impeller-vs-Skia exonerated" arm was an env-var switch on a
  release bundle; release builds compile those switches out, so it
  measured Impeller against Impeller. Caveat for the fix decision:
  upstream warns the Skia opt-out will be removed in a future release.
- **Mechanism** (observed 2026-08-28, replacing the earlier fvp#271
  research story, which left no footprint here): mdk renders into the
  void — per-player accounting (position, cache, fps, vo) healthy and
  indistinguishable from a playing run while the glass is dead; no GL
  errors under `GL_DEBUG=1`; zero `gdk gl context change` lines in 30+
  logs; FBO creation identical frozen-vs-healthy. Two failure ages
  under Impeller: textures born dead (blank faces / uninitialized-FBO
  confetti under LIVE badges) whenever clip/saveLayer content is in the
  scene from birth, and a rare wall-wide simultaneous stop after good
  frames (synchronized burned-in clocks) without it. The single-texture
  zoom playing fits: the trigger scales with composited load. The
  Impeller-internal detail belongs to the upstream report (issue #14).
- **The validation rig:** `panel/tool/freeze_probe.sh` — autonomous
  launch/capture/verdict, calibrated both directions (known-playing reads
  5/6 moving with the idle doorbell cell frozen; known-frozen reads 0/6).
  Method and trust rules: `.claude/skills/flutter-linux-eyes/SKILL.md`.
  Supporting knobs shipped for it: `CAMERAS_OPEN=auto`, `VIDEO_TILE`
  arms incl. `rawmix`+`VIDEO_MIX`, `PANEL_RENDERER=skia` (runner-level
  renderer pin, release-valid), `VIDEO_DEBUG` pulse+pixel lines (the
  pixel sampler segfaults release GLES runs — rig leaves it off).

The hunt is tracked on the wayfinder map (GitHub issue #4); decisions
live on its closed tickets. Owed once it closes: delete every bisect
arm (`CAMERAS_GRID`, `VIDEO_TILE`, `VIDEO_MIX`), revert the
`VIDEO_DECODERS=FFmpeg` pin to auto (disproved both directions), decide
the frame pulse's fate against measurements, settle the renderer
default per the fix decision (issue #11), and carry the upstream report
(issue #14) to flutter/fvp — the clean-room probe plus the renderer A/B
is the repro.

The original plan, for reference:
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

**Addendum 2026-08-26 — hardware decoding scrambles the wall; the shipped
default is now software.** First real look at the RTSP transport driving the
*whole grid* on the Hub's own display: of four live tiles, one decoded
cleanly, two rendered as macroblock garbage (red/yellow, then green/purple
noise) and one stayed blank — all four wearing the LIVE badge, because the
sessions were healthy and only the pictures were not.

Not the cameras, and not the air. The same three substreams software-decoded
inside the go2rtc container for 6–8 s each with **zero ffmpeg warnings**, at
`h264 640x360` and 15–20 fps — so go2rtc's relay and the 2.4 GHz link were
both fine, and the fault was entirely Panel-side.

**First hypothesis, and it was wrong**: fvp's Linux list prefers hardware
(`['VAAPI', 'CUDA', 'VDPAU', 'hap', 'FFmpeg', 'dav1d']`) and the Hub is
hybrid graphics (Intel Raptor Lake-S UHD iGPU + NVIDIA RTX 4090 Laptop,
driver 595.84, no `vainfo`, no host `ffmpeg`), so the decoder looked guilty.
Pinning `['FFmpeg']` **did not fix it** — the corruption changed character
(macroblocks became a washed-out overlay) and spread to the one tile that had
been clean. A cause that survives replacing the decoder is not the decoder.

**Actual cause: `lowLatency: 1`**, the single option the Panel passed to
`fvp.registerWith` since the transport landed. fvp's own source says what it
does, one line above applying it:

```dart
// +nobuffer: the 1st key-frame packet is dropped. -nobuffer: high latency
player.setProperty('avformat.fflags', '+nobuffer');
```

It **drops the first key frame**. H.264 is differential, so a decoder given
the packets after an IDR but not the IDR has nothing to reference: it paints
garbage and keeps painting until the camera sends another key frame — a long
time on a long-GOP Wyze substream, and with error propagation sometimes never
resolving. That is why plain `ffmpeg`, which drops nothing, decoded the same
substreams flawlessly, and why swapping decoders changed only the flavour.

Fix: two operational settings in `live_video_rtsp_io.dart`, both resolved by
`main()` environment-first exactly like `VIDEO_TRANSPORT`, both logged at
boot as `panel.video_player`:

| setting | shipped | notes |
|---|---|---|
| `VIDEO_LOW_LATENCY` | `0` | **the fix.** Every value > 0 sets `+nobuffer`, so 0 is the only safe one; the knob exists to reproduce the fault, not to tune it. Costs mdk's ordinary buffering — slower first frame, some delay behind real time |
| `VIDEO_DECODERS` | `FFmpeg` | software, portable across the dev box's NVIDIA and the appliance's AMD. `auto` restores fvp's hardware-first list |

**Open:** whether hardware decode was ever a problem at all is now unknown —
it was only ever observed alongside the dropped key frame. Worth one run at
`VIDEO_DECODERS=auto` with `VIDEO_LOW_LATENCY=0` before treating software as
required, since the appliance is a modest AMD Radeon rather than this dev
laptop and would rather not spend a core on decode. Software is affordable at
tile size regardless (640×360 × 6; the phase-8 prototype measured ~half a
core for six streams including software GL under Xvfb); the 1080p zoom is the
case to re-measure.

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

- **Floodlight preload EOF loop — CLOSED 2026-08-26 by retiring A4
  (superseded), not by root-causing it.** The record: after the cameras'
  RTSP re-setup, the two preloaded mains (`.54`/`.62` `stream0` via the
  `ffmpeg:…#video=copy#audio=copy` producer) EOF-looped every ~7–15 s and
  never latched, while an on-demand pull of the same restream delivered a
  frame in 9.6 s. Entries commented in the live yaml (backup
  `go2rtc.yaml.bak-20260826-preload-suspend`), log quiet since. The
  retirement's argument: preload's two jobs were MJPEG-path artifacts and
  the shipped RTSP default has neither (cold main 3.9 s), while preload
  is config-only (POST `/api/preload` is 405 on 1.9.14 — no runtime
  arm/disarm), so reproduction costs production restarts and camera
  knocks for a feature with no remaining job. **If preload is ever wanted
  again** (MJPEG back as the daily driver, or N3/N4 reviving it), the
  preserved protocol: uncomment one entry + restart; if the loop returns,
  test whether preload's probe consumer selects producers differently
  from a real consumer, and whether a plain `rtsps://` first producer (no
  ffmpeg wrap) latches where the wrapped one does not — transient EOFs on
  the wrapped producers also appear in normal use (seen on three subs
  2026-08-26 ~04:07) and recover via retry when a real consumer holds;
  the N2 log-skim should watch whether that noise grows.

- **VAAPI:** blocked on the standard image (no Intel libva driver;
  `/dev/dri` IS mapped and the probe command is
  `curl -s http://127.0.0.1:1984/api/ffmpeg/hardware`). The one-line
  option is the `alexxit/go2rtc:1.9.14-hardware` image variant — an owner
  pin decision (bigger image, different contents). Moot if N5 retires the
  MJPEG transcodes.
- **Camera status text cosmetics — VERIFIED 2026-08-26, nothing to do:**
  the raw `StatusState('on'/'off')` never reaches a user-visible surface.
  `DevicePresentation.statusText` renders only in the non-video Popup
  body; video kinds take `_LiveVideoBox` (`device_popup.dart` ~890), and
  Dollhouse pins label only `PowerState` compactly. Re-check only if a
  camera kind ever grows a non-video status row.
- **HA log noise — VERIFIED 2026-08-26, quiet:** zero `command_line`
  lines in `hub/ha-config/home-assistant.log` after a day of the five
  probes at 60 s (`|| echo OFF` keeps the exit clean). Nothing to wrap.
- **Wall deployment:** the wall build must pick up the Panel changes when
  the kiosk finally exists (no cage/touchscreen yet as of 2026-08-25 —
  commissioning 06 stops at Xvfb first-light).

### N11 — Mid-watch reconnect + honest retry faces *(IMPLEMENTED 2026-08-26, same day as requested — record below; the original sketch follows it)*

What landed (suite 571+2 after):
- `_Feed._onDialFailed`: the ladder now serves person-origin feeds whose
  kind is `DeviceKind.camera`; a person-origin non-camera (the doorbell)
  still rests at `failed` — the arm carries the #177014 argument.
- `CameraFeed.retryAttempt` (0 when none; reset on playing and on
  health-flip recovery; HOLDS through a re-dial's connecting phase — that
  persistence is what the faces read). Doc on the interface states the
  +1 display rule: the first re-dial reads "try 2".
- Faces: zoom — "Reconnecting… try #N" for `retrying` AND for
  `connecting` with a nonzero count ("Connecting…" is first-dials only);
  tile — quiet "Reconnecting…" corner tag over the aged still for
  `retrying`, word-swap for re-dial connecting. `failed` keeps "Live view
  failed" and is now doorbell-territory only.
- Tests: the old "person-origin rests at failed" pin is superseded and
  says so in place; new pins — camera-person climbs the ladder, doorbell
  rests (canary), count resets on playing and holds through connecting;
  view-level: a killed zoom shows "Reconnecting… try 2" through the
  re-dial. Invariant §3.10 amended.

**Adversarial review round (same day, 10 agents), all confirmed findings
fixed — suite 575+2 after:**
- *(major)* the count climbed with NO notification on same-phase
  retrying→retrying (a re-dial failing synchronously never leaves
  retrying, and `ValueNotifier`'s `==` short-circuit swallows the
  setPhase) — the counted face froze at "try 2". Fix: `retryAttempt` is a
  `ValueListenable<int>`; both faces listen to it beside `phase`; pinned
  by a notifier-count test and an on-screen "try 2 → try 3" widget test.
- *(minor ×2)* `_stop()` kept the count and the ladder rung across
  idle-park → resume — a scrolled-back tile wore "Reconnecting…" for a
  fresh start and inherited mid-ladder backoff. Fix: `_stop()` zeroes the
  count (the getter's own contract); pinned.
- *(minor)* person ladder re-dials bypassed admission — N cameras dying
  together re-dialled in one tick. Fix: `_requestDial(ladder: true)`
  routes timer-born dials through the gate; the tap itself stays
  unspaced; pinned (two-feed spacing test).
- *(minor)* a born-failed FIRST attempt claimed "Reconnecting…" though no
  picture was ever up. Fix: faces track `_sawPlaying`; a first connect
  that keeps failing stays "Connecting…", counted ("Connecting… try 3").
- *(nit ×2)* the kind wall is now origin-blind (`kind == camera` alone
  decides the ladder — no policy path dials a non-camera today, but the
  wall is structural), and the stale "retries never" / "policy-started"
  doc passages were rewritten.

The original sketch, for the reasoning:

**Observed (owner):** the grid and the zoom both work — but a stream that
fails mid-watch never comes back on its own, and the face just says
"Connecting…" with no sign anything is being retried.

**Why it behaves that way today** (all deliberate, now to be revisited):
- A **zoomed** camera is person-origin, and invariant §3.10 exempts
  person-origin feeds from the automatic retry ladder — so a mid-watch
  failure parks at `failed` until the person re-taps. This is the
  "doesn't reconnect" the owner saw.
- **Tiles** DO auto-retry (5 s → 15 s → 60 s → 60 s…), but retry progress
  is a log fact (`tile_retry`), not a wall fact — the failed/retrying face
  reads "Live view failed" by the phase-8 "honest faces" ruling.

**Design sketch:**
1. Expose the ladder on the seam: `CameraFeed` gains a read of the retry
   state (`_Feed._retryAttempt` exists; e.g. `int get retryAttempt`, 0
   when none) so faces can render it without a second source of truth.
2. **Zoom reconnect — the invariant amendment**: give person-origin
   feeds of `DeviceKind.camera` the retry ladder (or a bounded 3-attempt
   variant ending in a "Tap to retry" face). **The doorbell must stay
   manual** — an automatic re-dial on the Ring stream re-opens cloud
   sessions in a loop (#177014); gate by kind where the ladder arms, and
   add a doorbell canary test. Update: invariant §3.10's wording, the
   pinned person-origin tests in `stream_director_test.dart`, and
   CONTEXT.md's Stream Director entry.
3. **Faces**: distinguish a first dial from a recovery — zoom wears a
   centered "Reconnecting… try #2" while the ladder works; tiles a quiet
   corner variant of the same words. "Connecting…" stays for the first
   dial only. Amend the §C honest-faces table in the phase-8 doc.
4. Note the overlap that already exists: a probe-detected outage re-dials
   on the health flip (D1's gates); the ladder covers what the minute
   probe can't see fast — mid-stream EOFs and Wi-Fi blackouts.

### N12 — Audio policy for the RTSP transport + the doorbell's LISTEN leg *(IMPLEMENTED 2026-08-26 — forced by the default flip, delivered as the inbound-audio feature)*

**Why it existed:** MJPEG was silent by nature; fvp is not, and both Wyze
stream tiers carry a `pcm_mulaw` track (probed via the restream) — so the
RTSP default would have played six overlapping camera audios the moment
the grid opened on a machine with working sound. The same player is also
the missing LISTEN leg of ADR-0011 (inbound doorbell audio at the wall).

**What landed (suite 579+2 after):**
- `LiveVideoSession.setMuted(bool)` — the seam's new member. **Every
  session is born muted** (all four implementations); unmuting is a
  surface decision. MJPEG: no-op (no audio track). MSE/web: deliberate
  no-op — `muted` is autoplay-load-bearing in a browser and programmatic
  unmute pauses Chrome's autoplay-started video; sound on the second
  screen is N9's kiosk-flag question. RTSP/fvp: real, `setVolume(0|1)`,
  desired state tracked so an unmute racing `initialize` still lands
  before a sample plays.
- **The pool's silent-linger guarantee** (`live_video_keepalive.dart`
  `_release`): every session kept for the linger is re-muted at release —
  sound can never outlive the surface that asked for it, whichever of the
  Popup's routes closed it. Pinned by a lease test.
- **The Popup is the audible surface** (`device_popup.dart`): unmutes its
  session at open (doorbell ding-Popup and camera Popups alike), and
  **ducks to muted while the talk button is held** — ADR-0011's
  half-duplex mechanism, the wall's speaker feeding the wall's mic being
  the echo loop it breaks — restoring on release. Pinned by an
  unmute/duck/restore ordering test.
- Both wrappers (`_CountedSession`, the pool lease) delegate; the test
  fake records `muted` + ordered `mutedChanges`.

**Deliberately out, with reasons:** zoom/tile audio (the zoom would need
`CameraFeed` to carry the muted want across re-dials — add it only if the
owner asks for zoom sound); web audio (N9). **Operational note:** inbound
doorbell audio exists only on the RTSP transport — switching production
to `VIDEO_TRANSPORT=mjpeg` trades it away, which is worth remembering
when weighing a rollback.

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
