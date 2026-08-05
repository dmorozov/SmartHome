# 2 — The Hub stack

Bring `hub/compose.yaml` up on the Appliance: Home Assistant, Mosquitto,
ring-mqtt, go2rtc, with Zigbee2MQTT parked. At the end of this chapter the
broker refuses anonymous clients, four containers are Up, and HA is reachable
on `:8123` — but nothing is onboarded and no device is integrated yet. That is
the next chapter.

Everything here runs **on the Hub host**, from `hub/`. Nothing in this chapter
needs a second machine.

Standing notes for this directory live in [`../../hub/README.md`](../../hub/README.md);
the step-by-step this chapter is distilled from, including the as-built record
of 2026-08-04, is
[`../../docs/plans/device-integrations/phase-1-hub-stack.md`](../../docs/plans/device-integrations/phase-1-hub-stack.md).

## Preconditions

| Precondition | Check |
|---|---|
| Docker Engine + Compose v2 plugin | `docker compose version` |
| The repo checked out on the Hub host, working tree writable by your uid | `ls -ld hub/mosquitto/config` → `1000:1000 0775` on this host |
| The host is Linux, not macOS | ADR-0008. HomeKit pairing and TV discovery need real multicast; Docker-on-macOS does not have it |
| A LAN address you can name | Today `192.168.68.81`, an **unreserved** DHCP lease. The Deco serves no local DNS, so there is no `.local` shortcut — reservations are made by MAC in the Deco app |

**No passwordless sudo exists on the Hub host.** This chapter is written so
that the whole bring-up needs none: the one privileged operation (chowning a
file inside the working tree to uid 1883) goes through a throwaway container
that is root *inside* the bind mount. Where a step genuinely needs `sudo`, it
is called out and it is yours to run.

## 1. What the stack is

| Service | Image (pinned) | Network | Ports | What it is for |
|---|---|---|---|---|
| `homeassistant` | `ghcr.io/home-assistant/home-assistant:2026.7` | **host** | 8123 | The Hub proper: device state, integrations, automations. The Panel is its client (ADR-0002) |
| `mosquitto` | `eclipse-mosquitto:2.1.2-alpine` | bridge, published | 1883 | The MQTT bus: ring-mqtt → HA today, Zigbee2MQTT and ESPHome/ratgdo later |
| `ring-mqtt` | `tsightler/ring-mqtt:5.9.3` | **default bridge** | 55123, 8556→8554 | Ring account bridge. Publishes Ring devices to MQTT, HA picks them up by discovery |
| `go2rtc` | `alexxit/go2rtc:1.9.10` | **host** | 1984, 8554, 8555 | Camera restream layer for the Panel's tap-to-view popups |
| `zigbee2mqtt` | `koenkk/zigbee2mqtt:2` | host | 8080 | **Parked** behind the `zigbee` profile; no coordinator exists yet |

Three network choices are load-bearing, not preference:

- **HA runs host-networked** because HomeKit-controller pairing (Ecobee) and
  Samsung TV discovery need mDNS/multicast, which Docker bridge networking
  breaks. Consequence used throughout the rest of the guide: inside HA,
  `127.0.0.1` *is* the Hub host, so HA reaches the broker's published 1883 at
  localhost.
- **go2rtc runs host-networked** because WebRTC needs dynamic UDP ports and
  correct ICE candidate addresses.
- **ring-mqtt stays on the default bridge** — the one service that does. It
  needs only the broker and the Ring cloud, and its internal RTSP server binds
  8554, which would collide with go2rtc's host-networked 8554. Compose
  republishes it as **8556** on the host. ring-mqtt therefore reaches the
  broker by compose service name: `mqtt://ring:…@mosquitto:1883`.

### Image pinning policy

Every image is pinned **exactly**, and updated deliberately after reading
release notes — never by a floating tag. The Hub is a black-box appliance; a
`compose pull` must not be able to change behaviour under a house.

Two pins deserve their history:

