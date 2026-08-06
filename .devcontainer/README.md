# Developing SmartHome: the devcontainer

The development environment for this repo — the *only* documented one
([ADR-0009](../docs/adr/0009-development-in-the-devcontainer-on-the-target-os.md)).
One pinned toolchain (Flutter 3.44.8, web + Linux desktop targets, Chrome,
mosquitto clients, ffmpeg, jq) on **Ubuntu 24.04 — the mini-PC target OS,
deliberately not the 26.04 the interim Hub host runs** — plus the dev Hub
stack (`hub/dev/compose.yaml`: HA, Mosquitto, ring-mqtt, go2rtc) brought
up automatically as sibling containers. The five files here are heavily
commented on purpose: **the two hook scripts ARE the setup
documentation** — `initialize.sh` (host-side, pre-up: seeding, the
one-driver guard) and `post-create.sh` (in-container: verification, the
manual credential steps, the daily commands). This page holds what the
scripts cannot: how to get in, what "working" looks like, and what to do
when it isn't.

## Opening it

Prerequisites on the host: VS Code with the Dev Containers extension, and
Docker usable **without sudo** (user in the `docker` group — the hooks
never escalate). Then: open the repo folder → **"Reopen in Container"**.
First open builds the image (minutes); every later open is fast.
`initialize.sh` refuses to adopt a dev-Hub stack that was started by hand
— `docker compose down` in `hub/dev/` first, once. Closing the VS Code
window **stops the dev Hub too** (`shutdownAction: stopCompose`);
state survives in the bind mounts under `hub/dev/`.

## The addressing rule

