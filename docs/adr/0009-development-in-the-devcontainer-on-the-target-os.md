# Development happens in the devcontainer, on the target OS

By 2026-08-05 development was documented across two machines: natively on
the Intel laptop — Ubuntu 26.04, which is also ADR-0008's interim
production Hub host — with a Mac as an optional secondary for Panel UI
work. That arrangement carried three costs that grew with the project.
Ubuntu 26.04 is outside Flutter's documented Linux support range
(20.04–24.04 — [`../research/platform-os-feasibility.md`](../research/platform-os-feasibility.md)),
so every host toolchain quirk was ours alone to own. A kiosk bundle
linked on 26.04 carries no guarantee it runs on the mini PC's Ubuntu
Server 24.04 — glibc symbol versioning only promises forward
compatibility, never backward
([`../research/flutter-cage-spike.md`](../research/flutter-cage-spike.md)
build logistics). And because the dev workstation and the production Hub
host are one machine, host-run development kept a standing invitation to
collide with the real house — realised on 2026-08-05, when the first
devcontainer `up` died on production's ports, and answerable only by the
shifted-port discipline `hub/dev/compose.yaml` now documents.

**Decision (2026-08-06):** all development and testing happens inside the
repo's devcontainer ([`../../.devcontainer/`](../../.devcontainer/)):
Ubuntu 24.04 — the mini-PC target OS (ADR-0001) — with Flutter pinned,
the full web and Linux desktop toolchains, and the dev Hub stack
(`hub/dev/`) brought up automatically as sibling containers on shifted
host ports. The devcontainer is also the canonical golden host: goldens
are baked in the image and are expected green there, nowhere else.
Native host development and Mac-host development are no longer documented
flows; the Mac develops through the same devcontainer (the images ship
arm64 variants; Chrome is amd64-only, which the Dockerfile documents).

The empirical basis, all verified in-container on 2026-08-06 before
deciding: the full test suite at exact host parity; `flutter build linux
--release` producing a bundle whose measured glibc ceiling (`GLIBC_2.34`)
runs on both the 24.04 target and the 26.04 interim host; the web dev
loop against the dev Hub; the live end-to-end Hub test; Ring, MQTT and
go2rtc bring-up; and golden determinism — the pre-decision in-image run
reproduced the host baseline's failures exactly, no more, no fewer.

**What this does not change.** ADR-0008's core stands untouched:
multicast-dependent integrations require a Linux host with host
networking, and the production Hub stack runs on the interim host (the
mini PC later), never in the devcontainer — bridge networking cannot
carry mDNS, so nothing discovery-dependent may even be attempted there.
Hardware stays physical: the cage spike, the touchscreen, and GPU
performance judgments happen on metal (the container renders through
llvmpipe — fine for tests and goldens, meaningless for animation
verdicts). Sweet Home 3D remains a host-side GUI application; only its
converter runs in-container.

**Supersedes:** the "Mac keeps exactly two roles" clause of ADR-0008 —
Panel development and the `hub/dev/` sandbox both moved into the
devcontainer — and the root README's "Development topology (decided
2026-07-30)". The Linux-only rule for the multicast stack, 0008's actual
decision, is not reopened.

**Reopen when** the target OS moves — a purchased mini PC on a different
LTS moves the base image with it, which is the point of pinning to the
target — or when Flutter's supported range leaves 24.04 behind, or if
the devcontainer ever fails to reproduce a defect that manifests on the
appliance (that would mean the parity claim broke, and the container
stops being evidence).
