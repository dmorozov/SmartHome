# Hub

The headless smart-home broker behind the Panel: Home Assistant (Container),
Mosquitto, Zigbee2MQTT, and go2rtc, orchestrated by Docker Compose. The Hub
owns device state, integrations, and automations; the Panel is its client,
never its replacement (see `CONTEXT.md` and ADR-0002).

Research backing every choice here: `docs/research/hub-and-device-integrations.md`.

**Developing the Panel's `HubClient`?** You do not need this stack, or the
appliance. `dev/` runs Home Assistant alone on your workstation (Mac
included) with a generated stand-in for the device fleet — see
[`dev/README.md`](dev/README.md).

## ⚠️ Dated risks (from the repo README — do not lose these)

> **Before upgrading past HA 2026.8** — define an explicit `turn_on`
> (Wake-on-LAN action) per Samsung TV: the `samsungtv` integration removes
> implicit WOL in 2026.8. This compose file pins HA 2026.7, so the pin is the
> guard — do the TV config before bumping the pin.
>
> **By October 2026** — Samsung starts phasing out free SmartThings API
> access ($4.99/mo "Personal Plan"). Decide: pay, or drop the oven
> integration.

## Prerequisites

- The Appliance (dev laptop for now): Ubuntu 26.04 LTS with Docker Engine and
  the Compose plugin installed. The hub stack must run on this Linux machine —
  Docker-on-macOS breaks the multicast/mDNS that Ecobee HomeKit pairing and
  Samsung TV discovery require.
- SMLIGHT SLZB-06 Zigbee coordinator on the LAN, running in **Ethernet mode**
  (not WiFi — serial-over-WiFi is failure-prone per Zigbee2MQTT's own
  guidance), reachable from the Appliance.

## Bring-up (in order)

1. Create the live configs from the tracked examples (the live files are
   gitignored on purpose — Z2M injects the Zigbee network key into its config
   at runtime, and go2rtc stream URLs embed camera credentials):

   ```sh
   cp z2m-data/configuration.example.yaml z2m-data/configuration.yaml
   cp go2rtc/go2rtc.example.yaml go2rtc/go2rtc.yaml
   cp ha-config/mqtt.example.yaml ha-config/mqtt.yaml
   ```

   `mqtt.yaml` (manually-declared MQTT entities — its topics embed the Ring
   location id) is **load-bearing for HA startup**: `configuration.yaml`
   includes it, so skipping this copy fails HA's config check. Fill its two
   ids per the comments in the example.

   In `z2m-data/configuration.yaml`, replace `SLZB-06-IP-OR-HOSTNAME` with
   the coordinator's LAN IP or hostname (give it a DHCP reservation).
2. From this directory:

   ```sh
   docker compose up -d
   ```

   Compose starts Mosquitto before Zigbee2MQTT; Home Assistant reconnects to
   whatever it needs.
3. Pin Zigbee2MQTT exactly: check the version it came up with
   (`docker compose logs zigbee2mqtt | head`), then replace the major-pin `2`
   tag in `compose.yaml` with that exact version and commit. (HA and go2rtc
   are already pinned exactly.)
4. Home Assistant onboarding at `http://<appliance>:8123` — create the admin
   user. Add the MQTT integration pointing at `<appliance>:1883` so Zigbee
   devices flow in via MQTT discovery.
5. Zigbee2MQTT frontend at `http://<appliance>:8080` — permit joins and pair
   the Zigbee devices (Inovelli switches, ThirdReality plugs, …).
6. go2rtc UI at `http://<appliance>:1984` — add camera streams to
   `go2rtc/go2rtc.yaml` when the RTSP-flashed Wyze cams exist (live file
   gitignored — stream URLs embed camera credentials).

## How the Panel connects

The Panel speaks the Hub's **WebSocket API** — the same API HA's own frontend
uses:

- Endpoint: `ws://<appliance>:8123/api/websocket`
- Auth: a **long-lived access token** (valid 10 years), minted in the HA UI:
  your profile (bottom-left avatar) → **Security** → **Long-lived access
  tokens** → Create token. The token lives in the Panel's configuration only —
  never in this repo.
- Over it the Panel gets entity states, filtered event subscriptions, and
  service calls for every integrated Device. Video popups bypass the Hub and
  come from go2rtc directly (research doc §5).

## Migration to the mini PC

The stack moves **unchanged**: stop the stack, copy this entire directory
(including the gitignored runtime state) to the mini PC, and
`docker compose up -d` there. Nothing in the compose file is
laptop-specific — the SLZB-06 is on the LAN, not on USB, so even the Zigbee
radio needs no re-pairing.

The runtime state that must come with it:

| Path | Why it cannot be recreated |
|---|---|
| `ha-config/.storage` | Every config entry and credential, plus the auth store. 5 of its files are `0600 root`, so an unprivileged `tar` silently drops them |
| `ring-mqtt-data/ring-state.json` | **The Ring refresh token.** Added to this list 2026-08-05, when B2 created it — before that the directory held nothing worth copying. Losing it is the only failure here that costs a **live 2FA session with a human present**, and it cannot be re-derived from anything |
| `z2m-data` | Zigbee database and network keys — losing them re-pairs every Zigbee device by hand |
| Mosquitto persistence | Retained messages and subscriptions |

`go2rtc/go2rtc.yaml` and `z2m-data/configuration.yaml` are gitignored config
rather than state — recreate them from their `.example` files, then re-add the
camera credentials and the Zigbee coordinator address.

**Never restore a stale `ring-state.json` over a newer one**, and never run two
ring-mqtt instances against one Ring account: the token rotates in place, so a
rolled-back or duplicated copy is expected to invalidate the session and drop
you back at the 2FA prompt.

Mosquitto is already off anonymous access (`allow_anonymous false` +
`password_file`, decision D4 — see the comment block in
`mosquitto/config/mosquitto.conf`). Carry `mosquitto/config/passwd` across with
the rest of the runtime state, and re-`chown 1883:1883` it on the new box, or
nothing will be able to connect there.

## Layout

| Path | Tracked in git | Purpose |
|---|---|---|
| `compose.yaml` | yes | The stack definition (pinned images) |
| `ha-config/` | starter files only | HA `/config`; runtime state gitignored |
| `custom_components/` | yes | Our own extensions/fixes slot (see its README) |
| `mosquitto/config/` | yes | Broker config (`mosquitto.conf`); `passwd` + `passwd.backup.*` gitignored |
| `mosquitto/data/`, `mosquitto/log/` | directory only (`.gitkeep`) | Bind-mount targets; contents gitignored. Tracked so `docker compose up` does not have dockerd create them root-owned in the working tree |
| `z2m-data/` | example starter only | Z2M state; live config, DB, and keys gitignored |
| `go2rtc/` | example starter only | Stream definitions; live config gitignored (camera credentials) |
