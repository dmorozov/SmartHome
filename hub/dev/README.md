# Development Hub

A real Home Assistant for the Panel to talk to, brought up automatically
as the devcontainer's sibling containers (ADR-0009) on whatever machine
hosts the devcontainer — Apple-silicon Macs included, because the HA
image ships an arm64 variant, verified against the same `2026.7` pin the
appliance uses.

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

Open the repo in the devcontainer — that IS the bring-up
(`.devcontainer/README.md` is the guide, ADR-0009 the decision). The
devcontainer uses this same compose file as its base, so opening the
editor brings this stack up as sibling containers, closing the window
stops it (state survives in the bind mounts here), and **"Rebuild
Container"** recreates it. `.devcontainer/initialize.sh` seeds the two
gitignored files below on every start, and says why that must happen
host-side. One host-side step remains, once: if a stack was ever started
by hand in this directory, `docker compose down` here before the first
devcontainer open — the two drivers share one compose project (the
`name:` in this compose file wins), and `initialize.sh` refuses to adopt
a hand-started stack, so ownership cannot change hands by accident. The
by-hand-in-the-browser credential steps further down apply either way.

What `initialize.sh` seeds — kept here as the recovery reference, not as
a setup step:

- `go2rtc/go2rtc.yaml`, copied from the tracked
  `go2rtc/go2rtc.example.yaml` (the live file is gitignored because real
  stream URLs embed camera credentials).
- `ring-mqtt-data/config.json`, which must exist before ring-mqtt starts
  (v5.x refuses to run without it; the whole directory is gitignored
  because ring-mqtt later stores the Ring refresh token next to it).
  This is the canonical content — `initialize.sh` writes it verbatim
  from here:

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

If either file goes missing (both are gitignored, so a `git clean` loses
them), re-run `bash .devcontainer/initialize.sh` on the host — it is
idempotent and runs on every devcontainer start anyway — or recreate
them from the above by hand.

Then, **by hand in the browser** — these steps create credentials, so do
them yourself:

1. Open <http://localhost:18123> and complete onboarding (create the admin
   user; skip the location/analytics steps if you like). 18123, not 8123 —
   every host port here is the SHIFTED dev set, because the production Hub
   stack runs on this same machine and owns the canonical ports
   (compose.yaml's header has the full table; canonical = the real house,
   shifted = this sandbox). HA's own docs, if the onboarding UI has moved:
   <https://www.home-assistant.io/getting-started/onboarding/> — and
   <https://demo.home-assistant.io/> is a click-around demo needing no
   install at all.
2. Create the Panel's long-lived token: click your user (bottom left) →
   **Security** → *Long-lived access tokens* → **Create token**. Copy it —
   HA shows it once. Save it to `token` in this directory (gitignored) —
   every command below reads it from there.
3. Keep it out of git. It reaches the Panel as `HA_TOKEN` — in the process
   environment on native targets, or `--dart-define` for web builds — the
   same way the appliance's token will.

The token and the account live in `ha-config/.storage/`, which is
gitignored along with the database and logs; only `configuration.yaml` and
`packages/` are tracked.

## Real device integrations

Ports for the services below are published on **127.0.0.1 only** — the web
UIs and the broker are reachable from the host machine, never from the
LAN. That is only the host-side half of the addressing rule: from inside
the devcontainer, dial the compose service name on the canonical
container port instead (`mosquitto:1883`, `http://go2rtc:1984`,
`http://homeassistant:8123`) — the `localhost` + shifted-port addresses
are for the browser, which runs on the host.

**MQTT into HA** (once, before Ring): Settings → *Devices & Services* →
*Add integration* → **MQTT**. Broker `mosquitto`, port `1883`, no
credentials (the compose network hostname — NOT `localhost`, which inside
the HA container is the HA container).

