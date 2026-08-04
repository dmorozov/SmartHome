# Appliance provisioning

The **Appliance** is the always-on computer hosting the Hub and driving the Panel — the Intel dev laptop during development, the Ryzen AI mini PC in production (see [`../CONTEXT.md`](../CONTEXT.md)). This directory provisions it to boot straight into a full-screen app under the `cage` Wayland kiosk compositor: today the spike app, later the Panel app (same unit, one `ExecStart` path change).

Everything here follows the spike runbook: [`../docs/research/flutter-cage-spike.md`](../docs/research/flutter-cage-spike.md).

## Contents

| File | What it does |
|---|---|
| `ansible/` | **The provisioning path**: packages, `cage` user, PAM, templated `cage@.service`, gated enable/hardening (inventory: laptop / minipc / test-appliance) — see `ansible/README.md` |
| `scripts/check-hybrid-gpu.sh` | Interactive diagnostic, runbook Step 0a: which GPU owns HDMI; prints the `WLR_DRM_DEVICES` pin or mitigation advice; read-only |
| `scripts/screen-power-probe.sh` | Interactive diagnostic, runbook Step 7: `wlr-randr` blank/wake cycle + read-only DDC/CI probe; never runs destructive `setvcp` |
| `test/` | Disposable systemd+SSH container (Docker) for testing the playbooks and deployment scripts — models Ubuntu 24.04 by default (the mini PC's OS per ADR-0001), `UBUNTU_TAG=26.04` for the dev laptop's; see `test/README.md` for what it can and cannot validate |

## Spike-day order of operations

1. **`scripts/check-hybrid-gpu.sh`** — find which GPU owns the HDMI port (runbook Step 0a). On the laptop, cage must run on the Intel `i915` iGPU, never the NVIDIA dGPU; note the printed `WLR_DRM_DEVICES=/dev/dri/by-path/pci-<addr>-card` pin — by PCI path, because `cardN` numbering is not guaranteed stable across boots, and mandatory for every cage run on this machine. Run it **with the touchscreen plugged in**: with nothing connected every connector reads `disconnected` and the HDMI owner cannot be determined.
2. **Provision** — from the Mac (or any controller with the repo): `cd appliance/ansible && ansible-playbook site.yml -l laptop` (set the laptop's address in `inventory.yml` first; needs only openssh-server on the laptop). Installs packages, `cage` user, PAM, unit. Enables nothing.
3. **Bootstrap the spike app** — build the four-page touch-test app and copy the bundle to `/home/cage/spike_app/bundle/` (see `../spike/` and runbook Step 5; pin Flutter >= 3.44 stable).
4. **Manual cage run** — from a local TTY with GNOME's display manager stopped (`sudo systemctl stop gdm3` — or `gdm`): `WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card cage -- <bundle>`; work through tap / multi-touch / fling / pinch, both backends (runbook Step 6).
5. **`scripts/screen-power-probe.sh`** — from SSH with the cage session env exported: blank/wake cycle and DDC/CI probe (runbook Step 7).
6. **Enable the boot unit** (runbook Step 8) — only after confirming SSH works, because VT switching is disabled under cage. `wlr_drm_devices` is **already pinned** in `ansible/host_vars/laptop.yml` (the i915 card, by PCI path) — step 1 only reports the value, it never writes it, so re-check that the two agree rather than setting it afresh. Then run the gated converge — it clears gdm's seat claim, enables `cage@tty1`, and sets `graphical.target`:

   ```bash
   cd appliance/ansible
   ansible-playbook site.yml -l laptop -e kiosk_enable=true -e kiosk_disable_gdm=true
   # then, on the laptop:
   sudo reboot
   ```

   To return the laptop to its desktop later: `sudo systemctl disable cage@tty1.service && sudo systemctl enable gdm3`.

Score the result against the runbook's 13-item pass/fail checklist; on failure, use its fallback ladder (Weston kiosk-shell, `GDK_BACKEND=x11`, labwc, flutter-pi).

## Provisioning evolution (2026-07-30)

Ansible in **`ansible/`** is the single provisioning path. History, same day:
planned post-spike → pulled forward once the `test/` container made playbook
testing possible → the interim bash script (`install-kiosk.sh`) and static
`systemd/` files were retired after the playbooks surpassed them (fresh-host
converge, `changed=0` idempotence, `--check` dry-run, gated enable/hardening
all verified; the bash path had none of that). The runbook keeps the manual
recipe as reference documentation. Note: Ansible "playbooks" ≠ the spike
"runbook" (`docs/research/flutter-cage-spike.md`).

## Later hardening (appliance polish — optional for the spike, record findings anyway)

- `/etc/default/grub`: `GRUB_TIMEOUT=0`, `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3"` (then `sudo update-grub`) — silent boot.
- `/etc/systemd/logind.conf`: `NAutoVTs=0`, `ReserveVT=0` — no spare getty VTs on the Appliance.
- Kernel parameter `vt.global_cursor_default=0` — hides the blinking VT cursor, but its documented behavior is **UNVERIFIED**; confirm on-device via `/sys/module/vt/parameters/global_cursor_default`.
- Longer term (per the roadmap): revisit Ubuntu Core + Ubuntu Frame once the system design is frozen; production Appliance runs Ubuntu **Server** 24.04 (no desktop environment at all).
