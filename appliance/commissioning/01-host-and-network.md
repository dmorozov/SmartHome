# 1 — Host and network

Bare machine → *ready to run the Hub*. End state: an addressable, SSH-reachable
Linux box that stays up with the lid shut, has a working Docker Engine with a
live apt source behind it, and carries this repo. No container is started here;
that is the next chapter.

Everything below was executed on the Hub host on 2026-08-03 and re-verified
2026-08-04. The as-built record with the full reasoning is
[`../../docs/plans/device-integrations/phase-0-laptop-bring-up.md`](../../docs/plans/device-integrations/phase-0-laptop-bring-up.md);
this chapter is the runnable version of it.

**This host has no passwordless sudo.** Every `sudo` line below is handed to the
operator to run at a terminal; an agent cannot complete them.

---

## 1.1 OS — two machines, two answers

Do not collapse these into one row. They differ for a measured reason.

| Machine | OS | Kernel | Why |
|---|---|---|---|
| **Hub host** — Lenovo Legion 9 16IRX8, Intel i9-13980HX, Intel UHD `i915` iGPU + NVIDIA RTX 4090 dGPU | Ubuntu **Desktop 26.04 LTS** (*resolute*) | 7.0.0-28-generic, systemd 259 | One install serves the Hub now and the cage spike later. Intel graphics, so no backported-kernel requirement. |
| **Mini PC** — Ryzen AI, production Appliance, not purchased | Ubuntu **Server 24.04 LTS** + HWE kernel | HWE (7.0.0-28.28~24.04.1 today) | [ADR-0001](../../docs/adr/0001-plain-linux-kiosk-not-fuchsia-or-chromeos.md). Its Strix Point **Radeon** iGPU wants the newest kernel its LTS can offer, and it runs with no desktop environment at all. |

The 24.04+HWE pin comes from AMD-graphics research
([`../../docs/research/platform-os-feasibility.md`](../../docs/research/platform-os-feasibility.md), §118)
and is about the mini PC's Radeon iGPU. It does not transfer to an Intel `i915`
laptop, and 26.04's own kernel is newer than 24.04's HWE stack anyway. That is
why the Hub host moved and the mini PC did not.

Verify:

```bash
lsb_release -rs          # 26.04 on the Hub host, 24.04 on the mini PC
uname -r                 # 7.0…
lspci -k | grep -A3 -E 'VGA|3D'   # confirms i915 vs amdgpu before you argue about kernels
```

### If the machine arrives on an interim release

This one did — 25.10 (*questing*), already EOL. Check before anything else:

```bash
distro-info --supported   # a codename absent from this list is EOL
```

Upgrade with SSH already up (§1.3), not before:

```bash
sudo do-release-upgrade
```

It works, and it leaves two things behind. One is this project's business
(§1.5); the other is deliberately out of scope (§1.5, scope fence).

### Which release ansible knows about

`kiosk_hwe_kernel_packages` in
[`../ansible/group_vars/all.yml`](../ansible/group_vars/all.yml) maps
`24.04 → linux-generic-hwe-24.04` and `26.04 → linux-generic-hwe-26.04`. An
unmapped release makes the role **assert**, not guess — HWE metas exist only for
LTS releases. Never collapse that map to plain `linux-generic`: on 24.04 that
resolves to the GA 6.8 stack, not the HWE one.

---

## 1.2 Network — wired if you can, reserved by MAC either way

The rule is Ethernet: mDNS and camera streams both prefer it, and the mini PC
will be wired. **As built, the Hub host is on Wi-Fi** — `wlp164s0` (AX210) at
`192.168.68.81/22`, gateway `192.168.68.1`; wired `enp162s0` (Killer E3000
2.5GbE) is cabled-down. That is a deliberate deviation, not an oversight.

### The Deco reality

The LAN is a TP-Link Deco XE75Pro mesh (gateway `.1`, satellites `192.168.71.249`
and `.250`). Two measured consequences:

- **The Deco serves no local DNS.** Reverse lookups for LAN devices fail
  outright. Anything that "resolves" is systemd-resolved synthesising a local
  answer, not the router answering.
- **`.local` is not a substitute.** `resolvectl mdns` reads `no` on every link
  here, and mDNS resolves this host to link-local IPv6 only.

