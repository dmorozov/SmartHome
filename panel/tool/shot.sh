#!/usr/bin/env bash
# Screenshot the Panel's web build without a visible browser.
#
#   tool/shot.sh [url] [out.png] [width] [height]
#   tool/shot.sh http://localhost:8100/ /tmp/panel.png 1440 900
#
# Why this exists: Chrome extensions screenshot by injecting a script into
# the page and waiting for it to run. Flutter web keeps the main thread
# busy, so that injection times out on a heavy frame and the screenshot
# fails — intermittently, and worst exactly when the UI is doing something
# interesting. Headless Chrome captures from the browser process instead,
# so a busy page cannot block it.
#
# --virtual-time-budget lets the page's timers run as fast as they can and
# fires the capture once they settle, so animations are finished rather
# than caught mid-flight.
set -euo pipefail

URL="${1:-http://localhost:8100/}"
OUT="${2:-panel-shot.png}"
W="${3:-1440}"
H="${4:-900}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [ ! -x "$CHROME" ]; then
  echo "Chrome not found at: $CHROME" >&2
  echo "Set CHROME=/path/to/chrome (Linux: google-chrome or chromium)." >&2
  exit 1
fi

# A throwaway profile: never touch the real one, and start from a clean
# cache so a stale service worker cannot serve an old bundle.
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT

"$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --user-data-dir="$PROFILE" \
  --virtual-time-budget=20000 \
  --window-size="$W,$H" \
  --screenshot="$OUT" \
  "$URL" 2>/dev/null || true

if [ ! -s "$OUT" ]; then
  echo "no screenshot written — is the build being served at $URL?" >&2
  exit 1
fi
echo "wrote $OUT (${W}x${H}) from $URL"
