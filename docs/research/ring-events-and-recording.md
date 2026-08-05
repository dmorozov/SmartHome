# Ring events, camera recording, and the stream plane — research

Researched 2026-08-05 against live sources (GitHub repos/APIs, official docs,
maintainer statements). Backs `docs/plans/device-integrations/phase-7-doorbell-events-and-cameras.md`.
Versions verified that day: **go2rtc v1.9.14** (2026-01-19; Hub pins 1.9.10),
**ring-mqtt v5.9.3** (2026-03-09; Hub pins 5.9.3 — current), **Frigate
v0.17.2** (2026-06-28), **frigate-hass-integration v5.15.4**, **MediaMTX
v1.20.0** (2026-08-05). HA is pinned at 2026.7.

Facts below marked **[unconfirmed]** could not be pinned to an authoritative
source and must be re-verified before anything load-bearing is built on them.

## §1 ring-mqtt will never hand HA an `event` entity

- ring-mqtt's latest release **is** the 5.9.3 the Hub runs. Grep of the
  current source: every camera entity is `binary_sensor | switch | select |
  light | camera | number | button | sensor` — zero `component: 'event'`
  anywhere, no issue/PR/roadmap item proposing it. The wiki roadmap for
  v6.0.0 is go2rtc-based streaming and polling changes, not entities.
  The `event.*_ding` this repo's phase-3 doc hoped for does not exist in any
  ring-mqtt version, past or announced.
- Ding topics (wiki `MQTT-Device-Topics`, source `devices/base-ring-device.js`):
  - `ring/<location_id>/camera/<device_id>/ding/state` — literal `ON` / `OFF`
  - `ring/<location_id>/camera/<device_id>/ding/attributes` —
    `{"lastDing": <epoch-sec>, "lastDingTime": "<ISO8601>"}`
  - `ring/<location_id>/camera/<device_id>/status` — `online` / `offline`
- **Nothing ring-mqtt publishes is MQTT-retained.** The single publish path
  (`lib/mqtt.js`) sends QoS 1 with no retain flag — including discovery. The
  "replay" seen after an HA restart is ring-mqtt itself: it subscribes to
  `hass/status` and on HA's birth message republishes discovery + all states,
  immediately and then every 30 s, **6 cycles total** (`lib/ring.js`).
