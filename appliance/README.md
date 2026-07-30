# Appliance provisioning

The **Appliance** is the always-on computer hosting the Hub and driving the Panel — the AMD laptop during development, the Ryzen AI mini PC in production (see [`../CONTEXT.md`](../CONTEXT.md)). This directory provisions it to boot straight into a full-screen app under the `cage` Wayland kiosk compositor: today the spike app, later the Panel app (same unit, one `ExecStart` path change).

Everything here follows the spike runbook: [`../docs/research/flutter-cage-spike.md`](../docs/research/flutter-cage-spike.md).

## Contents

| File | What it does |
|---|---|
| `systemd/cage@.service` | Boot-to-app unit (cage wiki recipe + spike restart tweaks); installed to `/etc/systemd/system/` |
| `systemd/cage.pam` | PAM stack for the cage session (logind grants DRM/input access); installed to `/etc/pam.d/cage` |
| `scripts/install-kiosk.sh` | Idempotent provisioning: packages, `cage` user, unit + PAM install; deliberately enables nothing |
| `scripts/check-hybrid-gpu.sh` | Runbook Step 0a: which GPU owns HDMI; prints the `WLR_DRM_DEVICES` pin or mitigation advice; read-only |
| `scripts/screen-power-probe.sh` | Runbook Step 7: `wlr-randr` blank/wake cycle + read-only DDC/CI probe; never runs destructive `setvcp` |
| `test/` | Disposable Ubuntu 24.04 systemd+SSH container (Docker) for testing the deployment scripts and, later, the Ansible playbooks — see `test/README.md` for what it can and cannot validate |

## Spike-day order of operations

1. **`scripts/check-hybrid-gpu.sh`** — find which GPU owns the HDMI port (runbook Step 0a). On the laptop, cage must run on the amdgpu iGPU; note the printed `WLR_DRM_DEVICES=/dev/dri/cardN` pin — it is mandatory for every cage run on this machine.
2. **`sudo scripts/install-kiosk.sh`** — packages, `cage` user, unit + PAM files. Enables nothing; prints the exact enable commands for later.
3. **Bootstrap the spike app** — build the four-page touch-test app and copy the bundle to `/home/cage/spike_app/bundle/` (see `../spike/` and runbook Step 5; pin Flutter >= 3.44 stable).
4. **Manual cage run** — from a local TTY with GNOME's display manager stopped (`sudo systemctl stop gdm`): `WLR_DRM_DEVICES=/dev/dri/cardN cage -- <bundle>`; work through tap / multi-touch / fling / pinch, both backends (runbook Step 6).
5. **`scripts/screen-power-probe.sh`** — from SSH with the cage session env exported: blank/wake cycle and DDC/CI probe (runbook Step 7).
6. **Enable the boot unit** (runbook Step 8) — only after confirming SSH works, because VT switching is disabled under cage. On the GNOME laptop, gdm's claim on the `display-manager.service` alias must be cleared first, or `systemctl enable` refuses:

   ```bash
   sudo systemctl disable gdm3                              # or gdm
   readlink /etc/systemd/system/display-manager.service     # must NOT point at gdm
   sudo rm -f /etc/systemd/system/display-manager.service   # if it still does

   sudo systemctl enable cage@tty1.service
   sudo systemctl set-default graphical.target
   sudo reboot
   ```

   To return the laptop to its desktop later: `sudo systemctl disable cage@tty1.service && sudo systemctl enable gdm3`.

Score the result against the runbook's 13-item pass/fail checklist; on failure, use its fallback ladder (Weston kiosk-shell, `GDK_BACKEND=x11`, labwc, flutter-pi).

## Provisioning evolution (decided 2026-07-30)

Bash scripts are the **spike-phase** tooling only. Once the spike settles the real
configuration (GPU pin, compositor choice, screen-power mechanism, gdm handling),
this directory is ported to **Ansible playbooks** (`appliance/ansible/`) as the
mini-PC provisioning step: inventory with `laptop` / `minipc` host vars,
`cage@.service` as a Jinja2 template (the `WLR_DRM_DEVICES` and ExecStart
differences become per-host variables instead of commented lines), and the
hardening list below as tagged tasks. The laptop can self-provision via
`ansible-playbook --connection=local`. These scripts then retire or remain as the
playbooks' smoke test. Note: Ansible "playbooks" ≠ the spike "runbook"
(`docs/research/flutter-cage-spike.md`).

## Later hardening (appliance polish — optional for the spike, record findings anyway)

- `/etc/default/grub`: `GRUB_TIMEOUT=0`, `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3"` (then `sudo update-grub`) — silent boot.
- `/etc/systemd/logind.conf`: `NAutoVTs=0`, `ReserveVT=0` — no spare getty VTs on the Appliance.
- Kernel parameter `vt.global_cursor_default=0` — hides the blinking VT cursor, but its documented behavior is **UNVERIFIED**; confirm on-device via `/sys/module/vt/parameters/global_cursor_default`.
- Longer term (per the roadmap): revisit Ubuntu Core + Ubuntu Frame once the system design is frozen; production Appliance runs Ubuntu **Server** 24.04 (no desktop environment at all).