**Ring** (ring-mqtt): open <http://localhost:65123>, log in with the Ring
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
see the example file), `docker restart go2rtc-dev`, preview at
<http://localhost:11984>. Wyze cameras need the official RTSP firmware
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
docker restart homeassistant-dev
```

The generator refuses unknown Device kinds and duplicate Device names
(two devices with one name would collapse into a single HA entity id).

## Point the Panel at it

From a terminal in the devcontainer — `-d web-server`, because the
browser lives on the host (`post-create.sh` prints this same command):

```sh
cd panel
flutter run -d web-server --web-port 8080 --profile \
  --dart-define=HUB=ha \
  --dart-define=HA_URL=http://localhost:18123 \
  --dart-define=HA_TOKEN="$(cat ../hub/dev/token)" \
  --dart-define=GO2RTC_URL=http://localhost:11984
```

`--profile` is load-bearing, not an optimisation: a debug `-d web-server`
build waits for a debug connection before running `main()`, and the
web-server device only gets one from the Dart Debug Chrome extension —
without it the page stays blank with an empty console
(`panel/README.md` has the full story).

Then open <http://localhost:8080> on the host (VS Code forwards the
port). `localhost` + shifted ports are correct in those dart-defines
even though the command runs in-container: the BROWSER dials HA and
go2rtc, and the browser is on the host, where compose publishes the dev
stack on 18123/11984. Dart-defines, not an environment prefix: a web
build has no process environment, so `HA_URL=…` in front of the command
would be silently discarded and you would get FakeHub
(`panel/README.md` owns the environment-vs-dart-define order).

Without `HUB=ha` the Panel runs on `FakeHub` as before. The header badge
shows which Hub the Panel talks to and whether it is currently reachable;
`[panel] I hub.config … env=available|unavailable` names where each setting
came from, and whether the environment was consulted at all.

`GO2RTC_URL` (in the recipe above) points the camera and doorbell Popups
at go2rtc. Leaving it off is a supported state and the boot log says so
(`GO2RTC_URL=absent`, then `popup.go2rtc url=absent`): there is no built-in
default, on purpose, because a camera is a camera under every Hub and a
default address would open a socket to nothing on every dev run. A Device
also needs a `stream:` name in `panel/assets/house/bindings.yaml`, and none of
the generated stand-ins has one — the dev fleet has no video. Setting both
against a go2rtc that has the named stream gets you an actual picture: in
the browser it plays over a WebSocket; a native `-d linux` build plays HTTP
MJPEG instead and needs **two producers** in `go2rtc.yaml`, or it gets an
empty stream and says nothing about why. `selftest` is the stream to point
at while there is no camera. See `panel/README.md`, "Live video in the
Popup".

The end-to-end check — real handshake, real snapshot, real command
round-trip — is a test. The canonical form, from a terminal in the
devcontainer (service-name DNS, because here the TEST process is the one
dialling; `post-create.sh` prints this same command):

```sh
cd panel
PANEL_LIVE_HUB=1 HA_URL=http://homeassistant:8123 \
  HA_TOKEN="$(cat ../hub/dev/token)" flutter test test/ha_hub_live_test.dart
```

Never drop `HA_URL`: the test's built-in default is `localhost:8123`,
which from in-container reaches nothing — and on the host is the REAL
house's HA. Pointing at a different Hub is the same command with a
different `HA_URL` and token file, no recompile. Right now the run fails
at the `ThermostatState` cast — the dev-Hub parity drift
(`.devcontainer/README.md`, "Standing caveats") — while connecting,
authenticating and snapshotting is the pass signal; failing before the
cast is a real problem.

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
docker logs -f homeassistant-dev   # watch it — any service, by container name
```

Lifecycle belongs to the devcontainer — never `docker compose` from
in-container, where the relative bind paths resolve against the wrong
filesystem (`.devcontainer/compose.yaml` header): opening the repo is
`up`, closing the VS Code window stops the whole stack (the account and
token survive in the bind mounts here), **"Rebuild Container"**
recreates it. To start over — works from in-container too, once HA is
stopped:

```sh
docker stop homeassistant-dev
rm -rf ha-config/.storage ha-config/*.db
docker start homeassistant-dev
```

No *state* here migrates to the appliance — the HA account, tokens and
database stay put; the real Hub is `../compose.yaml`, and the Panel just
points at a different host and token. What DOES carry over is authored
config: `go2rtc.yaml` stream definitions, the ring-mqtt settings (env vars
in `compose.yaml`; the Ring account gets re-authenticated on the
appliance), and the list of Kasa/Emporia IPs to re-add there.
