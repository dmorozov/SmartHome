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