So a reservation is made **by MAC address, in the Deco app** — there is no
hostname handle to attach it to. Get the MAC from the host itself:

```bash
ip -br link show wlp164s0    # or enp162s0 when wired
```

The exact Deco-app menu wording for address reservation is **UNVERIFIED** — it
is an operator-side mobile app, not something in this repo. What matters is that
the entry is keyed on the MAC printed above.

Verify the DNS claims yourself before believing any hostname:

```bash
resolvectl query 192.168.68.59     # a LAN device: expect "not found"
resolvectl mdns                    # expect "no" on every link
```

### What an unreserved lease actually costs

Traced through the code during phase 0. Only one of the four things usually
cited is real:

| Claimed to break on a drifted lease | Reality |
|---|---|
| Panel build | **Was** the whole exposure (compile-time `HA_URL`). Fixed: [`../../panel/lib/config/hub_config.dart`](../../panel/lib/config/hub_config.dart) resolves `HUB`/`HA_URL`/`HA_TOKEN` **environment-first**. |
| ring-mqtt state | No host-IP content — compose DNS plus an account-bound OAuth refresh token. |
| HomeKit pairings | Keys live in `.storage`; `homekit_controller` re-resolves over mDNS. Same-subnet IP change does not invalidate a pairing. |
| Camera configs | Those carry the *cameras'* addresses. go2rtc has no `webrtc: candidates:` block. |
| The Panel's camera Popups | `GO2RTC_URL` resolves environment-first alongside `HA_URL` (same file), so a drifted go2rtc address costs the same restart. Worth naming because it is the one setting with **no** built-in default: unset, the Popup says the view is unavailable rather than dialling a `localhost` the Panel invented. |

Net: a drifted lease costs an environment change and a Panel restart. Nothing
rebuilds, nothing re-pairs. See
[`../../hub/README.md`](../../hub/README.md) "Migration to the mini PC" — the
stack is designed to move machines unchanged.

The genuine re-pairing cliff is losing `hub/ha-config/.storage` or
`hub/ring-mqtt-data/`. No phase has a backup step for those yet.

Record the address where the tooling reads it —
[`../ansible/inventory.yml`](../ansible/inventory.yml), `ansible_host:` under
`laptop`.

---

## 1.3 SSH

Ansible needs SSH before it can do anything, and the `kiosk` role does **not**
install it. This step is bootstrap, and it is manual.

```bash
sudo apt install -y openssh-server
systemctl is-active ssh          # active
```

From the controller (the Mac): `ssh <user>@192.168.68.81`.

As built and re-measured 2026-08-04: **OpenSSH 10.2p1**, `ssh.service` active,
listening on `0.0.0.0:22` and `[::]:22`. `ufw` is **inactive**, so no firewall
rule was needed — check `sudo ufw status` on any host where it is not. Host keys
exist for ed25519, ecdsa and rsa. `~/.ssh/authorized_keys` on the Hub host is
**0 bytes**: password auth works, key auth is not set up.

### 1.3a Key auth from the Mac, end to end (owner task **G2**)

Nothing is broken without this — password auth works. What it costs you is a
prompt on **every** Ansible converge, and `--ask-become-pass` already asks for
one password; two prompts per run is what makes people start skipping converges.

Everything in steps 1–4 runs **on the Mac**. Nothing here needs sudo on either
machine.

**Step 1 — do you already have a key?**

```bash
ls -l ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null
```

If `id_ed25519.pub` exists, skip to step 2 — reuse it. Do not generate a second
key per host; the point of a keypair is that the private half never moves and
you have one identity to revoke.

If nothing exists, make one. Ed25519, not RSA: shorter, faster, and the default
OpenSSH has recommended for years.

```bash
ssh-keygen -t ed25519 -C "mac -> smarthome hub" -f ~/.ssh/id_ed25519
```

- **Use a passphrase.** The private key is a file; a passphrase is what makes a
  copied file useless. macOS makes this free — step 3 hands it to the Keychain
  so you type it once, ever.
- Accept the default path. `ssh-copy-id` and Ansible both find it without
  configuration, and a custom path is one more thing to remember in a year.

**Step 2 — check the fingerprint BEFORE you trust it.**

