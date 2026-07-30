# Platform OS feasibility: touch-panel appliance + hub server on one AMD Ryzen AI mini PC

Synthesized 2026-07-30 from three research fragments (Fuchsia, ChromeOS/Flex, plain Linux kiosk stacks), each verified against primary sources on that date. Target: an AMD Ryzen AI mini PC (~32 GB RAM) with an HDMI touchscreen, running a custom dollhouse touch UI **and** hosting the smart-home hub server 24/7 on the same box. Stated priority: a reliably working smart home. Claims that could not be verified against primary sources are flagged **UNVERIFIED**.

## 1. Executive summary

| Option | Verdict | Key blocker / enabler |
|---|---|---|
| **Fuchsia + Flutter** | **Not viable — do not pursue** | Blockers at every layer: Workstation product discontinued and removed from the source tree; supported x64 hardware is two Intel NUC models only; **no AMD GPU (Magma) driver exists** → no Vulkan → no Scenic → no touch UI at all; Flutter-for-Fuchsia tooling deleted from the Flutter SDK in Sept 2024; no server/daemon story (Starnix is Android-oriented, compatibility UNVERIFIED). |
| **ChromeOS / ChromeOS Flex** | **Reject** | Decisive blocker: no supported way to run the hub as a 24/7 background service — Crostini never starts at boot, dies on logout, and is unavailable in kiosk sessions. Kiosk mode also costs $25–50/device/year + Google Admin console enrollment; Ryzen AI mini PC almost certainly not Flex-certified (UNVERIFIED per specific model). |
| **Plain Linux (Debian 13 / Ubuntu 24.04 LTS) + Flutter kiosk (cage)** | **Recommended (top choice)** | Linux desktop is a fully supported, stable Flutter target (x64 first-class); cage/Weston/labwc are actively maintained kiosk compositors; hub runs as ordinary systemd services fully independent of the UI. Requirement: Flutter ≥ 3.44 stable for the Wayland touch fix. UNVERIFIED: no published Flutter-under-cage example found (low risk, half-day spike). |
| **Plain Linux + browser kiosk (Chromium/Firefox)** | **Viable — most field-proven; strong fallback** | The wall-panel stack the Home Assistant community converged on; Chromium `--kiosk` on Wayland is the standard recipe; Firefox `-kiosk` Wayland-default since 121. Same OS substrate as the Flutter path, so the choice stays reversible. Gives up native dollhouse rendering control. |
| **Ubuntu Core + Ubuntu Frame** | **Credible appliance-OS contender — revisit later** | Enabler: immutable OS, transactional OTA updates, and the one kiosk compositor whose vendor documents Flutter as a supported client. Blocker for now: everything must be snap-packaged, which fights a Java/Docker-centric hub stack and slows iteration during the build phase. |
| **webOS OSE** | Not viable for this hardware | Only supported physical target is Raspberry Pi 4; x86-64 exists only as a VirtualBox/qemu dev-emulator image. Web-app-centric, not Flutter-first. |
| **Android-x86 / Bliss OS** | Not viable for this architecture | Android-x86 is dead (last release March 2020). Bliss OS is alive but Android is hostile to the 24/7 hub workload (JVM services, Docker, USB serial daemons); driver roulette per machine. |

## 2. Fuchsia OS

**Verdict: NOT viable** as the base for this appliance. Fuchsia the *project* is alive and shipping milestone releases (F31, 2026-07-22), but Fuchsia the *self-installable general-purpose OS* is dead for third parties.

### Project status

