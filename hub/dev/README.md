# Development Hub

A real Home Assistant for the Panel to talk to, running on whatever
machine you are coding on — including an Apple-silicon Mac (the HA image
ships an arm64 variant, verified against the same `2026.7` pin the
appliance uses).

This started as HA-alone, so the Panel's WebSocket `HubClient` could be
built against real HA protocol traffic instead of waiting for the mini PC.
On 2026-08-03 it grew the rest of the non-multicast stack — Mosquitto,
ring-mqtt, go2rtc — because every integration that does not need
mDNS/multicast can be built right here: Ring, Wyze (RTSP), Kasa (by IP),
Emporia. Real entities replace the generated stand-ins Device by Device.

**It is not the appliance stack.** `../compose.yaml` — host networking,
Zigbee2MQTT — is the real Hub and still belongs on the Linux appliance.
What this one cannot do, by construction:

- no mDNS/multicast (bridge networking), so no HomeKit-controller pairing
  for the Ecobee and no Samsung TV discovery — and no auto-discovery of
  LAN devices generally: add Kasa/ESPHome devices manually by IP, and give
  them DHCP reservations on the router;
- no Zigbee (no coordinator hardware yet — the SLZB-06 is Ethernet, so
  Zigbee2MQTT over TCP will work here once it is purchased).

A Device the real integrations do not cover yet binds to a generated
stand-in (below).

## Bring it up

```sh
cd hub/dev
cp go2rtc/go2rtc.example.yaml go2rtc/go2rtc.yaml   # live file is gitignored
docker compose up -d
```

`ring-mqtt-data/config.json` must exist before ring-mqtt starts (v5.x
refuses to run without it; the whole directory is gitignored because
ring-mqtt later stores the Ring refresh token next to it). If it is
missing, recreate it:

```json
{
    "mqtt_url": "mqtt://mosquitto:1883",
    "mqtt_options": "",
    "livestream_user": "",
    "livestream_pass": "",
    "disarm_code": "",
    "enable_cameras": true,
    "enable_modes": false,
    "enable_panic": false,
    "hass_topic": "homeassistant/status",
    "ring_topic": "ring"
}
```

Then, **by hand in the browser** — these steps create credentials, so do
them yourself:

1. Open <http://localhost:8123> and complete onboarding (create the admin
   user; skip the location/analytics steps if you like).
2. Create the Panel's long-lived token: click your user (bottom left) →
   **Security** → *Long-lived access tokens* → **Create token**. Copy it —
   HA shows it once.
3. Keep it out of git. It reaches the Panel as `HA_TOKEN` — in the process
   environment on native targets, or `--dart-define` for web builds — the
   same way the appliance's token will.

The token and the account live in `ha-config/.storage/`, which is
gitignored along with the database and logs; only `configuration.yaml` and
`packages/` are tracked.

## Real device integrations

Ports for the services below are published on **127.0.0.1 only** — the web
UIs and the broker are reachable from this machine, never from the LAN.

**MQTT into HA** (once, before Ring): Settings → *Devices & Services* →
*Add integration* → **MQTT**. Broker `mosquitto`, port `1883`, no
credentials (the compose network hostname — NOT `localhost`, which inside
the HA container is the HA container).

**Ring** (ring-mqtt): open <http://localhost:55123>, log in with the Ring
account + 2FA code; ring-mqtt stores the refresh token in
`ring-mqtt-data/` (gitignored — it IS a credential). Devices then appear
in HA via MQTT discovery. The doorbell's live-stream RTSP path for
`go2rtc.yaml` is shown in the same UI. Known issue (HA core #177014, on
the repo's calendar list): open Ring live streams on demand only — a held
stream can suppress doorbell events.

**Kasa plugs/switches**: no container — Settings → *Devices & Services* →
*Add integration* → **TP-Link Smart Home**, enter the device's IP (broadcast
discovery does not cross the bridge network). Local protocol, no cloud.

**Cameras** (go2rtc): put stream URLs in `go2rtc/go2rtc.yaml` (gitignored;
see the example file), `docker compose restart go2rtc`, preview at
<http://localhost:1984>. Wyze cameras need the official RTSP firmware
first — test one unit before flashing the fleet.