The first `ssh` to a new host asks you to accept its key, and clicking through
that prompt is what makes a man-in-the-middle possible. These are the Hub host's
actual host keys, read from `/etc/ssh/` on the box itself:

```
256   SHA256:NAdmTCIwHNclI16B9/NBSy72TacF22Qu+1xRBg8yYE4   (ED25519)
256   SHA256:x00p7zIbYLiyjGlLiQZISyIe7i18xncxeJPHcfavqBQ   (ECDSA)
3072  SHA256:pv6XKSEbBn2q+q3WhK1trUlUVSe65eYgAOaGVmje8fM   (RSA)
```

Modern OpenSSH offers ed25519 first, so the prompt should show the first one.
If what you see does not match a line above, **stop** — do not type `yes`.
Re-read them off the Hub host with:

```bash
# on the Hub host
for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
```

(These change if the host is reinstalled or `openssh-server` is purged and
reinstalled — a mismatch after either of those is expected, not an attack.)

**Step 3 — push the public key.**

```bash
# on the Mac
ssh-copy-id dmorozov@192.168.68.81
```

It asks for the Hub host's **login password** (the last time you should need
it), then appends the public half to `~/.ssh/authorized_keys` there, creating it
with the right modes. Only `id_ed25519.pub` leaves the Mac; `id_ed25519` — no
`.pub` — must never be copied anywhere.

**Step 4 — prove it, and load the passphrase into the Keychain.**

```bash
ssh -o PreferredAuthentications=publickey dmorozov@192.168.68.81 'echo key auth OK'
```

Forcing `publickey` is the point: without it, a silent failure just falls back
to a password prompt and looks like success. You want `key auth OK` and no
prompt.

Then, so the passphrase is asked once rather than per connection:

```bash
# on the Mac
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

**Step 5 — stop Ansible asking for the address.** Add to the Mac's
`~/.ssh/config`:

```
Host smarthome-hub
    HostName 192.168.68.81
    User dmorozov
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

`IdentitiesOnly yes` matters once you have more than one key: without it the
agent offers each in turn and sshd can hit `MaxAuthTries` and refuse you while
holding a key that would have worked.

**A caveat this repo owes you:** `192.168.68.81` is still an **unreserved DHCP
lease** (owner item **C1**), so both the `ssh-copy-id` above and the `HostName`
here are pinned to an address that can move. If it does, key auth does not
break — but the address in your config, in `hosts.ini`, and in `known_hosts`
all point somewhere else, and the symptom is a host-key warning rather than
anything that says "the lease moved". Doing C1 first makes this permanent.

**Hardening — deliberately not done here.** Turning off `PasswordAuthentication`
is the obvious next step and it is the one that locks you out of a headless box
if the key is wrong. Do it only after step 4 has passed from a **second**
terminal you keep open, and know that this Hub host has a physical keyboard, so
recovery is possible. It is not required for Ansible and it is not on the owner
list for that reason.

---

## 1.4 Power — an always-on-ish laptop

A closed lid must not take the house down.

### Lid (done, verified live)

A **drop-in**, not an edit to `/etc/systemd/logind.conf` — the drop-in survives
package upgrades and reverts by deleting one file.
`/etc/systemd/logind.conf.d/10-smarthome-hub.conf`:

