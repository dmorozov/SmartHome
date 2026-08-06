#!/usr/bin/env bash
# Devcontainer post-create hook — runs INSIDE the workspace container, once
# after it is (re)built (devcontainer.json `postCreateCommand`). Idempotent;
# safe to re-run by hand any time:
#     bash .devcontainer/post-create.sh
#
# Its three jobs: fetch the Panel's packages, verify the toolchain and the
# sibling dev-Hub containers actually work from in here, and print the
# bring-up steps no script can do for you (they create credentials).
# initialize.sh already ran on the host and seeded the gitignored dev-hub
# config files — the two scripts together are the whole setup story.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== SmartHome devcontainer: post-create =="

# Insurance for host/container uid mismatches (a Docker Desktop case; a
# no-op when ownership already lines up, which is the Linux norm).
git config --global --add safe.directory /workspaces/SmartHome 2>/dev/null || true

# ---- 1. Panel packages ------------------------------------------------------
(cd panel && flutter pub get)

# ---- 2. Verify, don't assume ------------------------------------------------
echo
echo "-- toolchain --"
flutter --version | head -1
echo "chrome: $([ -x "${CHROME_EXECUTABLE:-/nonexistent}" ] \
    && "$CHROME_EXECUTABLE" --version \
    || echo "absent (arm64 — use 'flutter run -d web-server' + the host browser)")"

# Golden tests load real fonts from the SDK cache and error loudly if they
# are missing (golden_setup.dart); catch that here instead of mid-suite.
if [ ! -d "$FLUTTER_ROOT/bin/cache/artifacts/material_fonts" ]; then
  echo "WARNING: material_fonts missing from $FLUTTER_ROOT/bin/cache —"
  echo "         goldens will refuse to run. Try: flutter precache"
fi

echo
echo "-- dev Hub (sibling containers, via the host's docker daemon) --"
if docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null \
     | grep -E 'homeassistant-dev|mosquitto-dev|ring-mqtt-dev|go2rtc-dev'; then
  :
else
  echo "WARNING: no dev-Hub containers visible. Is the docker socket"
  echo "         mounted (docker-outside-of-docker feature)? Try: docker ps"
fi

curl -fsSL https://claude.ai/install.sh | bash

# ---- 3. What remains is yours — these steps create credentials --------------
# Same steps as hub/dev/README.md "Bring it up"; addresses adjusted for
# where each thing runs. Rule of thumb: YOUR BROWSER runs on the host, so
# it uses localhost with the SHIFTED dev ports — the production Hub stack
# runs on this same machine and owns the canonical ones (hub/dev/
# compose.yaml's header has the table): dev HA localhost:18123 (all
# interfaces), go2rtc :11984 / ring-mqtt :65123 / MQTT :11883 on the
# host's 127.0.0.1. Anything running IN THIS CONTAINER uses the compose
# service name with the CANONICAL container port instead
# (http://homeassistant:8123) — the shift is host-side only.
cat <<'EOF'

== One-time, by hand in the HOST browser (creates credentials) ==

 1. HA onboarding:   http://localhost:18123
    (18123, not 8123 — :8123 on this machine is the REAL house's HA.)
    Create the admin user; skip location/analytics if you like.
 2. Panel token:     your user (bottom left) -> Security ->
    Long-lived access tokens -> Create. HA shows it ONCE. Save it to:
        hub/dev/token          (gitignored)
 3. MQTT into HA (once, before Ring): Settings -> Devices & Services ->
    Add integration -> MQTT. Broker `mosquitto`, port 1883, no credentials
    (compose-network hostname and container port — NOT localhost).
 4. Ring (optional): http://localhost:65123 — Ring login + 2FA; the
    refresh token lands in hub/dev/ring-mqtt-data/ (gitignored).

== Daily commands (terminal in this container) ==

 Panel against the dev Hub, in the HOST browser:
     cd panel
     flutter run -d web-server --web-port 8080 \
       --dart-define=HUB=ha \
       --dart-define=HA_URL=http://localhost:18123 \
       --dart-define=HA_TOKEN="$(cat ../hub/dev/token)" \
       --dart-define=GO2RTC_URL=http://localhost:11984
     # then open http://localhost:8080 on the host (VS Code forwards it).
     # localhost + shifted ports are correct in those dart-defines: the
     # BROWSER dials HA and go2rtc, and the browser is on the host, where
     # compose publishes the dev stack on 18123/11984.

 Tests (hermetic):        cd panel && flutter test
 The live end-to-end test (in-container, so service-name DNS):
     cd panel && PANEL_LIVE_HUB=1 HA_URL=http://homeassistant:8123 \
       HA_TOKEN="$(cat ../hub/dev/token)" flutter test test/ha_hub_live_test.dart

 Dev Hub services — by CONTAINER NAME, never `docker compose` from in here
 (compose's relative bind paths resolve against this container's
 /workspaces, not the host; see .devcontainer/compose.yaml):
     docker logs -f homeassistant-dev
     docker restart go2rtc-dev        # after editing hub/dev/go2rtc/go2rtc.yaml
     docker restart homeassistant-dev # after regenerating panel_dev.yaml
 Recreating the stack = VS Code "Rebuild Container", or compose on the host.

 Goldens: host-rendered — the committed images may differ on this host for
 font reasons alone (phase-0 open item 13 tracks exactly this). Regenerate
 and eyeball diffs; don't commit a regeneration just to make CI-of-one green.

EOF
echo "== post-create done =="
