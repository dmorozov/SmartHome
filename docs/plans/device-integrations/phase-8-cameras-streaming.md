# Phase 8 — Cameras streaming: diagnosis, policy, and the Stream Director

Grilling session 2026-08-24, owner-confirmed. Architecture review base: the
`/improve-codebase-architecture` report (candidates 1–6) plus a live probe of
the production go2rtc run the same night. Vocabulary: `CONTEXT.md` (Stream
Director, Camera Health added by this phase).

> **Handoff:** `phase-8-handoff.md` (same directory) is the session-portable
> record — the six review-confirmed defects and their applied fixes, the four
> refuted findings (do not re-fix), the invariant checklist, and the detailed
> implementation plan for every §D item below.

## A. What was measured, and what the flakiness actually is

The presenting symptom — "tiles fail intermittently, and WHICH tiles changes
between attempts, even on substreams" — was probed live on 2026-08-25 (UTC)
against the production go2rtc, and the answer is **not bandwidth**:

1. **Wyze RTSP daemon death.** 4 of 5 cameras (`.57` family, `.63`
   back-yard-door, `.54` garage, `.62` back-yard) actively refused TCP on
   RTSPS port 322 — instant RST in 0.06–0.10 s, 30/30 probes over 7+
   minutes, while answering pings at 0 % loss. A **single, idle** pull of a
   refusing camera fails in 0.3 s; mains and subs are equally dead. This is
   the failure the Wyze forums report for the RTSP-beta firmware: the daemon
   dies after hours/days of uptime. Recovery is a camera power-cycle or an
   RTSP re-toggle in the Wyze app — nothing Hub-side can revive it.
   **Resolved 2026-08-26, and the mechanism was worse than a dead daemon:**
   all four cameras had **lost their RTSP configuration outright** — the
   Wyze app showed RTSP as "Not Set" — so restarts could not help (there
   was nothing to start). Recovery was re-entering RTSP per camera **with
   the same credentials** (owner's store: `~/.sh_keys/wyze.env`; ground
   truth: the producer URLs in the live go2rtc.yaml). The port-322 probe
   (§B A2) detects this failure mode exactly as it detects a daemon crash.
2. **Minute-scale Wi-Fi blackouts.** Caught in the act: ~3 minutes of 100 %
   ping loss on two cameras (EHOSTUNREACH on opens attempted during it),
   then clean ~11 ms. Any open that lands inside an episode fails; the same
   open a minute later succeeds.
3. **Simultaneity was NOT implicated.** The one healthy camera opened in
   ~4.2 s identically under simultaneous and staggered launch, 4-for-4, and
   camera RTT got ~10× *better* under load (2.4 GHz power-save: idle pings
   spike to 1.1 s, streaming keeps the radio awake). Caveat: with four
   daemons down, real concurrency never exceeded one stream — the
   five-healthy stampede question is **open, not closed** (§E).
4. **Failure amplification ×2.** Each failed tile open dials the camera
   twice: the rtsps producer, then the MJPEG-wrapper producer re-DESCRIBEs
   the stream and dials it again (`exec/pipe: EOF` + nested 404, measured).
5. **VAAPI was impossible as configured**: the go2rtc container had no
   `/dev/dri` mapped (host exposes two render nodes; `/api/ffmpeg/hardware`
   reported ERROR on all five probes). Fixed by this phase (§B).
6. The Aug-16 setup-day logs show a *different* signature (producer i/o
   timeouts, `[exec] timeout` on the 17–18 s floodlights, the cold-MJPEG
   zero-byte race) — the cold-start races are real too, and `preload:`
   (§B) is their fix.

## B. Track A — Hub ops and config (no Panel code)

Decided and applied with this phase:

- **A1 Recovery + re-probe.** Power-cycle / RTSP-re-toggle the refusing
  cameras (owner action), verify with a port-322 probe. Recovery is an
  operational fact of this fleet now, not an incident.
- **A2 The monitor is the health backbone.** HA `command_line`
  binary_sensors TCP-probe each camera's port 322 once a minute
  (`binary_sensor.wyze_*_rtsp`, device_class `connectivity`). Credential-free,
  and double-duty: long-horizon daemon-uptime data, and real per-camera
  entities the Panel's existing Hub availability seam can consume — on the
  web build too. This displaced both alternatives: HA camera entities
  (heavier, not needed for reachability) and Panel-side `/api/streams`
  polling (responses embed producer URLs → credentials; localhost-only and
  still the wrong shape).
