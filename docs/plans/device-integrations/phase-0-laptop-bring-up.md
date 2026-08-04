# Phase 0 — Laptop bring-up

The AMD laptop becomes the Hub host. Everything else in the plan assumes
this phase's end state, so it runs first and completely.

State going in (per `appliance/ansible/inventory.yml`): the inventory still
carries a placeholder address — Ubuntu may or may not be installed. Steps
1–2 are skipped if already true.

## Steps

1. **OS**: Ubuntu **Desktop** 24.04 LTS with the HWE kernel (one install
   serves this plan now and the cage spike later — spike runbook Step 0).
   Verify: `lsb_release -rs` → `24.04`, `uname -r` → `6.11+` (HWE).
2. **Network — wired, pinned**: Ethernet, not Wi-Fi (mDNS and camera
   streams both prefer it; the mini PC will be wired too). Give the laptop
   a **DHCP reservation** on the router. Its address is about to be baked
   into the Panel build, ring-mqtt state, HomeKit pairings, and every
   camera config — it must never drift. Referred to as `<hub-ip>` from
   here on.
3. **SSH**: `sudo apt install -y openssh-server`. From the Mac:
   `ssh <user>@<hub-ip>` works. This is also the moment to put the real
   address into `appliance/ansible/inventory.yml` (`ansible_host:` for
   `laptop`) — the spike will need it anyway.
4. **Power management for an always-on-ish laptop**: lid close must not
   suspend —
   `/etc/systemd/logind.conf`: `HandleLidSwitch=ignore`,
   `HandleLidSwitchExternalPower=ignore`, then
   `sudo systemctl restart systemd-logind`. In GNOME: automatic suspend
   off (Settings → Power). The house's Hub is up only while this machine
   is; that is accepted for the dev phase, but it should at least survive
   a closed lid.
5. **Docker Engine** (native, no Desktop):
   `sudo apt install -y docker.io docker-compose-v2`, then
   `sudo usermod -aG docker $USER` and re-login. Verify:
   `docker run --rm hello-world`, `docker compose version` (v2.x).
6. **Repo**: clone/pull the SmartHome repo on the laptop. Sync with the
   Mac goes through the git remote (push from Mac, pull on laptop) — no
   rsync side-channels, or the two checkouts will drift.
