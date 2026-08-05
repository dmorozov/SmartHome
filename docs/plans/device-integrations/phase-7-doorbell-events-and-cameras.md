# Phase 7 — A real doorbell event, the Cameras view, and recording-shaped seams

Phase 3 closed with a debt stated honestly: ring-mqtt 5.9.3 published no
`event.*` entity, the doorbell got bound to the `binary_sensor` word shape,
and a press the Panel first hears about after a gap is lost. Research
(2026-08-05, [`../../research/ring-events-and-recording.md`](../../research/ring-events-and-recording.md))
settled what to do about it, and the owner scoped the rest of this phase the
same day: **(A)** give the classifier the timestamp shape it was built for,
**(B)** build the **Cameras** view — the owner-specified slide-out grid of
camera tiles — and **(C)** shape the architecture so a recording layer drops
in later **without building any of it now**. Recording is explicitly out of
scope by owner decision (2026-08-05); what is in scope is making sure nothing
built here has to move when it arrives.

Three facts from the research drive everything below (§ references are to the
research doc):

1. ring-mqtt will never publish an `event` entity (§1) — but HA's MQTT event
   platform can mint one from ring-mqtt's own ding topic, and the fit is
   exact (§2).
2. Any continuously-held Ring live session suppresses dings — wiki-verbatim,
   plus HA core #177014 (§5). This kills every always-on recorder for the
   doorbell *and* is why the Ring tile defaults off in the Cameras view.
3. This Ring account has an active Protect plan (the event select on the live
   Hub lists Ding/Motion/Person 1–5), so Ring's cloud is already recording
   every event with pre-roll, and ring-mqtt's wiki ships the download
   automation (§5). The future "doorbell recordings" feature is a clip
   *catalog*, not a recorder.

## A. `event.front_door_ding`, minted from ring-mqtt's topic

### A1. Why this shape, and what it fixes

`classifyDing()` rule 2 (timestamp shape) has been built and tested since
2026-08-04 and has never had an entity to run against. Today's word shape
loses two real presses:

- the **first press after a gap** — `on` restored after an HA/Panel restart
  and `on` from a finger are the same string, so rule 3 must stay silent
  (phase-3 §2 documents this as the cost being paid);
- a **second press inside the ding window** — the binary_sensor holds `on`
  for `ding_duration` (default 180 s), so a repeat press is `on → on`,
  which rule 1 must reject. This one was not in phase-3's ledger; research
  §1 surfaced it.

The MQTT event entity fixes both: it fires on **every** `ON` publish (ring-
mqtt republishes `ON` per press even mid-window), and its state is the ISO
timestamp of the last event — restored across HA restarts *without*
re-firing, which is exactly rule 2's food. The Panel needs **zero code
change**: rebind and the classifier switches rules by itself.

### A2. The entity — one gitignored include, one tracked example

