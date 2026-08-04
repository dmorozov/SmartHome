#!/usr/bin/env bash
# check-hybrid-gpu.sh — runbook Step 0a: which GPU owns the HDMI connector?
#
# On the hybrid-graphics laptop (Intel UHD iGPU / i915 + NVIDIA RTX 4090 dGPU)
# cage/wlroots must run on the integrated card — the NVIDIA proprietary driver
# is the worst-supported wlroots combo and would contaminate the spike verdict.
# The mini PC is AMD (amdgpu), so both driver families are treated as valid
# integrated cards here. This script enumerates /sys/class/drm, reports each
# card's driver and connectors, identifies which card owns HDMI-A-*, and prints
# the recommended WLR_DRM_DEVICES pin as a stable /dev/dri/by-path/... path.
#
# Read-only: inspects sysfs, modifies nothing.
# Runbook: docs/research/flutter-cage-spike.md (Step 0a).

set -euo pipefail

if [[ ! -d /sys/class/drm ]]; then
    echo "error: /sys/class/drm not found — is this a Linux box with DRM?" >&2
    exit 1
fi

shopt -s nullglob

found_cards=0
igpu_card=""              # first card driven by an integrated-GPU KMS driver
igpu_driver=""
nvidia_present=0

# Integrated / open-source KMS drivers cage may safely composite on: i915 and
# xe are Intel (this laptop), amdgpu and radeon are AMD (the mini PC). Anything
# else — nvidia, nouveau — stays out of the compositor's path.
is_igpu_driver() {
    case "$1" in
        i915|xe|amdgpu|radeon) return 0 ;;
        *) return 1 ;;
    esac
}

# cardN numbering is NOT guaranteed stable across boots: it follows driver probe
# order, so a kernel/driver change can renumber the cards even when the hardware
# does not move. Always pin by PCI path, which is fixed by the bus topology.
stable_pin() {
    local card="$1" link
    for link in /dev/dri/by-path/*-card; do
        if [[ "$(readlink "${link}")" == "../${card}" ]]; then
            printf '%s\n' "${link}"
            return
        fi
    done
    printf '/dev/dri/%s\n' "${card}"   # by-path absent: last resort
}
hdmi_owner_card=""        # card owning an HDMI-A-* connector (connected wins)
hdmi_owner_driver=""
hdmi_owner_connected=0

echo "== DRM cards and connectors (/sys/class/drm) =="

for card_path in /sys/class/drm/card*; do
    name="$(basename "${card_path}")"
    # Only the card nodes themselves (card0, card1, ...), not connectors.
    if [[ ! "${name}" =~ ^card[0-9]+$ ]]; then
        continue
    fi
    found_cards=1

    driver="unknown"
    if driver_link="$(readlink "${card_path}/device/driver" 2>/dev/null)"; then
        driver="$(basename "${driver_link}")"
    fi

    echo
    echo "${name}  (/dev/dri/${name})  driver: ${driver}"

    if is_igpu_driver "${driver}" && [[ -z "${igpu_card}" ]]; then
        igpu_card="${name}"
        igpu_driver="${driver}"
    fi
    if [[ "${driver}" == "nvidia" || "${driver}" == "nouveau" ]]; then
        nvidia_present=1
    fi

    have_connector=0
    for conn_path in /sys/class/drm/"${name}"-*; do
        conn="$(basename "${conn_path}")"
        conn="${conn#"${name}"-}"
        status="unknown"
        if [[ -r "${conn_path}/status" ]]; then
            status="$(<"${conn_path}/status")"
        fi
        echo "    connector: ${conn}  (${status})"
        have_connector=1

        if [[ "${conn}" == HDMI-A-* ]]; then
            # Remember the owner; a *connected* HDMI beats a disconnected one.
            if [[ -z "${hdmi_owner_card}" ||
                  ( "${status}" == "connected" && ${hdmi_owner_connected} -eq 0 ) ]]; then
                hdmi_owner_card="${name}"
                hdmi_owner_driver="${driver}"
                if [[ "${status}" == "connected" ]]; then
                    hdmi_owner_connected=1
                fi
            fi
        fi
    done
    if [[ ${have_connector} -eq 0 ]]; then
        echo "    connector: (none — render-only or headless node)"
    fi
done

if [[ ${found_cards} -eq 0 ]]; then
    echo "error: no /sys/class/drm/cardN entries found." >&2
    exit 1
fi

echo
echo "== Conclusion =="

if [[ -z "${hdmi_owner_card}" ]]; then
    echo "No HDMI-A-* connector found on any card."
    echo "If the touchscreen is meant to be on HDMI, plug it in and re-run;"
    echo "for full detail run: drm_info | less   (installed by the ansible kiosk role)."
elif [[ ${hdmi_owner_connected} -eq 0 ]]; then
    echo "No HDMI-A-* connector reads 'connected' — nothing is plugged in, so"
    echo "which card owns the physical HDMI port is UNDETERMINED. Several cards"
    echo "advertise HDMI-A-* connectors that are not routed to a socket; the"
    echo "tie-break below would just pick the first one. Plug the touchscreen in"
    echo "and re-run before spike day."
    if [[ -n "${igpu_card}" ]]; then
        echo
        echo "Meanwhile the pin is unambiguous — cage runs on the integrated card"
        echo "(${igpu_card}, driver ${igpu_driver}), never on a discrete one:"
        echo
        echo "    WLR_DRM_DEVICES=$(stable_pin "${igpu_card}")"
    fi
elif is_igpu_driver "${hdmi_owner_driver}"; then
    echo "HDMI (${hdmi_owner_card}) is wired to the integrated '${hdmi_owner_driver}' card — good."
    echo
    echo "Pin cage to it (mandatory wherever a discrete GPU is also present —"
    echo "on this laptop, never let cage open the NVIDIA card):"
    echo
    echo "    WLR_DRM_DEVICES=$(stable_pin "${hdmi_owner_card}")"
    echo
    echo "For boot: set wlr_drm_devices in appliance/ansible/host_vars/<host>.yml;"
    echo "the kiosk role templates it into cage@.service as Environment=."
    echo "For manual runs: WLR_DRM_DEVICES=$(stable_pin "${hdmi_owner_card}") cage -- <app>"
else
    echo "HDMI (${hdmi_owner_card}) is wired to the '${hdmi_owner_driver}' card,"
    echo "not the integrated GPU. Do not run cage on it. Mitigations, in order (Step 0a):"
    echo
    echo "  (a) Check BIOS/UEFI for a MUX / 'hybrid graphics' / 'iGPU only'"
    echo "      switch and route the HDMI port to the iGPU."
    echo "  (b) Try a USB-C DP-alt-mode -> HDMI adapter — USB-C outputs are"
    echo "      commonly iGPU-wired (UNVERIFIED for this model)."
    echo "  (c) Last resort: run the spike's software layers on the laptop's"
    echo "      built-in screen and accept that touch tests wait for an"
    echo "      iGPU-driven output."
    if [[ -n "${igpu_card}" ]]; then
        echo
        echo "Either way, pin cage to the integrated '${igpu_driver}' card:"
        echo
        echo "    WLR_DRM_DEVICES=$(stable_pin "${igpu_card}")"
    fi
fi

if [[ ${nvidia_present} -eq 1 && -n "${igpu_card}" ]]; then
    echo
    echo "Note: an NVIDIA card is present — WLR_DRM_DEVICES pinning is mandatory"
    echo "for every cage invocation on this machine, manual or systemd."
fi
