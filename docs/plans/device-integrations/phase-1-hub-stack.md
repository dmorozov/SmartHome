# Phase 1 — The real Hub stack, up on the laptop

`hub/compose.yaml` finally runs where it was designed to run. Three compose
edits first (done on the Mac, synced via git — they are plain repo files),
then bring-up on the laptop.

## 1. Compose promotion (repo edits)

### 1a. Add ring-mqtt to `hub/compose.yaml`

Promoted from the `hub/dev/` sandbox work of 2026-08-03 (same image pin,
same config.json pattern). It joins the **default bridge network with
Mosquitto** — NOT host networking, because ring-mqtt's internal RTSP
server binds 8554 and would collide with go2rtc's host-networked 8554:

```yaml
  ring-mqtt:
    # Pinned exactly (latest at first bring-up 2026-08-03). Standalone
    # container, not an HA "Add-on" (add-ons need HA OS; we run Container).
    image: tsightler/ring-mqtt:5.9.3
    container_name: ring-mqtt
    depends_on:
      - mosquitto
    environment:
      TZ: ${TZ:-UTC}
    ports:
      - "55123:55123"   # web UI: Ring 2FA login -> refresh token
      - "8556:8554"     # internal RTSP, remapped: 8554 belongs to go2rtc
    volumes:
      # config.json (authored) + runtime state incl. the Ring REFRESH
      # TOKEN -> the whole directory is gitignored.
      - ./ring-mqtt-data:/data
    restart: unless-stopped
```

`hub/ring-mqtt-data/config.json` (create before first start; v5.x refuses
to run without it). `mqtt_url` uses the compose-network service name, with
the phase-1c credentials:

```json
{
    "mqtt_url": "mqtt://ring:<ring-password>@mosquitto:1883",
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

### 1b. Park Zigbee2MQTT behind a compose profile

No SLZB-06 coordinator exists yet; unparked, the service crash-loops. Add
to the `zigbee2mqtt` service:

```yaml
    profiles: ["zigbee"]
```

`docker compose up -d` now skips it; the future Zigbee phase starts it
with `docker compose --profile zigbee up -d`. (Also fill in the exact
image tag at that point, per the existing comment in the service.)

### 1c. Mosquitto: authenticated access NOW (D4)

Host networking exposes 1883 to the LAN, so the example config's "before
the mini PC" deadline moves to today. In `hub/mosquitto/config/mosquitto.conf`:
`allow_anonymous false`, `password_file /mosquitto/config/passwd`. On the
laptop after first start (or via a throwaway mosquitto container):

```sh
docker exec mosquitto mosquitto_passwd -c -b /mosquitto/config/passwd ha    '<ha-password>'
docker exec mosquitto mosquitto_passwd    -b /mosquitto/config/passwd ring  '<ring-password>'
docker exec mosquitto mosquitto_passwd    -b /mosquitto/config/passwd z2m   '<z2m-password>'   # for later
docker compose restart mosquitto
```

`passwd` is already covered by `hub/.gitignore`. Passwords live in the
password store of your choice; they appear only in `passwd` (hashed),
ring-mqtt's `config.json` (gitignored), Z2M's live config (gitignored,
later), and HA's `.storage` (gitignored).

### 1d. Gitignore + go2rtc starter

- `hub/.gitignore`: add `ring-mqtt-data/` and `token`.
- `cp hub/go2rtc/go2rtc.example.yaml hub/go2rtc/go2rtc.yaml` (on the
  laptop). Host networking means WebRTC needs no candidate tricks — leave
  the file minimal until phase 3 adds streams.

## 2. Bring-up (on the laptop)

```sh
cd hub
docker compose up -d          # homeassistant, mosquitto, go2rtc, ring-mqtt
docker compose ps             # 4 services Up; zigbee2mqtt absent (profile)
```

Then in a browser (from the Mac, `http://<hub-ip>:8123`):

1. **HA onboarding** — create the admin account. This is the Hub that
   migrates to the mini PC; name things accordingly.
2. **Long-lived token** — profile → Security → create, for the Panel.
   Store it on the Mac at `hub/token` (gitignored by 1d).
3. **MQTT integration** — Settings → Devices & Services → Add → MQTT:
   broker `127.0.0.1`, port `1883`, user `ha`, the 1c password. (HA is
   host-networked: localhost IS the laptop, and Mosquitto's 1883 is
   published on it.)

## 3. Panel against the real Hub (on the Mac)

```sh
cd panel
flutter run -d chrome \
  --dart-define=HUB=ha \
  --dart-define=HA_URL=http://<hub-ip>:8123 \
  --dart-define=HA_TOKEN="$(cat ../hub/token)"
```

## Done when

- `docker compose ps`: 4 services Up, none restarting; `docker compose
  logs ring-mqtt` shows it waiting for Ring auth (that's phase 3, not an
  error) and connected to MQTT with the `ring` user.
- Anonymous MQTT is refused: `mosquitto_sub -h <hub-ip> -t '#'` fails;
  with `-u ha -P …` it connects.
- The Panel console shows `hub.connected url=ws://<hub-ip>...` and a
  `hub.snapshot` line. `hub.missing_entities` will list ~everything —
  correct: the laptop Hub has no stand-in fleet and no real devices yet.
  Phases 2–5 drain that list; this phase only proves the wiring.
- `flutter test test/ha_hub_live_test.dart --dart-define=HA_TOKEN=...`
  passes against `HA_URL=http://<hub-ip>:8123`.

## Note: what happens to `hub/dev/`

Nothing is deleted. Its compose keeps working for protocol-sandbox use
(per ADR-0008), and its generated stand-in fleet remains the way to
develop Panel features without the laptop on. The 2026-08-03 additions to
it (mosquitto/ring-mqtt/go2rtc services) are now redundant with the real
stack and MAY be trimmed back in a later cleanup; trimming them is not
part of this plan.