The live file embeds this install's Ring location id and device id in the
topic. Be precise about what is being kept where: the **device id** already
appears in tracked commissioning docs (Ch. 5's as-built go2rtc excerpt), so
it is not what the gitignore protects; the **location id** has never been
tracked anywhere, and the full topic carries it. That — plus consistency
with the repo's pattern for per-install runtime facts
(`go2rtc.yaml`, `z2m-data/configuration.yaml`) — is why the live file is
gitignored with a tracked example. Do not paste a full topic into any doc:
half of it being public already is not a precedent for the other half.

1. `hub/ha-config/configuration.yaml` (tracked) gains, alongside the
   existing `automation:`/`script:` includes:

   ```yaml
   # Manually-declared MQTT entities (the UI-configured MQTT integration
   # handles discovery; this include adds entities discovery cannot mint).
   # Live file gitignored — its topics embed this install's Ring ids.
   # Fresh bring-up: cp mqtt.example.yaml mqtt.yaml first (hub/README).
   mqtt: !include mqtt.yaml
   ```

   **This makes `mqtt.yaml` load-bearing for HA startup**: a fresh clone
   without the copy step fails HA's config check. That is already true of
   `z2m-data/configuration.yaml` for Z2M — add the `cp` to the same
   bring-up step 1 in `hub/README.md` rather than inventing a new place.

2. `hub/ha-config/mqtt.example.yaml` (tracked), placeholders and procedure
   in comments; `hub/.gitignore` gains `!ha-config/mqtt.example.yaml` in its
   whitelist block:

   ```yaml
   event:
     - name: "Front Door Ding"
       unique_id: front_door_ding_event
       # Topic ids: HA → Settings → Devices & services → MQTT →
       # "Front Door" device → any entity → MQTT info, which shows the
       # subscribed topics. Do not guess; copy.
       state_topic: "ring/<location-id>/camera/<device-id>/ding/state"
       availability_topic: "ring/<location-id>/camera/<device-id>/status"
       payload_available: online
       payload_not_available: offline
       device_class: doorbell
       event_types:
         - ring        # the 2026.4 standard type for doorbell class —
                       # anything else deprecation-warns until 2027.4
       # ring-mqtt publishes bare ON/OFF, not JSON. Without this template
       # the entity silently does nothing (research §2). '{}' renders are
       # discarded by design, which is what filters OFF and the restart
       # replays of OFF.
       value_template: >-
         {{ '{"event_type":"ring"}' if value == 'ON' else '{}' }}
   ```

3. `docker compose restart homeassistant` (or Developer Tools → YAML →
   reload manually configured MQTT entities, once the include exists) →
   `event.front_door_ding` appears. The name collides with the
   binary_sensor's friendly name in the UI and that is fine — different
   domains, different entity ids, and the binary_sensor stops being bound
   in A3 anyway.

**Two holes, stated before they are found the hard way** (research §2).
The first:
nothing ring-mqtt publishes is retained, so the event platform's
retained-discard guard never fires — the replay this design filters is
ring-mqtt's own birth-republish of `OFF`, which the template maps to `{}`.
But an HA restart **during an active ding window** meets that same
birth-republish sending `ON` up to 6 times over ~2.5 min → up to 6 spurious
rings, each a fresh timestamp the classifier will honour. Bounded, rare
(restart within `ding_duration` of a real press), and shrinkable: set
`number.front_door_ding_duration` from 180 to **60** — nothing binds the
binary_sensor after A3, the freshness window is 60 s anyway, and the
collision window shrinks 3×. Do that as part of this step and record the
value in Ch. 5 §1.3.

**The second, smaller hole is the Panel's own restart.** `_rungFor` — the
press instant already rung for — is in-memory, and the controller's
constructor seed never sees the real Hub's snapshot (`HaHubClient.states`
is empty at construction; the snapshot arrives later through
`stateChanges` with no `previous`). So a Panel process restart within the
60 s freshness of an *already-answered* press re-rings once for it.
Bounded to one duplicate, rare, and half-desirable: the same walk rings a
press the Panel died before answering, which the word shape lost
outright. Accepted as-is. The close, if the duplicate ever matters more
than the recovered press, is seeding `_rungFor` from the first snapshot
delivery — which would also silence that recovered press, so it is a
trade, not a fix.

### A3. Rebind, and what moves in the docs

`panel/assets/house/bindings.yaml`:

```yaml
  doorbell:
    entity: event.front_door_ding     # was binary_sensor.front_door_ding
    stream: ring_doorbell
    connectivity: cloud
```

The binding-comment block there argues the word shape's cost at length —
rewrite it to say the timestamp shape is now bound and *why the event
entity's state satisfies rule 2* (ISO-8601 with offset; `DateTime.tryParse`
takes it). `doorbell` is already in `_integrated`
(`panel/test/bindings_drift_test.dart`), so the drift suite does not move.