Container-side ports are canonical; only the HOST side is shifted (the
production Hub owns the canonical host ports — full table and rationale
in `hub/dev/compose.yaml`'s header). So:

| Who is dialling | Use | Example |
|---|---|---|
| Your **browser** (runs on the host) | `localhost` + **shifted** port | HA `http://localhost:18123`, go2rtc `:11984`, ring-mqtt `:65123` |
| Anything **in this container** | service name + **canonical** port | `http://homeassistant:8123`, `mosquitto:1883`, `go2rtc:1984` |

On the host, canonical port = the real house, shifted port = this
sandbox. A tab on `:8123` can never quietly be the dev Hub.

Never run `docker compose` from in here — relative bind paths would
resolve against the container's `/workspaces`, not the host
(`.devcontainer/compose.yaml` header). Use container names instead:
`docker restart homeassistant-dev`, `docker logs -f go2rtc-dev`.

## One-time manual steps

They create credentials, so no script does them; `post-create.sh` prints
the current set (HA onboarding at `:18123` → long-lived token →
`hub/dev/token` → MQTT integration → optionally Ring). Done once per
`hub/dev/ha-config` lifetime — all four were completed 2026-08-06.

## What "working" looks like

Baseline (established 2026-08-06): **`cd panel && flutter test` → 398
pass / 1 skip / 0 failures.** The goldens are **baked in this container
and canonical here** (phase-0 item 13 closed by that bake): green
in-container, expected red on hosts with a different font stack — that
is the host's problem, not the goldens'; never re-bake outside the
image. The full verification battery (all rows exercised 2026-08-06;
rows 5 and 8's *eyes-on* halves — the green badge, a window on a
display — are the only parts a terminal cannot confirm):

| # | Check | Expect |
|---|-------|--------|
| 1 | `flutter --version` | 3.44.8, from `/opt/flutter` |
| 2 | `cd panel && flutter test` | 398 / 1 / 0 |
| 3 | `curl -s http://homeassistant:8123` | HTML back (service-name DNS) |
| 4 | the live test (command printed by post-create) | connects + auths + snapshots; **currently fails later at the thermostat cast** — that is the dev-Hub parity drift (below), not a container bug. Failing to connect/auth IS a container bug |
| 5 | `flutter run -d web-server --web-port 8080` + dart-defines post-create prints | Panel in the HOST browser at `localhost:8080`, HUB badge green |
| 6 | `docker ps` in-container | the four `*-dev` siblings |
| 7 | `ls -ld ~/.pub-cache` | owned by `vscode` |
| 8 | `flutter build linux --release` | bundle builds; its glibc ceiling (measured `GLIBC_2.34`) runs on the 24.04 mini PC and the 26.04 interim host both |
| 9 | close the window, `docker ps` on host | four dev containers stopped |
| 10 | reopen | fast path; the guard recognises its own stack by the `config_files` label |

## When it isn't — triage

| Symptom | Likely cause | Fix direction |
|---------|--------------|---------------|
| `Address already in use` on 8080 | an earlier `flutter run` still alive (often an agent session's background run) | `ss -tlnp \| grep 8080`, stop that pid — never a missing dependency |
| initialize.sh refuses on reopen | the guard no longer recognises the running stack | `docker inspect homeassistant-dev --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}'` must list `.devcontainer/compose.yaml`; adjust the `case` pattern |
| Port collision on a shifted port (18123/11883/11984/65123/28554/28555) | something new claimed it on the host | `ss -tlnp \| grep <port>`; pick another, update `hub/dev/compose.yaml`'s table + both READMEs + post-create.sh |
| `pub get` fails on cache permissions | pub-cache volume owned by root | `sudo chown -R vscode /home/vscode/.pub-cache`, then fix the Dockerfile ordering |
| Panel in the host browser can't reach HA | dart-defines must say `localhost` + shifted ports (the BROWSER dials, from the host) | use the exact command post-create prints |
| The live test can't reach HA | in-container it is the opposite: `http://homeassistant:8123` | same |
| ring-mqtt crash-looping | its `config.json` missing/root-owned | `ls -l hub/dev/ring-mqtt-data/`; re-run `bash .devcontainer/initialize.sh` on the host |
| CMake error naming a foreign path in `panel/build/linux` | the checkout was built from the host once; caches embed absolute paths | `rm -rf panel/build/linux` and rebuild — one-time after any host↔container switch |
| Goldens red in-container | a real rendering change, or the SDK pin moved | they are canonical HERE — investigate before touching `--update-goldens` |

## Standing caveats

- **Dev-Hub parity drift** (open): `panel/assets/house/bindings.yaml`
  binds several Devices to real entities the dev Hub's generated package
  does not serve (`climate.main_floor`, `event.front_door_ding`, four
  switches — `hub.missing_entities` names them at connect). Consequences:
  those pins sit `Unknown` against the dev Hub, and the live test fails
  at the `ThermostatState` cast. Fix direction is a design decision —
  regenerate the dev package with currently-bound ids, or teach
  `panel/tool/gen_dev_entities.dart` + the live test which Devices are
  real-bound; `bindings_drift_test.dart` is the honesty-keeper to extend.
- **Dev HA is published on all host interfaces** (`0.0.0.0:18123`, while
  every other dev service binds `127.0.0.1`). An un-onboarded HA is
  claimable by whoever reaches it first, and this one is wired to a
  broker that holds a Ring token — onboard promptly after any
  `ha-config` reset, or narrow the publish to `127.0.0.1:18123:8123`
  and use VS Code port forwarding instead.
- **`devcontainer-lock.json` is tracked on purpose:** features pinned by
  digest, same deliberate-updates-only policy as the HA/ring-mqtt image
  pins. Feature updates are a commit, not a rebuild surprise.
- **What the container cannot do, by design:** anything
  mDNS/multicast (which the host-run dev stack could not do either —
  bridge networking both times; appliance-side per ADR-0008), operating
  the production Hub stack, the cage/touchscreen/GPU work
  (`docs/research/flutter-cage-spike.md` — though the container CAN
  build the spike bundle), and Sweet Home 3D's GUI (its converter runs
  here). GUI runs in-container render through llvmpipe — fine for tests,
  meaningless for performance judgments. On Apple-silicon hosts the
  image has no Chrome (amd64-only; the web flow via `-d web-server`
  is unaffected).

## Where this goes next

The image is a deterministic golden host, which makes it the natural CI
runner: the same container that bakes the goldens verifies them. That is
the first backlog item riding this bundle; nothing about it is wired yet.