- **Ding lifecycle** (`devices/camera.js processNotification`, fired by the
  FCM push): state `ON`, held for `duration` (default **180 s**, settable
  10–180 via `number.front_door_ding_duration`), then one `OFF`. A second
  press inside the window **republishes `ON`** (comment: "Will republish to
  MQTT for new dings even if ding is already active") — a new MQTT message,
  but **no off→on state transition** in HA.
- **`lastDingTime` is written at the instant of the ding**, not on a poll:
  `processNotification` sets it from the push payload's own
  `created_at` and publishes state `ON` and the attributes back-to-back in
  the same call. Two caveats: at startup ring-mqtt refetches the last ding
  from Ring's event-history API and republishes the attributes with a
  seconds-precision timestamp; the push-time `created_at` string's exact
  format was **[unconfirmed]** — if the two formats differ, an
  attribute-change trigger false-fires once per ring-mqtt restart.

## §2 HA's MQTT `event` platform fits ring-mqtt's topics exactly

Docs: <https://www.home-assistant.io/integrations/event.mqtt/>. Schema:
`state_topic` (required, JSON payloads carrying `event_type`), `event_types`
(required list), `value_template` (renders the payload into that JSON).

- **Retained messages are discarded by design** — doc sentence: "Note that
  replayed retained messages will be discarded", confirmed in core source
  (`mqtt/event.py`: `if msg.retain:` → debug-log → return). Moot for
  ring-mqtt (nothing retained) but it means a broker-side retain surprise
  cannot ring the house either.
- Confirmed in core source: a `value_template` result of `''`, `'None'`, or
  `'{}'` is **silently ignored** (debug only); invalid JSON or an unlisted
  `event_type` logs a WARNING. So mapping `OFF` → `{}` filters it cleanly.
- ring-mqtt's bare `ON`/`OFF` payload **requires** a `value_template` — an
  MQTT event entity without one silently does nothing on non-JSON payloads
  (community-verified failure mode).
- Since **HA 2026.4**, `device_class: doorbell` event entities must include
  the standard `ring` event type (deprecation warning until 2027.4).
- The entity's **state is the ISO timestamp of the last event** and is
  **restored across HA restarts without re-firing** (`EventEntity` is a
  `RestoreEntity` restoring `last_event_type` and attributes).
- Because the entity fires on **every** `ON` publish (not on state
  transitions), a second press inside the 180 s ding window — invisible to
  the `binary_sensor` — produces a fresh event.
- The one hole: an HA restart **during an active ding window** meets
  ring-mqtt's birth-republish, which resends `ON` up to 6 times over ~2.5
  minutes → up to 6 spurious events with fresh timestamps. Bounded, rare
  (needs a restart within `ding_duration` of a real press), and shrinkable
  by lowering `number.front_door_ding_duration`.
- `mqtt:` YAML in HA *packages* is common practice but not explicitly
  doc-confirmed **[unconfirmed]** — an `mqtt: !include` from
  `configuration.yaml` avoids the question entirely.

## §3 Alternatives considered for the ding shape

- **Template event platform** exists since HA 2025.9
  (core PR #145408; `template:` → `event:` with triggers). Whether a
  trigger-based template *event* restores its state across restarts is
  ambiguous — template docs say only trigger-based sensors/binary sensors
  restore; the event base class implies otherwise **[unconfirmed]**.
- **Trigger-based template sensor** on `off→on` restores state across
  restarts (doc-verbatim) but misses in-window repeat presses (no off→on
  edge) — strictly worse than §2.
- **Native HA `ring` integration side-by-side with ring-mqtt**: provides
  push-fed `event.*_ding` since HA 2024.10 (`ring/event.py`, PR #125506).
  Coexistence is mechanically safe — HA generates its own
  `hardware_id = uuid4()` per config entry; ring-mqtt registers a separate
  persistent `systemId`; each is an independent authorized device with its
  own auto-refreshing token (maintainer: tokens die only on password change
  or device removal). Costs: a second Ring credential/2FA session to keep
  alive, a duplicate device card per camera, doubled 60 s polling, and two
  open core bugs on exactly the entity we'd depend on (#128332 ding event
  fired multiple times, #134431 event entities unresponsive).
- **ring-mqtt publishes no MQTT device triggers** (zero `device_automation`
  in the codebase) — that route does not exist.

## §4 Recording: what each candidate actually offers

- **go2rtc has no recording and none planned** — verified through v1.9.14
  release notes; recording-adjacent issues closed without a feature
  (**[unconfirmed]** only in that no explicit "never" quote exists). Its
  blessed pattern is external recorders consuming its RTSP restream
  (`rtsp://<host>:8554/<name>?mp4` — "useful for recording as MP4 files
  (e.g. Home Assistant or Frigate)"). It does offer a **bounded MP4 export**:
  `GET /api/stream.mp4?src=<name>&duration=<s>&filename=<f>` — a clip pull
  with zero extra software. v1.9.11 added `preload` (keep a producer
  connected from startup) — the explicit exception to on-demand teardown;
  the Hub's pinned 1.9.10 predates it.
- **Frigate v0.17.2** (MIT; Frigate+ is optional paid detection models only):
  - Record-only is possible (`detect: enabled: false`,
    `motion: enabled: false`) but **never zero-decode**: maintainers state
    Frigate always decodes a stream ("If you truly want a barebones NVR
    experience then choosing the AI NVR is probably not the right choice") —
    the pattern is a low-res substream on the `detect` role decoded 24/7,
    with the `record` role stream-copied.
  - It holds a **permanent RTSP connection per camera** — no on-demand mode.
  - An **external go2rtc is supported for camera inputs** (maintainer-
    confirmed); only Frigate's own web live view degrades (5 fps jsmpeg).
    Its bundled go2rtc (v1.9.10 inside 0.17.2) cannot be disabled — run
    Frigate bridged with 8554/1984 unexposed to avoid colliding with the
    Hub's host-networked go2rtc.
  - Retention per camera (`record.continuous.days`, alert/detection retain
    modes), storage layout `recordings/YYYY-MM-DD/HH/<camera>/MM.SS.mp4`,
    HTTP API for summaries/clips/HLS/exports, and an HA integration (HACS)
    with full media-source browsing of clips.
  - Hardware decode: `preset-vaapi` on the Intel iGPU (keeps the NVIDIA GPU
    free) or `preset-nvidia`.
  - 0.17.2 was substantially a security-fix release (several go2rtc-API-
    related RCE/auth-bypass advisories) — pin at least 0.17.2 when the time
    comes.
- **MediaMTX v1.20.0** has **native recording and a playback server**:
  `record: yes`, fMP4 segments (crash-tolerant parts), `recordDeleteAfter`
  retention, playback API (`/list`, `/get` returning browser-embeddable
  fMP4). It would *complement* go2rtc — a `paths:` entry per camera with
  `source: rtsp://127.0.0.1:8554/<name>` records from the restream. But
  `record: yes` pulls that source **continuously** — same hazard class as
  Frigate for Ring.
- **Plain ffmpeg segment container**: established community pattern
  (`-c copy -f segment -segment_time 900 -segment_atclocktime 1 -strftime 1`
  + `find -mmin +N -delete` cron). ~0 CPU, one go2rtc consumer per camera,
  and the only recorder here whose **connection lifecycle is fully yours** —
  which is what Ring needs. Gotchas: ffmpeg exits on stream drop and never
  reconnects (supervise it); in-progress MP4 segments lose their moov atom
  on crash (MKV/MPEG-TS are crash-safer); RTSP stall-timeout flag renamed
  `-stimeout` → `-timeout` around ffmpeg 5 **[unconfirmed]**.
- **HA `camera.record`**: 30 s default duration (max 3600), `lookback` only
  works if a stream was already active, long reliability complaint trail
  (corrupt mp4s, stuck "already recording" state, failures inside
  automations). Not credible as a 24/7 recorder; acceptable for one-off
  bounded clips at best.
- **Scrypted NVR**: $40/yr for 4 cameras + $10/yr each beyond — out.

## §5 Ring: the suppression constraint, and the recording path that avoids it

- **The constraint, verbatim from the ring-mqtt wiki**: "Ring cameras will
  not send motion notifications while live streaming is active" — plus
  warnings that continuous streaming drains/overheats the device and that
  *all* streaming transits Ring's cloud (nothing is local). HA core
  **#177014** independently documents the same failure through HA's own Ring
  integration (WebRTC sessions that outlive the frontend suppress subsequent
  ding events; still open). Scope: **any active live session, however
  initiated**. A recorder holding `rtsp://<host>:8556/<id>_live`
  continuously would permanently kill ding/motion. Frigate and MediaMTX
  `record: yes` are therefore **categorically unsafe for the Ring stream**.
- **The event stream is playback, not live view.** ring-mqtt exposes
  `rtsp://<host>:8556/<id>_event`: it "plays back the most recently recorded
  motion event by streaming the recording **directly from Ring servers**",
  once per RTSP client, then shuts down. Selection via the event `select`
  entity (5 most recent ding / motion / on-demand events). **Requires a Ring
  Protect plan** — wiki-verbatim: "use of this feature requires a Ring
  Protect plan that supports video storage". This install has one: the
  select entity lists Ding/Motion/Person 1–5 on the live Hub. Because
  playback streams from Ring's servers, not the device, it does not start a
  device live session — so it should not suppress notifications
  (**[unconfirmed]** as a literal wiki sentence; high-confidence inference
  from the two statements above).
- **The recording-download prior art ships in ring-mqtt's own wiki**: the
  event select entity carries **`eventId` and `recordingUrl` attributes** —
  a direct HTTPS MP4 URL (valid ~15 min, refreshed ~every 10). The wiki's
  documented automation: trigger on ding/motion → `wait_for_trigger` on the
  `eventId` attribute changing (recording processed) → HA
  `downloader.download_file` with that URL into a dated filename. No RTSP,
  no live session, and — with Protect — the clip includes the **pre-roll
  seconds before the press**, which a triggered local pull always misses.
  The wiki also states the no-Protect fallback plainly: trigger an ffmpeg
  pull of `_live` on the event (loses the lead seconds; suppresses further
  notifications during the pull).

## §6 The stream-plane math the Cameras view and any recorder rely on

- **N consumers cost one upstream connection per stream** — go2rtc's own
  README: cameras "will have one connection from go2rtc" while go2rtc fans
  out to RTSP/WebRTC/MSE/MJPEG consumers. A 6-tile grid costs each camera
  exactly one producer connection.
- **Zero consumers tears producers down** — verified in
  `internal/streams/stream.go`: `RemoveConsumer()` unconditionally calls
  `stopProducers()`, all producer types included (exceptions: active
  `publish`, and v1.9.11 `preload`). The `ffmpeg:<name>#video=mjpeg`
  transcode costs CPU only while a wall is actually watching, and the Ring
  producer (plus ring-mqtt's upstream cloud session, which closes ~5–10 s
  after clients disconnect) is active only while someone views or records.
  **go2rtc's idle-teardown is what keeps the doorbell's notifications alive
  today; any recorder must preserve that property for the Ring stream.**
