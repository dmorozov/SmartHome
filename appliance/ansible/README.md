# Appliance Ansible playbooks

**The** provisioning path for every Appliance (laptop, mini PC, test
container) — the interim bash script and static systemd files were retired
2026-07-30 once these playbooks were verified against the `../test/`
container (see `../README.md` "Provisioning evolution"). The runbook
(`../../docs/research/flutter-cage-spike.md`) keeps the manual recipe as
reference documentation for what the role automates.

## Target hosts

| Host | Role | Behavior |
|---|---|---|
| `minipc` | Production Appliance (Ryzen AI, Ubuntu Server 24.04, no DE) | Boots straight into the kiosk — gated converge with `kiosk_enable=true` + `kiosk_hardening=true`. **No NPU-specific provisioning yet, deliberately**: the XDNA2 NPU has no viable Linux inference path in 2026 (NVR detector = Hailo-8L M.2, LLM = iGPU per `docs/research/frigate-amd-acceleration.md`); the HWE kernel task already ships the `amdxdna` driver, and an accelerator role gets added with the NVR/voice-LLM roadmap items. |
| `laptop` | Development environment (Intel i9-13980HX, Intel UHD iGPU + NVIDIA RTX 4090 dGPU, Ubuntu Desktop 26.04 LTS) | **Daily-driver guarantee: a plain converge leaves it a normal GNOME laptop** — all kiosk gates default `false` (cage installed but never enabled, gdm untouched). Becomes a kiosk only with the explicit spike-day flags, reversible via `sudo systemctl disable cage@tty1.service && sudo systemctl enable gdm3`. Docker + the hub stack (`hub/compose.yaml`) are still manual — a `hub` role comes later. |
| `test-appliance` | Playbook test bed (disposable Docker container, `../test/`) | Headless; tests all playbook logic over real SSH, excluding kernel/GPU/NPU specifics (`kiosk_hwe_kernel: false`) and anything needing a real seat (cage compositing, touch). Models **Ubuntu 24.04** by default — the mini PC's OS, and the only Appliance with no hardware to converge; `UBUNTU_TAG=26.04 ../test/run.sh rebuild` models the 26.04 dev laptop. Dispose/recreate with `../test/run.sh reset`. |

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

## Panel runtime settings and the HA token

The Panel resolves `HUB`, `HA_URL` and `HA_TOKEN` from the process
environment first (`panel/lib/config/hub_config.dart`), so the appliance
delivers them through `cage@.service` — a moved Hub costs a converge and a
restart, never a Flutter rebuild.

| Var | Default | Delivered as |
|---|---|---|
| `panel_hub_kind` | `fake` | `Environment=HUB=` in the unit |
| `panel_ha_url` | `http://localhost:8123` | `Environment=HA_URL=` in the unit |
| `panel_log_level` | *(empty — no line emitted)* | `Environment=LOG=` in the unit |
| `panel_env_file` | `/etc/smarthome/panel.env` | `EnvironmentFile=-` in the unit |
| `panel_ha_token` | `$PANEL_HA_TOKEN` on the controller | the 0600 file above |

**The token never goes in an `Environment=` line, and never into this repo.**
`systemctl show <unit> -p Environment` hands those values to *any* local
user with no authentication — the system D-Bus policy grants
`Properties.Get`/`GetAll` on `org.freedesktop.systemd1` to
`context="default"`, and polkit defines no action for property reads — and
the unit file itself is `0644`. `EnvironmentFiles=` reports only the path.

Keep the token in `hub/token` (already gitignored) on the controller and
hand it to the converge through the environment:

```sh
cd appliance/ansible
PANEL_HA_TOKEN="$(cat ../../hub/token)" \
  ansible-playbook site.yml -l laptop -e panel_hub_kind=ha
```

`$(cat …)` keeps the value out of shell history, `no_log: true` keeps it out
of ansible's output and `--diff`, and `pipelining = True` (ansible.cfg) keeps
it out of any temp file on the target. Do **not** use `-e panel_ha_token=…`:
extra-vars are visible in `ps`.

A converge with `PANEL_HA_TOKEN` unset leaves an existing token untouched
(`force: false`), so routine converges need no secret at all. Setting
`panel_hub_kind=ha` with no token anywhere fails the play rather than
shipping a Panel that throws at boot and restart-loops behind a dead screen.

Rotating the token: rewrite `hub/token`, re-converge. systemd re-reads
`EnvironmentFile=` at every start, so no `daemon-reload` is involved — but the
`Restart cage` handler is gated `when: kiosk_enable | bool`, and `kiosk_enable`
defaults `false`. So the restart happens only where the kiosk is actually
enabled (the mini PC, or a laptop converge that passes `-e kiosk_enable=true`).
On a default laptop converge the new token lands on disk and nothing is
restarted, which is correct — there is no running compositor to restart — but
it does mean "re-converge" alone is not the whole rotation there.

`panel_log_level` is the same environment-first story with none of the
secrecy (`panel/lib/diagnostics/log.dart`): it is what raises the Panel's log
level on a kiosk you cannot rebuild, which is the whole reason the level
stopped being a build-time define.

```sh
ansible-playbook site.yml -l laptop -e panel_log_level=debug
```

Empty by default, and empty means *no* `Environment=LOG=` line at all — the
Panel keeps its own per-mode default (`info` in release, `debug` otherwise),
so an unset value changes nothing. The `panel.start` line reports
`log_from=environment` once the unit is supplying it. A level is not a
secret, so it belongs in the unit file alongside `HUB`/`HA_URL`, not in the
0600 file that exists only for the token.

`kiosk_app` still points at the spike app; these settings are inert until it
points at the Panel bundle (the spike binary ignores them).

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
# ... spike day. wlr_drm_devices is already pinned in host_vars/laptop.yml
# (the i915 card, by PCI path); check-hybrid-gpu.sh only reports the value,
# it never writes it — re-run it with the touchscreen attached to confirm.
ansible-playbook site.yml -l laptop -e kiosk_enable=true -e kiosk_disable_gdm=true
```

The test container connects as `ubuntu` with passwordless sudo; real hosts
need `--ask-become-pass` or configured sudo.