- `eclipse-mosquitto:2.1.2-alpine` replaced a floating `:2` on 2026-08-03.
  `:2` had already moved to the 2.1 line, and 2.1 marks `password_file` and
  `allow_anonymous` — the two directives this whole chapter stands on — for
  removal in 3.0. The tag looks odd on purpose: upstream publishes the 2.1
  line only as `-alpine`, there is no unsuffixed `2.1.2`.
- `koenkk/zigbee2mqtt:2` is the one **major-only** pin left, deliberately: the
  service has never been started, so there is no exact version to record. Pin
  it exactly at first Zigbee bring-up (§7).

Re-measured, contradicting the earlier audit: **2.1.2 does not warn** about
`password_file`/`allow_anonymous`. It loads them through its builtin-security
plugin and logs `Plugin builtin-security has registered to receive 'basic-auth'
events`, with no deprecation line. The migration to `mosquitto_password_file`
is still coming before 3.0; it is just not nagging yet.

Calendar risks that gate the HA pin are in
[`../../hub/README.md`](../../hub/README.md) — read them **before** bumping
past 2026.7 (Samsung TV `turn_on`/WOL in 2026.8; SmartThings API charging from
October 2026).

## 2. Bind sources are pre-created on purpose

Every bind-mount source in `compose.yaml` arrives with the clone. `ha-config/`,
`custom_components/`, `z2m-data/`, `ring-mqtt-data/` and `go2rtc/` all carry a
tracked file; `mosquitto/data/` and `mosquitto/log/` carry an empty `.gitkeep`
for no other reason.

Why it matters: compose sets `CreateMountpoint` on bind mounts, so a missing
source is created by **dockerd, as root, inside your git working tree**. That
is not a bring-up failure — the eclipse-mosquitto entrypoint runs
`chown -R 1883:1883 /mosquitto/data` before exec'ing the broker, and
`/mosquitto/log` is never written at all because `mosquitto.conf` uses
`log_dest stdout`. What the `.gitkeep` buys is that `git clean` and the
"copy this whole directory to the mini PC" migration stop needing `sudo`.

The `.gitignore` uses the `dir/*` + negation form for these
(`mosquitto/data/*` then `!mosquitto/data/.gitkeep`). The directory form would
not have worked: git does not descend into an excluded directory, so the
negation could never match.

**One wrinkle to expect.** That entrypoint `chown -R` also re-owns
`mosquitto/data/.gitkeep` to uid 1883 on the host. `git status` stays clean
(git tracks the mode, not the owner), but deleting that file later needs
`sudo` — which this host does not hand out without a password prompt. Measured
after 8 hours of uptime: `mosquitto/data` is `1883:1883`, `mosquitto/log`
stays `1000:1000`. Neither is root-owned, which was the point.

## 3. Mosquitto auth bootstrap

**This is the single most error-prone step in the system.** Read the whole
section before typing anything. The failure mode is a restart loop, and the
tool you are using tells you to do exactly the wrong thing.

`mosquitto.conf` sets:

```
allow_anonymous false
password_file /mosquitto/config/passwd
```

Authenticated from day one (decision D4): port 1883 is published to the LAN, so
anonymous was never acceptable, laptop or not. Two consequences fall out
immediately:

1. **The broker refuses to start if `password_file` names a missing file.** The
   file must exist before first start. Empty is fine — empty plus
   no-anonymous means nobody connects until users are added.
2. **The broker opens that file after dropping privileges** to uid 1883. So
   ownership, not just mode, decides whether it starts.

### 3a. The ownership table

`1883` is the eclipse-mosquitto image's `mosquitto` uid (verified:
`id mosquitto` → `uid=1883(mosquitto) gid=1883(mosquitto)`). All three
combinations were run against the live 2.1.2 broker:

| `passwd` owner:group, mode | Broker startup log | Works? |
|---|---|---|
| `root:root 0600` | `Error: Unable to open pwfile` | ❌ **restart loop** |
| `root:1883 0640` | `Warning: File … owner is not mosquitto. Future versions will refuse to load this file.` | ⚠️ works today, refuses later |
| **`1883:1883 0600`** | *no warning at all* | ✅ **use this** |

### 3b. The trap

During bootstrap, `mosquitto_passwd` prints:

```
File … owner is not root. Future versions will refuse to load this file.
To fix this, use `chown root /mosquitto/config/passwd`
```

**Do not follow that advice.** It gives you row 1 of the table — an unreadable
file and a restart loop. 2.1.2's ownership check compares the file's owner to
*whoever is running*, and `mosquitto_passwd` runs as **root** while the broker
runs as **mosquitto**. Only the broker's warning gates loading, and the broker
wants owner `mosquitto`. The broker says so itself, one line before it opens
the file: `Info: running mosquitto as user: mosquitto.`

Corollary: `mosquitto_passwd` rewrites the file with `mkstemp`+`rename` and
does not preserve ownership, and `docker exec` runs as root (the image sets no
`USER`). So **the file is root:root after every `mosquitto_passwd` run** and
must be chowned back each time. The chown after the three users below is not
belt-and-braces; without it the restart on the last line dies.

And no, you cannot dodge this by running `mosquitto_passwd` as uid 1883: the
`mkstemp`+`rename` needs write permission on the *directory*, and
`mosquitto/config` is the host checkout's `1000:1000 0775`. Root is the only
uid that can do it across that bind mount.

### 3c. The sequence

Passwords are yours to choose. Generate them **URL-safe** — the `ring` one
rides inside a URL in `ring-mqtt-data/config.json`, where a `@` or `:` will
silently break parsing.

From `hub/`:

```sh
touch mosquitto/config/passwd

# The chown helper. There is no passwordless sudo on this host, so it runs
# root INSIDE a throwaway container, writing across the bind mount.
chown_pw() { docker run --rm -v "$PWD/mosquitto/config:/c" --entrypoint sh \
    eclipse-mosquitto:2.1.2-alpine -c 'chown 1883:1883 /c/passwd && chmod 600 /c/passwd'; }

chown_pw
docker compose up -d mosquitto

docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd ha   '<ha-password>'
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd ring '<ring-password>'
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd z2m  '<z2m-password>'

# MANDATORY, not optional — see 3b. The file is root:root 0600 by here.
chown_pw

# mosquitto_passwd 2.1 leaves `<file>.backup.XXXXXX` next to the file it edits:
# same hashes, same secrecy. `passwd` alone does not match it in .gitignore,
# which is why `passwd.backup.*` is listed there too. Remove them anyway.
rm -f mosquitto/config/passwd.backup.*

docker compose restart mosquitto
```

Three users, one per client, no sharing:

| User | Used by | Where the matching secret goes |
|---|---|---|
| `ha` | Home Assistant's MQTT integration | HA's `.storage` (entered in the UI, next chapter) |
| `ring` | ring-mqtt | `ring-mqtt-data/config.json`, inside `mqtt_url` |
| `z2m` | Zigbee2MQTT (later) | `z2m-data/configuration.yaml`, when Zigbee arrives |

Verify the broker came up clean — the target is **no warning at all**:

```sh
docker compose logs mosquitto | head -20
```

Expected, measured on this host:

```
mosquitto version 2.1.2 starting
Config loaded from /mosquitto/config/mosquitto.conf.
Info: running mosquitto as user: mosquitto.
Plugin builtin-security has registered to receive 'basic-auth' events.
Opening ipv4 listen socket on port 1883.
mosquitto version 2.1.2 running
```

> The bootstrap comment block inside
> [`../../hub/mosquitto/config/mosquitto.conf`](../../hub/mosquitto/config/mosquitto.conf)
> spells the same sequence with `sudo chown`. That form is correct in
> principle and unusable on this host, which has no passwordless sudo. The
> `chown_pw` container form above is the one that works here; the two produce
> an identical result.

## 4. Tracked example → live config

Three services take a config file that must never be committable, so the repo
tracks an `*.example.*` starter and the live file is gitignored. Copying is a
bring-up step, not an optional polish step: **ring-mqtt v5.x refuses to start
without `config.json`.**

