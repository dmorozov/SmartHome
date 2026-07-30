# Appliance Ansible playbooks

**The** provisioning path for every Appliance (laptop, mini PC, test
container) — the interim bash script and static systemd files were retired
2026-07-30 once these playbooks were verified against the `../test/`
container (see `../README.md` "Provisioning evolution"). The runbook
(`../../docs/research/flutter-cage-spike.md`) keeps the manual recipe as
reference documentation for what the role automates.

## Layout

- `site.yml` — the one play: role `kiosk` against any Appliance
- `inventory.yml` — `laptop` (dev), `minipc` (production, placeholder),
  `test-appliance` (the Docker container)
- `group_vars/all.yml` — package sets, kiosk user/app/tty, and the **gates**
- `roles/kiosk/` — packages, `cage` user, PAM, templated `cage@.service`;
  gated blocks for gdm clearing, boot-enable, and hardening

## The gates (all default false — a plain converge enables nothing)

| Var | What it unlocks |
|---|---|
| `kiosk_enable` | `systemctl enable cage@<tty>` + `graphical.target` default — the point of no return on a console-only box; confirm SSH first |
| `kiosk_disable_gdm` | Laptop only: disable gdm and clear its `display-manager.service` alias so the kiosk unit can claim it |
| `kiosk_hardening` | logind `NAutoVTs=0`/`ReserveVT=0` (takes effect at next reboot); grub silent boot (skipped automatically where grub is absent, e.g. containers). `vt.global_cursor_default=0` is deliberately NOT managed until verified on-device (runbook flags it UNVERIFIED) |

Per-host settings (e.g. the mandatory `wlr_drm_devices` GPU pin on the
laptop) live in `host_vars/`.

## Usage

```sh
cd appliance/ansible

# Test cycle against a fresh disposable container:
../test/run.sh reset
ansible-playbook site.yml -l test-appliance
ansible-playbook site.yml -l test-appliance   # idempotence: expect changed=0

# --check works EXCEPT against a never-converged box with an empty apt cache
# (the apt module cannot update the cache in check mode → "No package
# matching 'cage'"). Real hosts have a populated cache; on a fresh container
# run one real converge (or apt-get update) first.

# Dev laptop (once Ubuntu is on it and its address is set in inventory.yml):
ansible-playbook site.yml -l laptop
# ... spike day, after check-hybrid-gpu.sh sets wlr_drm_devices:
ansible-playbook site.yml -l laptop -e kiosk_enable=true -e kiosk_disable_gdm=true
```

The test container connects as `ubuntu` with passwordless sudo; real hosts
need `--ask-become-pass` or configured sudo.
