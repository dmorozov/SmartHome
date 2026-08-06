#!/usr/bin/env bash
# Devcontainer pre-up hook — runs on the HOST, as you, every time the
# devcontainer starts (devcontainer.json `initializeCommand`), BEFORE
# `docker compose up`. Idempotent: everything checks before it touches.
#
# Why these steps are host-side and pre-up rather than in post-create.sh:
# the dev Hub services bind-mount directories under hub/dev/, and dockerd
# creates a missing bind source as root:root at `up` (CreateMountpoint —
# hub/.gitignore tells the same story). By then it is too late: ring-mqtt
# is already crash-looping on its missing config.json, and nothing
# unprivileged can write into the root-owned directory. Created here first,
# the directories belong to you and the first `up` comes up healthy.
#
# The manual half of bring-up (HA onboarding, the long-lived token, Ring
# auth) still exists — post-create.sh prints it. This script only seeds
# what hub/dev/README.md says to seed, with the same content.
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- 0. One driver at a time -----------------------------------------------
# The editor derives its compose --project-name from the merged config's
# top-level `name:` — smarthome-dev-hub, from hub/dev/compose.yaml — so the
# devcontainer's stack and a `docker compose up` run by hand in hub/dev/
# are the SAME compose project. Compose would not collide: it would adopt
# the hand-started containers, and from then on closing the editor window
# stops a stack you started on purpose (shutdownAction: stopCompose).
# Ownership should change hands explicitly, never by side effect — refuse.
# The com.docker.compose.project.config_files label records which -f files
# created a container: the devcontainer's own stack (running OR stopped —
# this hook runs on every start) lists this overlay, a hand-started one
# lists only hub/dev/compose.yaml.
if command -v docker >/dev/null 2>&1 \
   && docker inspect homeassistant-dev >/dev/null 2>&1; then
  config_files="$(docker inspect homeassistant-dev \
      --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}')"
  case "$config_files" in
    */.devcontainer/compose.yaml*)
      : ;; # our own stack from a previous devcontainer up — `up` reconciles it
    *)
      echo "A dev Hub stack started by hand in hub/dev/ exists on this daemon" >&2
      echo "(running or stopped). Opening the devcontainer would silently take" >&2
      echo "it over — both drivers share one compose project — and closing the" >&2
      echo "editor window would then stop it. Change drivers explicitly:" >&2
      echo "    cd hub/dev && docker compose down" >&2
      echo "then reopen. (Your HA account/token/Ring state live in bind mounts" >&2
      echo "under hub/dev/ and survive.)" >&2
      exit 1
      ;;
  esac
fi

# ---- 1. Bind-mount sources that must pre-exist, owned by you ---------------
mkdir -p hub/dev/ring-mqtt-data hub/dev/mosquitto/data

# ---- 2. go2rtc's live config from its tracked example ----------------------
# Gitignored because real stream URLs embed camera credentials; the example
# carries only the synthetic `selftest` pattern, so the copy is safe.
if [ ! -f hub/dev/go2rtc/go2rtc.yaml ]; then
  cp hub/dev/go2rtc/go2rtc.example.yaml hub/dev/go2rtc/go2rtc.yaml
  echo "seeded hub/dev/go2rtc/go2rtc.yaml from the tracked example"
fi

# ---- 3. ring-mqtt's config.json --------------------------------------------
# v5.x refuses to start without it. This is the canonical content from
# hub/dev/README.md, verbatim — authored, no secrets: the dev broker is
# anonymous (see hub/dev/mosquitto/config/mosquitto.conf), so mqtt_url
# carries no password. The DIRECTORY stays gitignored because ring-mqtt
# later writes the Ring REFRESH TOKEN next to this file.
if [ ! -f hub/dev/ring-mqtt-data/config.json ]; then
  cat > hub/dev/ring-mqtt-data/config.json <<'JSON'
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
JSON
  echo "seeded hub/dev/ring-mqtt-data/config.json (per hub/dev/README.md)"
fi