```ini
# SmartHome — this laptop is the Hub host; a closed lid must not take the house
# down. Revert: rm this file && systemctl restart systemd-logind
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

Then either `sudo systemctl restart systemd-logind` or a reboot. On this host it
was the 26.04 upgrade's reboot that applied it — restarting `systemd-logind`
under a live GNOME session on a daily-driver laptop is worth avoiding.

Verify against the running manager, not the file:

```bash
for p in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked IdleAction; do
  printf '%s = ' "$p"
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager "$p"
done
```

All four read `s "ignore"` here.

### GNOME auto-suspend — one half done, one half **still open**

GNOME's power plugin is a *per-user session* setting, independent of logind. On
AC it is already correct; on battery it is not.

```bash
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
# 'nothing'
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type
# 'suspend'      <-- OPEN GAP
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout
# 900
```

**Unplug the power and the Hub dies 15 minutes later.** This is a known open
item, deliberately left rather than silently changed on someone's work laptop.
The setting that closes it, if the operator wants it closed:

```bash
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
```

Two caveats before running it. It applies to **the user whose session runs
GNOME**, so run it as that user, not under sudo. And it removes the only thing
currently stopping an unplugged laptop from draining flat — acceptable for a
machine that lives on a desk, a decision for one that does not.

The mini PC has no desktop environment (ADR-0001), so this whole subsection is
laptop-only.

---

## 1.5 Docker Engine

Under [ADR-0008](../../docs/adr/0008-device-integrations-on-a-linux-host-never-macos.md)
the whole Hub *is* Docker — [`../../hub/compose.yaml`](../../hub/compose.yaml)
puts Mosquitto and Home Assistant on the LAN under host networking. Treat the
engine as production software, not a dev convenience.

As built, ahead of the original plan text (`docker.io` + `docker-compose-v2`):
upstream **docker-ce 29.7.1** and **compose v5.4.0** from `download.docker.com`.
The commands below are that path — the one this host actually took, and the one
whose end state the verification block asserts. The distro alternative is a
deliberate, different choice; it is spelled out after the verification, not
mixed into it.

Run as the operator (this host has no passwordless sudo):

```bash
# 1. Docker's signing key, at the path the as-built docker.sources names
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
     -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 2. the apt source, deb822 form. VERSION_CODENAME is `resolute` on 26.04 —
#    read it, do not type it. A hand-typed stale codename here is exactly the
#    end state the next subsection is about.
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# 3. engine, CLI, containerd, and the compose v2 plugin
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# 4. run docker without sudo
sudo usermod -aG docker "$USER"                     # then log out and back in
```

Verify as the **login user**, without sudo:

```bash
docker --version           # Docker version 29.7.1
docker compose version     # v5.4.0
docker run --rm hello-world
groups | tr ' ' '\n' | grep -x docker
```

As built this pulled six packages, all `…~ubuntu.26.04~resolute`: `docker-ce`
and `docker-ce-cli` 5:29.7.1, `containerd.io` 2.2.6, `docker-buildx-plugin`
0.36.0, `docker-compose-plugin` 5.4.0, and `docker-ce-rootless-extras` 5:29.7.1
pulled in as a dependency. That is the same six the upgrade line in the next
subsection names.

### The distro path — a different choice, not a shortcut to the same place

Ubuntu's own archive ships Docker too, and one line installs it:

```bash
sudo apt install -y docker.io docker-compose-v2     # distro path — NOT what this host runs
sudo usermod -aG docker "$USER"
```

Take it only with both consequences understood:

- **You get different versions, and the verification block above will not
  match.** Measured on this host's archive today: `docker.io` 29.1.3-0ubuntu4.1
  and `docker-compose-v2` 2.40.3+ds1. So `docker --version` reads 29.1.3, not
  29.7.1, and `docker compose version` reads v2.40.3, not v5.4.0. Nothing in
  `hub/compose.yaml` needs the newer pair — this is a currency and support
  question, not a compatibility one.
- **In exchange, the `docker.sources` trap below cannot happen to you.** There
  is no third-party source to be silently disabled by `do-release-upgrade`, and
  `unattended-upgrades` already covers `${distro_id}:${distro_codename}` and
  `-security`, so Docker CVEs ride the normal archive path instead of needing a
  deliberate `sudo apt upgrade`.

Whichever you pick, record it — the rest of this chapter's Docker material
assumes the upstream origin, because that is what this box is on.

### The `docker.sources` trap after a release upgrade

`do-release-upgrade` disables every third-party apt source, silently. It writes
`Enabled: no` into each `.sources` file under `/etc/apt/sources.list.d/`, renames
the `.list` ones to `*.list.disabled`, and leaves `Suites:` on the **old**
codename. The failure mode is not an error — it is `apt-get -s upgrade` cheerfully
reporting 0 packages while Docker sits frozen with no security path behind it.

Detect it:

```bash
apt-cache policy docker-ce
```

A healthy answer names a repository. A trapped one shows only
`/var/lib/dpkg/status`:

```
docker-ce:
  Installed: 5:29.7.1-1~ubuntu.26.04~resolute
  Candidate: 5:29.7.1-1~ubuntu.26.04~resolute
 *** 5:29.7.1-1~ubuntu.26.04~resolute 500
        500 https://download.docker.com/linux/ubuntu resolute/stable amd64 Packages
