#!/usr/bin/env bash
# install-kiosk.sh — provision the Appliance for boot-to-Panel under cage.
#
# Installs the runbook Step 1 package set (plus drm-info for the Step 0a
# hybrid-GPU check), creates the unprivileged 'cage' user, and installs the
# systemd unit and PAM config. It does NOT enable the unit or change the
# default target — those are deliberate manual steps printed at the end.
#
# Idempotent: safe to re-run at any time.
# Runbook: docs/research/flutter-cage-spike.md (Steps 0a, 1, 8).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_SRC_DIR="${SCRIPT_DIR}/../systemd"

if [[ ${EUID} -ne 0 ]]; then
    echo "error: this script must run as root (try: sudo $0)" >&2
    exit 1
fi

# --- OS check: the runbook was verified on Ubuntu 24.04 (noble) only -------
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        echo "WARNING: expected Ubuntu 24.04 LTS (noble); found: ${PRETTY_NAME:-unknown}." >&2
        echo "         Package names and the cage 0.1.5+20240127 snapshot facts in the" >&2
        echo "         runbook were only verified on noble. Proceeding anyway." >&2
    fi
else
    echo "WARNING: /etc/os-release not found; cannot verify this is Ubuntu 24.04." >&2
fi

# --- Packages (runbook Step 1, plus drm-info for Step 0a) ------------------
echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Kiosk/diagnostic set (all in noble universe) + hybrid-GPU check tool:
apt-get install -y \
    cage wlr-randr swayidle grim ddcutil evtest libinput-tools wev \
    drm-info
# Flutter Linux toolchain prerequisites
# (docs.flutter.dev/platform-integration/linux/setup):
apt-get install -y \
    clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev
# Flutter SDK bootstrap prerequisites — found by the appliance/test container:
# without unzip the flutter launcher dies with 'Unable to extract Dart SDK'.
apt-get install -y \
    curl git unzip zip xz-utils

# --- The 'cage' user: dedicated, unprivileged ------------------------------
echo "==> Ensuring the 'cage' user exists"
if id cage >/dev/null 2>&1; then
    echo "    user 'cage' already exists — leaving it untouched."
else
    # System user with a real home (the app bundle lives there), created with
    # a locked password and a nologin shell: the only way in is the systemd
    # unit's PAM session, never an interactive login.
    useradd --system --create-home --home-dir /home/cage \
        --shell /usr/sbin/nologin cage
    echo "    created system user 'cage' (locked password, nologin shell)."
fi

# --- Unit + PAM config -----------------------------------------------------
# Copies a config file into place; on overwrite, shows what changed first.
install_file() {
    local src="$1" dst="$2"
    if [[ ! -f "${src}" ]]; then
        echo "error: source file missing: ${src}" >&2
        exit 1
    fi
    if [[ -f "${dst}" ]]; then
        if cmp -s "${src}" "${dst}"; then
            echo "    ${dst} already up to date."
            return 0
        fi
        echo "    ${dst} exists and differs — overwriting. Diff (installed -> new):"
        diff -u "${dst}" "${src}" || true
    fi
    cp "${src}" "${dst}"
    chmod 0644 "${dst}"
    echo "    installed ${dst}"
}

echo "==> Installing systemd unit and PAM config"
install_file "${SYSTEMD_SRC_DIR}/cage@.service" /etc/systemd/system/cage@.service
install_file "${SYSTEMD_SRC_DIR}/cage.pam" /etc/pam.d/cage
systemctl daemon-reload

# --- Deliberately NOT done here: enabling boot-to-Panel --------------------
cat <<'EOF'

==> Done. Nothing has been enabled yet.

Before enabling the boot unit (runbook Step 8):
  - run appliance/scripts/check-hybrid-gpu.sh; if this Appliance has an
    NVIDIA dGPU, set the WLR_DRM_DEVICES Environment= line in
    /etc/systemd/system/cage@.service (a commented template is in the unit);
  - build the spike app and copy the bundle to /home/cage/spike_app/bundle/
    (runbook Step 5), e.g.:
      sudo rsync -a ~/spike_app/build/linux/x64/release/bundle/ /home/cage/spike_app/bundle/
      sudo chown -R cage:cage /home/cage/spike_app

On a machine with a desktop (the dev laptop runs GNOME): the unit carries
Alias=display-manager.service, and gdm already owns that alias, so
'systemctl enable' will refuse until gdm's claim is cleared:
  sudo systemctl disable gdm3          # (or gdm, depending on package name)
  readlink /etc/systemd/system/display-manager.service   # must NOT point at gdm
  sudo rm -f /etc/systemd/system/display-manager.service # if it still does

Then enable boot-to-Panel:
  sudo systemctl enable cage@tty1.service
  sudo systemctl set-default graphical.target
  sudo reboot

(To go back to the GNOME desktop later:
  sudo systemctl disable cage@tty1.service && sudo systemctl enable gdm3)

WARNING (from the runbook): cage runs with VT switching disabled —
Ctrl-Alt-F2 is dead once the unit owns the seat. Make sure SSH access
works BEFORE you reboot, or you will lose the machine's console.
EOF
