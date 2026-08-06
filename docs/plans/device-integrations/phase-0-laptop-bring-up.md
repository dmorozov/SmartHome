# Phase 0 — Laptop bring-up

The Intel dev laptop becomes the Hub host. Everything else in the plan assumes
this phase's end state, so it runs first and completely.

State going in (per `appliance/ansible/inventory.yml`): the inventory still
carries a placeholder address — Ubuntu may or may not be installed. Steps
1–2 are skipped if already true.

## Steps

1. **OS**: Ubuntu **Desktop 26.04 LTS** (*resolute*) on its 7.x kernel — one
   install serves this plan now and the cage spike later (spike runbook
   Step 0). Verify: `lsb_release -rs` → `26.04`, `uname -r` → `7.0…`.
   **This step originally read "24.04 LTS with the HWE kernel".** That pin
   was never about this machine: it came from Strix Point AMD-graphics
   research (`docs/research/platform-os-feasibility.md:118`), which is about
   the **mini PC**'s Radeon iGPU and its need for the newest kernel 24.04
   could offer. This laptop is Intel `i915` (see the as-built below), so the
   rationale does not transfer, and 26.04's own kernel is newer than 24.04's
   HWE stack anyway. The mini PC keeps 24.04 Server + HWE per ADR-0001; only
   the Hub-host laptop moves. The as-built table records the upgrade that
   was actually performed.
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
repo describes in twelve files. That also dissolves the stated rationale for the
24.04+HWE pin, which came from Strix Point AMD-graphics research
(`docs/research/platform-os-feasibility.md:118`) and applies to the mini PC.