| Copy from | To (gitignored) | Why it can never be committed |
|---|---|---|
| `ring-mqtt-data/config.example.json` | `ring-mqtt-data/config.json` | Embeds the `ring` broker password in `mqtt_url`. The whole directory later accumulates the Ring **refresh token** |
| `go2rtc/go2rtc.example.yaml` | `go2rtc/go2rtc.yaml` | Stream URLs embed camera credentials (RTSP user:pass) |
| `z2m-data/configuration.example.yaml` | `z2m-data/configuration.yaml` | Z2M **rewrites this file at runtime** and injects the generated Zigbee network key and pan_id on first start |

```sh
cp ring-mqtt-data/config.example.json ring-mqtt-data/config.json
chmod 600 ring-mqtt-data/config.json
# then edit: put the `ring` password into mqtt_url, and drop the "_comment" key
cp go2rtc/go2rtc.example.yaml go2rtc/go2rtc.yaml
```

`ring-mqtt-data/config.json` ends as:

```json
"mqtt_url": "mqtt://ring:<ring-password>@mosquitto:1883",
```

`mosquitto` there is the **compose service name**, resolved on the default
bridge network — this is the one service that is not host-networked, so
`127.0.0.1` would be wrong.

`go2rtc.yaml` stays byte-identical to the example for now: no streams until
cameras exist. Copy it anyway, so the live/example split is established before
anyone is editing under pressure.

Skip the Z2M copy entirely until the coordinator exists (§7).

Confirm every live file is actually ignored before you go further:

```sh
git check-ignore -v hub/go2rtc/go2rtc.yaml hub/ring-mqtt-data/config.json \
                    hub/mosquitto/config/passwd hub/token
```

Every line must print a rule. Silence on any path means that file is
committable — stop and fix `.gitignore` first.

### Optional: `TZ`

`ring-mqtt` reads `TZ: ${TZ:-UTC}`. Measured today: `TZ` is unset in the
operator's environment and there is no `hub/.env`, so ring-mqtt timestamps its
log in UTC (`2026-08-04T07:16:38.879Z`) while the host runs
`America/Los_Angeles`. Harmless, and worth fixing before anyone debugs Ring
event timing. Compose auto-loads `hub/.env`, and `hub/.gitignore` matches
`*.env`, so a one-line `TZ=America/Los_Angeles` there is safe.

## 5. Bring the stack up

```sh
cd hub
docker compose up -d
docker compose ps
```

Compose starts `mosquitto` before `ring-mqtt` (`depends_on`); HA tolerates the
broker appearing after it, because the MQTT integration reconnects. Expect
**four** services and no `zigbee2mqtt`:

```
go2rtc          alexxit/go2rtc:1.9.10                          Up
homeassistant   ghcr.io/home-assistant/home-assistant:2026.7   Up
mosquitto       eclipse-mosquitto:2.1.2-alpine                 Up   0.0.0.0:1883->1883/tcp
ring-mqtt       tsightler/ring-mqtt:5.9.3                      Up   0.0.0.0:55123->55123/tcp, 0.0.0.0:8556->8554/tcp
```

The HA image tag is a **minor** pin: `2026.7` currently resolves to 2026.7.4.
That is deliberate — patch releases inside a minor are the ones you want; the
gate is on the minor.

## 6. Done when

Run all four. They are the acceptance criteria for this chapter, and none of
them needs a host package.

**a. Four services Up, none restarting.**

```sh
docker compose ps
```

**b. Anonymous MQTT is refused.** The broker image already ships
`mosquitto_sub`/`mosquitto_pub`, so run them out of a throwaway container
rather than installing `mosquitto-clients` on the host:

```sh
docker run --rm --network host eclipse-mosquitto:2.1.2-alpine \
  mosquitto_sub -h 192.168.68.81 -t '#' -C 1
#  -> Connection error: Connection Refused: not authorised     (exit 5)

docker run --rm --network host eclipse-mosquitto:2.1.2-alpine \
  mosquitto_pub -h 192.168.68.81 -u ha -P '<ha-password>' -t smarthome/selftest -m up
#  -> silent, exit 0
```