7. *(Optional but recommended while SSH'd in)*: run
   `appliance/scripts/check-hybrid-gpu.sh` and record the
   `WLR_DRM_DEVICES` pin in `appliance/ansible/host_vars/laptop.yml` — it
   costs two minutes now and unblocks spike day later. Not needed for any
   Hub work.

## Done when

- `ssh <user>@<hub-ip>` from the Mac works over Ethernet;
- `docker compose version` succeeds as the login user;
- lid closed ≠ Hub down;
- the repo is checked out on the laptop and `inventory.yml` carries the
  real address.

## As built — 2026-08-03

Executed on the laptop. `<hub-ip>` = **192.168.68.81** for every later phase.

The machine is a **Lenovo Legion 9 16IRX8: Intel Core i9-13980HX, Intel UHD
iGPU (i915), NVIDIA RTX 4090 Laptop dGPU** — *not* the AMD/Radeon laptop the
repo describes in six places. That also dissolves the stated rationale for the
24.04+HWE pin, which came from Strix Point AMD-graphics research
(`docs/research/platform-os-feasibility.md:118`) and applies to the mini PC.

| Step | Result |
|---|---|
| 1 OS | ⚠️ **Open.** Found Ubuntu **25.10** (kernel 6.17.0-35), not 24.04 LTS. 25.10 is **EOL** — `distro-info --supported` lists jammy/noble/resolute/stonking, not questing. Decision: upgrade to **26.04 LTS**; `do-release-upgrade` confirms it is offered. Not yet run. |
| 2 Network | ⚠️ **Deliberate deviation.** Wi-Fi (`wlp164s0`, AX210) at 192.168.68.81/22, gw .68.1. Wired `enp162s0` (Killer E3000 2.5GbE) is cabled-down. **No DHCP reservation** — accepted knowingly, see below. |
| 3 SSH | ✅ openssh-server 10.0p1 installed, enabled, `SSH-2.0-OpenSSH_10.0p2` answering on 192.168.68.81:22. ufw is **inactive**, so no rule needed. `~/.ssh/authorized_keys` is empty — key login needs the Mac's pubkey; password auth works. `inventory.yml` carries the real address. |
| 4 Power | ⚠️ **Configured, not yet verified.** Drop-in `/etc/systemd/logind.conf.d/10-smarthome-hub.conf` sets `HandleLidSwitch`/`ExternalPower`/`Docked=ignore`. `systemd-logind` was **not** restarted (live GNOME session on a work laptop); it applies at the next boot, which the 26.04 upgrade forces. GNOME AC auto-suspend set to `nothing`. **Battery auto-suspend left ON at 900 s** — unplug the power and the Hub dies 15 min later. |
| 5 Docker | ✅ Already satisfied, ahead of the plan: docker-ce **29.7.1** + compose **v5.4.0** (plan says `docker.io`/v2.x), login user already in `docker`, `hello-world` runs unprivileged, docker enabled at boot. |
| 6 Repo | ✅ `/home/dmorozov/Work/SmartHome`, remote `git@github.com:dmorozov/SmartHome.git`, level with `origin/main` (0 ahead, 0 behind). |
| 7 GPU pin | ✅ Recorded in `host_vars/laptop.yml` as `/dev/dri/by-path/pci-0000:00:02.0-card` (the i915 iGPU) — pinned by stable PCI path, since `cardN` numbering is not boot-stable (observed card1=nvidia, card2=i915). `check-hybrid-gpu.sh` only knows `amdgpu`, so its verdict on this box is an artefact; see the caveat in `host_vars/laptop.yml`. |

### Why the unreserved Wi-Fi lease was accepted

Step 2's "must never drift" is true for **one** of the four things it names.
Traced through the code:

- ✅ **Panel build** — as found at the time of this phase, `panel/lib/main.dart`
  read `HA_URL` via `String.fromEnvironment`, a *compile-time* const. An
  address change meant a `flutter build` rerun and a bundle redeploy, and
  phase 4 planned a second baked constant (`GO2RTC_URL`). **This was the
  whole exposure** — and it has since been fixed, below.
- ❌ **ring-mqtt state** — `config.example.json` points at compose DNS
  (`mqtt://ring:…@mosquitto:1883`); the persisted state is an account-bound
  Ring OAuth refresh token. No host-IP content.
- ❌ **HomeKit pairings** — keys live in `.storage`; `homekit_controller`
  re-resolves the Ecobee over mDNS. A hub IP change on the same subnet does
  not invalidate the pairing.
- ❌ **Camera configs** — those carry the *cameras'* addresses. `go2rtc` has no
  `webrtc: candidates:` block; host networking auto-detects.

`hub/README.md:84-91` is direct counter-evidence to the drift panic: the stack
is designed to move to a different machine unchanged.

So the residual risk of an unreserved lease was **one Panel rebuild**, not a
re-pairing cliff — and that has now been removed. HA cannot own this setting
(the Panel needs the address before it can reach HA to ask for it), so it
became a Panel-side runtime lookup instead:

`panel/lib/config/hub_config.dart` resolves `HUB`, `HA_URL` and `HA_TOKEN`
**environment first**, then the build's `--dart-define`, then built-in
defaults; `config/runtime_env.dart` is a conditional export so the web build,
which has no process environment, is unaffected. `panel/lib/boot.dart` keeps
its "reads no files and no environment" contract — the resolver is pure and
`main()` is the only thing that touches the environment. Boot logs origins
only, never the token:

```
[panel] I hub.config HUB=build HA_URL=environment HA_TOKEN=environment env=available
```

**Caveat — web is the exception.** `-d chrome` has no process environment, so
there `--dart-define` remains the only route; `env=unavailable` in the line
above is how a web run says an `HA_URL=…` prefix was discarded.

Net effect: a drifted lease costs an environment change and a Panel restart.
**Nothing needs rebuilding, and no device needs re-pairing.** The delivery
half on the appliance — `Environment=HA_URL=` in `cage@.service` — is
**not wired yet** (open item 7); until then the Panel is started by hand or
by `flutter run -d linux`, both of which already honour the environment.

**The real re-pairing cliff is elsewhere**: losing `hub/ha-config/.storage` or
`hub/ring-mqtt-data/` forces the Ecobee physical re-pair (one free HomeKit
slot, per D0a), Ring 2FA re-auth, and Wyze per-camera credentials. Neither
path has a backup step anywhere in phases 0–6.

A `.local` name is not a substitute today: mDNS resolves this host to
link-local IPv6 only (`fe80::…`) and `resolvectl mdns` is off on every link.

### Open items this phase surfaced

1. **Run `do-release-upgrade`** to 26.04 LTS (step 1). Do it with SSH already
   up, as it now is.
2. `appliance/ansible/roles/kiosk/tasks/main.yml:12` hardcodes
   `linux-generic-hwe-24.04`. Verified a **no-op** on 25.10 (same 6.17 kernel,
   same `linux-meta` source) — but the name will **not resolve on 26.04**, and
   the role has no `ansible_distribution` gate. Fix before the first converge
   after the upgrade. Do *not* simply default it to `linux-generic`: on 24.04
   that silently downgrades 7.0 HWE → 6.8 GA.
3. `appliance/test/Dockerfile` is `FROM ubuntu:24.04`, so the test bed models
   a different OS than the Hub host.
4. Phase 1 gaps with no owner: `mosquitto-clients` is absent (its Done-when
   check needs it), and `hub/mosquitto/data|log/` do not exist after clone.
5. Correct the AMD→Intel description of this laptop across `README.md:72`,
   `spike/README.md:12`, `appliance/ansible/README.md:15`,
   `docs/research/flutter-cage-spike.md:11`.
6. Verify the lid setting after the reboot:
   `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch`
7. **Wire the Panel's settings into the appliance.** The resolver is done,
   its delivery is not: `roles/kiosk/templates/cage@.service.j2` sets only
   `WLR_DRM_DEVICES`/`WLR_LIBINPUT_NO_DEVICES`, and `kiosk_app` still points
   at the spike app. Needs `HUB`/`HA_URL` as `Environment=` lines plus vars.
   **Not the token**: `Environment=` lands in a world-readable unit file and
   `systemctl show` echoes it to any local user — use `EnvironmentFile=` at
   mode 0600 owned by `kiosk_user`, with `no_log: true` on the ansible task.
   That is a strictly narrower channel than the previous baked-in constant,
   which is the bar to clear.
8. `LOG` is still build-time only (`log.dart` uses `String.fromEnvironment`)
   while `HUB`/`HA_URL`/`HA_TOKEN` are now environment-first. Raising the log
   level on a wall panel you cannot rebuild is exactly the case the change
   was made for — either route `LOG` through the same resolver or say
   explicitly why not.