| Step | Result |
|---|---|
| 1 OS | ✅ **Done — upgraded 2026-08-03.** Found Ubuntu **25.10** (kernel 6.17.0-35), which is **EOL** (`distro-info --supported` lists jammy/noble/resolute/stonking, not questing). `do-release-upgrade` was run and completed; the host now reports Ubuntu **26.04 LTS** (*resolute*), kernel **7.0.0-28-generic**, systemd **259**. Open item 1 is closed. The upgrade did leave a mess in `/etc/apt/sources.list.d/` — open items 9 and 10. |
| 2 Network | ⚠️ **Deliberate deviation.** Wi-Fi (`wlp164s0`, AX210) at 192.168.68.81/22, gw .68.1. Wired `enp162s0` (Killer E3000 2.5GbE) is cabled-down. **No DHCP reservation** — accepted knowingly, see below. |
| 3 SSH | ✅ openssh-server 10.0p1 installed, enabled, `SSH-2.0-OpenSSH_10.0p2` answering on 192.168.68.81:22. ufw is **inactive**, so no rule needed. `~/.ssh/authorized_keys` is empty — key login needs the Mac's pubkey; password auth works. `inventory.yml` carries the real address. |
| 4 Power | ✅ **Configured and verified 2026-08-03.** Drop-in `/etc/systemd/logind.conf.d/10-smarthome-hub.conf` sets `HandleLidSwitch`/`ExternalPower`/`Docked=ignore`. `systemd-logind` was never restarted by hand (live GNOME session on a work laptop) — the 26.04 upgrade's reboot did it, and the settings are now **live**: `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager …` returns `"ignore"` for `HandleLidSwitch`, `HandleLidSwitchExternalPower` **and** `HandleLidSwitchDocked` (`IdleAction` also reads `"ignore"`). Open item 6 is closed. GNOME AC auto-suspend set to `nothing`. ⚠️ **Battery auto-suspend is still ON at 900 s** — unplug the power and the Hub still dies 15 min later. |
| 5 Docker | ✅ **Engine works**, ahead of the plan: docker-ce **29.7.1** + compose **v5.4.0** (plan says `docker.io`/v2.x), login user already in `docker`, `hello-world` runs unprivileged, docker enabled at boot. ⚠️ **But since the 26.04 upgrade Docker receives no updates at all**: `do-release-upgrade` wrote `Enabled: no` into `/etc/apt/sources.list.d/docker.sources` (which still reads `Suites: questing`), so the installed `…~ubuntu.25.10~questing` builds have no repository behind them — open item 9. |
| 6 Repo | ✅ `/home/dmorozov/Work/SmartHome`, remote `git@github.com:dmorozov/SmartHome.git`, level with `origin/main` (0 ahead, 0 behind). |
| 7 GPU pin | ✅ Recorded in `host_vars/laptop.yml` as `/dev/dri/by-path/pci-0000:00:02.0-card` (the i915 iGPU) — pinned by stable PCI path, since `cardN` follows driver probe order and is not guaranteed stable across boots (here the dGPU enumerates first: card1=nvidia, card2=i915, so "the iGPU is the low card" cannot be assumed either). `check-hybrid-gpu.sh` **now recognises `i915`** and prints exactly this by-path pin (fixed 2026-08-03, open item 5); what it still cannot determine with nothing plugged in is which card owns the physical HDMI port — see the caveat in `host_vars/laptop.yml`. |

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
[panel] I hub.config HUB=build HA_URL=environment HA_TOKEN=environment GO2RTC_URL=absent env=available
```

**A fourth setting joined them 2026-08-04**: `GO2RTC_URL`, the address of the
go2rtc daemon the camera Popups play from. It resolves through the same
`resolveHubConfig` rather than through a reader of its own — unlike `LOG`
(item 8), whose separate path is earned by *not* being an address. `GO2RTC_URL`
is the same species of fact as `HA_URL`: a daemon on the Hub box whose
staleness is indistinguishable from its being down, which is exactly what the
`hub.config` line exists to disambiguate. It has **no built-in default**,
because `defaultHaUrl` is earned by `HUB=fake` gating it and video has no such
gate. See `panel/README.md`, "Live video in the Popup".

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

1. ✅ **CLOSED 2026-08-03.** ~~**Run `do-release-upgrade`** to 26.04 LTS
   (step 1). Do it with SSH already up, as it now is.~~ Run and completed:
   the host is Ubuntu 26.04 LTS (resolute), kernel 7.0.0-28-generic,
   systemd 259 (see the `1 OS` row). Two things it left behind live on as
   items 9 and 10.
2. ✅ **CLOSED 2026-08-03.** ~~`appliance/ansible/roles/kiosk/tasks/main.yml:12`
   hardcodes `linux-generic-hwe-24.04`, and the role has no
   `ansible_distribution` gate.~~ Fixed as prescribed below:
   `kiosk_hwe_kernel_packages` in `group_vars/all.yml` maps
   `24.04 → linux-generic-hwe-24.04` and `26.04 → linux-generic-hwe-26.04`, the
   role asserts rather than guesses on an unmapped release, and an
   `apt-mark manual` task claims the meta-package so the removable shim is no
   longer its only parent. The finding that survives as *host* work is the
   `apt-mark`: until a fixed converge runs (or you run it by hand),
   `apt-mark showauto linux-generic-hwe-26.04` still names it, and
   `apt-get purge linux-generic-hwe-24.04` would orphan the running kernel
   stack. Do not accept Ubuntu's "safely removed" advice before then.
   The original reasoning, kept because it is the record of what was measured:
   **Correction, measured on 26.04 (2026-08-03):** the name *does* resolve —
   26.04 ships it as a **transitional** package (`Source: linux-meta`,
   `Depends: linux-generic-hwe-26.04`, "Transitional package for upgrades…
   can be safely removed"), installed here at 7.0.0-28.28, so the converge is a
   silent no-op rather than a failure. It is still wrong to keep: Ubuntu
   carries such shims exactly one LTS cycle (`linux-generic-hwe-22.04` is
   already **absent** from 26.04), so the hardcode breaks on 28.04 and
   meanwhile pins a package the archive calls removable. The `linux-generic`
   warning **stands, re-verified**: on `noble-updates`/amd64 `linux-generic` →
   `linux-image-generic (= 6.8.0-136.136)` while `linux-generic-hwe-24.04` →
   `linux-image-generic-hwe-24.04 (= 7.0.0-28.28~24.04.1)`. Fix: resolve the
   name from an `ansible_distribution_version`-keyed map in
   `group_vars/all.yml`, assert on an unmapped release, and `apt-mark manual`
   the meta — after the upgrade this host had `linux-generic-hwe-26.04` marked
   *auto*, parented only by the removable shim.
3. ✅ **CLOSED 2026-08-03.** ~~`appliance/test/Dockerfile` is `FROM ubuntu:24.04`,
   so the test bed models a different OS than the Hub host.~~ The premise was
   mis-framed: the container has never modelled the Hub host (it cannot run the
   hub stack at all), it models the **Appliance under provisioning** — and that
   is still the mini PC on 24.04 LTS per ADR-0001, an unpurchased machine for
   which this container is the *only* pre-flight. Bumping the base would have
   traded that away to simulate a laptop we already own and can converge
   directly. Resolved by parameterising instead: `ARG UBUNTU_TAG=24.04`, so
   `UBUNTU_TAG=26.04 ./run.sh rebuild` is one env var away and the default
   still guards the mini PC. `ubuntu:26.04` is confirmed to exist (amd64, same
   digest as the `resolute` tag), and every package the Dockerfile and
   `group_vars/all.yml` install resolves on both releases unchanged.
4. ~~Phase 1 gaps with no owner~~ — **both turned out smaller than written;
   closed by a repo edit, see phase 1 §1e.**
   - `mosquitto-clients` is indeed absent on the host, but the Done-when check
     never needed it: `eclipse-mosquitto:2` ships `mosquitto_sub`/`mosquitto_pub`
     in `/usr/bin`, so the check runs as
     `docker run --rm --network host eclipse-mosquitto:2 mosquitto_sub -h <hub-ip> …`
     with zero host packages — and keeps working on the mini PC. A host install
     (`resolute/universe`, 2.0.22) is optional convenience.
   - `hub/mosquitto/data|log/` really do not exist after clone, and they are the
     only two missing bind sources in `hub/compose.yaml`. Compose sets
     `CreateMountpoint`, so `dockerd` would create them **root-owned inside the
     git tree** — but that never broke the broker: the image entrypoint runs as
     root and does `chown -R 1883:1883 /mosquitto/data` before starting
     mosquitto, and `/mosquitto/log` is never written (`log_dest stdout`).
     Fixed for hygiene by tracking a `.gitkeep` in each; `hub/.gitignore` had to
     move to the `dir/*` + negation form, because git does not descend into an
     excluded directory.
   - Found while verifying the above, and **worth more than either**: phase 1's
     passwd bootstrap chowns the file to 1883 *before* the
     `docker exec … mosquitto_passwd` calls, but those run as root and rewrite
     the file via mkstemp+rename without preserving ownership — so the restart
     at the end of the recipe would have died on `Error: Unable to open pwfile`.
     The chown now repeats after them, and `passwd.backup.*` (hashed) is
     gitignored.
5. ✅ **CLOSED 2026-08-03.** All twelve files corrected, and both non-cosmetic
   consequences dealt with: `check-hybrid-gpu.sh` now recognises `i915`/`xe`
   alongside `amdgpu`/`radeon` and prints
   `WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card` on this box (it
   previously fell through the mitigation branch and printed **no pin at all**),
   and the void mini-PC transfer argument is replaced everywhere by the honest
   one — only the driver-independent half (cage/wlroots, Flutter GTK, libinput,
   systemd/PAM) transfers, so the mini PC needs a full §4 re-run rather than a
   regression check. `host_vars/laptop.yml`'s caveat and connector inventory
   were corrected in the same pass and now match sysfs. The scope, kept as the
   record of what was found:
   ~~Correct the AMD→Intel description of this laptop.~~ Full grep (AMD, Radeon,
   Ryzen, amdgpu, Strix, iGPU, hybrid) found it in **twelve** files, not four:
   `CONTEXT.md`, `README.md` (63, 64, 72), `appliance/README.md` (3, 18, 21),
   `appliance/ansible/README.md:15`, `appliance/ansible/group_vars/all.yml:9`,
   `appliance/scripts/check-hybrid-gpu.sh`, `spike/README.md` (12, 19, 30-31),
   `spike/bootstrap.sh:169`, `docs/research/flutter-cage-spike.md` (11-15,
   186, 208, 227-241), `docs/adr/0008:17`,
   `docs/plans/device-integrations/README.md` (5, 40), and this file's line 3.
   Mini-PC, ADR-0001 and `frigate-amd-acceleration.md` mentions are CORRECT —
   leave them. Two hits are not cosmetic: **(a)** `check-hybrid-gpu.sh` matches
   the literal string `amdgpu`, so on this box it takes the mitigation branch
   *and prints no `WLR_DRM_DEVICES` pin at all* — verified by running it; and
   **(b)** `README.md:63` / runbook "Spike host" rest the mini-PC transfer
   argument on a shared `amdgpu` Mesa path that does not exist. Only the
   driver-independent half (cage/wlroots, Flutter GTK, libinput, systemd/PAM)
   transfers, so the mini PC needs a full §4 re-run, not a regression check.
   Also update `host_vars/laptop.yml`: its script caveat and its connector
   inventory (card1/nvidia = HDMI-A-1, card2/i915 = HDMI-A-2..5) are wrong.
6. ✅ **CLOSED 2026-08-03.** ~~Verify the lid setting after the reboot:
   `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch`~~
   Verified after the 26.04 reboot: `HandleLidSwitch`,
   `HandleLidSwitchExternalPower` and `HandleLidSwitchDocked` all read
   `"ignore"`, as does `IdleAction`. A closed lid no longer takes the Hub
   down. **Still open by design** (tracked in the `4 Power` row, not as its
   own item): GNOME *battery* auto-suspend remains ON at 900 s, so pulling
   the power still kills the Hub 15 minutes later.
7. ~~**Wire the Panel's settings into the appliance.**~~ **Done.**
   `roles/kiosk/templates/cage@.service.j2` now carries `Environment=HUB=`
   and `Environment=HA_URL=` from `panel_hub_kind`/`panel_ha_url`
   (`group_vars/all.yml`). **Both default to empty, and that is load-bearing**
   — the first draft defaulted them to `fake` + `http://localhost:8123` on the
   reasoning that those are `hub_config.dart`'s own defaults, so a converge
   would change nothing. That was wrong: resolution is environment-*first*, so
   an `Environment=HUB=fake` line would have beaten a bundle built with
   `--dart-define=HUB=ha` and silently forced it onto the fake Hub. Empty
   emits no `Environment=` line at all, which is what actually makes "a
   converge changes nothing until someone asks it to" true. `panel_log_level`
   follows the same rule for the same reason.

   **The token took the narrower channel, as required**:
   `EnvironmentFile=-{{ panel_env_file }}` (`/etc/smarthome/panel.env`, mode
   0600 owned by `kiosk_user`), written by a `no_log: true` task from
   `$PANEL_HA_TOKEN` on the *controller* — the value is never in this repo,
   never in an `Environment=` line `systemctl show` would echo to any local
   user, and never in `ps` (no `-e panel_ha_token=…`). `force: false` means a
   converge without the variable exported leaves an existing token alone. The
   leading `-` keeps a tokenless `HUB=fake` box from restart-looping behind a
   dead screen; the genuinely broken combination — `HUB=ha` with no token
   anywhere — fails the *converge* instead, via an assert that runs before
   the unit is ever written. See `appliance/ansible/README.md`.

   **Extended 2026-08-04** by `panel_go2rtc_url` → `Environment=GO2RTC_URL=`,
   under the same empty-by-default rule and for one reason more: the Panel has
   no built-in default for that setting at all, so a value in `group_vars`
   would not be re-stating a default, it would be inventing the setting. It is
   not a secret — go2rtc is unauthenticated here and the camera credentials
   live in `hub/go2rtc/go2rtc.yaml`, not in the base address — so it rides an
   `Environment=` line and needs none of the `EnvironmentFile=` machinery. The
   role's asserts needed nothing: there is no `GO2RTC_URL`-shaped equivalent
   of "`HUB=ha` requires a token", because an absent go2rtc costs one Popup
   body, not the wall.

   Still open by design, and deliberately decoupled: `kiosk_app` points at
   the spike bundle, which ignores all of this. The wiring goes live
   unchanged the day it points at the Panel bundle.
8. ~~`LOG` is still build-time only.~~ **Done.**
   `panel/lib/diagnostics/log.dart` resolves the level environment-first
   through `Log.applyLevel(environment)`, and `main()` calls it *before* the
   first line is emitted — otherwise `LOG=off` could not silence the very
   boot lines it is asked to silence. `log_from=environment|build|default`
   on `panel.start` names the origin that won.

   Deliberately a **separate pure resolver, not a field on `HubConfig`**:
   `LOG` is not a Hub setting, nothing hands it to `bootPanel`, and putting
   it on the `hub.config` line would blunt that line's one job — telling a
   stale address from a dead Hub. There is no import cycle to worry about
   (`log.dart` imports only `flutter/foundation`, and nothing under
   `config/` logs), but there *is* a contract to protect: `Log` is reachable
   from `bootPanel`, whose contract is that it reads no files and no
   environment. A static initializer calling `Platform.environment` would
   break that transitively, at whichever arbitrary moment the first log line
   happened to be emitted — and `flutter_test_config.dart` assigns
   `Log.level` before any read, so the environment path would silently never
   run under test. So the environment is **passed in**, exactly as
   `resolveHubConfig` takes it, and `main()` remains the only thing in the
   Panel that touches the environment. Web is the same exception as
   everywhere else: no process environment, so `--dart-define=LOG=` stays
   the only route there.

   Delivered by the same converge as item 7: `panel_log_level` (empty by
   default, so an unset value emits no `Environment=LOG=` line and changes
   nothing) — a level is not a secret, so it rides in the unit file next to
   `HUB`/`HA_URL` rather than in the 0600 file the token needs.
9. ✅ **CLOSED 2026-08-03 — fixed and verified on the host.** `docker.sources`
   now reads `Suites: resolute` with no `Enabled:` line, and all six packages
   were moved onto the 26.04 builds:
   `docker-ce 5:29.7.1-1~ubuntu.26.04~resolute`, `docker-ce-cli` likewise,
   `containerd.io 2.2.6`, `docker-buildx-plugin 0.36.0`,
   `docker-compose-plugin 5.4.0`, `docker-ce-rootless-extras`.
   `apt-cache policy docker-ce` now shows a 500-priority candidate from
   `download.docker.com … resolute/stable` instead of only
   `/var/lib/dpkg/status`. The phase-0 step-5 Done-when check was re-run after
   the daemon restart and still passes: Docker 29.7.1, Compose v5.4.0,
   `docker run --rm hello-world` unprivileged. Done before phase 1 existed, as
   the analysis below required. **The caveat stands**: this restored
   *visibility*, not automation — `unattended-upgrades` allows only
   `Ubuntu:resolute{,-security}` origins, so Docker CVEs still need a
   deliberate `apt upgrade`. The finding, kept as the record:
   ~~**Every third-party apt source went dark in the upgrade — and one of
   them is ours.**~~ `do-release-upgrade` did not merely leave third-party
   suites on `questing`: it wrote `Enabled: no` into every `.sources` file
   under `/etc/apt/sources.list.d/` and renamed the `.list` ones to
   `*.list.disabled`. The only live apt source on the Hub host is now
   `ubuntu.sources` (resolute) — `apt-get -s upgrade` reports 0 packages
   and `apt-cache policy docker-ce` shows no repository at all, only
   `/var/lib/dpkg/status`. **Exactly one of those files is this project's
   business**: `docker.sources` (`Suites: questing` *and* `Enabled: no`).
   docker-ce is frozen at `5:29.7.1-1~ubuntu.25.10~questing` with no
   security path, and under ADR-0008 the whole Hub *is* Docker — phase 1
   puts Mosquitto and Home Assistant on the LAN under host networking.
   Docker does publish for 26.04 and the pool is real, not an empty
   `Release`: `dists/resolute/stable/binary-amd64/Packages.gz` carries 15
   `docker-ce` versions topping out at `5:29.7.1-1~ubuntu.26.04~resolute`
   — the same upstream 29.7.1 already installed, rebuilt for 26.04 — plus
   `docker-ce-cli` 29.7.1, `containerd.io` 2.2.6, `docker-buildx-plugin`
   0.36.0 and `docker-compose-plugin` 5.4.0. Fix is two lines in
   `docker.sources` (`questing` → `resolute`, drop `Enabled: no`), then
   `apt update` and `apt install --only-upgrade` the six docker packages.
   That restarts `dockerd`, so do it **before** the phase-1 stack exists,
   not after — and note it restores *visibility* only:
   `unattended-upgrades` allows origins `Ubuntu:resolute{,-security}`
   only, so Docker CVEs still need a deliberate `apt upgrade`. Nothing
   else about the upgrade is half-done: `dpkg --audit` is clean, no
   package is half-configured, `apt-get -s autoremove` has nothing to
   remove, there is no `/run/reboot-required` (the host booted 22:54,
   after the upgrade finished 22:51), and the only `/etc` leftovers are
   `/etc/default/grub.ucf-dist` (ucf correctly kept the
   grub-customizer-modified local file) and a 2025-dated
   `/etc/ca-certificates.conf.dpkg-old`. All 44 `?obsolete` packages are
   third-party or superseded kernels/libs; re-enabling `docker.sources`
   clears six of them.
10. **Scope fence for item 9 — do not "finish the job" on the other
    sources.** `graphics-drivers`, `grub-customizer`, `globalprotect`,
    Chrome, `kubernetes`, `antigravity`, `windsurf` and
    `nvidia-container-toolkit` are the owner's personal/work tooling on a
    daily-driver laptop; this project touches none of them. Two are worth
    *knowing* about: (a) **the NVIDIA driver is not at risk** —
    `nvidia-driver-595-open` 595.84 is installed as
    `595.84-0ubuntu0.26.04.1` from `resolute-updates/restricted` and
    `resolute-security/restricted`, i.e. the Ubuntu archive, not the PPA,
    so the dark PPA supplies nothing and re-pointing it at `resolute`
    would be the risky move (a driver swap under a live GNOME session on
    a hybrid-GPU box), not leaving it disabled; (b) **no phase 0–6 needs
    GPU passthrough into Docker** — `nvidia-container-toolkit` 1.19.1 is
    installed and `/etc/docker/daemon.json` registers an `nvidia` runtime
    that `docker info` confirms, but `hub/compose.yaml` passes no
    `devices:` and no `/dev/dri` to any service, and go2rtc 1.9.10
    restreams RTSP without transcoding. Frigate — the only GPU consumer
    the repo describes — is under README's "Future roadmap (explicitly
    deferred)", is absent from the phase 0–6 table, and targets the *mini
    PC* with a **Hailo-8L** detector and iGPU **VAAPI** decode, never
    CUDA. `.distUpgrade` and `.list.disabled` files are inert (apt reads
    only `*.list`/`*.sources`); leave them as the pre-upgrade record.
11. ✅ **DECIDED AND APPLIED 2026-08-03: pinned exactly, to
    `eclipse-mosquitto:2.1.2-alpine`.** Surfaced while closing item 4, decided
    by the user, and the facts the audit had left unmeasured were measured
    before acting:
    - `docker image inspect eclipse-mosquitto:2` →
      `org.opencontainers.image.version = 2.1.2`. The floating tag *had*
      already moved to the 2.1 line, as suspected.
    - **There is no unsuffixed `2.1.2` tag.** Docker Hub publishes the whole
      2.1 line only as `-alpine` (`2.1.2-alpine`, `2.1-alpine`); the
      unsuffixed `2`, `2.0`, `2.0.22` tags are the 2.0 line plus a `2` that
      now points at 2.1.2. Pinning the obvious-looking `2.1.2` would not have
      resolved at all.
    - Digest-checked rather than assumed: `:2` and `:2.1.2-alpine` are the
      **same** amd64 image (`sha256:6dba0f1b2795…`), so this pin changes
      nothing about what runs — it only stops it moving. `2.0.22` is a
      genuinely different image (`sha256:54c90ecc7864…`).
    - Consequence deliberately accepted: the config keeps `password_file` +
      `allow_anonymous`, which 2.1 deprecates, so expect a deprecation line in
      the broker log. The plugin migration (`mosquitto_password_file` /
      `mosquitto_acl_file`) becomes its own dated task before any 3.0 move,
      rather than a surprise on a tag bump.
    - **Still open, the other half:** `zigbee2mqtt:2` (compose line ~75) is
      floating in exactly the same way. Left alone on purpose — Z2M is not
      deployed until the coordinator arrives, and its own comment already says
      to pin at first deploy.

    The original finding, kept as the record:
    - `hub/compose.yaml:59` pins `eclipse-mosquitto:2` — a *major* tag, so the
      image the Hub runs changes under it whenever upstream pushes. Every
      other service is pinned tighter: `home-assistant:2026.7`,
      `ring-mqtt:5.9.3`, `go2rtc:1.9.10`. One exception worth noting so this
      does not get "fixed" by halves: `zigbee2mqtt:2` (line 75) is floating in
      exactly the same way, but Z2M is not deployed until the Zigbee
      coordinator arrives, so it is the less urgent half of the same question.
    - The audit reports that `:2` has already moved to **2.1.x**, and that
      mosquitto 2.1 **deprecates `password_file` and `allow_anonymous`** — the
      two directives `hub/mosquitto/config/mosquitto.conf` and phase 1 §1c
      just standardised on (decision D4). Not re-measured here (no image was
      pulled): confirm against the 2.1 release notes and `docker image
      inspect` before acting.
    - Why it matters now rather than later: a deprecation warning today is a
      removal on some later `docker compose pull`, and the failure mode is the
      broker starting with **auth silently not configured the way the config
      says**, on a port published to the LAN.
    - The options, for whoever decides: (a) pin exact (`eclipse-mosquitto:2.0.x`)
      and schedule the 2.1 config migration as its own task; (b) move to 2.1
      now and rewrite §1c plus the config comment onto whatever 2.1 replaces
      those directives with; (c) leave `:2` floating and accept that the
      broker's auth config can go stale without a repo change. Whichever wins,
      the phase-1 §1c recipe and `mosquitto.conf`'s comment block have to move
      with it — they document the directive names in three places.

12. **The upgrade silently answered the spike runbook's own open question about
    the cage base — SPIKE-DAY WORK, recorded not acted on (user decision
    2026-08-03).** `docs/research/flutter-cage-spike.md` line ~708 asks
    verbatim whether to stay on noble's cage snapshot, move to 26.04, or build
    from source. 26.04 decided it by fiat: `apt-cache policy cage` now offers
    **0.2.1-1**, `Depends: libwlroots-0.19`, against the **0.1.5+20240127 /
    wlroots 0.17** the entire runbook was researched on. Nothing here blocks
    phases 1–6 (the Hub does not use cage), but re-verify before spike day:
    - Whether wlroots 0.19 implements **wlr-output-power-management**. If it
      does, "cage has no output power management, so `wlopm` does not work" is
      obsolete and the whole screen-power priority ladder in `README.md`
      (wlr-randr trick → `ddcutil` → compositor swap → Flutter night mode)
      collapses to its first rung.
    - Whether `WLR_DRM_DEVICES` and `WLR_LIBINPUT_NO_DEVICES` are still the
      wlroots 0.19 variable names. The hybrid-GPU pin, `host_vars/laptop.yml`
      and `cage@.service.j2` all depend on them.
    - Version drift in the runbook's other citations: `wlr-randr` is 0.4.1 on
      resolute (doc cites noble's 0.3.0), `swayidle` 1.9.0 (doc cites 1.8.0),
      `drm-info` 2.6.0. The §2 touch-path commit audit and the #182606 analysis
      were all done against wlroots 0.17.

    ✅ **Re-audit done — 2026-08-05**, recorded as dated *Re-audit 2026-08-05*
    amendments in the runbook. Answers, in this item's own order: (1) wlroots
    0.19 **does** implement wlr-output-power-management — and 0.17 already did
    — but the ladder does **not** collapse: the gap was always cage-side
    wiring, and the v0.2.1 source still never calls it (implementing PR #512
    open, in active review 2026-06 — re-check before the mini-PC build).
    (2) `WLR_DRM_DEVICES` and `WLR_LIBINPUT_NO_DEVICES` are both intact in the
    0.19.2 source *and* in `strings` of the resolute `.deb` — the hybrid-GPU
    pin, `host_vars/laptop.yml` and `cage@.service.j2` keep working untouched.
    (3) Version drift is recorded in the runbook's §2 table and §5 rungs; the
    touch-path commits (`7ec7e3df`, per-point forwarding, `96ffaa34`) are all
    ancestors of `v0.2.1`, so the noble-era commit audit carries over to the
    spike box's package. Bonus resolutions beyond what this item asked:
    libseat's backend order (seatd → logind → builtin, read from Ubuntu's own
    source — the runbook's U3(b) UNVERIFIED is closed) and the kiosk unit
    verified against systemd 259 (`systemd-analyze verify` clean; the utmp
    lines are no-ops there, 259 being built `-UTMP`).

13. **The Panel's golden tests are red on 26.04 — 5 failures, and they are the
    upgrade's doing, not any code change.** `flutter test` in `panel/` gives
    `+169 ~1 -5`; all five are in `test/golden/dollhouse_golden_test.dart`
    (0.55–0.75 % pixel diffs, e.g. `hub_gave_up.png` 7640 px). Confirmed
    pre-existing by re-running them against a pristine `git archive HEAD`
    checkout — the phase-0 close-out touched no widget, theme or data code.
    This is host font/rendering drift from 25.10 → 26.04. Decide deliberately:
    regenerate the goldens on 26.04 (and accept that the Mac then disagrees),
    or make the golden rig pin its own font stack. Leaving it is the one option
    that costs something — a permanently red suite stops being a signal.

    ✅ **CLOSED 2026-08-06** — both options at once, in a form the item did
    not name: the goldens were re-baked inside the devcontainer image
    (Ubuntu 24.04, Flutter and the material fonts pinned in the image) — a
    regeneration whose font stack is pinned by the image rather than by the
    rig — and ADR-0009 makes that image the canonical golden host. The
    in-container suite is 398 pass / 1 skip / 0 failures. Red on this 26.04
    host is now the *expected* out-of-container state, not a defect: the
    permanently-red cost above only applied while a host run was the signal,
    and it no longer is.

14. ✅ **Done — 2026-08-04. The Flutter Linux toolchain is installed and
    `flutter build linux --release` succeeds on this host.** `clang`, `clang++`,
    `cmake` and `ninja` are present (`/usr/bin/clang`, `/usr/bin/cmake`,
    `/usr/bin/ninja`), along with `gtk+-3.0` 3.24.52, `liblzma` 5.8.3 and
    `xkbcommon` 1.13.1. The release bundle exists at
    `panel/build/linux/x64/release/bundle/panel` (23832 B, built 2026-08-04
    18:16) with `libapp.so` and `libflutter_linux_gtk.so` beside it. Ubuntu
    26.04 is still outside Flutter's documented support range
    (`docs/research/platform-os-feasibility.md:91` records **20.04–24.04 LTS**)
    — it simply works anyway, and that is now a measurement rather than a
    hope. Two sub-points survive as separate, smaller concerns: (b) 26.04
    ships CMake 4.2.3 / gcc 15.2 while `panel/linux/flutter/CMakeLists.txt`
    still declares `cmake_minimum_required(VERSION 3.10)` — configures today,
    deprecated territory tomorrow; (c) `liblzma-dev` is on Flutter's own Linux
    dependency list and is **missing from `flutter_toolchain_packages`** in
    `group_vars/all.yml`, so the Ansible converge would not reproduce this
    install on a fresh host even though the host it was measured on is fine.
    Fix (c) before anyone believes the kiosk role is idempotent.

    **What the build was then used to prove, and what it was not.** The
    **Linux release binary** — not the Dart VM, not a browser — was run
    headless under `Xvfb :99` (1280×800×24, `LIBGL_ALWAYS_SOFTWARE=1`,
    llvmpipe) against the real Hub (`127.0.0.1:8123`) and the real go2rtc
    (`127.0.0.1:1984`). A doorbell state change opened the Popup unprompted
    and **live MJPEG video rendered inside it**, with clean teardown. Its own
    log is the record: `hub.connected … devices=33` → `ui.ding device=doorbell
    entity_state=on` → `popup.doorbell reason=ding` → `popup.stream_open
    name=selftest` → `popup.stream_closed reason=popup_closed`. A screenshot
    of the app window shows the "Ring Doorbell" Popup with the test pattern
    inside it; go2rtc logged the consumer as `user_agent: Dart/3.12
    (dart:io)`, 931 kB transferred, and reports `consumers: []` afterwards.

    **Four things this does NOT prove — state them every time this result is
    cited:** (1) **not cage** — this was Xvfb with the X11 GDK backend and
    software GL; `cage` is not installed on this box at all (README **G6**),
    so the kiosk half of the spike (**A7**) is untouched; (2) **no touch
    input** — no touchscreen is attached (the kernel input list has a
    touchpad and no absolute-position device), so every interaction was a
    state push over HA's REST API, not a finger on glass; (3) **a synthetic
    stream, not a camera** — the source was go2rtc's
    `ffmpeg:selftest#video=mjpeg`, and a real Ring stream adds 2–5 s of
    start-up on top of the 2.1 s transcode spin-up; (4) **a synthetic
    doorbell** — the ding was a fabricated `sensor.ring_doorbell` state POSTed
    to HA's REST API, and that entity does not exist in HA now.

    One loose end for an agent: the bundle that rendered video was built from
    a `bindings.yaml` carrying `stream: selftest` on the `doorbell` Device.
    The **tracked** `panel/assets/house/bindings.yaml` has no `stream:` line
    there and is clean against `HEAD`, so a Panel built from the repo today
    opens that Popup with no video in it. See phase-4 §B.

15. **`appliance/test/run.sh` bind-mounts the Hub's own Docker socket into a
    `--privileged` container.** Harmless when the dev box was a Mac and that
    socket belonged to Docker Desktop's disposable VM — which is still how
    `appliance/test/README.md` frames it. It is not harmless now: the same
    laptop is the Hub host, so from phase 1 onward that socket is
    root-equivalent access to the daemon running Home Assistant, Mosquitto,
    ring-mqtt and go2rtc. Either fence the test bed off the Hub daemon
    (a rootless or separate daemon, or drop the socket mount) or state
    explicitly that the test bed must not be run while the Hub stack is up.
