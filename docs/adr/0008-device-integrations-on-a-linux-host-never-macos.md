# Device integrations run on a Linux host; macOS never hosts the multicast stack

The Hub's device integrations need real LAN presence: HomeKit-controller
pairing (local Ecobee), Kasa/ESPHome auto-discovery, and later Samsung TV
discovery and Zigbee all depend on mDNS/multicast reaching the Hub.
Docker-on-macOS cannot provide it and no workaround is acceptable: Docker
Desktop's VM is NAT-only and its 4.34+ "host networking" is an L4
TCP/UDP port proxy (no multicast, by architecture — docker/roadmap#238);
docker-mac-net-connect adds only unicast host→container routing over
WireGuard, and link-local multicast does not route through a tunnel;
Colima/socket_vmnet bridged setups are documented-fragile; a bridged
Linux VM (UTM/Fusion) would work but adds a hypervisor layer we would
keep for months and use for nothing else.

**Decision (2026-08-03):** the Hub stack with device integrations
(`hub/compose.yaml`, host networking) runs only on x86 Linux hosts — the
Intel dev laptop now, the mini PC later. The Mac keeps exactly two roles:
Panel development (Flutter web/macOS against the laptop's Hub over LAN)
and the disposable protocol sandbox `hub/dev/` (bridge networking,
generated stand-in entities, cloud-only services — nothing
discovery-dependent may be attempted there, and its results must never be
read as evidence about production networking). **Both Mac roles are
superseded by
[ADR-0009](0009-development-in-the-devcontainer-on-the-target-os.md):**
Panel development and the `hub/dev/` sandbox moved into the devcontainer,
which runs the same on a Mac — and the sandbox's
nothing-discovery-dependent rule travels with it unchanged. The decision
above — no multicast stack on macOS, ever — stands.

**Consequences:** the house's Hub is up only while the laptop is; real
Hub state (HA config, Ring token, HomeKit pairings) accumulates on the
laptop and migrates to the mini PC by directory copy, as
`hub/compose.yaml` already documents. Reopen this only if the Appliance
stops being Linux-with-Docker — a Mac-hosted Hub was rejected, not
deferred.
