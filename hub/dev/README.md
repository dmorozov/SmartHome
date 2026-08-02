# Development Hub

A real Home Assistant for the Panel to talk to, running on whatever
machine you are coding on — including an Apple-silicon Mac (the HA image
ships an arm64 variant, verified against the same `2026.7` pin the
appliance uses).

This exists so the Panel's WebSocket `HubClient` can be built and tested
now, against real HA protocol traffic, instead of waiting for the mini PC.

**It is not the appliance stack.** `../compose.yaml` — host networking,
Mosquitto, Zigbee2MQTT, go2rtc — is the real Hub and still belongs on the
Linux appliance. What this one cannot do, by construction:

- no mDNS/multicast (bridge networking), so no HomeKit-controller pairing
  for the Ecobee and no Samsung TV discovery;
- no Zigbee, no MQTT broker, no cameras.

Everything the Panel binds to here is a generated stand-in (below).

## Bring it up

```sh
cd hub/dev
docker compose up -d
```

Then, **by hand in the browser** — these steps create credentials, so do
them yourself:

1. Open <http://localhost:8123> and complete onboarding (create the admin
   user; skip the location/analytics steps if you like).
2. Create the Panel's long-lived token: click your user (bottom left) →
   **Security** → *Long-lived access tokens* → **Create token**. Copy it —
   HA shows it once.
3. Keep it out of git. It will be passed to the Panel at build time
   (`--dart-define`), the same way the appliance's token will be.

The token and the account live in `ha-config/.storage/`, which is
gitignored along with the database and logs; only `configuration.yaml` and
`packages/` are tracked.

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

Without `HUB=ha` the Panel runs on `FakeHub` as before. The header badge
shows which Hub the build talks to and whether it is currently reachable.

The end-to-end check — real handshake, real snapshot, real command
round-trip — is a test:

```sh
cd panel
flutter test test/ha_hub_live_test.dart \
  --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"
```

It is skipped without the token, so plain `flutter test` stays hermetic.

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

Nothing here migrates to the appliance. When the mini PC arrives, the real
Hub is `../compose.yaml` with real integrations, and the Panel just points
at a different host and token.
