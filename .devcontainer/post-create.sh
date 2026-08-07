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

# ---- 1b. Playwright MCP + its browser ---------------------------------------
# The agent's browser (.mcp.json's `playwright` server). Installed HERE and
# not in the Dockerfile for a hard reason: devcontainer FEATURES — including
# the Node one that provides npm — are layered on top of the image *after*
# it is built, so there is no npm during the image build to install this
# with.
#
# Pinned, and pinned in one place, because the two halves must agree: the
# server bundles its own `playwright`, and a browser fetched by any other
# version lands under a different revision directory that this one will not
# look in ("Executable doesn't exist"). Installing the browser with the CLI
# out of the server's OWN dependency tree is what keeps them matched — never
# a stray `npx playwright install`.
#
# `.mcp.json` runs the resulting `playwright-mcp` binary off PATH with no
# version in the command, so this file is the only place the version lives.
# It also passes --headless, which is NOT the default and cannot be omitted:
# this container has no display.
PLAYWRIGHT_MCP_VERSION=0.0.79

echo
echo "-- playwright mcp --"
npm_root="$(npm root -g)"
# The package manifest, not `playwright-mcp --version`: that prints
# "Version 0.0.79" and a string compare against it silently never matches,
# so the guard reinstalls on every run (found the hard way).
installed_mcp="$(node -p \
  "require('$npm_root/@playwright/mcp/package.json').version" 2>/dev/null || true)"
if [ "$installed_mcp" != "$PLAYWRIGHT_MCP_VERSION" ]; then
  npm install -g "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}"
  npm_root="$(npm root -g)"
else
  echo "server: already $PLAYWRIGHT_MCP_VERSION"
fi
playwright_cli="$npm_root/@playwright/mcp/node_modules/playwright/cli.js"
# The browser cache is a named volume (compose.yaml), so this ~170 MB
# download happens on first create and is skipped by every rebuild after.
if [ -z "$(ls -A "$HOME/.cache/ms-playwright" 2>/dev/null)" ]; then
  node "$playwright_cli" install chromium
else
  echo "chromium: already in $HOME/.cache/ms-playwright (named volume)"
fi
# Root-only, and separate from the download above so the browser stays owned
# by this user: `install --with-deps` would need sudo for the whole thing and
# leave a root-owned cache in a volume that outlives the container.
sudo "$(command -v node)" "$playwright_cli" install-deps chromium

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

# Claude Code CLI, refreshed on every container create. The devcontainer
# FEATURE (devcontainer.json, digest-pinned) installs it at image-build
# time, but the CLI self-ships faster than images rebuild — this keeps it
# current without unpinning the feature. Failure is non-fatal by design
# (|| true): no network at create time must not brick the container.
curl -fsSL https://claude.ai/install.sh | bash || true

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
 5. GitHub CLI: `gh auth login` — the issue tracker
    (docs/agents/issue-tracker.md) runs on gh, so filing or reading
    issues from in here needs it. Once per container; a "Rebuild
    Container" starts a fresh home directory and loses it.

== Daily commands (terminal in this container) ==

 Panel against the dev Hub, in the HOST browser:
     cd panel
     flutter run -d web-server --web-port 8080 --profile \
       --dart-define=HUB=ha \
       --dart-define=HA_URL=http://localhost:18123 \
       --dart-define=HA_TOKEN="$(cat ../hub/dev/token)" \
       --dart-define=GO2RTC_URL=http://localhost:11984
     # then open http://localhost:8080 on the host (VS Code forwards it).
     # --profile is load-bearing (learned 2026-08-06): a DEBUG web-server
     # build loads all its modules and then waits for a debug connection
     # before running main(), and the web-server device only gets one from
     # the Dart Debug Chrome extension — no extension, no app: a blank
     # page with an empty console. Profile skips that gate. For
     # breakpoints/hot reload, install the extension and drop the flag.
     # localhost + shifted ports are correct in those dart-defines: the
     # BROWSER dials HA and go2rtc, and the browser is on the host, where
     # compose publishes the dev stack on 18123/11984.
     # "Address already in use" on 8080 is not a missing dependency —
     # it is an earlier `flutter run` still alive (an agent session's
     # background run, a forgotten terminal). Find and stop it:
     #     ss -tlnp | grep 8080     # the dart pid holding the port

 Tests (hermetic):        cd panel && flutter test

 The agent's browser (.mcp.json `playwright`) is pre-installed here —
 headless Chromium, matched to the pinned server. Nothing to do by hand;
 to check it yourself:
     playwright-mcp --version     # expect the pinned version
     ls ~/.cache/ms-playwright    # expect chromium-<rev>
 It is HEADLESS by force: this container has no display, and headed is
 @playwright/mcp's default, so the flag in .mcp.json is load-bearing.
 Point it at the Panel with http://localhost:8080 once `flutter run` is up.
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

 Goldens: THIS container is the canonical golden host (ADR-0009; baked
 2026-08-06, suite 398/1/0 in here). A red golden in-container is a real
 change — investigate, and re-bake (--update-goldens) only in here, never
 on a host. Red on a host machine is expected and means nothing.

EOF
echo "== post-create done =="
