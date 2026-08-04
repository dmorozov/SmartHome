# Device integrations — the whole available fleet, before the real hardware

Goal: every device the house owns today is integrated into the Hub and
visible/controllable on the Panel, with only two machines involved — the
**AMD dev laptop** as the Hub host (ADR-0008) and the Mac for Panel
development. The Ryzen mini PC stays unpurchased; the kiosk/cage spike stays
the project's final step. Samsung TVs are explicitly out of scope (user
decision 2026-08-03); the oven is a dated decision, not a task (D3).

Grilling session 2026-08-03. Research base:
[`../../research/hub-and-device-integrations.md`](../../research/hub-and-device-integrations.md)
(per-device sections cited throughout as §3.x).

## The fleet, by integration path

| Device(s) | Path | Local? | Phase |
|---|---|---|---|
| Kasa outdoor plug + 2 wall switches | HA core `tplink`, native discovery | ✅ local | 2 |
| Tesla Wall Connector | HA core `tesla_wall_connector`, HTTP by IP | ✅ local (monitor-only) | 2 |
| Ecobee thermostat | **dual**: core `ecobee` cloud (keyless since HA 2026.3) + `homekit_controller` | ✅ local (+ cloud features) | 2 |
| Ring Video Doorbell | ring-mqtt 5.9.3 (promoted into `hub/compose.yaml`) + go2rtc | ☁️ cloud, permanently (§3.1) | 3 |
| Wyze cameras (v3-class + floodlights) | RTSP firmware flash where possible, docker-wyze-bridge for the rest | ✅/☁️ mixed (D1) | 4 |
| LG washer + dryer | HA core `lg_thinq` (PAT) | ☁️ | 5 |
| Litter-Robot 5 Pro | HA core `litterrobot` | ☁️ | 5 |
| Petlibro One + Granary feeder | HACS `petlibro` | ☁️ | 5 |
| Emporia Vue 3 + Emporia outlets | HACS cloud now, ESPHome reflash later (D2) | ☁️ now, ✅ later | 5 |
| SmartThings oven | decision due, not a build task (D3) | ☁️ | — |

Out of scope, listed so nothing is silently dropped: Samsung TVs (user
decision); myQ garage (blocked on ratgdo purchase); Zigbee
switches/outlets/coordinator (blocked on purchase); Ecobee schedule UI on
the Panel; mini-PC migration; the cage spike.

## Decisions from the grilling (D-log)

Decisions the user confirmed are marked ✅; the rest were cut short when the
user called for the plan — each carries my recommendation and is **applied
by default** unless overridden before its phase starts.

- **D0 ✅ Environment**: Hub on the AMD laptop, real `hub/compose.yaml`,
  host networking (ADR-0008). macOS Docker workarounds investigated and
  rejected (host-networking mode, docker-mac-net-connect, Colima bridged,
  UTM/Fusion VM — the VM would work but adds a layer used for nothing else).
- **D0a ✅ Ecobee pairing slot is free**: linked to Alexa (cloud-to-cloud,
  no HomeKit slot) and the ecobee app only. Never HomeKit-paired.
- **D1 Wyze** (recommended): flash ONE v3 to official RTSP firmware as the
  experiment (§3.2 — firmware availability in 2026 is the UNVERIFIED bit);
  floodlights and any unflashed unit go through docker-wyze-bridge. Decide
  fleet-wide flashing only after the single-unit result.
- **D2 Emporia** (recommended): HACS cloud integration now for Vue 3 +
  outlets readings; the ESPHome reflash (§3.4) is a separate bench day,
  deferred — it needs disassembly/UART and must not block this plan.
- **D3 Oven** (recommendation: let the deadline decide): skip the
  SmartThings integration unless the $4.99/mo "Personal Plan" is accepted
  by the existing calendar item (October 2026). Not a phase in this plan.
- **D4 ✅ implied Mosquitto auth**: the broker is LAN-exposed under host
  networking, so password auth goes in at phase 1, not "before the mini
  PC" as the config's old comment said.
- **D5 Bindings against the placeholder house** (recommended): bind real
  entities to the placeholder Keys now (`doorbell`, `thermostat`,
  `washer`…) — the placeholder resembles the real house, Keys are stable
  identities, and re-keying after the real drawing lands is a
  bindings.yaml-only edit by design (ADR-0005).

## Phases

Each phase ends with the Panel showing something it could not show before,
verified by the `[panel]` diagnostic lines (`hub.snapshot`,
`hub.missing_entities`) and by eye. Order is by increasing friction;
phases 3–5 are independent of each other and may interleave.

| Phase | File | Delivers |
|---|---|---|
| 0 | [phase-0-laptop-bring-up.md](phase-0-laptop-bring-up.md) | Laptop on the LAN, Docker ready, repo synced |
| 1 | [phase-1-hub-stack.md](phase-1-hub-stack.md) | Real Hub up: compose promotion (ring-mqtt in, Z2M parked, broker auth), HA onboarded, Panel connected |
| 2 | [phase-2-local-quick-wins.md](phase-2-local-quick-wins.md) | First real Devices: Kasa, Tesla WC, Ecobee (cloud + local HomeKit) |
| 3 | [phase-3-ring.md](phase-3-ring.md) | Doorbell events + on-demand live view plumbing |
| 4 | [phase-4-cameras.md](phase-4-cameras.md) | Wyze streams in go2rtc; **Panel popup live video** (the one real Panel feature in this plan) |
| 5 | [phase-5-cloud-fleet.md](phase-5-cloud-fleet.md) | HACS + the cloud accounts: LG, Whisker, Petlibro, Emporia |
| 6 | [phase-6-bindings-sweep.md](phase-6-bindings-sweep.md) | Every available device bound, `missing=0`, goldens, docs updated |

## Secrets discipline (applies to every phase)

Nothing new: HA `.storage`, `z2m-data`, `go2rtc.yaml`, `passwd`, tokens are
already gitignored under `hub/`. New in this plan: `hub/ring-mqtt-data/`
(Ring refresh token) and `hub/token` (the laptop Hub's long-lived Panel
token) — phase 1 adds both to `hub/.gitignore`. Cloud credentials (ecobee,
LG, Whisker, Petlibro, Wyze, Emporia) are typed into the HA UI only and
live in `.storage`; they never touch a tracked file. The Panel keeps
logging `token=set`, never the token.
