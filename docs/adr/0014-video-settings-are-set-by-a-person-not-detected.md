# Per-machine video settings are set by a person, never detected by the Panel

**Decision (2026-09-04):** the settings that legitimately differ between one
appliance and the next are chosen by a **person at commissioning**, written
into `host_vars/<box>.yml`, templated into the kiosk unit as `Environment=`
lines, and read by the Panel environment-first at boot. **The Panel never
inspects the machine it is running on in order to configure itself** — not at
first start, not per boot, not at all. There is no hardware probe in
`panel/lib` and there is not going to be one.

The procedure is [commissioning 6 §6.10](../../appliance/commissioning/06-panel-and-bindings.md).

## What this is about, and what it is not

Exactly two settings are properties of the machine: which decoders fvp may use
(`VIDEO_DECODERS`) and whether a playing stream forces the engine to redraw
(`VIDEO_REPAINT_PULSE`). The other two knobs on the same value object are not
machine properties and are not in scope: `VIDEO_LOW_LATENCY` is `0` on every
machine that will ever exist — above zero it drops the stream's first key frame,
so it is a fault reproducer rather than a tuning — and `VIDEO_DEBUG` is a
diagnostic.

The **transport** (`rtsp` | `mjpeg`) is not in scope either, and that is a
finding rather than an omission. MJPEG costs go2rtc a per-stream transcode
(52 % CPU / 573 MiB against RTSP's 35 % / 117 MiB, measured 2026-08-26) and
gives up the doorbell's inbound audio ([0011](0011-ring-two-way-audio-via-go2rtc-half-duplex.md)),
so it is *worse* on weaker hardware, not better. There is no machine for which
it is the right answer — only a fault for which it is the way back. It is a
rollback switch, and rollbacks are pulled by people.

## Why not detect

Four reasons, in the order they were established.

**A capability probe answers the wrong question.** The camera wall was painted
in macroblocks on 2026-08-26 and the first diagnosis blamed hardware decoding.
It was wrong: the cause was `lowLatency: 1` setting `avformat.fflags=+nobuffer`,
which drops the first key-frame packet, and H.264 has nothing to reference
without it. A probe asking "is VAAPI available?" would have answered *yes*,
correctly, and been useless — the hardware was capable throughout and the
capability was never the variable.

**Capability does not predict outcome, and we measured that directly.** On
2026-09-04 `VIDEO_DECODERS=auto` was run properly for the first time: eight
freeze-probe arms, four per decoder, CPU sampled over a 14 s window. `auto`
came in at 46.1 / 47.2 / 49.6 / 50.4 % against software's 53.7 / 55.2 / 57.9 /
60.4 % — no overlap between the arms, about 15 % cheaper, and no corruption in
any grab. And yet `nvidia-smi` showed NVDEC essentially idle (4 % peak against
a 0 % baseline), so **the engine that produced the saving could not be
identified** with the tools on the box (`vainfo` and `intel_gpu_top` are both
absent, and the host has no passwordless sudo). A detector would have had to
decide from evidence a human could not interpret.

**The failure is deceptive.** A dead camera is easy: it shows an aged still and
an offline badge. A *mis-decoded* camera shows a corrupt picture under a **LIVE
badge**, which reads as a working camera to anyone glancing at the wall and is
invisible in a screenshot. This house's cameras break often enough on their
own; a configuration mechanism whose failure mode is indistinguishable from the
ambient one is a bad mechanism, however clever.

**And there is one appliance.** The mini PC that the software decoder pin
exists to be portable to is `minipc.placeholder.invalid` in the inventory —
unpurchased. Every "per-machine" setting today has exactly one machine to be
right for, which makes an auto-detector a seam with one adapter.

## Why the human shape is the house pattern, not a compromise

This is already how every machine-specific setting in the appliance works, three
times over: `check-hybrid-gpu.sh` prints prose and a person copies
`wlr_drm_devices` into `host_vars/laptop.yml`; `screen-power-probe.sh` reports
DDC capability and nothing consumes it; commissioning 1 §1.1 has you run `lspci`
and read it yourself. **Probe prints → person records a var → ansible templates
it → the Panel resolves environment-first.** The single genuinely automatic
hardware-fact-to-behaviour mapping in the whole appliance is HWE kernel
selection, and even that *asserts* rather than guessing when it meets a
distribution release it has no mapping for.

There is also a counter-precedent inside this repo for the other shape:
[0012](0012-panel-renders-with-skia-on-linux.md) picks a machine-dependent
default — the renderer — and pins it **statically in the C runner**, having
first been misled for a week by an environment-switch A/B that release builds
compile out. The Panel deciding its own configuration at runtime is a road this
project has already been down.

## Consequences

- **`RtspTuning` needs no `sources` map**, and the absence is now principled
  rather than incidental. A value chosen by a person arrives as an environment
  variable, so it already *is* `ConfigSource.environment`; there is no
  "detected" origin to report and no precedence rule to invent. `HubConfig`
  carries origins because a wrong address and a dead daemon look identical on
  a badge — nothing here has that ambiguity.
- **The grading step is advisory and never gating.** A camera asleep during the
  check is a Wyze daemon, not a verdict; two of the eight arms measured on
  2026-09-04 graded 4/6 for exactly that reason.
- **Record the result either way**, dated, in `host_vars/<box>.yml` — including
  when nothing was wrong. `VIDEO_DECODERS=auto` sat in these documents as a
  bolded "worth one run" for nine days because there was nowhere to write down
  that it had been done.
- **`panel/tool/freeze_probe.sh` is not ported to the appliance.** It needs
  XWayland, ImageMagick and a live compositor; the production box runs Ubuntu
  Server with no desktop environment at all ([0001](0001-plain-linux-kiosk-not-fuchsia-or-chromeos.md))
  behind cage/wlroots. The rig exists to replace a human when nobody is
  watching, and at commissioning somebody is.
- **This is appliance-only by construction.** The web Panel has no process
  environment, and its transport is MSE with no choice to make, so none of this
  reaches a second screen served from the box.

## What this rules out — do not re-propose

- A hardware probe at the Panel's first start, persisted in
  `shared_preferences`. The Panel has no first-run concept today and should not
  grow one for this.
- A probe on every boot: non-deterministic *and* invisible, which is the worst
  pair available.
- A `ConfigSource.detected`, or any precedence rule placing a machine's opinion
  against an operator's.
- Selecting the **transport** from hardware, for the reason given above.
- Re-proposing `VIDEO_DECODERS=auto` on the strength of its CPU number. It was
  measured favourably and kept at software deliberately; the reasoning lives at
  `panel/lib/config/video_tuning.dart`.

## Re-check this decision if

- **The mini PC is purchased.** Grading it by hand is the reopening trigger for
  the decoder question specifically — that machine measured on its own silicon
  is the one thing nobody has been able to do, and the whole software pin rests
  on it.
- **The number of Panels grows.** The roadmap allows for more rooms getting
  their own screens. Hand-grading scales to a handful of boxes and stops
  scaling somewhere after that; at that point the answer is more likely a
  fleet-wide default plus per-box exceptions than a detector, but the trade
  genuinely changes.
- **The decode engine becomes identifiable.** If `vainfo`/`intel_gpu_top` are
  installed, or fvp is made to report which decoder it selected, then a probe
  could finally distinguish "hardware engaged" from "hardware present" — which
  is the specific ignorance that sank automation here.
