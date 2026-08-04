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
4. DHCP-reserve the camera, add to `hub/go2rtc/go2rtc.yaml`:
   `wyze_<location>: rtsp://user:pass@<cam-ip>/live`, restart go2rtc,
   verify at `:1984` (MSE link).

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
`go2rtc.yaml` like the flashed ones. Auth model is cloud login + LAN/TUTK
transport → these bind as `connectivity: cloud`.

## A4. Bindings

Each `cam-*` Key (and `cam-garage` for the garage's Wyze if one lives
there) binds to what go2rtc serves; the camera *state* entity in HA is
secondary for now — cameras are Popup-first Devices. If this ring-mqtt/
wyze path created HA `camera.*` entities, bind those; otherwise leave
`entity:` off (pin renders, unknown state) and the Popup still streams —
the stream name, not the entity, is what the Popup consumes. **Open
design point for the implementer**: where the Panel learns the
go2rtc stream name for a Device — recommendation: a `stream:` key in
`bindings.yaml` next to `entity:`, parsed by `bindings_parser.dart`,
rejected by the loader when it names no go2rtc stream at runtime is NOT
checkable — so validate lazily: Popup shows its existing "unavailable"
placeholder on 404.

## B. Live video in the Popup (Panel feature)

Target: tap a camera pin (or doorbell ding, phase 3) → Popup plays live
video in ≤ 2 s → closing the Popup tears the stream down (the #177014
rule, and battery-cam courtesy generally).

- **Transport: MSE over WebSocket first** (`ws://<hub-ip>:1984/api/ws?src=<stream>`
  consumed via MediaSource) — TCP, no ICE/candidate complexity, fine on
  LAN, works in Chrome and the GTK embedder's WebView-free future is not
  this phase's problem (kiosk playback tech is re-validated at spike
  time; ADR-0001's web-kiosk fallback plays MSE natively either way).
  WebRTC is the latency upgrade, deferred until MSE proves insufficient.
- **Flutter web implementation**: an `HtmlElementView` hosting a `<video>`
  element fed by a small JS-interop MSE shim (package-free; go2rtc's own
  `video-stream.js` is the reference implementation to crib from).
  Non-web builds keep the placeholder for now (the appliance target gets
  its treatment at spike time).
- **Config**: the Panel needs the go2rtc base URL — a new `GO2RTC_URL`
  alongside `HA_URL`, logged at startup as `panel.start … go2rtc=set`.
  Add it to `resolveHubConfig` (`panel/lib/config/hub_config.dart`) rather
  than as a bare `--dart-define`, so it resolves environment-first like the
  others and one more address does not re-bake the binary.
- **Diagnostics**: `[panel] I popup.stream_open name=wyze_porch` /
  `popup.stream_closed` / `W popup.stream_failed reason=…` — a wall
  panel's video failure must be greppable, not a black rectangle.
- **Tests**: widget test that the Popup requests the stream URL for the
  Device's `stream:` and tears down on close (fake the shim); golden of
  the Popup's chrome around a solid-color stand-in frame.

## Done when

- Every Wyze unit either serves RTSP locally (flashed) or restreams via
  wyze-bridge; all visible in the go2rtc UI; the A1 inventory table in
  this file records which path each took.
- Popup plays live video for at least: one Wyze camera and the Ring
  doorbell; open ≤ 2 s on LAN; close = stream teardown (verify in go2rtc
  UI: consumer count drops to 0).
- Doorbell ding while no stream is open still arrives (re-run the
  phase-3 check with video now real).
- `flutter test` green including the new Popup tests; goldens updated
  deliberately.
