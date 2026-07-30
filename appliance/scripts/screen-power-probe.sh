#!/usr/bin/env bash
# screen-power-probe.sh — runbook Step 7: screen blank/wake probes.
#
# Part 1 (wlr-randr): discovers the output on the running cage session and
# runs one off / sleep 3 / on cycle. cage has no wlr-output-power-management
# (wlopm does NOT work under cage); --off removes the output from the layout,
# and whether the Flutter surface comes back fullscreen is the UNVERIFIED part
# this probe exists to answer.
#
# Part 2 (ddcutil): read-only DDC/CI probe — detect, capabilities, brightness.
# Panel-dependent and UNVERIFIED per the runbook ("many small HDMI
# touchscreens don't" implement DDC/CI). Record the result either way: it is
# a panel-purchase criterion.
#
# Non-destructive: the VCP D6 power-off (setvcp) is printed, NEVER run.
# Runbook: docs/research/flutter-cage-spike.md (Steps 6 and 7).

set -euo pipefail

# --- Part 1: wlr-randr blank/wake cycle against the cage session -----------

if [[ -z "${WAYLAND_DISPLAY:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
    cat >&2 <<'EOF'
error: WAYLAND_DISPLAY and/or XDG_RUNTIME_DIR are not set.

This probe talks to the running cage session. From SSH, export the cage
session's environment first (runbook Step 6) — for a session owned by
user 'cage':

    export XDG_RUNTIME_DIR=/run/user/$(id -u cage)
    export WAYLAND_DISPLAY=wayland-0

then re-run this script.
EOF
    exit 1
fi

if ! command -v wlr-randr >/dev/null 2>&1; then
    echo "error: wlr-randr not found — run appliance/scripts/install-kiosk.sh first." >&2
    exit 1
fi

echo "== Part 1: wlr-randr blank/wake probe =="
echo "Session: WAYLAND_DISPLAY=${WAYLAND_DISPLAY}  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
echo

# Output names are the non-indented lines of wlr-randr's report.
mapfile -t outputs < <(wlr-randr | awk '/^[^[:space:]]/ {print $1}')

if [[ ${#outputs[@]} -eq 0 ]]; then
    echo "error: wlr-randr reported no outputs. Is cage actually running on" >&2
    echo "this Wayland display, and is the env above the cage session's?" >&2
    exit 1
fi

output="${outputs[0]}"
if [[ ${#outputs[@]} -gt 1 ]]; then
    echo "Multiple outputs found: ${outputs[*]} — probing the first: ${output}"
else
    echo "Output: ${output}"
fi

echo
echo "In another terminal, watch for output-remove side effects during the cycle:"
echo "    journalctl -f          # or: journalctl -u cage@tty1 -f"
echo
echo "Running: off -> sleep 3 -> on ..."
# From --off until a successful --on, ANY exit (set -e failure, Ctrl-C, or
# --on itself failing — which is exactly the cage re-enable bug #515 this
# probe exists to catch) must not leave the panel dark without a recovery path.
recover() {
    echo "RECOVERY: re-enabling output ${output} ..." >&2
    wlr-randr --output "${output}" --on \
        || echo "recover manually:  wlr-randr --output ${output} --on   (or: systemctl restart cage@tty1)" >&2
}
trap recover EXIT INT TERM
wlr-randr --output "${output}" --off
sleep 3
wlr-randr --output "${output}" --on
trap - EXIT INT TERM
echo "Cycle done."

cat <<EOF

CHECK NOW (the UNVERIFIED bits this probe exists for):
  - Did the Flutter surface come back FULLSCREEN at the right size?
    (--off removes the output from the layout; resize-back is UNVERIFIED —
    cage issue #245 discussion, re-enable bug #515.)
  - Any cage errors/crashes in the journal?

Automated blank-on-idle, wake-on-touch (run manually, blocks the terminal;
short timeout for testing):

    swayidle -w \\
      timeout 30 'wlr-randr --output ${output} --off' \\
      resume     'wlr-randr --output ${output} --on'

Wait 30 s -> screen off; tap -> screen on. Note whether the wake tap also
ACTS inside the app — it is delivered as a real touch, so the production
Panel app must debounce input-after-blank.
EOF

# --- Part 2: DDC/CI probe (read-only) --------------------------------------

echo
echo "== Part 2: DDC/CI probe — PANEL-DEPENDENT, UNVERIFIED =="
echo "Compositor-independent alternative for power/brightness. Many small HDMI"
echo "touchscreens don't implement DDC/CI; record the result either way — it"
echo "is a panel-purchase criterion (runbook Step 7)."
echo

if ! command -v ddcutil >/dev/null 2>&1; then
    echo "ddcutil not found — run appliance/scripts/install-kiosk.sh, then re-run."
    exit 0
fi

# ddcutil needs the i2c-dev module and (typically) root.
priv=()
if [[ ${EUID} -ne 0 ]]; then
    priv=(sudo)
fi

echo "--- modprobe i2c-dev"
"${priv[@]}" modprobe i2c-dev \
    || echo "modprobe i2c-dev failed — DDC/CI probing cannot proceed."

echo "--- ddcutil detect"
"${priv[@]}" ddcutil detect \
    || echo "detect failed or found no displays (no DDC/CI? record this)."

echo "--- ddcutil capabilities"
"${priv[@]}" ddcutil capabilities \
    || echo "capabilities query failed (no DDC/CI? record this)."

echo "--- ddcutil getvcp 10   (brightness)"
"${priv[@]}" ddcutil getvcp 10 \
    || echo "getvcp 10 failed (no DDC/CI brightness? record this)."

cat <<'EOF'

NOT RUN (destructive, panel-dependent, UNVERIFIED — runbook Step 7):

    sudo ddcutil setvcp D6 0x05     # power off via VCP D6

Run it manually only when you are ready to test panel power-off, with a way
to power the panel back on.
EOF
