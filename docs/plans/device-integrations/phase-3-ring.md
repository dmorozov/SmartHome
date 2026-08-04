# Phase 3 — Ring doorbell: events now, streaming plumbing ready

ring-mqtt is already Up (phase 1) and waiting at its auth gate. This phase
authenticates it, binds the doorbell, and lays the go2rtc plumbing that
phase 4's Panel popup will consume. Cloud, permanently (§3.1) —
`connectivity: cloud` and at peace with it.

## 1. Authenticate

Browser → `http://<hub-ip>:55123` → Ring account + 2FA code. The refresh
token lands in `hub/ring-mqtt-data/` (gitignored). `docker compose logs
ring-mqtt` then shows device discovery; because MQTT discovery is on, the
doorbell materialises in HA automatically: device "Front Door" (or
similar) with, typically:

- `event.*_ding` (doorbell press events — HA 2026-era ring-mqtt publishes
  event entities; older styles use `binary_sensor.*_ding`; use whichever
  this version created)
- `binary_sensor.*_motion`
- `camera.*_snapshot` (still image)
- battery/wifi diagnostics

## 2. Bind the doorbell

The `doorbell` kind opens the Popup on tap (vocabulary table) and its
state is a `StatusState`. Bind the entity whose state changes on a press
— check which of ding-event/binary_sensor this ring-mqtt version emits:

```yaml
  doorbell:
    entity: event.<front_door>_ding    # or binary_sensor.<...>_ding
    connectivity: cloud
```

**Verify**: press the physical button → the entity fires in HA
(Developer Tools → States) → the Panel pin re-renders
(`hub.state_changed` at debug level).

## 3. go2rtc live-view plumbing

ring-mqtt runs an internal RTSP server (bridge network, remapped to host
port 8556 in phase 1). Stream path: ring-mqtt web UI → the camera's info
page shows the RTSP URL and credentials if livestream auth is set. Add to
`hub/go2rtc/go2rtc.yaml` on the laptop:

```yaml
streams:
  ring_doorbell: rtsp://127.0.0.1:8556/<ring-device-id>_live
```

`docker compose restart go2rtc`, then open `http://<hub-ip>:1984` → the
`ring_doorbell` stream → **links → MSE**. First frames take 2–5 s (the
stream spins up on demand — ring-mqtt starts the Ring live session only
when an RTSP client connects, which is exactly the on-demand behavior we
need).

**The #177014 rule** (HA core issue, on the repo calendar): an OPEN Ring
live stream can suppress ding events. Consequences, enforced in phase 4's
Panel work: live view opens on tap, closes with the Popup, is never held
open in the background, and nothing auto-opens the stream on motion.

## 4. Doorbell-ring Popup (Panel behavior, small)

Today the Popup opens when the *user taps* the doorbell pin. The desired
phase-1-video behavior from the README — "doorbell ring pops up video" —
is a Panel change: on the ding entity's state change, open the Popup
unprompted. Implementation sketch: `HubController` already re-renders on
`state_changed`; add a listener that, when the `doorbell`-kind Device's
status transitions to *ringing*, pushes the Popup route (and auto-closes
it after N seconds of no interaction — a wall panel must never strand a
modal). Test: scripted `FakeHub` emits the transition; widget test
asserts the Popup appears and auto-dismisses. **Actual video inside the
Popup is phase 4** — until then it shows the existing placeholder.

## Done when

- Physical button press → Panel doorbell pin reacts (entity round-trip
  verified) and the Popup opens unprompted (FakeHub-tested behavior, then
  observed live).
- `ring_doorbell` plays in the go2rtc web UI via MSE, on demand, and a
  ding is still delivered while NO stream is open (the #177014 rule holds
  because nothing holds a stream).
- Ring refresh token exists only under `hub/ring-mqtt-data/`; `git
  status` shows nothing new tracked.