```

The fix is two lines in `/etc/apt/sources.list.d/docker.sources` — set `Suites:`
to the new codename and delete the `Enabled: no` line. The file should end up as:

```
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: resolute
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
```

Then, as the operator:

```bash
sudo apt update
sudo apt install --only-upgrade docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
```

**Do this before the hub stack exists.** It restarts `dockerd`.

Two things it does not do:

- It restores **visibility, not automation**. `unattended-upgrades` allows
  `${distro_id}:${distro_codename}` and `-security` only (verified in
  `/etc/apt/apt.conf.d/50unattended-upgrades`), so Docker CVEs still need a
  deliberate `sudo apt upgrade`.
- It does not touch the HWE meta-package's apt mark. On a release-upgraded host
  `linux-generic-hwe-26.04` can be marked *auto* with only the removable
  transitional shim as its parent — one `apt autoremove` from deleting the
  running kernel stack. The `kiosk` role claims it with `apt-mark manual`.

  **Owner item G1 — DONE 2026-08-04, and re-verified while writing this.**
  `apt-mark showmanual` lists **both** `linux-generic-hwe-26.04` and
  `linux-generic-hwe-24.04`; `apt-mark showauto | grep linux-generic-hwe`
  matches nothing. The mark was set by hand rather than by a converge, so the
  role's task is now a no-op here — which is the intended shape: it checks
  `showauto` first and only claims what is actually auto-marked. Verify with

  ```bash
  apt-mark showauto | grep -E '^linux-generic-hwe' || echo 'none auto — G1 holds'
  ```

  On any host where that *does* print something, do not accept Ubuntu's
  "safely removed" advice about `linux-generic-hwe-24.04` until a converge (or
  the same `apt-mark manual` by hand) has run.

### Scope fence — do not "finish the job"

The other dark sources on this host (`graphics-drivers`, `grub-customizer`,
`globalprotect`, Chrome, `kubernetes`, `antigravity`, `windsurf`,
`nvidia-container-toolkit`) are the owner's personal and work tooling on a
daily-driver laptop. This project touches none of them. Notably the NVIDIA
driver is **not** at risk — `nvidia-driver-595-open` 595.84 comes from
`resolute-updates/restricted`, the Ubuntu archive, not the dark PPA; re-pointing
that PPA would be the risky move, not leaving it off. `.distUpgrade`,
`.pre-resolute` and `.list.disabled` files are inert (apt reads only `*.list` and
`*.sources`) — leave them as the pre-upgrade record.

No phase 0–6 needs GPU passthrough into Docker: `hub/compose.yaml` passes no
`devices:` and no `/dev/dri`, and go2rtc restreams RTSP without transcoding.

---

## 1.6 Repo checkout

```bash
git clone git@github.com:dmorozov/SmartHome.git ~/Work/SmartHome
```

As built at `/home/dmorozov/Work/SmartHome`, remote
`git@github.com:dmorozov/SmartHome.git`.

Sync between the controller and the Hub host goes through the git remote — push
from the Mac, pull on the Hub host. **No rsync side-channels**, or the two
checkouts drift and the phase records stop describing either of them.

Two files the clone will never bring, both gitignored, both mode 0600, both
created in later chapters on the host itself:

| Path | What it holds | Created by |
|---|---|---|
| [`../../hub/.broker-passwords.env`](../../hub/) | Mosquitto users `ha` / `ring` / `z2m` | Hub-stack chapter |
| [`../../hub/token`](../../hub/) | HA long-lived access token for the Panel | after HA onboarding |

Never paste either value into a doc, a commit, an ansible extra-var, or a
`systemctl show`-visible `Environment=` line — see
[`../ansible/README.md`](../ansible/README.md) for why the token takes the
`EnvironmentFile=` route.

---

## 1.7 What ansible does, and what stays manual

[`../ansible/README.md`](../ansible/README.md) is the authority; this is the
commissioning-relevant slice.

| Step in this chapter | Automated? |
|---|---|
| OS install / release upgrade | **Manual.** |
| Network, DHCP reservation | **Manual** — router-side, and by MAC. |
| `openssh-server` | **Manual.** Ansible connects over it; it cannot install its own transport. |
| logind lid drop-in | **Manual.** The role's `kiosk_hardening` gate touches `NAutoVTs`/`ReserveVT`, not lid handling. |
| GNOME auto-suspend | **Manual**, per-user, laptop only. |
| Docker Engine + `docker.sources` | **Manual.** There is no `hub` role yet — the README says so explicitly. |
| Repo checkout | **Manual.** |
| HWE kernel meta + `apt-mark manual` | **kiosk role**, gated `kiosk_hwe_kernel` (true on real hardware, false in the test container). Already satisfied by hand on this host — **G1 done**, §1.5. |
| cage / `wlr-randr` / `swayidle` / `grim` / `ddcutil` / `evtest` / `libinput-tools` / `wev` / `drm-info` | **kiosk role.** |
| Flutter Linux toolchain (`clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `liblzma-dev`) + bootstrap (`curl`, `git`, `unzip`, `zip`, `xz-utils`) | **kiosk role.** As of 2026-08-05 this list is tested on both targets — see §1.7a. `libstdc++-12-dev` used to be here and was removed: `clang` pulls the release-matched headers itself, and any hand-written pin is wrong on one of the two releases. |
| `cage` user, PAM, templated `cage@.service`, Panel env + token file | **kiosk role**, all enable/hardening behind gates that default `false`. |

