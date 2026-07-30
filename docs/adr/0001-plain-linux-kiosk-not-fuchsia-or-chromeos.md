# Plain Linux + cage kiosk, not Fuchsia or ChromeOS

The appliance (one AMD Ryzen AI mini PC hosting both the 24/7 Hub and the touch Panel) runs Ubuntu Server 24.04 LTS + HWE kernel with no desktop environment: systemd boots the `cage` Wayland kiosk compositor, which launches the Panel app; the Hub runs as ordinary systemd/Docker services fully independent of the display stack. The originally preferred Fuchsia OS was rejected on verified facts: the Workstation configuration is discontinued and removed from the tree, x86 support covers only two Intel NUCs, there is no AMD GPU driver, and Flutter-for-Fuchsia tooling was deleted from the SDK in Sept 2024. ChromeOS/Flex was rejected because Crostini cannot run unattended at boot or inside kiosk sessions (so it cannot host the Hub) and kiosk mode requires paid Google enterprise enrollment. Full citations: `docs/research/platform-os-feasibility.md`.

## Consequences

- The Flutter + neumorphism + dollhouse vision is unchanged; only the OS beneath it changed.
- Flutter vs web UI stays reversible — both run on the identical substrate; swapping the app cage launches is the only change.
- Ubuntu Core + Ubuntu Frame is the documented later hardening path once the design freezes.
