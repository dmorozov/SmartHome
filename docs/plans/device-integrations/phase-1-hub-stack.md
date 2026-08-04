# Phase 1 — The real Hub stack, up on the laptop

`hub/compose.yaml` finally runs where it was designed to run. Three compose
edits first (done on the Mac, synced via git — they are plain repo files),
then bring-up on the laptop.

> **Status: §1 (all repo edits) applied 2026-08-03 on the Mac.** The
> snippets below are kept as the record of what changed and why; on the
> laptop, start at §2 after `git pull`.

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

`hub/ring-mqtt-data/config.example.json` is the tracked starter (same
example-file pattern as go2rtc and Z2M; v5.x refuses to start without a
config.json). On the laptop:
`cp ring-mqtt-data/config.example.json ring-mqtt-data/config.json`, then
put the `ring` user's password from §1c into `mqtt_url` — it uses the
compose-network service name: `mqtt://ring:<ring-password>@mosquitto:1883`.

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

The published port exposes 1883 to the LAN, so the old config's "before
the mini PC" deadline moved to today: `hub/mosquitto/config/mosquitto.conf`
now sets `allow_anonymous false` + `password_file /mosquitto/config/passwd`.

**Gotcha the config comment also documents**: mosquitto refuses to start
if `password_file` names a missing file — so the file must exist (empty
is fine: empty + no-anonymous = nobody connects until users are added)
*before* first start. On the laptop, from `hub/`:

```sh
touch mosquitto/config/passwd
sudo chown 1883:1883 mosquitto/config/passwd && sudo chmod 600 mosquitto/config/passwd
docker compose up -d mosquitto
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd ha    '<ha-password>'
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd ring  '<ring-password>'
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd z2m   '<z2m-password>'   # for later
docker compose restart mosquitto
```

(`1883` is the eclipse-mosquitto container's `mosquitto` uid; the chown
lets the broker read a 600-permission file across the bind mount.)

`passwd` is already covered by `hub/.gitignore`. Passwords live in the
password store of your choice; they appear only in `passwd` (hashed),
ring-mqtt's `config.json` (gitignored), Z2M's live config (gitignored,
later), and HA's `.storage` (gitignored).

### 1d. Gitignore + go2rtc starter

- `hub/.gitignore`: `ring-mqtt-data/*` (except the example) and `token`
  added.
- `cp hub/go2rtc/go2rtc.example.yaml hub/go2rtc/go2rtc.yaml` (on the
  laptop). Host networking means WebRTC needs no candidate tricks — leave
  the file minimal until phase 3 adds streams.

## 2. Bring-up (on the laptop)

```sh
cd hub
# 1. broker auth bootstrap — the touch/chown/mosquitto_passwd sequence from §1c
# 2. live configs from the tracked examples:
cp ring-mqtt-data/config.example.json ring-mqtt-data/config.json   # + set the ring password
cp go2rtc/go2rtc.example.yaml go2rtc/go2rtc.yaml
# 3. everything up:
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