A plain converge is safe on a daily-driver laptop — every kiosk gate defaults
`false`, so cage is installed and never enabled and gdm is untouched:

```bash
cd appliance/ansible
ansible-playbook site.yml -l laptop --ask-become-pass
```

`--ask-become-pass` is required here precisely because this host has no
passwordless sudo. Nothing in this chapter's end state depends on that converge
having run — it is the boundary between "ready to run the Hub" and spike-day
work ([`../README.md`](../README.md)).

### 1.7a The Flutter Linux toolchain — two facts, and they disagree

That row used to end "Known gap: `liblzma-dev` is on Flutter's own dependency
list and is **missing** from `flutter_toolchain_packages`." Half of that went
stale on 2026-08-04 and half did not, and collapsing the two is how a doc
starts lying. Keep them apart:

- **The host is complete, and it builds.** Owner item **G4 — DONE 2026-08-04.**
- **The role would not have reproduced it.** The owner installed the missing
  piece by hand, so a fresh converge built a box that was *not* this one.

#### What was measured on the host

Re-measured while writing this section, not copied forward:

| | Version | Where from |
|---|---|---|
| `clang` / `clang++` | 21.1.8 (`1:21.1.6-71` meta) | `/usr/bin/clang`, `/usr/bin/clang++` |
| `cmake` | 4.2.3-2ubuntu2 | `/usr/bin/cmake` |
| `ninja` | 1.13.2-1 | `/usr/bin/ninja` |
| `pkg-config` | 2.5.1-4 | `/usr/bin/pkg-config` |
| `gtk+-3.0` | **3.24.52** | `libgtk-3-dev` 3.24.52-0ubuntu1 |
| `liblzma` | **5.8.3** | `liblzma-dev` 5.8.3-1, `resolute/main` |
| `xkbcommon` | **1.13.1** | `libxkbcommon-dev` 1.13.1-1 |
| Flutter / Dart | 3.44.8 stable / 3.12.2 | `/home/dmorozov/Java/Flutter/flutter` |

`flutter doctor -v` reports `[✓] Linux toolchain - develop for Linux desktop`.

**`flutter build linux --release` succeeds**, and this is the only claim that
actually counts — the version table above is what a passing build happened to
be standing on, not a proof on its own. The artefact:

```
panel/build/linux/x64/release/bundle/panel        (23832 B, 2026-08-04 18:16)
panel/build/linux/x64/release/bundle/lib/libapp.so
panel/build/linux/x64/release/bundle/lib/libflutter_linux_gtk.so
```