Paper trail: phase-3 §2 gains a one-line pointer ("the missing `event.*`
entity was minted in phase 7"); Ch. 5 §1.3's template-sensor escape hatch is
marked **superseded** (that snippet was never installed and now never will
be — the event entity strictly dominates it, research §3).

### A4. Verify — four presses, two of which used to fail

Owner at the door, agent at the logs (`journalctl` for the Panel,
Developer Tools → States for the Hub). The protocol is phase-3 §2's, plus
the two regressions this phase exists to close:

1. **Plain press**: `event.front_door_ding` state jumps to now; Panel logs
   `ui.ding` and the Popup opens unprompted. (Worked before, must still.)
2. **The gap press — the whole point**: restart HA, wait for the Panel to
   reconnect, press once. The house **must ring**. Under the word shape
   this press was silently lost (`reason=first_sight`); rule 2 judges the
   fresh timestamp on its age instead.
3. **The double press**: press twice ~10 s apart. **Both ring.** Under the
   word shape the second was `on → on`, invisible by construction.
4. **The quiet restart**: restart HA with nobody at the door, watch 3
   minutes. **Nothing rings** — birth-republish sends `OFF`, the template
   renders `{}`, the entity holds its restored timestamp, and rules 2a/2b
   keep the Panel silent: `already_rung` for a press this Panel answered,
   `stale` for an older restored timestamp. (Not rule 1: the link drop
   cleared `_lastSeen`, so the snapshot arrives with no `previous` to be
   unchanged against — rule 1 only covers same-run re-reports such as a
   YAML reload.) The greppable words are `reason=already_rung` and
   `reason=stale`, not `unchanged`.

Then re-run the go2rtc half of phase-3's "done when": a ding arrives while
no stream is open (#177014 rule still holds because nothing holds a stream).

### A5. Rejected alternatives, so nobody re-litigates them

- **Trigger-based template sensor on `off→on`** — restores across restarts
  but misses in-window repeats; strictly dominated (research §3).
- **Template sensor on `lastDingTime`** (the phase-3 escape hatch) — the
  attribute *is* written at push time (research §1 settled what phase 3
  left UNVERIFIED), but the startup history-refetch may republish it in a
  different string format, false-firing once per ring-mqtt restart. The
  event entity needs none of that reasoning.
- **Template event platform** (HA 2025.9+) — works, but adds a template
  layer over the same topic the MQTT event entity reads natively, and its
  restart-restore behaviour is ambiguous in the docs (research §3).
- **Native `ring` integration side-by-side** — mechanically safe
  (independent authorized clients, research §3) and zero-config, but costs
  a second Ring credential/2FA session to keep alive, duplicate device
  cards, doubled polling, and two open core bugs on exactly the entity
  we'd depend on (#128332 multi-fire, #134431 unresponsive events). Keep
  in the back pocket if the MQTT event entity disappoints in practice.

## B. The Cameras view

### B1. The name, before the code

"Dashboard" is on the Language avoid-list (`CONTEXT.md`), and this view
will be spoken of daily. Add the Language entry as part of this phase:

> **Cameras**: the Panel's full-screen grid of camera tiles, slid out from
> a right-edge tab on the Dollhouse. Tiles start and stop their own live
> streams; closing the view stops them all.
> _Avoid_: dashboard, camera wall, NVR view

### B2. The shape — owner-specified, 2026-08-05

- A **right-edge tab** on the Dollhouse, camera icon, always visible.
- Tap → the Cameras view **slides out leftward** over the full screen.
- **Top-right close button** returns to the Dollhouse.
- **Tap a tile to start/stop that camera's stream** — every tile is a
  toggle.
- **The Ring tile is off by default.** Wyze-class tiles may default live.

Build it as a full-screen route (slide transition), not a Popup: it is
navigated to, not raised by an event, and the Popup's registry/deadline
machinery solves problems this view does not have. What it *keeps* from the
Popup is the session discipline: every open tile session is closed in
`dispose()`, which runs however the route leaves.

### B3. Tiles: enumeration, defaults, lifecycle

- **Enumeration**: every Device whose kind has `video: true` — today
  `doorbell` plus `cam-garage` / `cam-living` / `cam-office`. No new Keys,
  no drawing session, ADR-0005 untouched. A video Device with no `stream:`
  yet (all three cams until phase 4 lands hardware) renders an honest
  "not wired" body — the grid is stable now and lights up per camera later.
- **Defaults are a kind fact, not a per-device toggle**: add
  `autoLive: bool` to `KindSpec` (`panel/lib/domain/device_vocabulary.dart`)
  — `camera: true`, `doorbell: false`. Same reasoning as the `video` flag's
  own row (a doorbell's live view has cloud side effects — §5's
  suppression — whatever brand it is), and
  `panel/test/device_vocabulary_test.dart` gains the row assertion the
  `video` flag never got.
- **Session per tile** through the existing seam — `VideoConfig.urlFor` +
  `openLiveVideo`, `FakeGo2rtc` in tests. Nothing new below the widget.
- **Ring live is a person's choice with a stated cost**: while that tile
  streams, dings may be suppressed (#177014 / research §5). No deadline on
  a person-opened tile — that is D14's rule from the Popup, kept — but the
  **view itself idles back to the Dollhouse** after N minutes without a
  touch, and that is a real trade, not a free bound: it caps a *forgotten*
  Ring tile, and it also interrupts a *deliberate* long watch — expecting
  a delivery is exactly N+ minutes of watching with zero touches. Soften
  the cliff rather than pretending it away: 30 s before firing, the view
  shows "Still watching? Tap to stay" — one tap per N minutes is a fair
  price for holding a Ring session open — and an unanswered prompt logs
  `cameras.idle_return reason=unanswered` on its way out. N is an
  implementation decision; 5 minutes is the suggestion. (Rejected:
  exempting the view from idle-return while a manually-toggled tile is
  live — that un-bounds the forgotten-tile case, the one with the
  suppression cost, to protect a case a single tap already protects.)
  A ding during a live Ring tile still classifies normally — go2rtc
  multiplexes, so the Popup and the tile share one upstream session
  rather than fighting.
- **Appliance cost is per-live-tile**: each live tile is one
  `ffmpeg:…#video=mjpeg` transcode (~186 kB/s, phase-4 §B) that exists
  only while watched. Default-off tiles cost zero — the reason default-live
  is reserved for local cameras.

### B4. The Ring tile's off state: a snapshot, not a black box

The off-state face is `camera.front_door_snapshot` — an MQTT camera whose
JPEG *HA already holds* (snapshot mode is `Auto` on the live Hub), so
showing it costs **no Ring session**. Two things follow:

- **A small new seam, and the fence it must not cross.** The bytes come
  from HA's REST `camera_proxy` endpoint with the Panel's existing token —
  a still image via authenticated GET, refreshed every ~60 s while the
  view is open. The token travels **only** as an `Authorization: Bearer`
  header — never as a query parameter or signed path (HA offers both, and
  Lovelace uses the query form; a token in a URL reaches logs, history
  and error text, the G3 leak class all over again) — and the fetcher's
  error handling never echoes the request URL.
  `HubClient` stays video-free (its contract test carries
  zero video references, deliberately); this is a sibling seam beside
  `VideoConfig`, injected the same way, faked the same way. Never reach
  for go2rtc's frame-grab here — pulling a frame from `ring_doorbell`
  *starts a live session*, which is the exact thing the off state exists
  to avoid.
- **The web build needs CORS for it.** The WebSocket API never cared, but
  a browser `fetch()` against HA REST does: `http: cors_allowed_origins:`
  in `hub/ha-config/configuration.yaml` (tracked), listing the
  second-screen origin when it exists. Without it the appliance shows a
  snapshot and the web build a broken tile — silently, per CORS custom.
  (`Authorization` is a non-simple header, so the browser preflights;
  expected, not a bug.)

### B5. Diagnostics and tests

- Log vocabulary mirrors the Popup's, prefixed `cameras.`:
  `cameras.opened` / `cameras.closed` (with `open_s=` and live-tile
  count), `cameras.tile_open name=…` / `tile_closed` / `tile_failed
  reason=…`, and `cameras.idle_return` when the timeout fires. The
  snapshot fetcher is a **new HTTP channel and gets its own lines** —
  `cameras.snapshot_ok entity=…` / `cameras.snapshot_failed entity=…
  status=…` — where `status=` is an HTTP status code or a classified
  word, **never exception text**: Dart's `HttpException`/
  `ClientException` messages embed the full request URI, the same
  exception-text leak class phase-4 §B closed for `YamlException`.
  Stream names and entity ids only, never URLs.
- Widget tests (all against `FakeGo2rtc` / a fake snapshot fetcher): tab
  opens the view; close returns; a tile tap opens exactly that Device's
  stream and a second tap closes it; view dispose closes every open
  session; doorbell tile is off at entry and shows the snapshot; camera
  tiles honour `autoLive`; idle timeout fires and tears down; a
  no-stream Device renders the not-wired body and dials nothing.
- Live verify on the dev Hub: open the view with `selftest` +
  `ring_doorbell` defined → toggle tiles → `http://127.0.0.1:1984`
  consumer counts rise and fall per tap; close the view → every stream
  back to bare `url` stubs, `consumers: []`.

## C. Recording: deferred on purpose, designed for anyway

**Nothing in this section is built in phase 7.** It is the architecture
part of the owner's ask: when recording arrives, it must drop in without
moving what A and B build. The research doc §4–§6 is the evidence base.

### C1. The asymmetry that shapes everything

- **Ring records itself.** Protect is active; every ding/motion already
  lands in Ring's cloud *with pre-roll*, and ring-mqtt exposes the catalog
  (event select: id + `recordingUrl` attributes) and the playback path
  (`_event` RTSP — a replay from Ring's servers, not a device session).
  The future doorbell-recordings feature is therefore **catalog + fetch**:
  either the wiki's own automation (event → wait for `eventId` →
  `downloader.download_file` of the MP4 into a dated local archive) or
  on-demand playback. This path exists only while the Protect plan does —
  if it lapses, the doorbell falls to the wiki's no-Protect fallback (an
  event-triggered pull of `_live`), which loses the pre-roll and
  suppresses further notifications during the pull (research §5).
  No local recorder for Ring — **ever**: any recorder
  that holds `_live` continuously suppresses dings permanently (§5), which
  rules Frigate and MediaMTX `record: yes` out *for this one stream*
  categorically, and go2rtc's future `preload` option must likewise never
  name `ring_doorbell`.
- **Local cameras get a real recorder later**, and it consumes go2rtc's
  restream — one connection per camera regardless of viewers/recorders,
  the single-video-plane property this repo already relies on. The repo
  README's future-roadmap commitment (Frigate on-box, detection, Hailo-8L
  on the mini PC) still stands; research adds the current facts: Frigate
  0.17.2 (MIT, external-go2rtc inputs supported, always decodes a detect
  substream, run it bridged so its bundled go2rtc never fights the host
  one), MediaMTX 1.20 (native fMP4 record + playback API — the
  record-only interim if recording is wanted *before* detection hardware),
  plain ffmpeg segments (maximal lifecycle control, ~0 CPU). The choice is
  a decision gate in that future phase, not here.

### C2. The seams phase 7 cuts (and the ones it refuses to)

1. **Stream names stay the recorder's camera list.** `bindings.yaml`'s
   `stream:` keys are exactly what a recorder consumes off go2rtc
   (`rtsp://127.0.0.1:8554/<name>`). **Which cameras get recorded is the
   future recorder's own config — a chosen subset of these stream names,
   never a flag in `bindings.yaml`** (the House describes the house; what
   an NVR retains is the NVR's policy). That is where the owner's "record
   selected ones" lives. No schema change now; a future `clips:` key
   (naming a clip *provider*, charset-validated like `stream:`, never a
   URL) is the sketched extension point.
2. **Tiles stay ignorant of clips.** The tile widget takes an injected
   live-session opener (B3); a future clips pane composes *beside* the
   grid, driven by a `ClipsProvider` interface — `list(device)` →
   clips (id, start, kind, thumbnail), `open(clip)` → something playable —
   with Ring-cloud and Frigate/MediaMTX implementations later. Defined
   here so B is built against the seam's silhouette; **not** written now.
3. **`HubClient` stays video-free.** The contract test is the fence; the
   snapshot fetcher (B4) deliberately lives beside `VideoConfig`, not
   inside the Hub seam — and so will `ClipsProvider`.
4. **Ports and placement are already reserved knowledge**: 8554/1984/8555
   go2rtc (host), 8556 ring-mqtt, 8557 pre-reserved wyze-bridge; a
   recorder or playback server picks a free port and runs bridged.
   Storage: the mini-PC purchase criteria already require the second M.2
   for exactly this; the dev laptop's 392 GB free is ample for
   experiments (storage math: bitrate-Mbps × 10.8 GB/day/camera).
5. **What phase 7 refuses to add**: any always-on stream consumer, any
   `preload`, any recording schema in `bindings.yaml`, any clip UI. Every
   one of these is cheap to add *when wanted* and expensive to carry
   speculatively.

## Done when

Written 2026-08-05, all open. A is agent-plus-owner (physical presses); B
is agent work verifiable on the dev Hub; C is a standing constraint, not a
task.

- ⬜ **A.** `event.front_door_ding` exists on the live Hub via
  `mqtt: !include mqtt.yaml` (+ tracked example, gitignore whitelist line,
  hub/README bring-up `cp`), `ding_duration` lowered and recorded, and the
  **four-press protocol passes** — including the gap press (2) and the
  double press (3), the two that used to fail by construction. The quiet
  restart (4) rings nothing.
- ⬜ **A.** `doorbell` binds `event.front_door_ding`; the bindings.yaml
  comment argues the new shape; phase-3 §2 and Ch. 5 §1.3 point here;
  `flutter test` count unchanged (the five golden failures stay the five
  golden failures).
- ⬜ **B.** CONTEXT.md carries the **Cameras** Language entry; the view
  ships behind the right-edge tab with slide-out/close exactly as
  specified; tiles toggle their own sessions; the doorbell tile defaults
  off showing the HA-held snapshot; `autoLive` is a tested `KindSpec` row.
- ⬜ **B.** Teardown proven live: toggling tiles moves go2rtc consumer
  counts at `:1984`, and closing the view returns every stream to bare
  `url` stubs with `consumers: []`. On the web build, the snapshot renders
  from the second-screen origin (CORS line landed) — or the origin does
  not exist yet and the line is documented as pending.
- ⬜ **C.** Still nothing recording: no new always-on consumer on any
  stream, `preload` absent from `go2rtc.yaml`, `bindings.yaml` schema
  untouched — and the seams ledger (C2) is what the future recording
  phase opens with.