As each real entity appears, point the Device's `entity:` at it in
`panel/assets/house/bindings.yaml` — the stand-in fleet keeps covering
whatever is not yet real.

## The stand-in fleet

`packages/panel_dev.yaml` is **generated** from the Panel's own
`panel/assets/house/house.yaml`, so every one of the 33 Device pins has
an entity behind it:

| Panel state | Entity the Panel binds to | Poke it with |
|---|---|---|
| `SwitchState`, `GarageDoorState` | `input_boolean.<device_id>` | the toggle in the HA UI |
| `PowerState` | `sensor.<slugified name>` (device_class `power`, W) | `input_number.<id>_watts` |
| `StatusState` | `sensor.<slugified name>` | `input_text.<id>_status` |
| `ThermostatState` | `climate.<slugified name>` | `input_number.<id>_current`, or the climate card's setpoint |

The split is deliberate: the Panel sees the domains production will
actually serve (`sensor.*` readings, a real `climate.*` with
`current_temperature` and `temperature`), while the helpers behind them
give you something to drag in the UI. The generated file's header lists
the full device → entity mapping.

Note `climate.ecobee` is a `generic_thermostat` over a helper temperature
sensor and a dummy "calling for heat" switch — a genuine climate entity
with no hardware attached.

Regenerate after re-running the converter (the Placements are its input):

```sh
cd panel && dart run tool/gen_dev_entities.dart
cd ../hub/dev && docker compose restart
```

The generator refuses unknown Device kinds and duplicate Device names
(two devices with one name would collapse into a single HA entity id).

## Point the Panel at it

```sh
cd panel
flutter run -d chrome \
  --dart-define=HUB=ha \
  --dart-define=HA_URL=http://localhost:8123 \
  --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"
```

From the environment instead — which wins over the dart-defines
(`panel/lib/config/hub_config.dart`). **Not on `-d chrome`:** web has no
process environment, so an `HA_URL=…` prefix there is discarded and you
silently get FakeHub. Use a native target:

```sh
cd panel
HUB=ha HA_URL=http://localhost:8123 HA_TOKEN="$(cat ../hub/dev/token)" \
  flutter run -d linux        # or -d macos
```

Without `HUB=ha` the Panel runs on `FakeHub` as before. The header badge
shows which Hub the Panel talks to and whether it is currently reachable;
`[panel] I hub.config … env=available|unavailable` names where each setting
came from, and whether the environment was consulted at all.

The end-to-end check — real handshake, real snapshot, real command
round-trip — is a test:

```sh
cd panel
flutter test test/ha_hub_live_test.dart \
  --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"

# or, pointing at a different Hub without recompiling the test:
PANEL_LIVE_HUB=1 HA_URL=http://<hub-ip>:8123 HA_TOKEN="$(cat ../hub/token)" \
  flutter test test/ha_hub_live_test.dart
```

Plain `flutter test` stays hermetic: the test only runs for a
`--dart-define=HA_TOKEN` (already per-invocation) or an explicit
`PANEL_LIVE_HUB`. Gating on `HA_TOKEN` alone would not be enough now that
settings resolve environment-first — a token merely exported in your shell
would be enough to reach a real house and toggle a real light.

## Housekeeping

`configuration.yaml` turns on debug logging for `websocket_api`, so every
frame the Panel exchanges shows up in the log — including the auth frame,
**token and all, in plaintext**. Acceptable for a localhost development Hub
whose config directory is gitignored; never do it on the appliance. Wiping
`ha-config/` (below) clears it.

```sh
docker compose logs -f          # watch it
docker compose down             # stop, keep the account and token
docker compose down && rm -rf ha-config/.storage ha-config/*.db   # start over
```

No *state* here migrates to the appliance — the HA account, tokens and
database stay put; the real Hub is `../compose.yaml`, and the Panel just
points at a different host and token. What DOES carry over is authored
config: `go2rtc.yaml` stream definitions, the ring-mqtt settings (env vars
in `compose.yaml`; the Ring account gets re-authenticated on the
appliance), and the list of Kasa/Emporia IPs to re-add there.