Fuchsia is actively developed — milestone releases through **F31** ([release notes index](https://fuchsia.dev/whats-new/release-notes), [F31 notes](https://fuchsia.dev/whats-new/release-notes/f31), dated July 22, 2026) — but the visible product focus is Google-internal: Nest Hub smart displays (the only shipped Fuchsia consumer product, per [9to5google's Fuchsia guide](https://9to5google.com/guides/fuchsia/) and [Fuchsia 16 on Nest Hub coverage](https://9to5google.com/2024/03/01/fuchsia-16-nest-hub-whats-new/)), plus Starnix/virtualization work oriented at Android devices — F31's Starnix changelog includes Qualcomm IPC router sockets (AF_QIPCRTR), a distinctly Android-phone-shaped feature. The "microfuchsia" product targets Fuchsia in VMs on Android devices ([Android Authority](https://www.androidauthority.com/microfuchsia-on-android-3457788/)). Google formally abandoned adjacent general-purpose ambitions: Chrome-on-Fuchsia discontinued January 2024 ([9to5google](https://9to5google.com/2024/01/15/google-is-no-longer-bringing-the-full-chrome-browser-to-fuchsia/)); Fuchsia-on-smart-speakers abandoned 2023 ([9to5google](https://9to5google.com/2023/07/25/google-abandons-assistant-speakers-fuchsia/)).

### Workstation product — CONFIRMED discontinued

The Workstation configuration (desktop-ish shell with Flutter/Ermine UI on an Intel NUC) is gone, confirmed against the primary source tree:

- The `products/` directory on `main` of `fuchsia.git` contains **no `workstation` product** — current entries are `bringup`, `minimal`, `core` (deprecated), `workbench`, `terminal` (deprecated), `microfuchsia`, `tests`, `zedboot`, `kernel_cmdline` ([products/ listing](https://fuchsia.googlesource.com/fuchsia/+/refs/heads/main/products/)).
- The "Build Workstation" doc returns 404 on fuchsia.dev (https://fuchsia.dev/fuchsia-src/development/build/build_workstation) and 404 on the `main` source branch (https://fuchsia.googlesource.com/fuchsia/+/refs/heads/main/docs/development/build/build_workstation.md) — both verified 2026-07-30.
- Secondary coverage: [Hacker News, Dec 2023](https://news.ycombinator.com/item?id=38815828), [OSnews Fuchsia topic](https://www.osnews.com/topic/fuchsia/), [How-To Geek](https://www.howtogeek.com/fuchsia-in-2024-catching-up-with-googles-secret-os/).

The closest surviving equivalent, `workbench`, is a developer-testing product, not a UI product a kiosk could ship on.

### Hardware support

The canonical [Supported system configurations](https://fuchsia.dev/fuchsia-src/reference/hardware/support-system-config) page lists exactly four targets: Astro (AMLogic S905D2G, ARM), Khadas VIM3 (ARM), **Intel NUC11TNHi5**, and **Intel NUC7i5DNHE**. Per [RFC-0130](https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0130_supported_hardware), "supported" applies only to the exact CI-tested configuration, and the RFC contains no statement of AMD CPU support at all. Even the blessed path is broken: the [Install Fuchsia on a NUC guide](https://fuchsia.dev/fuchsia-src/development/hardware/intel_nuc) carries the notice that "As of Jun 9, 2025, the installation workflow using `recovery-installer` is broken at the moment" — broken for over a year on *supported* hardware, and the install image is `core.x64`, not a UI product.

Driver story for an arbitrary Ryzen AI mini PC (checked against driver directories on `main`):

- **GPU: no AMD driver exists.** [src/graphics/drivers/](https://fuchsia.googlesource.com/fuchsia/+/refs/heads/main/src/graphics/drivers/) contains Intel, ARM Mali, virtio, and other drivers — nothing for AMD RDNA/Radeon. Fuchsia's stack (Magma → Vulkan → Scenic → Flutter) is Vulkan-based, so with no Magma driver for the Radeon iGPU there is no accelerated graphics session at all — at best a bootloader framebuffer console. **This alone kills the touch-panel use case.**
- **WiFi: Intel and Broadcom only.** [src/connectivity/wlan/drivers/](https://fuchsia.googlesource.com/fuchsia/+/refs/heads/main/src/connectivity/wlan/drivers/) contains `lib-iwlwifi` (Intel) plus a `third_party/` directory (historically Broadcom brcmfmac). AMD mini PCs commonly ship MediaTek or Realtek WiFi — no drivers. (**UNVERIFIED:** exact current contents of `third_party/`.)
- **Storage: OK on paper** — [src/devices/block/drivers/](https://fuchsia.googlesource.com/fuchsia/+/refs/heads/main/src/devices/block/drivers/) includes `nvme`, `ahci`, `sdhci`/`sdmmc`, `usb-mass-storage`.
- **Board/platform:** both supported x64 targets use the `//src/devices/board/drivers/x86` board driver; whether Zircon even boots to userland on a Ryzen AI (Phoenix/Strix) platform is **UNVERIFIED — no evidence of anyone testing Fuchsia on modern AMD hardware was found**.
- **NPU (Ryzen AI/XDNA): nothing** — no driver, no mention anywhere in the tree or docs.

### Starnix (Linux compatibility layer)

Starnix implements the Linux UAPI so unmodified Linux binaries run natively (no VM), tested with glibc and bionic binaries ([Starnix concepts](https://fuchsia.dev/fuchsia-src/concepts/components/v2/starnix), [kernel README](https://fuchsia.googlesource.com/fuchsia/+/refs/heads/main/src/starnix/kernel), [RFC-0082](https://fuchsia.googlesource.com/fuchsia/+/2940d6f300031e852333c3ee0548ecba1d69c961/docs/contribute/governance/rfcs/NNNN_starnix.md)). It is very active (F31: eBPF hardening, filesystem-sync syscalls, AF_QIPCRTR, faster clock reads), but the feature mix shows its driver is running Android artifacts on Google hardware. There is **no compatibility matrix, no supported third-party workflow, no Docker/OCI story, no systemd**, and no documented path for long-running network daemons with device access (Zigbee/Z-Wave USB dongles, mDNS). Whether a full JVM, Home Assistant, or an MQTT broker runs under Starnix on self-built Fuchsia is **UNVERIFIED and undocumented** — and irrelevant in practice, since a working Fuchsia system can't be gotten onto the AMD box in the first place.

### Flutter on Fuchsia

- **Engine embedder: in-tree, minimally maintained, Google-internal.** The Fuchsia embedder (`engine/src/flutter/shell/platform/fuchsia`) still receives commits — e.g. [flutter/flutter#185440](https://github.com/flutter/flutter/pull/185440), merged 2026-04-28 — but exists to serve Google's own smart-display products.
- **Developer tooling: deleted.** Fuchsia target support was disabled in `flutter_tools` ([flutter/flutter#155111](https://github.com/flutter/flutter/pull/155111), merged 2024-09-12) and the entire `packages/flutter_tools/lib/src/fuchsia` directory was deleted ([flutter/flutter#154880](https://github.com/flutter/flutter/pull/154880), merged 2024-09-17). `flutter build fuchsia` / `flutter run` against a Fuchsia device no longer exists in the Flutter SDK.
- **The embedder-API replacement is dormant.** The standalone runtime at [fuchsia.googlesource.com/flutter-embedder](https://fuchsia.googlesource.com/flutter-embedder/) (per the [2021 roadmap](https://fuchsia.dev/fuchsia-src/contribute/roadmap/2021/flutter_on_fuchsia_velocity)) is explicitly experimental and its last commit is ~3.4 years old — abandoned.

A third party cannot realistically build, deploy, and update a Flutter app on self-installed Fuchsia in 2026. Confidence on the discontinuation/tooling/driver facts is high (checked against fuchsia.dev, fuchsia.googlesource.com `main`, and flutter/flutter via GitHub API on 2026-07-30).

## 3. ChromeOS / ChromeOS Flex

**Verdict: reject for this appliance.** ChromeOS's one genuinely relevant feature — managed kiosk mode that auto-launches a fullscreen web app at boot — costs $25–50/device/year and requires Google Admin console enrollment, and (decisively) there is **no supported way to run the hub server as a 24/7 background service on the same machine**.

### Which ChromeOS applies

ChromeOS proper ships only preinstalled on Chromebook/Chromebox hardware; for generic x86-64 PCs the installable variant is **ChromeOS Flex**. Google "officially certifies only whole-models as configured from OEMs" ([ChromeOS Flex FAQ](https://support.google.com/chromeosflex/answer/11543105?hl=en)); a 2024–2025 Ryzen AI mini PC is almost certainly not on the [certified models list](https://support.google.com/chromeosflex/answer/11513094) (**UNVERIFIED for any specific model** — the list must be checked per model, but it is dominated by older OEM machines). Flex also lacks the Google security chip ("the ChromeOS verified boot procedure is not available"), automatic firmware updates, and guaranteed TPM-backed key protection ([Differences between ChromeOS Flex and ChromeOS](https://support.google.com/chromeosflex/answer/11542901)).

### Custom shell = kiosk mode = paid enrollment

The ChromeOS shell is not replaceable; the supported single-purpose-appliance path is **kiosk mode** — one admin-configured app auto-launched fullscreen at device start ([Manage Chrome kiosk app settings](https://support.google.com/chrome/a/answer/9273974?hl=en)). Supported kiosk app types are web apps / PWAs / Isolated Web Apps ([chromeos.dev/kiosk](https://chromeos.dev/en/kiosk), [Add web apps to Chrome kiosks](https://support.google.com/chrome/a/answer/9781496?hl=en)); Chrome apps in kiosk are deprecated after ChromeOS 150 ([End of support for Chrome apps](https://support.google.com/chrome/a/answer/15950395)). The dollhouse UI would have to be a web app (Flutter web build qualifies); a Flutter *native* Linux build cannot be a kiosk app.

Kiosk apps deploy only to managed (enrolled) devices ([chromeos.dev/kiosk](https://chromeos.dev/en/kiosk)), configured via the Google Admin console ([Enroll ChromeOS devices](https://support.google.com/chrome/a/answer/1360534?hl=en)) — meaning a Google Workspace / Cloud Identity admin account with a verified domain for a single home device. Official pricing ([Kiosk & Signage Upgrade one-pager, services.google.com PDF](https://services.google.com/fh/files/misc/kiosk_signage_upgrade.pdf)): Kiosk & Signage Upgrade **$25/device/year** (no Android apps); Chrome Enterprise Upgrade **$50/device/year**. A one-time Perpetual upgrade (~$150/device) exists via resellers (**UNVERIFIED** against a current Google price page; reseller listings only). There is no free/unmanaged kiosk path on current ChromeOS ([Purchase upgrades](https://support.google.com/chrome/a/answer/7613771?hl=en)). Flex devices can be enrolled after purchasing an upgrade; whether the cheaper Kiosk & Signage Upgrade specifically can enroll Flex devices is not stated in Google's Flex docs (**UNVERIFIED from Google directly**; third-party signage vendors document Flex kiosk deployments as working, e.g. [Screenly's Flex kiosk guide](https://support.screenly.io/hc/en-us/articles/43114739340435-Using-Google-ChromeOS-Flex-in-Kiosk-Mode-with-Screenly-Anywhere)).

### The dealbreaker: no unattended background services

Google's official Linux-on-ChromeOS FAQ ([chromeos.dev Linux FAQ](https://chromeos.dev/en/linux/linux-on-chromeos-faq)):

- Autostart at boot: **"Nope! All VMs (and their containers) need to be manually relaunched."**
- Logout: **"All VMs (and their containers) are tied to your login session. As soon as you log out, all programs are shut down/killed by design."**
- Container data lives in the user's encrypted home directory, mounted only after login; Crostini is available only to the primary user profile and **not in kiosk or managed guest sessions** ([Running Custom Containers Under ChromeOS](https://www.chromium.org/chromium-os/developer-library/guides/containers/containers-and-vms/)).

Consequences: the hub server (Home Assistant / openHAB / custom Java services, MQTT, Zigbee/Matter controller) could only run while a user session is open with Crostini manually started — an OS-update reboot at 3 a.m. leaves the smart home dead until someone logs in. And the kiosk session that would show the dollhouse UI cannot host the Linux backend at all — the two supported modes are mutually exclusive with the two requirements. Community workarounds (auto-login + extension-triggered VM start, e.g. ChromeOS-AutoStart) are unsupported hacks against the platform's explicit security design. On Flex, Crostini support additionally "varies, depending on the specific model" ([Flex differences](https://support.google.com/chromeosflex/answer/11542901)), and Android apps are not supported on Flex at all ([Flex FAQ](https://support.google.com/chromeosflex/answer/11543105?hl=en)).

**Bottom line:** ChromeOS subtracts the one thing the project needs most (unattended services surviving reboots) and charges an annual fee plus Google-cloud enrollment for the one thing it does well (fullscreen kiosk launch), which plain Linux replicates for free.

## 4. Plain Linux + Flutter kiosk

**Verdict: the recommended base.** Everything is inside supported, actively maintained territory.

### Flutter on Linux desktop in 2026

Linux desktop is a fully supported, stable Flutter target. The official supported-platforms page (Flutter 3.44.7, updated 2026-07-17) lists **Debian 10–13** (Debian 12 CI-tested on every commit) and **Ubuntu 20.04–24.04 LTS** (22.04 CI-tested), x64 first-class ([docs.flutter.dev/reference/supported-platforms](https://docs.flutter.dev/reference/supported-platforms)). Stable since Flutter 3, May 2022, with Canonical ([snapcraft.io blog](https://snapcraft.io/blog/bring-multi-platform-apps-to-linux-desktop-with-flutter-3)). Current Debian stable 13 "trixie" (full support to Aug 2028, LTS to Jun 2030 — [debian.org](https://www.debian.org/News/2025/20250809), [releases](https://www.debian.org/releases/)) is inside the supported range.

The Linux embedder is GTK 3-based — hard runtime deps are just `libgtk-3-0 libblkid1 liblzma5` ([building docs](https://docs.flutter.dev/platform-integration/linux/building)) — and runs as a native Wayland client ([flutter/flutter#57932](https://github.com/flutter/flutter/issues/57932), closed completed 2020-10-21).

**Touch input:** a Wayland touch regression ([flutter/flutter#182606](https://github.com/flutter/flutter/issues/182606), opened 2026-02-19) was fixed and closed 2026-05-22, with the reporter confirming everything works on Ubuntu 26.04 with stable 3.44 — **practical rule: use Flutter ≥ 3.44 for a Wayland touch panel**. A long-open wart ([flutter/flutter#90366](https://github.com/flutter/flutter/issues/90366), touch delivered as mouse events breaking fling scroll) appears stale — the current embedder maps `GDK_SOURCE_TOUCHSCREEN` to the touch device kind ([fl_view.cc reference](https://api.flutter.dev/linux-embedder/fl__view_8cc.html)) — but merits a 10-minute hands-on fling/inertia test early. Complex multi-finger gestures are less battle-tested on Linux than Android/iOS; prototype the dollhouse pan/zoom gestures before committing.

### Kiosk compositors (no desktop environment needed)

Flutter needs only a Wayland compositor (or X server) plus GTK 3 libs:

- **cage** — purpose-built Wayland kiosk compositor: "displays a single maximized application at a time" ([cage-kiosk.github.io](https://cage-kiosk.github.io/cage/), [README](https://github.com/cage-kiosk/cage/blob/master/README.md)); the author lists home-automation panels as a target use ([hjdskes.nl](https://www.hjdskes.nl/projects/cage/)). Actively maintained: v0.3.1 released 2026-06-30, last push 2026-07-20. Usage: `cage /path/to/app`. Boot-to-app plumbing is documented in the [cage wiki systemd recipe](https://github.com/cage-kiosk/cage/wiki/Starting-Cage-on-boot) (`cage@tty1.service` + small PAM stack with `pam_systemd.so`, `graphical.target` default).
- **Weston kiosk-shell** — the reference compositor's dedicated kiosk shell force-fullscreens every toplevel ([weston docs](https://wayland.pages.freedesktop.org/weston/toc/kiosk-shell.html)); distro-packaged alternative.
- **labwc** — minimal wlroots stacking compositor, default on Raspberry Pi OS, used in RPi kiosk guides ([labwc.github.io](https://labwc.github.io/getting-started.html), [github](https://github.com/labwc/labwc), [RPi forum threads](https://forums.raspberrypi.com/viewtopic.php?t=378883), [linuxjunkies.org guide](https://linuxjunkies.org/guides/raspberry-pi-kiosk-mode)). 0.20.1 released 2026-06-15.
- **Ubuntu Frame** — Canonical's Mir-based kiosk compositor, explicitly documented as compatible with Flutter, Qt, GTK, Electron, SDL2, with touch and an on-screen keyboard built in ([ubuntu.com/frame docs](https://ubuntu.com/frame/docs/24/how-to/packaging-iot-gui/packaging-an-application/), [snapcraft.io/ubuntu-frame](https://snapcraft.io/ubuntu-frame)). Pulls you into snap packaging, but it is the one kiosk compositor whose vendor documents Flutter as a supported client — and it installs on regular Ubuntu Server too.

**UNVERIFIED (minor):** no published example of specifically *Flutter-under-cage* was found; closest verified evidence is the GTK embedder running natively on Wayland with touch confirmed working, and Ubuntu Frame (an equally bare Wayland kiosk compositor) officially supporting Flutter clients. Risk is low; mitigations: `GDK_BACKEND=x11` + cage's XWayland, or switch to Weston kiosk-shell/labwc. Budget a half-day spike.

### Lightweight embedders (fallbacks)

- **flutter-pi** ([github.com/ardera/flutter-pi](https://github.com/ardera/flutter-pi)) runs directly on KMS/DRI with no X11/Wayland; the README explicitly supports x86-64, and AMD's `amdgpu` driver provides the required modesetting. Release 1.1.1 on 2026-01-31. Trade-offs: GTK-embedder-native plugins don't work, and scroll inertia through the C embedder API has a known gap ([flutter/flutter#120020](https://github.com/flutter/flutter/issues/120020)).
- **Sony flutter-embedded-linux / flutter-elinux** ([github](https://github.com/sony/flutter-embedded-linux)) supports x64 with Wayland/DRM backends, but its latest release is 3.27.1 (2024-12-19) — roughly a year behind stable and below the ≥3.44 Wayland-touch requirement. Disqualifying for the touch panel today.
- Older direct-Wayland embedders ([chinmaygarde/flutter_wayland](https://github.com/chinmaygarde/flutter_wayland), [LibertyGlobal/flutter-embedder-wayland](https://github.com/LibertyGlobal/flutter-embedder-wayland)) are abandoned — ignore.

On a 32 GB x86 box there is no resource pressure justifying a custom embedder; the official GTK embedder under cage is the supported path.

### Hardware note (AMD Ryzen AI)

Ryzen AI 300 "Strix Point" (RDNA 3.5 / Radeon 890M-class iGPU) is well supported by the open AMD stack but wants a recent kernel + Mesa: Phoronix found a smooth experience with kernel 6.14 + Mesa 25.0 and recommends "as new a distribution as possible" ([Framework 13 Strix Point review](https://www.phoronix.com/review/framework-13-amd-strix-point), [one-year-later retest](https://www.phoronix.com/review/amd-strix-point-2025)). Prefer **Ubuntu 24.04 LTS + HWE kernel** or **Debian 13** (kernel 6.12 LTS; use a backports kernel if graphics glitches appear). **UNVERIFIED:** exact iGPU model in the specific mini PC — check the SKU before choosing distro/kernel.

## 5. Plain Linux + browser kiosk

**Verdict: viable, and the most field-proven wall-panel stack of 2026** — it is what the RPi/Home Assistant community converged on after Raspberry Pi OS went Wayland.

- **Chromium:** `chromium --kiosk --ozone-platform=wayland <url>` is the standard recipe used by current HA kiosk projects ([kr1schan/rpi-ha-kiosk](https://github.com/kr1schan/rpi-ha-kiosk), [cage+Chromium NixOS kiosk write-up](https://stefansblog.org/posts/cage-kiosk---ein-wayland-kiosk-auf-basis-von-nixos-und-chromium/)). Chrome 140 (stable Aug/Sep 2025) shipped `--ozone-platform-hint=auto` as default, auto-selecting Wayland ([Phoronix](https://www.phoronix.com/news/Chromium-Ozone-Wayland-2025), [OMG! Ubuntu](https://www.omgubuntu.co.uk/2025/08/chrome-140-wayland-auto-detection-linux), [Ozone docs](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/ozone_overview.md)). Rough edges: a historical `--kiosk` fullscreen bug on Ozone/Wayland ([issues.chromium.org/40189002](https://issues.chromium.org/issues/40189002) — moot under cage, which maximizes everything), and Chromium's Wayland `text-input` (on-screen keyboard) support is weaker than Firefox's (per the [rpi-ha-kiosk README](https://github.com/kr1schan/rpi-ha-kiosk)).
- **Firefox:** documented enterprise kiosk mode (`firefox -kiosk <url>`, [support.mozilla.org](https://support.mozilla.org/en-US/kb/firefox-enterprise-kiosk-mode)); native Wayland default since Firefox 121 (Dec 2023), which also brought touchscreen gestures and swipe navigation ([Phoronix](https://www.phoronix.com/news/Firefox-121-Available), [OMG! Ubuntu](https://www.omgubuntu.co.uk/2023/12/firefox-121-released-now-defaults-to-wayland-on-linux)). Prefer Firefox (or add wvkbd/squeekboard) if an on-screen keyboard matters.

### Prior art (both Linux paths)

- **[puterboy/HAOS-kiosk](https://github.com/puterboy/HAOS-kiosk)** — HA add-on rendering dashboards on the HA server's own HDMI output, "tested on both RPis and mini-PCs" ([HA community thread, v1.2.0](https://community.home-assistant.io/t/major-update-v1-2-0-haoskiosk-add-on-display-your-dashboards-directly-on-your-haos-server/975086)). The exact "hub + panel on one always-on box" shape — proof the pattern works.
- **[kunaalm/HA-Chromium-Kiosk](https://github.com/kunaalm/ha-chromium-kiosk)** — Chromium kiosk on plain Debian: dedicated kiosk user, DM-less auto-login, systemd service at boot.
- **[kr1schan/rpi-ha-kiosk](https://github.com/kr1schan/rpi-ha-kiosk)** — Ansible-provisioned Wayland touchscreen HA kiosk with OSK and HA-automation-controlled display power.
- DIY x86 mini-PC touch panel builds: [HA community large-kiosk thread](https://community.home-assistant.io/t/help-with-a-large-kiosk-control-panel-16-18-screen/393074), [onporpoise NUC+touchscreen build](https://www.onporpoise.co.uk/home-assistant-touchscreen-kiosk-build-part-1-hardware-setup/).
- **Flutter smart-home panels specifically: prior art is thin.** Notable Flutter HA clients — HA Client ([discontinued](https://community.home-assistant.io/t/discontinued-ha-client-native-android-client-for-home-assistant/69912)) and HassKit — are dead/stale, and were phone apps. Snapp X documents Flutter kiosk deployments on embedded Linux ([Medium/Snapp X](https://medium.com/snapp-x/flutter-on-embedded-devices-7070b5907b91)); Canonical documents Flutter kiosks on Ubuntu Frame/Core ([ubuntu.com/frame docs](https://ubuntu.com/frame/docs/24/how-to/packaging-iot-gui/packaging-an-application/), [Running Flutter Apps on Ubuntu Core](https://medium.com/nerd-for-tech/running-flutter-apps-on-ubuntu-core-31453d4fed2a)). A custom dollhouse Flutter panel is pioneering territory UI-wise, but the *platform* layer (Flutter GTK app in a Wayland kiosk) is within documented, supported behavior.

## 6. Other appliance-OS options

- **Ubuntu Core + Ubuntu Frame — the one credible "appliance OS" contender.** Immutable, transactional OTA updates, strictly confined snaps, first-party Flutter kiosk documentation ([ubuntu.com/frame](https://ubuntu.com/frame/docs/24/how-to/packaging-iot-gui/packaging-an-application/), [Ubuntu Core docs](https://documentation.ubuntu.com/core/how-to-guides/using-ubuntu-core/)). Cost: everything (hub, Zigbee tooling, panel app) must be snap-packaged, which fights a Java/Docker-centric hub stack and slows iteration. Reasonable to revisit once the system design is frozen; wrong choice for the build phase. Ubuntu Frame itself installs fine on regular Ubuntu Server, giving its Flutter-tested compositor without Ubuntu Core.
- **webOS OSE — not viable for this hardware.** Alive (2.28.0, March 2025) but its only supported physical target is Raspberry Pi 4; the sole x86-64 artifact is a VirtualBox/qemux86-64 dev-emulator image ([webosose.org system requirements](https://www.webosose.org/docs/guides/setup/system-requirements/), [build-webos releases](https://github.com/webosose/build-webos/releases)). Web-app-centric (Qt/Enact), not Flutter-first. Skip.
- **Android-x86 — dead; Bliss OS — alive but wrong fit.** Android-x86's last release is 9.0-r2, March 2020 ([Phoronix](https://www.phoronix.com/news/Android-x86-9.0-r2), [changelog](https://www.android-x86.org/changelog.html)). Bliss OS is actively developed ([blog.blissos.org](https://blog.blissos.org/), [github](https://github.com/BlissOS)) and would run a Flutter Android build with excellent touch, but the same box must host the 24/7 hub — JVM services, Docker, Zigbee/Z-Wave USB serial daemons — which Android is hostile to, plus per-machine driver roulette. Only sensible if the panel were a separate device, and even then a tablet beats it. Skip.

## 7. Recommendation

**Ranked:**

1. **Plain Linux + Flutter kiosk (primary).** Debian 13 *or* Ubuntu Server 24.04 LTS (Ubuntu 24.04 + HWE kernel favored for Strix Point graphics), no desktop environment, no display manager. Boot flow: systemd `graphical.target` → `cage@tty1.service` (dedicated unprivileged `kiosk` user, PAM auto-session per the [cage wiki recipe](https://github.com/cage-kiosk/cage/wiki/Starting-Cage-on-boot)) → cage launches the Flutter app with `Restart=always`. Flutter pinned **≥ 3.44 stable** (Wayland touch fix). Display power via `wlr-randr`/`wlopm` driven by hub automations (pattern proven in [rpi-ha-kiosk](https://github.com/kr1schan/rpi-ha-kiosk)). The hub server runs as ordinary systemd services beside the UI, fully independent of the display stack — a UI crash never touches the hub. **Day-one spike:** run the default Flutter counter app under cage on the actual touchscreen and verify tap, drag, fling inertia, and multi-touch before building the dollhouse UI.
2. **Plain Linux + browser kiosk (fallback, lower risk).** Same base + cage + Chromium `--kiosk --ozone-platform=wayland`, or Firefox `-kiosk` if on-screen-keyboard/text-input matters. The single most field-proven wall-panel stack of 2026, at the cost of native dollhouse rendering control.
3. **Ubuntu Core + Ubuntu Frame (revisit later).** A hardening/appliance-ification step once the system design is frozen, if transactional updates and confinement become priorities — not for the build phase.
4. **ChromeOS/Flex and Fuchsia: rejected** for the reasons in sections 2–3; no conditions identified under which either becomes viable for this project.

**What this keeps open:**

- **Flutter vs. web UI stays reversible.** Both top options share the identical OS/compositor/systemd substrate; swapping the single app cage launches is the only change.
- **Compositor fallbacks in order** if a GTK/Wayland quirk bites: Weston kiosk-shell (distro-packaged, same shape) → labwc (if more than one window is ever needed) → `GDK_BACKEND=x11` under cage's XWayland → flutter-pi direct-to-KMS (verified x86-64; drops the compositor but also GTK-plugin compatibility and scroll-inertia polish).
- **Hub stack is unconstrained.** Full systemd means any mix of JVM services, Docker/OCI containers, MQTT brokers, and Zigbee/Z-Wave USB daemons — the exact workload ChromeOS and Fuchsia could not host.
- **Later appliance-ification path** via Ubuntu Frame on regular Ubuntu (no Ubuntu Core commitment) or full Ubuntu Core once iteration slows.