Use the host's LAN address, not `localhost` — the point is to prove the
**published** port is authenticated, because that is the surface the LAN sees.
`docker exec mosquitto mosquitto_sub …` is shorter and does traverse the
published port via docker's userland proxy, but it dials from inside the
broker's own container, which is a weaker claim. Installing
`mosquitto-clients` on the host (`resolute/universe` has 2.0.22 — older than
the broker, irrelevant on the wire) is debugging convenience, **not a
prerequisite**, and the container form is what survives the mini PC migration
unchanged.

The broker log should show both attempts, which is the real confirmation:

```
New client connected … (p4, c1, k60, u'ha').
Client … disconnected: not authorised.
```

**c. ring-mqtt is waiting for Ring auth — that is success, not an error.**

```sh
docker compose logs ring-mqtt | tail -5
```

```
State file /data/ring-state.json not found. No saved state data available.
No refresh token was found in the state file, use the Web UI at
  http://<host_ip_address>:55123/ to generate a token.
Successfully started the ring-mqtt web UI
MQTT URL: mqtt://ring:********@mosquitto:1883
```

The last line proves `config.json` parsed and the credential was picked up.
Ring login and 2FA belong to a later chapter; do not do it here.

**d. Both web surfaces answer.**

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.68.81:8123   # 302 (onboarding redirect)
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.68.81:1984   # 200 (go2rtc UI)
```

A `302` from `:8123` is exactly right at this point — it means HA is up and
un-onboarded.

## 7. Zigbee, when the coordinator arrives

`zigbee2mqtt` carries `profiles: ["zigbee"]`, so `docker compose up -d` skips
it. Without a coordinator the service just crash-loops, and a crash-looping
service in `docker compose ps` trains you to ignore red — that is the whole
reason it is parked.

Prerequisite: an **SMLIGHT SLZB-06 in Ethernet mode**, on the LAN, with a DHCP
reservation. Not WiFi — Zigbee2MQTT's own guidance is that serial-over-WiFi is
failure-prone. No USB device mapping appears in the compose file on purpose:
the radio stays central in the house and survives the laptop → mini PC move
untouched (ADR-0003).

```sh
cp z2m-data/configuration.example.yaml z2m-data/configuration.yaml
# edit: replace SLZB-06-IP-OR-HOSTNAME (port 6638 is the SLZB-06 factory
# default), and set the `z2m` broker password in the mqtt server URL
docker compose --profile zigbee up -d
docker compose logs zigbee2mqtt | head        # read the exact version
# then pin that exact tag in compose.yaml, replacing `2`, and commit
```

Z2M is host-networked, so its config's `mqtt://localhost:1883` reaches the
broker's published port and the frontend lands on `<hub-ip>:8080` with no
mapping. Pairing devices from that frontend is a later chapter.

## 8. Secrets inventory

Nothing in the table below is in git, and every path is covered by a rule in
[`../../hub/.gitignore`](../../hub/.gitignore) (verified with `git check-ignore`).

