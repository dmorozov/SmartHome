# Secrets our own stack owns live under ~/.sh_keys, outside the repo

Before this decision, every credential our own code or compose file
controlled the path for was scattered across `hub/`, gitignored file by
file: `hub/mosquitto/config/passwd`, `hub/ring-mqtt-data/{config.json,
ring-state.json}`, `hub/go2rtc/go2rtc.yaml`, `hub/token`,
`hub/.broker-passwords.env`. Gitignoring kept them out of git, but they
still sat inside the working tree — one `tar` of the wrong directory, one
overly broad `grep`, one careless `cp -r` away from leaving the tree they
were meant to be scoped to. That looseness is what produced the G3
incident: an agent inspecting `ring-mqtt-data/config.json` for an
unrelated task printed `MOSQUITTO_RING_PASSWORD` into its own transcript,
because the credential sat inside a URL value a name-keyed redaction
filter never matches. The file itself was never git-exposed — gitignore
worked as designed — but nothing about its location made "an agent will
eventually read this while doing something else" less likely.

**Decision (2026-08-07):** every secret file `hub/compose.yaml` or an
Ansible role in this repo fully controls the bind-mount/read path for
moves to `~/.sh_keys` on the host, outside the repository tree entirely.
Each container mounts its secret from there, onto the *same* in-container
path it always used — `mosquitto.conf`'s `password_file`, every
`docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd …`
command, ring-mqtt's `/data`, go2rtc's `/config/go2rtc.yaml` — none of
that changed. Only the host-side source of each bind mount moved. Layout:

| Path | Was |
|---|---|
| `~/.sh_keys/mosquitto/passwd` | `hub/mosquitto/config/passwd` |
| `~/.sh_keys/ring-mqtt/` (`config.json`, `ring-state.json`) | `hub/ring-mqtt-data/` |
| `~/.sh_keys/go2rtc/go2rtc.yaml` | `hub/go2rtc/go2rtc.yaml` |
| `~/.sh_keys/token` | `hub/token` |
| `~/.sh_keys/broker-passwords.env` | `hub/.broker-passwords.env` |
| `~/.sh_keys/wyze.env` *(future)* | — no file existed yet |

`~/.sh_keys/go2rtc/go2rtc.yaml` sits in its own subdirectory rather than
directly under `~/.sh_keys/`, unlike `token` and `broker-passwords.env`:
bind-mounting a lone *file* onto a container path with no pre-existing
parent directory in the image fails at container-create time (measured
against `alexxit/go2rtc:1.9.10`, which ships no `/config`) — mounting a
*directory* onto `/config` doesn't have that problem, matching the
original `./go2rtc:/config` shape.

Tracked example/starter files (`ring-mqtt-data/config.example.json`,
`go2rtc/go2rtc.example.yaml`) stay in the repo — they're templates, not
secrets. `rm -rf ~/.sh_keys` is the entire "forget every credential this
box holds" mechanism: no wipe script, no per-service teardown. Recovering
from that means what it obviously means — re-typing passwords, re-pairing
Ring's 2FA, re-minting the HA token — the same manual work a factory reset
of any of these services would need regardless of where the file sat.

**Explicit exception: `hub/ha-config/.storage` stays where it is.** Most
of this house's actual account credentials — Ecobee, Rachio, SmartThings,
LG ThinQ, Whisker, Emporia, TP-Link — are not files we point at. Home
Assistant's config-flow UI writes them straight into its own internal
store, mixed in with the entity registry, area assignments, dashboard
config, and the auth store itself. There is no supported way to relocate
one integration's credential out of `.storage` independently; the only
movable unit is the whole directory, and deleting or relocating *that*
carelessly would reset all of Home Assistant, not just its secrets. It
already has its own backup/restore procedure (the `.storage`-plus-
`ring-mqtt-data`-plus-`mosquitto/passwd` tar recipe in
`appliance/commissioning/02-hub-stack.md`, behind TODO item E7). Resetting
an HA-internal credential means removing that integration in HA's UI and
re-authenticating — not a folder delete under `~/.sh_keys`.

`hub/z2m-data/configuration.yaml` (the Zigbee network key Z2M generates on
first start) isn't created yet — no coordinator is on the LAN. Whether it
joins `~/.sh_keys` is an open question for whenever that lands; it has the
same profile as ring-mqtt's runtime state (container-written, not
authored), so the likely answer is yes, but there's nothing to move today.

**Consequences:** `hub/compose.yaml`'s three bind-mounted services
(mosquitto, ring-mqtt, go2rtc) read `${SH_KEYS_DIR}` at `docker compose`
invocation time, defined in `hub/.env` (gitignored — host-specific,
matching `*.env`). **Not `${HOME}`:** the first attempt at this used
`${HOME}/.sh_keys` directly and broke both mosquitto and go2rtc, because
`docker compose` running inside this repo's devcontainer resolves
`${HOME}` against the *devcontainer's own* filesystem (`/home/vscode`),
while the bind mount itself is created by the **host's** dockerd
(docker-outside-of-docker shares the socket, not the filesystem) — a
source path that doesn't exist on the host's own disk gets silently
auto-created as an empty directory rather than erroring, which is worse
than a clean failure: mosquitto and go2rtc both came up "successfully"
with empty credentials. `hub/.env` pins the literal host path
(`/home/dmorozov/.sh_keys` today) so the value is correct regardless of
which shell invokes `docker compose`.

**This exposed a second, pre-existing hazard, not new to ADR-0010:**
*every* relative path in `hub/compose.yaml` (`./ha-config`, `./mosquitto/config`,
etc.) resolves against the invoking shell's own working directory, and
`/workspaces/SmartHome` (this devcontainer's view of the repo) turned out
to have its own stray, unrelated directory on the real host — not a
symlink or bind mount to `/home/dmorozov/Work/SmartHome`, a completely
separate, mostly-empty path that happened to exist. Running `docker
compose up`/`--force-recreate` for a production service from inside the
devcontainer therefore silently re-points ALL of that service's relative
mounts at the wrong, empty location — not just the ones this ADR touched.
A plain `docker compose restart` is unaffected (it reuses an already-running
container's already-resolved mounts), which is why TODO item G7's `docker
compose restart homeassistant` remains safe as written. Recreating a
service from inside the devcontainer is not: use
`--project-directory /home/dmorozov/Work/SmartHome/hub --env-file
/workspaces/SmartHome/hub/.env` (or run it from the host's own terminal,
which has no such ambiguity) any time a production service needs
recreating, not just restarting.

The appliance's
`/etc/smarthome/panel.env` (delivered by the `kiosk` Ansible role)
deliberately stays where it is rather than also moving under
`~/.sh_keys`: it's owned by `kiosk_user`, a locked-down `nologin` system
account distinct from whoever runs `ansible-playbook`, and `/etc/smarthome/`
is already a dedicated, correctly-permissioned location for it — moving it
under an interactive operator's home directory would only relocate a
*deployed copy* of the token, not the credential's source of truth, while
raising the question of which account should be able to read it. Its
source value is `~/.sh_keys/token`, same as everywhere else. Reopen this
ADR's file layout if a secret this repo doesn't yet manage turns out not
to fit the "flat file our own compose/Ansible owns the path for" shape —
that's the test for whether something belongs under `~/.sh_keys` at all.