- **A3 go2rtc 1.9.10 → 1.9.14.** One-line tag edits (`hub/compose.yaml`,
  `hub/dev/compose.yaml`). The old pin's Frigate-0.17-alignment rationale is
  consciously superseded (owner decision: "no hard lock — newer has fixes");
  re-align deliberately if Frigate lands. 1.9.12 security additions are
  opt-in; `api.origin "*"` unaffected.
- **A4 Preload the two floodlights, video-only** (`preload:` in the live
  config). Kills both the 17–18 s cold start and the cold-MJPEG zero-byte
  race for the units that lose the on-demand start race by design. Scope
  stays floodlights-only until the A2 monitor produces a week of data
  (preload-all-subs would hold ~5× substream bitrate on the 2.4 GHz cell
  24/7, and its interaction with daemon death is unknown).
  **SUSPENDED 2026-08-26** (entries commented in the live yaml, backup
  `go2rtc.yaml.bak-20260826-preload-suspend`): after the cameras' RTSP
  re-setup, both preloaded mains EOF-looped — go2rtc re-dialling the
  floodlights every ~7–15 s without ever latching — while on-demand pulls
  of the same streams worked (9.6 s to a frame). A knock-loop is worse
  than the cold start it was hiding; re-enable once the cause is
  understood (handoff N10).
- **A5 Bounded MJPEG transcodes.** Custom templates in the live config:
  `mjpeg/tiles` (`-q:v 8 -r 10`) on the five substream wrappers,
  `mjpeg/zoom` (`-q:v 6 -r 15`) on the mains and `ring_doorbell`;
  `selftest` keeps the plain built-in template as the canonical check.
  Before this the wrappers ran source fps at ffmpeg's default quality
  (measured ~1.3 MB/s per 1080p MJPEG consumer). The template name must keep
  the `mjpeg/` prefix — go2rtc selects the output format from the codec name
  before the first `/`.
- **A6 `/dev/dri` mapped into the container**, then `#hardware=vaapi`
  probe-then-adopt (quality via `-global_quality`, not `-q:v`, on the VAAPI
  encoder). If the probe disappoints, software encode stands.
- **A7 Wyze tile stills go2rtc-direct**: `frame.jpeg?src=<sub>&cache=45s`,
  fetched by the Panel every 60 s and only while the tile is not live.
  **The Ring doorbell is never touched via `frame.jpeg`** — a go2rtc
  consumer on that stream opens a real Ring session and suppresses dings
  (HA #177014); its still stays HA-held (`camera.front_door_snapshot`).
  *Panel side implemented 2026-08-25* (handoff N6): `Go2rtcStillsConfig`
  beside `SnapshotConfig`, the tile preferring the HA-held JPEG and falling
  back to the frame grab for `DeviceKind.camera` only, gated by feed phase
  (grab only in idle/queued/unconfigured/unsupported — live, the retry
  ladder, and a health-declared-offline camera are never billed a grab).
  Measured en route: a dead camera's `frame.jpeg` is a **zero-byte 200**,
  which the fetchers now refuse rather than hand `Image.memory`.
- **A8 Explicitly unchanged**: RTSPS/TCP transport (every shipping NVR
  defaults to TCP; RTSPS removes the choice), `api.origin "*"` (owner
  decision, phase-4 §B0), go2rtc as the **only** RTSP client of any camera
  (Wyze serves ~3–4 sessions; the web second-screen consumes go2rtc only),
  doorbell `autoLive: false`.

## C. Track B — the Panel's Stream Director (build next)

One deep module above the player seam — the keepalive pool's own precedent:
wrap the opener, callers keep their shape. It absorbs the session dance
(open / phase-listen / log-failure-once / close) that today exists as three
drifted copies (CameraTile, ZoomedCamera, DevicePopup), and it is where
stream policy finally lives:

- **Which stream**: substream for tiles, main for zoom/Popup (unchanged,
  now stated in one place).
- **Admission**: ~400 ms spacing between dials (hygiene, not the fix — §A3);
  **no numeric cap** in v1 (capacity was not the failure; the policy object
  keeps an unset cap slot). Zoom-replaces-grid stays the structural budget.
- **Health-gated dialling**: an offline camera (Camera Health says so) is
  not dialled at all — its tile wears the aged still + "offline since…".
  Recovery detection is the monitor's job, not repeated dials (which the ×2
  amplifier makes doubly wasteful). Until the A2 entities are bound, retry
  carries it alone.
