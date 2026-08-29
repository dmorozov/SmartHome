#!/usr/bin/env bash
# Freeze probe — answers "does the camera wall's picture actually move?"
# without a person watching it. Part of the phase-8 frozen-video hunt.
#
# Launches the release Panel under the X11 GDK backend (XWayland renders it
# on the normal desktop; X11 is also what lets ImageMagick capture window
# contents — Wayland offers no scripted capture without a portal dialog),
# auto-opens the Cameras view (CAMERAS_OPEN=auto), waits out the stream
# warmup, grabs the window twice a few seconds apart, and pixel-diffs the
# grid area cell by cell. A cell whose pixels moved between the grabs is
# PLAYING; one whose pixels did not is FROZEN.
#
# Scar tissue, earned 2026-08-27, all of it load-bearing:
#  * The window is resolved by _NET_WM_PID against OUR child — never by
#    name order. A leaked window from an earlier run sits first in the
#    tree, drifts back to the Dollhouse on the 5-minute idle return, and
#    every capture of it reads "frozen" while lying about what it shows.
#  * Strays are swept before launch, and the kill is verified after —
#    a plain `kill` has failed to land more than once.
#  * VIDEO_DEBUG=on segfaults X11 runs (the tile pixel sampler's toImage
#    readback); the rig leaves it off and trusts the screenshots.
#  * The one expected-frozen cell on the demo house is the idle Ring
#    Doorbell tile — 5/6 moving is a healthy wall.
#
# Usage — the knobs ride the environment, exactly like a hand run:
#   tool/freeze_probe.sh                        the shipped wall (Skia)
#   PANEL_RENDERER=impeller tool/freeze_probe.sh   re-test Impeller before an
#                                               SDK upgrade (ADR-0012)
#
# Extra knobs of its own:
#   WARMUP  seconds before the first grab (default 25 — dial + first frame)
#   GAP     seconds between the two grabs (default 3)
#   OUT     where grabs and diffs land (default /tmp/freeze_probe)
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE=$PWD/build/linux/x64/release/bundle/panel
[[ -x $BUNDLE ]] || { echo "no release bundle — flutter build linux --release first" >&2; exit 2; }

WARMUP=${WARMUP:-25}
GAP=${GAP:-3}
OUT=${OUT:-/tmp/freeze_probe}
mkdir -p "$OUT"

# A blanked/locked screen stops Mutter compositing XWayland windows, and
# `import` then reads each window's LAST presented buffer: the app keeps
# running, the log looks healthy, and every capture is a stale lie that
# reads "frozen" (measured 2026-08-27 — a whole pairwise sweep was voided
# by this). No capture without a live compositor.
screen_blanked() {
  gdbus call --session --dest org.gnome.ScreenSaver \
    --object-path /org/gnome/ScreenSaver \
    --method org.gnome.ScreenSaver.GetActive 2>/dev/null | grep -q true
}
if screen_blanked; then
  echo "the screen is blanked or locked — wake it, then rerun" >&2
  exit 3
fi

pkill -9 -f "$BUNDLE" 2>/dev/null || true
sleep 1

# Forced, not defaulted: the desktop session exports GDK_BACKEND=wayland,
# and an inherited wayland silently hides the window from every X tool —
# the rig then measures a stale window or nothing. RIG_BACKEND overrides.
export GDK_BACKEND=${RIG_BACKEND:-x11}
export GO2RTC_URL=${GO2RTC_URL:-http://127.0.0.1:1984}
export CAMERAS_OPEN=auto
# Inhibit idle for the run's own duration, so a sweep of many runs cannot
# blank the screen halfway through and quietly void its own second half.
# The inhibitor is the child; the panel is ITS child — resolved by pgrep
# so the window's _NET_WM_PID (the panel's) still matches.
gnome-session-inhibit --inhibit idle --app-id freeze-probe \
  "$BUNDLE" >"$OUT/panel.log" 2>&1 &
WRAP=$!
sleep 1
PANEL=$(pgrep -n -f "$BUNDLE" || true)
[[ -n $PANEL ]] || { echo "panel process not found after launch" >&2; exit 2; }
finish() {
  kill "$WRAP" "$PANEL" 2>/dev/null || true
  sleep 1
  kill -9 "$WRAP" "$PANEL" 2>/dev/null || true
}
trap finish EXIT

# Our window, by PID — never by name order (see scar tissue above).
WID=""
for _ in $(seq 1 30); do
  sleep 1
  kill -0 "$PANEL" 2>/dev/null || { echo "panel died at startup (see $OUT/panel.log)" >&2; exit 2; }
  for w in $(xwininfo -root -tree 2>/dev/null | awk '$2 == "\"panel\":" {print $1}'); do
    pid=$(xprop -id "$w" _NET_WM_PID 2>/dev/null | awk '{print $3}')
    if [[ $pid == "$PANEL" ]]; then WID=$w; break 2; fi
  done
done
[[ -n $WID ]] || { echo "panel window never appeared (see $OUT/panel.log)" >&2; exit 2; }
echo "window $WID (pid $PANEL) up; warming up ${WARMUP}s"

sleep "$WARMUP"
kill -0 "$PANEL" 2>/dev/null || { echo "panel died during warmup (see $OUT/panel.log)" >&2; exit 2; }
import -window "$WID" "$OUT/a.png"
sleep "$GAP"
import -window "$WID" "$OUT/b.png"
# The guard again, AFTER the grabs: the inhibitor has been observed losing
# the race (2026-08-28 — a run blanked mid-warmup and read a healthy wall as
# 0/6, every pixel of both grabs identical including the window chrome). A
# verdict from a blanked screen is not a weak verdict, it is a false one.
if screen_blanked; then
  echo "the screen blanked DURING the run — verdict void, wake it and rerun" >&2
  exit 3
fi

python3 - "$OUT/a.png" "$OUT/b.png" <<'PY'
import sys
from PIL import Image, ImageChops

a, b = Image.open(sys.argv[1]).convert('RGB'), Image.open(sys.argv[2]).convert('RGB')
if a.size != b.size:
    sys.exit(f'grab sizes differ: {a.size} vs {b.size}')
w, h = a.size
# The grid area: below the header, full width minus the page gutters.
# Cells are diffed 3x2 — the wall's three columns, first two rows.
top, left, right, bottom = int(h * 0.15), 24, w - 24, h - 8
cols, rows = 3, 2
cw, ch = (right - left) // cols, (bottom - top) // rows
diff = ImageChops.difference(a, b)
moving = 0
for r in range(rows):
    for c in range(cols):
        box = (left + c * cw, top + r * ch, left + (c + 1) * cw, top + (r + 1) * ch)
        cell = diff.crop(box).convert('L')
        # Mean absolute difference, 0-255; >0.5 is real motion, below is
        # noise/static chrome. The number is printed so a borderline run
        # reads as borderline instead of lying with a label.
        m = sum(i * v for i, v in enumerate(cell.histogram())) / (cw * ch)
        state = 'PLAYING' if m > 0.5 else 'frozen'
        moving += state == 'PLAYING'
        print(f'cell r{r}c{c}: mean-diff {m:6.2f}  {state}')
print(f'--- {moving}/{cols * rows} cells moving')
PY
echo "grabs and log in $OUT"
