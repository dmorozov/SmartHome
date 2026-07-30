# Hub

The headless smart-home broker behind the Panel: Home Assistant (Container),
Mosquitto, Zigbee2MQTT, and go2rtc, orchestrated by Docker Compose. The Hub
owns device state, integrations, and automations; the Panel is its client,
never its replacement (see `CONTEXT.md` and ADR-0002).

Research backing every choice here: `docs/research/hub-and-device-integrations.md`.

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

- The Appliance (dev laptop for now): Ubuntu 24.04 LTS with Docker Engine and
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
   ```

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
(including the gitignored runtime state: `ha-config/.storage`, `z2m-data`
database and network keys, Mosquitto persistence) to the mini PC, and
`docker compose up -d` there. Nothing in the compose file is
laptop-specific — the SLZB-06 is on the LAN, not on USB, so even the Zigbee
radio needs no re-pairing.

Before the mini PC is treated as production, switch Mosquitto off anonymous
access — see the loud comment in `mosquitto/config/mosquitto.conf`.

## Layout

| Path | Tracked in git | Purpose |
|---|---|---|
| `compose.yaml` | yes | The stack definition (pinned images) |
| `ha-config/` | starter files only | HA `/config`; runtime state gitignored |
| `custom_components/` | yes | Our own extensions/fixes slot (see its README) |
| `mosquitto/config/` | yes | Broker config; `data/` and `log/` gitignored |
| `z2m-data/` | example starter only | Z2M state; live config, DB, and keys gitignored |
| `go2rtc/` | example starter only | Stream definitions; live config gitignored (camera credentials) |