That binary was then **run**, and it rendered live video — the appliance's
first light. It does not belong in this chapter: see
[Ch. 6](06-panel-and-bindings.md), the first-light record, for the procedure,
the verbatim log, and — the part that matters more than the picture — the four
things it does **not** prove (it ran under Xvfb and not `cage`, with no touch
input, against go2rtc's synthetic pattern and not a camera, on a ding injected
over HA's REST API and not a real Ring entity; and the `stream: selftest`
binding it needed was reverted afterwards, so a Panel built from this repo
today opens that Popup empty). This chapter's business is only that the
toolchain exists and produces a bundle.

#### `liblzma-dev` — fixed in the role 2026-08-04

[`../ansible/group_vars/all.yml`](../ansible/group_vars/all.yml) now lists it.
The variable is corrected; **the correction has not been converged anywhere**,
including here — this host already has the package, so a converge would report
`ok` and prove nothing about a fresh box. First real proof will come from
`../test/run.sh reset` plus a container converge.

Worth being exact about *why* it is in the list, because the obvious evidence
argues the other way: nothing in the artefact links it. `ldd` across
`bundle/panel` and both `bundle/lib/*.so` — ~70 shared objects each for the
binary and the engine `.so`, while `libapp.so` reports "statically linked" and
has none —
finds `liblzma` **zero** times. The rejected alternative was therefore to drop
it as cargo-cult. Rejected because nobody has run the build *without* it:
removing it needs sudo and would break the one machine known to build. "Absent
from `ldd`" is a weaker statement than "the build does not need it", and this
role's job is to reproduce a host that was measured, not to re-derive it.

#### `libstdc++-12-dev` — removed 2026-08-05, after a build test on both targets

Checked because §1.7 had been asserting it for a release nobody had verified it
against. It was wrong on **both** targets, and it is now gone from the role.
The evidence below is kept because the tempting fix — bump it to `-15-dev` —
is also wrong, and the next person to read Flutter's setup page will want to
add it back.

```bash
apt-cache policy libstdc++-12-dev
#   Installed: (none)
#   Candidate: 12.5.0-9ubuntu1
#   500 http://us.archive.ubuntu.com/ubuntu resolute/universe amd64 Packages
apt-cache policy libstdc++-15-dev
#   Installed: 15.2.0-16ubuntu1
#   500 http://us.archive.ubuntu.com/ubuntu resolute/main amd64 Packages
clang++ -v -x c++ -c /dev/null -o /dev/null 2>&1 | grep 'Selected GCC'
#   Selected GCC installation: /usr/lib/gcc/x86_64-linux-gnu/15
```

So the release build above succeeded with **no gcc-12 headers on the box at
all**. `clang++` 21 picks GCC 15 and takes its C++ headers from
`libstdc++-15-dev`. The entry is a copy of Flutter's setup page — which still
names `libstdc++-12-dev` — rather than anything measured here.

**And the list did not need the entry in the first place**, which is the part
worth knowing before anyone "fixes" it to `-15-dev`:

```bash
apt-cache depends clang-21 | grep stdc
#   Depends: libstdc++6
#   Depends: libstdc++-15-dev      <-- clang declares its own
apt-cache rdepends --installed libstdc++-15-dev
#   g++-15-x86-64-linux-gnu
#   clang-21
```

`clang` → `clang-21` → `libstdc++-15-dev`. The role's own `clang` entry already
drags in the correct, release-matched C++ headers; naming a libstdc++ version
by hand can only ever disagree with the compiler that is actually installed.

##### The test that closed it

Both targets, in disposable containers, installing the role's list with **no**
libstdc++ entry at all:

```bash
docker run --rm ubuntu:24.04 bash -c 'apt-get -qq update >/dev/null &&
  apt-get -qq install -y --no-install-recommends clang cmake ninja-build \
    pkg-config libgtk-3-dev liblzma-dev >/dev/null &&
  dpkg -l | grep -o "libstdc++-[0-9]*-dev"'
```

| | `clang` resolves to | libstdc++ that lands | C++17 compile+link+run |
|---|---|---|---|
| ubuntu:24.04 — mini PC | `clang-18` | `libstdc++-13-dev` | OK |
| ubuntu:26.04 — laptop | `clang-21` | `libstdc++-15-dev` | OK |

Then the real thing on the mini PC's OS — this repo's own Panel, clean tree,
`flutter build linux --release` inside `ubuntu:24.04`:

```
libstdc++-12-dev installed? 0
[✓] Linux toolchain - develop for Linux desktop
✓ Built build/linux/x64/release/bundle/panel
    libstdc++.so.6 => /lib/x86_64-linux-gnu/libstdc++.so.6
```

So the line went, and pinning `-15-dev` instead was rejected: it would break
24.04, which wants `-13`, and re-create the same staleness one release later.

**`liblzma-dev` survived the same test and was kept anyway.** The 24.04
container built the app without it too — but it is on Flutter's own documented
dependency list, and upstream's contract outranks one app's link graph. `ldd`
proves this app does not need it *today*; it says nothing about the next
Flutter release. Removing `-12-dev` fixes something actively wrong; removing
`liblzma-dev` would trade an upstream guarantee for a few hundred KB.

> **Harness trap, recorded because it cost an hour.** The first container run
> failed with `The type 'dynamic' is not exhaustively matched` in
> `device_popup.dart` — nothing to do with C++. The test had copied the host's
> `.dart_tool/` in, whose `package_config.json` holds host-absolute paths;
> inside the container those resolve to nothing, types collapse to `dynamic`,
> and the CFE reports it as a source error in application code. Delete
> `.dart_tool/` and `flutter pub get` inside the container. A clean
> `rm -rf build .dart_tool && flutter pub get && flutter build linux --release`
> on the host succeeds, which is what proved the tree innocent.

---

## 1.8 Verification checklist

Run on the Hub host as the login user. Every line is pasteable.

```bash
# 1. OS and kernel
lsb_release -rs && uname -r
#    -> 26.04 / 7.0.0-28-generic  (mini PC: 24.04 + HWE)

# 2. Address is what the tooling thinks it is
ip -br a show wlp164s0
grep ansible_host ~/Work/SmartHome/appliance/ansible/inventory.yml
#    -> the laptop's line matches the address above

# 3. SSH answers (run from the controller)
#    ssh <user>@192.168.68.81 true && echo ok

# 4. Lid is ignored, live
for p in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager "$p"
done
#    -> s "ignore"  x3

# 5. Suspend posture (expect the battery gap until it is closed)
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type
#    -> 'nothing' / 'suspend'   <-- second line is the KNOWN OPEN GAP

# 6. Docker runs unprivileged
docker --version && docker compose version && docker run --rm hello-world >/dev/null && echo docker-ok

# 7. Docker has a live apt source behind it (the release-upgrade trap)
apt-cache policy docker-ce | grep -q download.docker.com && echo apt-source-ok || echo TRAPPED
grep -E '^(Suites|Enabled):' /etc/apt/sources.list.d/docker.sources
#    -> Suites: resolute, and NO "Enabled: no" line

# 8. Repo present and level with the remote
git -C ~/Work/SmartHome remote -v
git -C ~/Work/SmartHome status -sb | head -1

# 9. HWE meta is manually marked (G1) — nothing auto means nothing to autoremove
apt-mark showauto | grep -E '^linux-generic-hwe' || echo 'none auto — G1 holds'

# 10. Flutter Linux toolchain (G4). The cheap check first:
flutter doctor -v | sed -n '/Linux toolchain/,/^\[/p'
#    -> [✓] Linux toolchain, and clang / cmake / ninja / pkg-config versions
pkg-config --modversion gtk+-3.0 liblzma xkbcommon
#    -> 3.24.52 / 5.8.3 / 1.13.1 as measured 2026-08-04

# 11. …and the only check that actually proves the toolchain (minutes, not
#     seconds — skip it on a box you are not about to build on)
cd ~/Work/SmartHome/panel && flutter build linux --release
ls -l build/linux/x64/release/bundle/panel
```

Done when 1–8 pass and the operator has consciously accepted, or closed, the
battery-suspend gap in step 5. Steps 9–11 are **owner items G1 and G4, both
done here** — they are in the list so a *second* Appliance gets held to the
same bar, and because 11 is the step that catches a role which installed the
packages but not a working build (§1.7a). Next: the Hub stack —
[`../../docs/plans/device-integrations/phase-1-hub-stack.md`](../../docs/plans/device-integrations/phase-1-hub-stack.md)
for the as-built detail, and the sibling chapter in this directory for the
runnable version.