- **Retry**: failed auto-live tiles re-dial at 5 s → 15 s → 60 s → every
  60 s (Wyze firmware drops off the network for seconds routinely; "changes
  on refresh" is what a no-retry policy looks like).
- **Viewport**: auto-live tiles start on becoming visible and stop on a
  45–60 s debounce after scroll-out (the grid scrolls today: 6 tiles
  visible, the 7th below the fold at the owner's resolution). Tiles a person
  explicitly started are never viewport-stopped. Overlays (Popups) pause the
  grid via app state — `visibility_detector` is bounding-box-only and blind
  to routes pushed on top (open bugs google/flutter.widgets #29/#295).
  Never dial in `initState`: the grid builds tiles 250 px below the fold
  (default cacheExtent), and kept-alive live tiles never get `dispose()` on
  scroll-out.
- **Honest faces**: queued = the idle face ("starting…" only past ~1 s);
  "Connecting…" only while a dial is in flight; retrying = aged still +
  quiet badge; offline = aged still + "offline since…". LIVE badge
  semantics unchanged.
- **Policy is data**: auto-live substreams remain the shipped default —
  phase-7 §B3 stands. Stills-first (Frigate's "Smart Streaming" default,
  the largest airtime lever available) is a policy swap, not a rewrite,
  held in reserve until the air demands it.
- **Camera Health** is its own small module: adapters = the A2 probe
  entities (primary; works on web), session outcomes, still-fetch outcomes.
  Expressed as per-tile state only. **Sorting the grid by health is
  rejected**: no surveyed product reorders (Frigate/UniFi keep stable,
  user-arranged order), a wall is spatial memory, and a live re-sort moves
  tiles under fingers and fights the pinned `ValueKey('tile-<id>')`
  lifecycle tests.

The pinned test invariants that must survive the refactor
(`cameras_view_test.dart`): every session closed by every route out; the
doorbell opens NOTHING on entry; tiles dial the substream, never the main;
zoom unmounts the grid; keepalive re-attach re-dials nothing; born-failed
sessions still log exactly once.

## D. Deferred, each with a named trigger

| Deferred | Trigger |
|---|---|
| ~~Stagger verdict~~ **CLOSED 2026-08-26**: 4 rounds (2 sim / 2 stag-2s) at five healthy cameras, 20/20 pulls ok in both modes → `dialSpacing` stays 400 ms as hygiene, per the decision rule. Simultaneous showed a real but non-fatal tail: 2 of 10 sim dials (one round) hit first-attempt EOF + retry (9.9 s / 12.2 s to first frame vs ≤6.0 s staggered max); staggered rounds were uniformly clean. Full data in the handoff's N1. | — |
| Preload-all-substreams | a week of A2 monitor data |
| H.264/RTSP adapter on the appliance — **prototype AND adapter built 2026-08-26** (fvp; `live_video_rtsp.dart`, `VIDEO_TRANSPORT=rtsp\|mjpeg`, default mjpeg; handoff N5 carries both records). Remaining: the 2 h soak verdict, a real-session eyeball of texture clipping, then the default flip and config retirement (deletes the MJPEG transcodes) | soak + owner's eyeball |
| Native `wyze://` source (1.9.14, experimental TUTK — bypasses the RTSP daemon entirely) | monitor shows chronic daemon death |
| Idle-return dedup (CamerasView / DevicePopup copies) | a third surface (the web second screen) |
| Web build platform-view ceiling (Flutter web caps overlays at 7; 6 MSE tiles + a Popup video is at it — detach grid views under a Popup) | web second-screen work |
| Mid-watch reconnect for the zoom (person-origin retry, doorbell excluded — #177014) + "Reconnecting… try #N" faces on zoom and tiles (owner request 2026-08-26; handoff N11) | after the N5 adapter |

## E. Done when

- All five cameras answer on 322 after recovery, and
  `binary_sensor.wyze_*_rtsp` history charts their daemon uptime.
- go2rtc 1.9.14 serves all 12 streams; `/api/preload` lists the two
  floodlights; a cold floodlight tile shows a picture without the zero-byte
  race.
- The MJPEG wrappers run bounded (`mjpeg/tiles` / `mjpeg/zoom`), hardware
  encode adopted or explicitly declined against the probe result.
- The Panel's three video call sites open through the Stream Director, the
  duplicated lifecycle copies are deleted, and the cameras_view suite still
  pins every invariant in §C.
- ~~The stampede experiment has been re-run at five healthy cameras and the
  stagger question closed with data.~~ **Done 2026-08-26** — §D carries the
  verdict (20/20 both modes; spacing stays 400 ms).
