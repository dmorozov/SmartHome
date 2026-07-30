# Frigate on an AMD Ryzen AI (Strix Point) Mini PC — Acceleration, Architecture, Storage, Integration

Research date: 2026-07-30. Target: Frigate NVR, 24/7 recording + object detection, 5–8 consumer cameras, Ryzen AI 300-series ("Strix Point", XDNA2 NPU, RDNA3.5 iGPU e.g. Radeon 880M/890M), 32 GB RAM, Linux.

**Frigate version landscape (verified via GitHub releases API on 2026-07-30):**

| Version | Date | Status |
|---|---|---|
| v0.17.2 | 2026-06-28 | current stable |
| v0.17.1 / v0.17.0 | 2026-03-22 / 2026-02-27 | stable line |
| v0.16.x | 2025-08 → 2026-01 | previous stable |
| v0.18.0-beta1/beta2 | 2026-07-12 / 2026-07-26 | pre-release (ROCm 7.2.0, RDNA4 support) |

Source: <https://github.com/blakeblackshear/frigate/releases>

---

## 1. Object-detection accelerator status (as of Frigate 0.17.2 / July 2026)

### 1a. AMD ROCm / iGPU detector

- **How it works today:** the dedicated "ROCm MiGraphX detector" was **removed in 0.17.0**; AMD GPUs are now used via the generic **ONNX detector** running on the `-rocm` Docker image (`ghcr.io/blakeblackshear/frigate:stable-rocm`), which bundles ONNX Runtime with the ROCm/MiGraphX execution provider. Requires passing `/dev/kfd` and `/dev/dri` into the container. Sources: [release notes](https://github.com/blakeblackshear/frigate/releases), [object detectors docs](https://docs.frigate.video/configuration/object_detectors).
- **iGPU support is unofficial.** Frigate docs: ROCm does not officially support integrated GPUs; iGPUs need `HSA_OVERRIDE_GFX_VERSION`. Frigate auto-maps gfx1031→10.3.0 and gfx1103→11.0.0; other chipsets need a manual override ([docs](https://docs.frigate.video/configuration/object_detectors)). Strix Point's iGPU is **gfx1150** (RDNA3.5) — not in Frigate's auto-map, so expect to set `HSA_OVERRIDE_GFX_VERSION=11.5.0` manually (UNVERIFIED for Frigate specifically; the gfx1150→11.5.0 mapping follows the standard gfx-number convention).
- **ROCm itself now lists Strix silicon:** AMD's current ROCm compatibility matrix lists Ryzen AI 9 HX 370/375 etc. (gfx1150) and Ryzen AI Max (gfx1151) ([ROCm compatibility matrix](https://rocm.docs.amd.com/en/latest/compatibility/compatibility-matrix.html)). Frigate **0.18 beta** upgrades the `-rocm` image to **ROCm 7.2.0** ([0.18.0-beta1 notes](https://github.com/blakeblackshear/frigate/releases/tag/v0.18.0-beta1)). The ROCm version inside the 0.17 image is UNVERIFIED (older than 7.2).
- **Field reports on Ryzen AI 300 class:**
  - Ryzen AI 9 HX 370 (Radeon 890M, gfx1150) running Frigate dev builds with ROCm 7.1.1 drivers: iGPU performs "decently under onnx detectors depending on the model sizes" (Dec 2025) — [discussion #18570](https://github.com/blakeblackshear/frigate/discussions/18570).
  - Known instability on the adjacent RDNA3 APU class (780M/gfx1103): periodic "Detection appears to be stuck" + GPU hangs; maintainer attributes it to AMD firmware/driver, no permanent fix; some users fall back to CPU — [discussion #19853](https://github.com/blakeblackshear/frigate/discussions/19853). A 780M memory-access-fault case was fixed by **not** installing `amdgpu-dkms` (use the in-kernel driver) — [discussion #21890](https://github.com/blakeblackshear/frigate/discussions/21890).
  - Maintainer position (NickM-27, [discussion #20810](https://github.com/blakeblackshear/frigate/discussions/20810)): on AMD, only **object detection and video decoding** are reliable; enrichments (semantic search, face recognition) are unstable on ROCm and fall back to CPU; for new dedicated Frigate boxes they still steer people to Intel (e.g. Core Ultra 125H).
- **Performance reference:** Frigate hardware docs list AMD 8700G (780M-class iGPU) at ~20–40 ms inference depending on model size ([hardware docs](https://docs.frigate.video/frigate/hardware/)) — usable but slower than Hailo/Intel NPU/Arc.

### 1b. AMD XDNA / XDNA2 NPU

- **Kernel:** the `amdxdna` accel driver is **mainline since Linux 6.14** (March 2025) and covers Ryzen AI 300 "Strix Point" NPUs (device 17f0); NPU firmware is in linux-firmware ([kernel docs](https://docs.kernel.org/accel/amdxdna/amdnpu.html), [Phoronix](https://www.phoronix.com/forums/forum/linux-graphics-x-org-drivers/open-source-amd-linux/1509807-amd-npu-firmware-upstreamed-for-the-ryzen-ai-amdxdna-driver-coming-in-linux-6-14)). Caveat: community reports that linux-firmware blobs have at times been protocol-incompatible with parts of the userspace stack ([Gentoo wiki notes](https://wiki.gentoo.org/wiki/User:Lockal/AMDXDNA)); the out-of-tree [amd/xdna-driver](https://github.com/amd/xdna-driver) + XRT userspace remains the reference stack.
- **Userspace/ONNX:** the Ryzen AI Software stack (ONNX Runtime + Vitis AI EP) is Windows-first. Linux wheels for onnxruntime-vitisai on XDNA2 are not generally published — users are still requesting Linux binaries from AMD in 2026 ([RyzenAI-SW issue #319](https://github.com/amd/RyzenAI-SW/issues/319), [Vitis AI EP docs](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html), [Ryzen AI docs](https://ryzenai.docs.amd.com/en/latest/index.html)). Status of official Linux support in Ryzen AI SW 1.7/1.8: partial/early — UNVERIFIED in detail.
- **Frigate:** there is **no official XDNA detector**. One user built a custom Frigate image with ONNX Runtime + VitisAI EP on **Strix Halo** (Ubuntu 25.10, xdna driver 2.21): YOLOx-s INT8 ran on the NPU at **~16 ms** with only 1–5 % NPU utilization — *slower than the same box's iGPU via MiGraphX (~6 ms)* — and the build required glibc hacks and `docker commit` to preserve. Maintainer (Feb 2026): "we were not aware that the NPU was working," invited a contribution; nothing merged as of 0.18-beta2 — [discussion #21906](https://github.com/blakeblackshear/frigate/discussions/21906). Maintainers separately confirmed "the NPU work in 0.17 is for Intel, not AMD" ([#20810](https://github.com/blakeblackshear/frigate/discussions/20810)).
- Note: [discussion #14186](https://github.com/blakeblackshear/frigate/discussions/14186) ("AMD CPU XDNA(NPU) … 3ms") is misleadingly titled — the fast result there is OpenVINO **on the CPU**, not the NPU.
- **Bottom line:** the XDNA2 NPU is not a practical Frigate detector on Linux in mid-2026. Treat it as a future upgrade, not a plan.

### 1c. OpenVINO on AMD CPUs

- Frigate docs explicitly say OpenVINO "runs on Intel **and AMD CPUs** … despite having no official support" — CPU plugin only (no AMD GPU/NPU via OpenVINO) ([object detectors docs](https://docs.frigate.video/configuration/object_detectors)).
- Real-world: a Ryzen 7940HS mini PC reported 3–5 ms inference with OpenVINO `device: CPU` and a small model ([#14186](https://github.com/blakeblackshear/frigate/discussions/14186)). Cost: sustained CPU load per detection stream; on a Strix Point CPU (Zen 5, 10–12 cores) 5–8 cameras is comfortably feasible as a fallback.

### 1d. Coral USB TPU

- **No longer recommended.** Frigate hardware docs now state the Coral "is no longer recommended for new Frigate installations, except in deployments with particularly low power requirements," while support continues "for as long as practicably possible" ([hardware docs](https://docs.frigate.video/frigate/hardware/); see also [discussion #18564 "Coral TPU probably abandoned"](https://github.com/blakeblackshear/frigate/discussions/18564)).
- Google effectively stopped Coral development around 2023; core libraries (libedgetpu, pycoral) largely unmaintained since ~2022 with community builds keeping them working; hardware still purchasable through resellers but framed in the press as discontinued ([XDA](https://www.xda-developers.com/intels-cheapest-cpus-do-what-googles-coral-accelerators/)). Frigate did add YOLOv9 support on Coral in 0.17.x, but the 8 MB on-chip ceiling keeps it limited to small models. Not the right choice for a new 2026 build.

### 1e. Hailo-8 / 8L (M.2)

- **Officially supported and now the top recommendation** in Frigate's hardware docs: Hailo-8 ≈ 7 ms, Hailo-8L ≈ 11 ms with the default YOLOv6n model, "consistent performance even with multiple cameras running concurrently"; auto-detects 8 vs 8L and picks default models; M.2 A+E/B+M/2242/2280 form factors ([hardware docs](https://docs.frigate.video/frigate/hardware/), [object detectors docs](https://docs.frigate.video/configuration/object_detectors)).
- Proven to coexist with AMD APU hosts (780M + Hailo-8 in [#21890](https://github.com/blakeblackshear/frigate/discussions/21890); a 17-camera 4K build on AMD with two Hailo M.2 cards in [#18570](https://github.com/blakeblackshear/frigate/discussions/18570)). Requires the Hailo driver (hailort) on the host and passing the device into Docker.

### Concrete recommendation for this box

1. **Buy a Hailo-8L (or Hailo-8) M.2 module** for the mini PC's spare M.2 slot (most Strix Point minis have a second 2280 or A+E-key slot — verify the slot exists before ordering). It is officially supported, ~7–11 ms deterministic inference, handles 8 cameras with headroom, and completely sidesteps ROCm-on-iGPU instability. Use the RDNA3.5 iGPU only for VAAPI decode.
2. **Plan B (no free slot / no extra spend):** run the `-rocm` image with the ONNX detector on the gfx1150 iGPU (`HSA_OVERRIDE_GFX_VERSION=11.5.0`, in-kernel amdgpu driver, no `amdgpu-dkms`), preferably on **Frigate 0.18** once stable (ROCm 7.2.0). Expect ~20–40 ms with YOLOv9-s/t class models — fine for 5–8 cameras — but treat GPU-hang reports on AMD iGPUs as a live risk.
3. **Plan C (zero-risk fallback):** OpenVINO detector with `device: CPU` and a 320×320 model — works today on AMD, ~3–5 ms reported, at the cost of CPU load.
4. **Do not** plan around the XDNA2 NPU (no supported path, DIY result was slower than the iGPU) or a Coral USB (officially de-recommended for new installs).

---

## 2. Hardware video decode (VAAPI on RDNA3.5)

- **Frigate config** ([hwaccel docs](https://docs.frigate.video/configuration/hardware_acceleration_video/)):

  ```yaml
  ffmpeg:
    hwaccel_args: preset-vaapi
  ```

  plus container env `LIBVA_DRIVER_NAME=radeonsi` and `/dev/dri` mapped into the container (`renderD128`). The VAAPI preset does automatic profile selection, "so it will work automatically with both **H.264 and H.265** streams."
- **Codec capability of the Strix Point VCN:** H.264 and HEVC decode (Polaris-and-newer per Mesa/radeonsi), and **AV1 decode** (supported on "Ryzen 6000 mobile APU and newer" — Strix Point qualifies) ([Jellyfin AMD HWA docs](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/amd/)). HEVC 10-bit decode is supported by this VCN generation (UNVERIFIED against an official AMD table; confirm on-device with `vainfo`).
- **Distro gotcha:** Fedora ships Mesa with H.264/H.265 VAAPI disabled for patent reasons — install the RPM Fusion "freeworld" Mesa drivers; Debian/Ubuntu Mesa works out of the box ([Jellyfin docs](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/amd/)).
- Load-wise, decoding 5–8 consumer streams (sub-stream for detect + main stream for record; record is stream-copy, no decode) is trivial for this VCN. Frigate 0.18-beta2 also fixed a VAAPI birdseye-encode preset for ffmpeg 8 ([beta2 notes](https://github.com/blakeblackshear/frigate/releases/tag/v0.18.0-beta2)).

---

## 3. go2rtc restreaming; Ring and Wyze in 2026

- **Architecture:** Frigate embeds **go2rtc v1.9.10** (0.17 docs). Recommended pattern: define the camera once under `go2rtc:` streams, then point Frigate's `detect`/`record` roles (and HA/other consumers) at `rtsp://127.0.0.1:8554/<name>` so the physical camera holds a single connection. go2rtc sources include rtsp, ffmpeg, http/flv, exec, webrtc, homekit, etc. ([restream docs](https://docs.frigate.video/configuration/restream)).
- **Ring — works, with caveats.** [ring-mqtt](https://github.com/tsightler/ring-mqtt) (tsightler) remains the maintained path: it exposes an **RTSP gateway** (its own embedded go2rtc) for live streams and event playback, which you feed into Frigate's go2rtc as an rtsp source. Status 2026: still actively maintained; Ring API changes during 2025–2026 periodically broke socket connections and required ring-client-api updates, and HA core 2026.4.1 had a Ring snapshot regression — i.e. functional but inherently fragile, cloud-dependent, and **not suitable for 24/7 continuous recording** (streams are on-demand and battery cams throttle; use event-driven live views only). Ring's official **Partner API** now offers WebRTC/WHEP + RTSP and clip download, but with a mandatory server-side **watermark** on all media ([Ring release notes](https://developer.amazon.com/docs/ring/release-notes.html), [ring-mqtt releases](https://github.com/tsightler/ring-mqtt/releases), [HA issue #167406](https://github.com/home-assistant/core/issues/167406)).
- **Wyze — works, with caveats.** [docker-wyze-bridge](https://github.com/mrlt8/docker-wyze-bridge) (mrlt8, plus the active [IDisposable fork](https://github.com/IDisposable/docker-wyze-bridge)) still bridges Wyze cams to local RTSP/WebRTC/HLS without subscription; requires a **Wyze developer API ID/key** (since 2024). Risk: Wyze firmware updates have broken the underlying TUTK protocol on some newer models (early-2025 update disabled TUTK on new V4 units) — pin camera firmware where possible. RTSP output feeds Frigate directly or via go2rtc ([wyze-bridge ↔ Frigate issue #1017](https://github.com/mrlt8/docker-wyze-bridge/issues/1017)).
- **Practical guidance:** treat Ring/Wyze as second-class sources (live view + event clips); put any camera you want 24/7-recorded on native RTSP (PoE/ONVIF) hardware.

---

## 4. Storage sizing and retention

- **Frigate's own guidance** deliberately avoids per-camera GB numbers; the [planning docs](https://docs.frigate.video/frigate/planning_setup/) list the variables (camera count, resolution/framerate, recording method, retention) and point to external calculators (e.g. IPConfigure). Media guidance from the same page: SSDs fine ("modern drives unlikely to wear out during typical home NVR use"), NVR-rated HDDs (WD Purple / Seagate SkyHawk) recommended for cost, network storage cautioned against.
- **Arithmetic (not a citation):** continuous recording consumes `bitrate (Mbps) × 10.8 GB/day` per camera. Typical consumer main streams:
  - 2 Mbps (1080p efficient/H.265) ≈ **22 GB/day/cam**
  - 4 Mbps (typical 2K–4MP H.264/H.265) ≈ **43 GB/day/cam**
  - 8 Mbps (4K) ≈ **86 GB/day/cam**
  - Example: 6 cams @ 4 Mbps ≈ 260 GB/day → **~1.8 TB/week**; a 4 TB drive holds ~15 days of full-continuous; H.265 on the cameras roughly halves this.
- **Retention config (0.17+, fully tiered)** ([record docs](https://docs.frigate.video/configuration/record)):

  ```yaml
  record:
    enabled: true
    continuous: { days: 7 }      # everything
    motion:     { days: 14 }     # motion segments kept longer
    alerts:     { retain: { days: 30 } }
    detections: { retain: { days: 30 } }
  ```

  Frigate auto-deletes the oldest recordings when free space falls below ~1 hour of headroom, regardless of retention settings. Segments buffer in `/tmp/cache` (mount as tmpfs) before being written out.
- **SSD endurance:** 260 GB/day ≈ 95 TB written/year of sequential video. A 1 TB consumer TLC drive (~600 TBW) lasts ~6 years at that rate; a 2–4 TB drive proportionally longer. Sequential large-segment writes are the friendly case for SSDs; the real endurance killers (constant small DB writes) are mitigated by keeping `/tmp/cache` on tmpfs. Practical setup for this mini PC: OS + Frigate DB on the primary NVMe, recordings on a second high-capacity NVMe/SATA SSD or an external/NAS-avoided USB HDD; avoid SD/eMMC entirely.

---

## 5. Integration surface for a custom UI

- **MQTT** ([MQTT docs](https://docs.frigate.video/integrations/mqtt)) — the primary event bus:
  - `frigate/events` — per-tracked-object lifecycle messages with parallel `before`/`after` JSON (id, camera, label, score, bounding box, zones, attributes like face/plate).
  - `frigate/reviews` — review items with severity (`detection`/`alert`); `frigate/stats` (mirror of `/api/stats`); `frigate/available` (online/offline); `frigate/triggers` (semantic-search triggers).
  - Per camera: `frigate/<camera>/<object>/snapshot` (JPEG), `frigate/<camera>/motion`, `audio/<type>`, `audio/dBFS`, plus paired state/command topics — `detect/state|set`, `recordings/state|set`, `enabled/state|set`, `snapshots`, `ptz`, `birdseye_mode/set`, `notifications/…`. Everything togglable from a custom dashboard via the `…/set` topics.
- **REST API** ([HTTP API reference](https://docs.frigate.video/integrations/api/frigate-http-api)) — full OpenAPI-documented surface under `/api/`: Auth, Events, Review, Media (snapshots/clips/recordings/previews), Export, Logs, Notifications, App/config, stats. Auth endpoints exist (JWT-based in 0.14+); schemas are published in the docs (45 schema objects), so you can generate a typed client.
- **WebSocket** — Frigate runs a WebSocket communicator at `/ws` that relays the same topic/payload structure as MQTT (used by Frigate's own frontend; you can subscribe and publish allowed command topics — internal IPC topics are blocked server-side; verified in [`frigate/comms/ws.py`](https://github.com/blakeblackshear/frigate/blob/v0.17.2/frigate/comms/ws.py)). Live video for a custom UI: MSE via go2rtc's WS endpoint (`/live/mse/api/ws?src=<camera>`), WebRTC via go2rtc, or the low-fi jsmpeg WS at `/live/jsmpeg/<camera>` ([live view docs](https://docs.frigate.video/configuration/live/)).
- **Home Assistant** ([HA integration docs](https://docs.frigate.video/integrations/home-assistant)) — official custom integration via HACS; requires the HA MQTT integration pointed at the same broker. Provides camera + image entities, occupancy/motion binary sensors per camera/zone/object, perf sensors, switches for detect/record/snapshots, a media browser for clips/snapshots, casting, and proxy endpoints for notification media. A custom UI can coexist: MQTT and REST are unaffected by HA's presence.

---

### Sources (primary)

- Frigate docs: [object detectors](https://docs.frigate.video/configuration/object_detectors) · [hardware](https://docs.frigate.video/frigate/hardware/) · [hwaccel](https://docs.frigate.video/configuration/hardware_acceleration_video/) · [restream](https://docs.frigate.video/configuration/restream) · [record](https://docs.frigate.video/configuration/record) · [planning](https://docs.frigate.video/frigate/planning_setup/) · [MQTT](https://docs.frigate.video/integrations/mqtt) · [HTTP API](https://docs.frigate.video/integrations/api/frigate-http-api) · [HA](https://docs.frigate.video/integrations/home-assistant) · [live](https://docs.frigate.video/configuration/live/)
- Frigate GitHub: [releases](https://github.com/blakeblackshear/frigate/releases) · discussions [#18570](https://github.com/blakeblackshear/frigate/discussions/18570), [#19853](https://github.com/blakeblackshear/frigate/discussions/19853), [#20810](https://github.com/blakeblackshear/frigate/discussions/20810), [#21890](https://github.com/blakeblackshear/frigate/discussions/21890), [#21906](https://github.com/blakeblackshear/frigate/discussions/21906), [#14186](https://github.com/blakeblackshear/frigate/discussions/14186), [#18564](https://github.com/blakeblackshear/frigate/discussions/18564)
- AMD/kernel: [amdnpu kernel docs](https://docs.kernel.org/accel/amdxdna/amdnpu.html) · [amd/xdna-driver](https://github.com/amd/xdna-driver) · [Ryzen AI SW docs](https://ryzenai.docs.amd.com/en/latest/index.html) · [RyzenAI-SW #319](https://github.com/amd/RyzenAI-SW/issues/319) · [ROCm compat matrix](https://rocm.docs.amd.com/en/latest/compatibility/compatibility-matrix.html) · [Vitis AI EP](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html)
- Ecosystem: [ring-mqtt](https://github.com/tsightler/ring-mqtt) · [Ring partner API notes](https://developer.amazon.com/docs/ring/release-notes.html) · [docker-wyze-bridge](https://github.com/mrlt8/docker-wyze-bridge) · [Jellyfin AMD HWA](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/amd/) · [XDA on Coral](https://www.xda-developers.com/intels-cheapest-cpus-do-what-googles-coral-accelerators/)

### UNVERIFIED / watch items

- Exact ROCm version bundled in the 0.17.x `-rocm` image (0.18 = 7.2.0 is verified).
- `HSA_OVERRIDE_GFX_VERSION=11.5.0` for gfx1150 under Frigate specifically (convention-based; no first-party Frigate doc for gfx1150 yet).
- HEVC 10-bit decode on Strix Point VCN (highly likely; confirm with `vainfo` on the device).
- Official Ryzen AI Software Linux support scope for XDNA2 in releases 1.7/1.8 (Linux wheels not generally published as of the cited issue).
- Whether the specific mini PC model has a free M.2 slot for a Hailo module — must be checked against the vendor spec.
