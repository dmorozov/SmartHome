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

## `flutter_toolchain_packages` — changed 2026-08-04, not yet converged

`liblzma-dev` was **added** to `flutter_toolchain_packages` in
`group_vars/all.yml`. It is on Flutter's documented Linux-desktop list and it
is on the Hub host, where `flutter build linux --release` succeeds — but it was
never in this variable, so until now a converge of a fresh box produced a
toolchain that was *not* the one measured to work. The owner had installed it
by hand; the role was quietly one package behind the machine it describes.

**Nothing has converged this yet.** The Hub host already has the package, so a
converge there reports `ok` and proves nothing. The real check is the container:

```sh
../test/run.sh reset
ansible-playbook site.yml -l test-appliance
ansible-playbook site.yml -l test-appliance   # expect changed=0
```

`libstdc++-12-dev` was **removed 2026-08-05** after being tested on both
targets. Do not add it back, and do not "correct" it to `-15-dev`:

| | `clang` resolves to | libstdc++ it pulls by itself |
|---|---|---|
| ubuntu:24.04 — mini PC | `clang-18` | `libstdc++-13-dev` |
| ubuntu:26.04 — laptop | `clang-21` | `libstdc++-15-dev` |

`clang` is already in this list and declares the release-matched C++ headers on
both, so a hand-written version can only disagree with the compiler apt
installs — and any single pin is wrong on one of the two targets. Proven at the
real-build level, not just apt's graph: this repo's Panel builds clean inside
`ubuntu:24.04` with no libstdc++ entry (`✓ Built bundle/panel`, linking the
base system's `libstdc++.so.6`).

`liblzma-dev` passed the same test and was **kept** anyway — it is on Flutter's
own documented dependency list, and upstream's contract is worth more than the
few hundred KB our link graph says we could save.
[Ch. 1 §1.7a](../commissioning/01-host-and-network.md) has the full numbers and
the container-harness trap that made the first attempt look like a Dart error.

## Panel runtime settings and the HA token

The Panel resolves `HUB`, `HA_URL`, `HA_TOKEN` and `GO2RTC_URL` from the
process environment first (`panel/lib/config/hub_config.dart`), so the
appliance delivers them through `cage@.service` — a moved Hub costs a converge
and a restart, never a Flutter rebuild.

| Var | Panel's own default | Delivered as |
|---|---|---|
| `panel_hub_kind` | `fake` | `Environment=HUB=` in the unit |
| `panel_ha_url` | `http://localhost:8123` | `Environment=HA_URL=` in the unit |
| `panel_go2rtc_url` | *(none — the Panel has no default)* | `Environment=GO2RTC_URL=` in the unit |
| `panel_log_level` | *(empty — no line emitted)* | `Environment=LOG=` in the unit |
| `panel_env_file` | `/etc/smarthome/panel.env` | `EnvironmentFile=-` in the unit |
| `panel_ha_token` | `$PANEL_HA_TOKEN` on the controller | the 0600 file above |

`panel_go2rtc_url` is where the camera and doorbell Popups fetch live video
from, e.g. `http://127.0.0.1:1984`. It is the only **address** in that table
the Panel has **no built-in default for** — `HA_URL`'s default is earned
because `HUB=fake` gates it, and video has no equivalent gate. (`panel_ha_token`
has no default either, but a default secret is not a thing that could exist.)
So leaving this empty is not "accept the default", it is "the Panel does not
know where go2rtc is", which it says out loud at boot as `GO2RTC_URL=absent`
and again as `popup.go2rtc url=absent`. Nothing breaks: every pin renders and a
camera Popup says the view is unavailable.

It is **not** a secret on this box and belongs on an `Environment=` line:
go2rtc runs unauthenticated here and the camera credentials live in
`hub/go2rtc/go2rtc.yaml`, not in this base address. That is a fact about this
deployment rather than about the setting — go2rtc 1.9 does have
`api.username`/`api.password`, and a URL carrying them would be a secret on an
`Environment=` line, which `systemctl show` hands to any local user with no
authentication. If this box ever gains go2rtc auth, that decision has to be
revisited here.

### What the journal sees of these two addresses

`GO2RTC_URL` and `HA_URL` sit on the same `# NON-SECRETS ONLY` lines in
`cage@.service`, and until 2026-08-04 only the first of them was treated that
way by the Panel. Both now go through one function
(`panel/lib/diagnostics/url_redaction.dart`), which is the point of it being
one function: the previous split is exactly how `GO2RTC_URL` came to be built
up from named parts while `HA_URL` was printed whole on every healthy boot.

What that function does, to both: it writes the line out of a **named list of
parts** — scheme, host and port, and nothing else — rather than taking anything
out of the value, and reports every part it dropped by presence only
(`path=set`, `query=set`, `fragment=set`, `auth=set`). A value with no host it
calls `url=unusable` and does not echo at all. The path was on the published
list until a verifier put a token in one (`http://10.0.0.5:1984/hunter2/`);
`path=set` now says "this is behind a reverse proxy" without saying where.

Read that as a claim about the **address lines** and nothing wider, because
that is all it is:

- `popup.go2rtc`, `hub.configured`, `hub.connecting` and `hub.connected` carry
  no part of either value beyond scheme, host and port. That is the whole
  claim, and it is pinned by `panel/test/url_redaction_test.dart`,
  `boot_test.dart` and `ha_hub_test.dart`.
- `hub.socket_error`, `hub.connect_failed` and `popup.stream_failed` reproduce
  a sentence some **other** process composed — `dart:io` appends `uri = <the
  whole URL>` to an `HttpException`, go2rtc quotes the producer it could not
  dial, and ffmpeg prints the input file it could not open. Those go through
  the same file's best-effort redaction, which finds URLs by their `scheme://`
  start and cuts each to its address. It is best-effort and says in its own
  docstring where it stops (a password with a space in it, a schemeless
  `user:pass@host`, one character of trailing punctuation). Do not read it as
  a guarantee.
- Neither claim covers the **camera** credentials in
  `hub/go2rtc/go2rtc.yaml`, which is a 0600 file and stays one.

So: a credential in `GO2RTC_URL` or `HA_URL` does not reach the journal through
the lines the Panel writes about those settings. A credential anywhere can
still reach it through a sentence a library or a daemon wrote, and the
redaction is a net rather than a wall.

**Setting this now is enough to get a picture, which it was not before.** Two
things that used to stand in the way are done: `api: origin: "*"` landed in
`hub/go2rtc/go2rtc.yaml` on 2026-08-04 (`E8` in the root README's TODO,
**decided** — the reasoning is that access to this system is LAN-only or over
the VPN, so the network boundary is the control), and the Panel has a real
player on **both** targets — MJPEG over HTTP on this appliance, MSE over a
WebSocket on web.

What is still needed is a stream to point at. Each camera must be **one
`streams:` entry with two producers** in `hub/go2rtc/go2rtc.yaml` — the H.264
source plus an `ffmpeg:<name>#video=mjpeg` line — or this appliance gets a
`200 OK` with zero bytes and no error anywhere. See
[Ch. 6 §6.5b](../commissioning/06-panel-and-bindings.md), which has the `curl`
that catches it.

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
