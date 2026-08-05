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
# 1883:1883 0600, confirmed correct against 2.1.2 — see "Ownership" below.
# There is no passwordless sudo on the Hub host, so the chown goes through a
# throwaway container (root inside, writing across the bind mount):
chown_pw() { docker run --rm -v "$PWD/mosquitto/config:/c" --entrypoint sh \
    eclipse-mosquitto:2.1.2-alpine -c 'chown 1883:1883 /c/passwd && chmod 600 /c/passwd'; }
chown_pw
docker compose up -d mosquitto
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd ha    '<ha-password>'
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd ring  '<ring-password>'
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd z2m   '<z2m-password>'   # for later
# REDO the chown — this is not belt-and-braces. mosquitto_passwd rewrites the
# file with mkstemp+rename and does not preserve ownership, and `docker exec`
# runs as root (the image sets no USER), so the file is root:root 0600 again by
# here. mosquitto drops to uid 1883 BEFORE it loads the password file, so
# without this the restart below dies on `Error: Unable to open pwfile`.
chown_pw
rm -f mosquitto/config/passwd.backup.*   # hashed backups mosquitto_passwd leaves
docker compose restart mosquitto
```

### Ownership — `1883:1883 0600` confirmed against 2.1.2

`1883` is the eclipse-mosquitto container's `mosquitto` uid. All three
combinations were run against the live broker on 2.1.2:

| passwd owner:group, mode | Broker startup log | Works? |
|---|---|---|
| `root:root 0600` | `Error: Unable to open pwfile` | ❌ **restart loop** |
| `root:1883 0640` | `Warning: File … owner is not mosquitto. Future versions will refuse to load this file.` | ⚠️ works today, refuses later |
| **`1883:1883 0600`** | *no warning at all* | ✅ **use this** |

**The trap worth knowing about**, because it points the wrong way: 2.1.2's
ownership check compares the file's owner to *whoever is running*, and
`mosquitto_passwd` runs as **root** while the broker runs as **mosquitto**.
So during bootstrap `mosquitto_passwd` prints

    File … owner is not root. Future versions will refuse to load this file.
    To fix this, use `chown root /mosquitto/config/passwd`

Following that advice literally gives you row 1 — an unreadable file and a
restart loop, because the broker logs `running mosquitto as user: mosquitto`
and opens the password file *after* dropping privileges. The only warning
that gates loading is the **broker's**, and it wants owner `mosquitto`. Ignore
the tool's version; chown back to `1883:1883` after every `mosquitto_passwd`
run, which is what the `chown_pw` call after the three users is for.

`mosquitto_passwd` cannot simply be run as uid 1883 to avoid this: it rewrites
via `mkstemp`+`rename`, needing write on the *directory*, and
`mosquitto/config` is the host checkout's `1000:1000 0775`. Root is the only
uid that can do it across that bind mount.

**Deprecation status, re-measured**: the audit expected mosquitto 2.1 to warn
about `password_file`/`allow_anonymous`. It does not, at 2.1.2 — the broker
loads them through its `builtin-security` plugin and logs
`Plugin builtin-security has registered to receive 'basic-auth' events` with
no deprecation line. The migration to `mosquitto_password_file` is still
coming before 3.0; it is just not nagging yet.

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

### 1e. Track the two Mosquitto runtime directories (phase-0 open item 4)

`hub/mosquitto/data/` and `hub/mosquitto/log/` are bind-mount sources in
`compose.yaml`, but nothing inside them was tracked, so a fresh clone did
not have them. They were the **only** missing bind source in the file —
`ha-config/`, `custom_components/`, `z2m-data/`, `ring-mqtt-data/` and
`go2rtc/` all arrive with a tracked file inside.

Fixed by committing an empty `.gitkeep` in each, which forced `hub/.gitignore`
from the directory form (`mosquitto/data/`) to the `dir/*` + negation form the
rest of that file already uses: git does not descend into an excluded
directory, so `!mosquitto/data/.gitkeep` underneath `mosquitto/data/` could
never have matched.

**This was hygiene, not a bring-up blocker** — worth writing down so nobody
re-litigates it. Compose sets `CreateMountpoint` on bind mounts, so `dockerd`
(root) creates a missing source as `root:root 0755`; but the
`eclipse-mosquitto` image runs as root and its entrypoint does
`chown -R 1883:1883 /mosquitto/data` before exec'ing the broker, so
persistence works either way, and `/mosquitto/log` is never written at all
because `mosquitto.conf` uses `log_dest stdout`. What the `.gitkeep` buys is
that `docker compose up` stops minting root-owned paths inside a git working
tree — so `git clean`, and the README's "copy this entire directory to the
mini PC", stop needing `sudo`.

One wrinkle to expect: that entrypoint `chown -R` also re-owns
`mosquitto/data/.gitkeep` to uid 1883 on the host. `git status` stays clean
(git tracks the mode, not the owner), but removing the file later needs `sudo`.

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

`-d chrome` is a **web** build, and web has no process environment — so the
dart-defines above are the only route here. On a native target the same
settings resolve from the environment first, which is what makes an
unreserved lease (phase 0 as-built) cheap to correct:

```sh
HUB=ha HA_URL=http://<hub-ip>:8123 HA_TOKEN="$(cat ../hub/token)" \
  flutter run -d linux        # or -d macos
```

Either way, confirm which origin won in the console — `env=unavailable` is
how a web run tells you an `HA_URL=…` prefix was discarded:
`[panel] I hub.config HUB=build HA_URL=build HA_TOKEN=build GO2RTC_URL=absent env=unavailable`.

`GO2RTC_URL` joined that line in phase 4's Panel work and resolves the same
way. It stays `absent` here: this phase brings go2rtc *up*, it does not put a
stream in it, and pointing the Panel at an empty go2rtc would buy nothing.

## Done when

- `docker compose ps`: 4 services Up, none restarting; `docker compose
  logs ring-mqtt` shows it waiting for Ring auth (that's phase 3, not an
  error) and connected to MQTT with the `ring` user.
- Anonymous MQTT is refused. **No host package is needed for this** — the
  broker image already ships `/usr/bin/mosquitto_sub` and `mosquitto_pub`, so
  run one out of a throwaway container rather than installing
  `mosquitto-clients`:

  ```sh
  docker run --rm --network host eclipse-mosquitto:2 \
    mosquitto_sub -h <hub-ip> -t '#' -C 1
  #  -> Connection error: Connection Refused: not authorised.   (non-zero exit)

  docker run --rm --network host eclipse-mosquitto:2 \
    mosquitto_pub -h <hub-ip> -u ha -P '<ha-password>' -t smarthome/selftest -m up
  #  -> silent, exit 0
  ```

  This is the form that survives the mini PC migration unchanged.
  `docker exec mosquitto mosquitto_sub -h <hub-ip> …` is shorter and does also
  traverse the published port (docker's userland proxy handles the hairpin),
  but it dials from inside the broker's own container, which is a weaker
  claim. Installing `mosquitto-clients` on the Hub host
  (`resolute/universe`, 2.0.22 — older than the 2.1.x broker, which is
  irrelevant on the wire) or `brew install mosquitto` on the Mac is
  convenience for later debugging, **not a prerequisite for this phase**.
- The Panel console shows `hub.connected url=ws://<hub-ip>:8123` and a
  `hub.snapshot` line. `hub.missing_entities` will list ~everything —
  correct: the laptop Hub has no stand-in fleet and no real devices yet.
  Phases 2–5 drain that list; this phase only proves the wiring.
- `PANEL_LIVE_HUB=1 HA_URL=http://<hub-ip>:8123 HA_TOKEN="$(cat ../hub/token)"
  flutter test test/ha_hub_live_test.dart` passes. (`flutter test` is a VM
  target, so it honours the environment; `PANEL_LIVE_HUB` is the deliberate
  opt-in that keeps a plain `flutter test` from ever dialling a real house.)

## As built — 2026-08-04 (§2 up to the browser step)

Run on the laptop Hub host, `<hub-ip>` = 192.168.68.81.

| Step | Result |
|---|---|
| Broker auth (§1c) | ✅ `passwd` created and bootstrapped with `ha`, `ring`, `z2m`, ownership `1883:1883 0600` — the plan's original value, **re-confirmed the hard way** after `mosquitto_passwd`'s "chown root" warning sent the first attempt into a restart loop (see the ownership table above). Broker starts with no warnings. Passwords generated URL-safe (they ride in ring-mqtt's `mqtt_url`) and written to `hub/.broker-passwords.env`, mode 0600, gitignored by `*.env`. **Move them into your password store — that file exists only to make this bring-up reproducible.** |
| Live configs | ✅ `go2rtc/go2rtc.yaml` from the example (unchanged, no streams until phase 3/4); `ring-mqtt-data/config.json` from the example with the `ring` password substituted and `_comment` dropped, mode 0600. Both gitignored, verified with `git check-ignore`. |
| Bind sources | ✅ The `.gitkeep` fix works as designed: after first start `mosquitto/data` is `1883:1883` (image entrypoint chown) and `mosquitto/log` stays `1000:1000`. **Neither is root-owned** — which is the whole point of pre-creating them. |
| `docker compose up -d` | ✅ 4 services Up, none restarting: `homeassistant` 2026.7, `mosquitto` 2.1.2-alpine, `ring-mqtt` 5.9.3, `go2rtc` 1.9.10. `zigbee2mqtt` absent, as the `zigbee` profile intends. |
| Done-when: anonymous refused | ✅ `mosquitto_sub -h <hub-ip> -t '#'` → `Connection error: Connection Refused: not authorised`, exit 5. Authed publish as `ha` → exit 0. Both run via `docker run --rm --network host eclipse-mosquitto:2.1.2-alpine`, with `mosquitto-clients` **still not installed on the host** — which is what makes the check portable to the mini PC. |
| Done-when: ring-mqtt | ✅ Exactly the expected not-an-error state: `No refresh token was found in the state file, use the Web UI at http://<host_ip>:55123/ to generate a token` + `MQTT URL: mqtt://ring:********@mosquitto:1883`. Ring auth is phase 3. |
| Reachability | ✅ `http://<hub-ip>:8123` → HTTP 302 (onboarding redirect); `http://<hub-ip>:1984` (go2rtc) → HTTP 200. |

### Still to do — this is the browser step, and it is yours

1. **HA onboarding** at `http://192.168.68.81:8123` — create the admin account.
   This is the Hub that migrates to the mini PC; name it accordingly.
2. **Long-lived token** → profile → Security → create → save to `hub/token`
   (gitignored). Nothing automated reads it yet; the appliance path
   (`PANEL_HA_TOKEN` → `/etc/smarthome/panel.env`) is wired but unused while
   `kiosk_app` still points at the spike app.
3. **MQTT integration** — Settings → Devices & Services → Add → MQTT: broker
   `127.0.0.1`, port `1883`, user `ha`, password from
   `hub/.broker-passwords.env`. HA is host-networked, so localhost *is* the
   laptop and Mosquitto's published 1883 is on it.
4. Then §3 — point the Panel at the real Hub and confirm `hub.connected` +
   `hub.snapshot`. `hub.missing_entities` listing ~everything is **correct**
   here: phases 2–5 drain that list, this phase only proves the wiring.

## Note: what happens to `hub/dev/`

Nothing is deleted. Its compose keeps working for protocol-sandbox use
(per ADR-0008), and its generated stand-in fleet remains the way to
develop Panel features without the laptop on. The 2026-08-03 additions to
it (mosquitto/ring-mqtt/go2rtc services) are now redundant with the real
stack and MAY be trimmed back in a later cleanup; trimming them is not
part of this plan.