| Path | Holds | Ignored by | Mode / owner |
|---|---|---|---|
| `hub/mosquitto/config/passwd` | The three broker credentials, **hashed** | `passwd` | `1883:1883 0600` — see §3, this one is load-bearing |
| `hub/mosquitto/config/passwd.backup.*` | Same hashes, left behind by `mosquitto_passwd` | `passwd.backup.*` | Delete them |
| `hub/.broker-passwords.env` | The three broker passwords in **cleartext**: `MOSQUITTO_HA_PASSWORD`, `MOSQUITTO_RING_PASSWORD`, `MOSQUITTO_Z2M_PASSWORD` | `*.env` | `0600`. **Move these into your password store and delete it** — nothing reads it at runtime; steps in [§8a](#8a-retiring-broker-passwordsenv-owner-task-g3) |
| `hub/ring-mqtt-data/config.json` | The `ring` password, in cleartext, inside `mqtt_url` | `ring-mqtt-data/*` | `0600` |
| `hub/ring-mqtt-data/ring-state.json` | The Ring **refresh token** (does not exist until Ring auth) | `ring-mqtt-data/*` | written by the container |
| `hub/ha-config/.storage/` | HA auth store, user credentials, and **every integration's saved credentials/tokens** | `ha-config/*` | `root:root`, written by the container |
| `hub/token` | The Panel's long-lived HA access token (10-year validity) | `token` | `0600` |
| `hub/go2rtc/go2rtc.yaml` | Camera RTSP credentials, once streams exist | `go2rtc/*` | — |
| `hub/z2m-data/configuration.yaml` | The generated Zigbee network key and pan_id, once Z2M runs | `z2m-data/*` | — |

The delivery side on the Appliance is separate and also not in git: the Panel's
token reaches the kiosk as `EnvironmentFile=-/etc/smarthome/panel.env` (0600,
kiosk user), written by a `no_log` Ansible task from `$PANEL_HA_TOKEN` on the
controller. See [`../ansible/README.md`](../ansible/README.md).

### 8a. Retiring `.broker-passwords.env` (owner task **G3**)

This section used to state the requirement and stop, which left the one
question that actually decides whether you can act on it — *does anything break
if I delete it?* — unanswered. Measured 2026-08-04: **no.**

- `hub/compose.yaml` has **no `env_file:`** anywhere, so nothing loads it at
  container start.
- No script, playbook, Python, Dart or Ansible file reads it. `grep -rl
  broker-passwords --include='*.sh' --include='*.yml' --include='*.py'
  --include='*.dart' .` returns nothing; every hit in this repo is prose.
- What the broker actually authenticates against is
  `hub/mosquitto/config/passwd` — **hashes**, `1883:1883 0600`, which your own
  user cannot even read. Three clients were connected while this was verified.

The file is therefore a note-to-self in cleartext, not a runtime dependency.

**Where each password already lives**, which is what makes deleting it safe:

| Variable | Broker user | Its other home |
|---|---|---|
| `MOSQUITTO_HA_PASSWORD` | `ha` | Saved inside HA's `.storage` when you added the MQTT integration (§3 of [3](03-home-assistant.md)) |
| `MOSQUITTO_RING_PASSWORD` | `ring` | **Also cleartext** in `hub/ring-mqtt-data/config.json`, inside `mqtt_url` — see the caveat below |
| `MOSQUITTO_Z2M_PASSWORD` | `z2m` | Nowhere. Z2M is parked until the SLZB-06 exists (owner item **D2**), so this one is unused today |

**The steps.** Run them in your own shell — the values must not travel through
a transcript, an agent session or a paste buffer:

```bash
# 1. Read them.
cat ~/Work/SmartHome/hub/.broker-passwords.env

# 2. Put all three in your password manager. Suggested entry names, so that
#    future-you searching for "mosquitto" finds them:
#      SmartHome / Mosquitto — ha
#      SmartHome / Mosquitto — ring
#      SmartHome / Mosquitto — z2m
#    Note on each: broker at <hub-ip>:1883, host-networked;
#    hashes in hub/mosquitto/config/passwd.

# 3. Read one BACK out of the manager and compare it to the file.
#    Do not skip this. It is the only step that catches a botched paste
#    while the original still exists.

# 4. Delete the file.
shred -u ~/Work/SmartHome/hub/.broker-passwords.env

# 5. Prove nothing broke. No restart is needed; existing sessions are unaffected
#    because the broker never read this file. You want no new auth failures.
cd ~/Work/SmartHome/hub && docker logs mosquitto --tail 20 && docker logs ring-mqtt --tail 10
```

**This does not de-cleartext the Hub, and saying so is the point.** The `ring`
password stays in `hub/ring-mqtt-data/config.json` as
`mqtt://ring:<password>@mosquitto:1883` — 0600 and gitignored, but readable by
anyone who can read that file. ring-mqtt has no secrets-file option, so there
is no cheap fix and it is not part of G3. Know about it rather than believe
this task removed it.

**Losing these is a reset, not a cliff.** A hash is one-way, so a forgotten
password cannot be recovered — but it can be *replaced*: `mosquitto_passwd` the
user, then update that user's one consumer. Minutes. Contrast the re-pairing
cliff below, where losing `.storage` means walking to the thermostat. That
asymmetry is why **E7** (back up `.storage`) outranks this item even though
this one looks more like a security task.

### The re-pairing cliff

Two directories are irreplaceable state, not caches:

| If you lose | You must redo |
|---|---|
| `hub/ha-config/.storage/` | Every integration's credentials and its whole entity/device registry — including **entity IDs**, which the Panel's `bindings.yaml` names directly. The Ecobee's HomeKit pairing key lives here, so losing `.storage` means a **physical re-pair at the thermostat's touchscreen** — someone has to walk to the device and read a code off it |
| `hub/ring-mqtt-data/` | Ring login **plus 2FA**, from the container's web UI |

> An earlier draft of this table said the Ecobee "has exactly one free HomeKit
> pairing slot". **Do not restore that.** It was a misreading of the `sf` flag
> in the accessory's mDNS advert, which is a boolean *status* flag — set means
> "not paired with any controller", clear means "paired" — and carries no slot
> count at all. The measurement and what it actually licenses you to say are in
> [`04-devices-local.md` §4.2.2](04-devices-local.md). What is true, and all
> that this row needs, is that re-pairing is a trip to the thermostat.

`mosquitto/config/passwd` is cheap by comparison — regenerate it with §3 and
re-enter three passwords. `mosquitto/data/mosquitto.db` is retained messages
only; losing it costs nothing but a re-publish.

**No phase in `docs/plans/device-integrations/` has a backup step — not phase
0 through 6.** Measured on this host today: HA's Backup integration entry
exists (it is a `default_config` system entry), `/config/backups` does not
exist, and no backup has ever been written. The migration story in
`hub/README.md` — "copy this entire directory to the mini PC" — is a *move*,
not a backup: it produces one copy, and it is the same copy.

Until someone designs that step, the honest mitigation is a manual one, and it
is worth doing before the next chapter starts creating pairings:

```sh
cd hub
docker compose stop homeassistant ring-mqtt
tar czf ~/hub-state-$(date +%F).tgz -C "$PWD" \
    ha-config/.storage ring-mqtt-data mosquitto/config/passwd
docker compose start homeassistant ring-mqtt
```

That tarball contains cleartext credentials and the Ring refresh token. Treat
it as a secret, and keep it out of the repo directory. Note it reads
root-owned files under `.storage`, so it needs `sudo` on this host — which you
run yourself.

## 9. Known gaps and traps in this stack

| # | Fact | Status |
|---|---|---|
| 1 | HA's `bluetooth` config entry sits in `setup_retry`: *"DBus service not found; docker config may be missing `-v /run/dbus:/run/dbus:ro`"*. This is a real gap in `compose.yaml`, not a false alarm | **Open.** The fix is that volume plus an HA restart; it has not been applied or tested here, so treat the fix as **UNVERIFIED** |
| 2 | `go2rtc.example.yaml`'s commented Ring line says `rtsp://127.0.0.1:8554/RING-CAMERA-ID_live`. On this stack that port is **go2rtc's own** RTSP server | **The example is wrong.** ring-mqtt's RTSP is published on **8556** (`8556:8554`), which is what the `compose.yaml` comment says. Use 8556 when cameras arrive |
| 3 | HA 2026.7 creates its own system `go2rtc` config entry, separate from the `go2rtc` container in this stack | Measured: nothing extra is listening (`1984`, `8554`, `8555` all belong to the container). Any deeper interaction between HA's bundled go2rtc and ours is **UNVERIFIED** |
| 4 | `mosquitto/log/` is a bind mount that is never written | Correct as designed: `mosquitto.conf` uses `log_dest stdout`, so `docker compose logs mosquitto` is the only log. Do not go looking in the directory |
| 5 | `hub/dev/` also defines mosquitto / ring-mqtt / go2rtc services | Not this stack. `dev/` is the workstation sandbox with a generated stand-in fleet (ADR-0008) and is redundant with the real stack now; trimming it is nobody's current task. Do not bring both up on the same host |

## Next

The stack is up and authenticated; HA is un-onboarded. The next chapter creates
the admin account, mints the Panel's long-lived token into `hub/token`, and
adds the MQTT integration pointing at `127.0.0.1:1883` as user `ha` — localhost
being correct precisely because HA is host-networked.
