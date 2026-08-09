# Ring two-way audio — next session brief (for Claude Code, inside the devcontainer)

**How to use this:** start Claude Code in the devcontainer and say
*"Read `docs/plans/ring-audio-next-session.md` and continue from there."*
Everything needed is in this file or linked from it.

Written 2026-08-08 at the end of the session that got two-way audio working;
**revised the same day** at the end of the session that converged the Ansible
role and disproved the ffmpeg diagnosis; **revised again 2026-08-09**, when the
owner's own `ring:` source was verified on 1.9.10 and the watchdog was built.

---

## Read these first

1. **[`docs/plans/ring-audio-stack.md`](ring-audio-stack.md)** — the spec. §0 is an
   implementation-status table; §4.5 is the converge transcript; §6 is the
   outstanding-item list this brief sequences.
2. **[`docs/adr/0011-ring-two-way-audio-via-go2rtc-half-duplex.md`](../adr/0011-ring-two-way-audio-via-go2rtc-half-duplex.md)**
   — the decision, why the alternatives were rejected, and a dated amendment
   withdrawing its stated *cause* for the ffmpeg corruption.
3. **[`docs/research/ffmpeg-ring-opus-corruption.md`](../research/ffmpeg-ring-opus-corruption.md)**
   — what is actually known about the inbound corruption, and the one capture
   that would settle it.
4. **`CLAUDE.md`** — git discipline.
5. **`hub/dev/ring-twoway-lab/RESULTS.md`** — every experiment, including six
   wrong theories and their corrections. **Read it before that directory is
   deleted** (item 5 below). Two of its conclusions are now known to be wrong;
   both are corrected in the two documents above, not in it.

## Where things stand

Two-way audio with the Front Door doorbell (`camera_id=319156885`) works and was
verified at the door in both directions, using go2rtc's native `ring:` source as
shipped — no fork, no bespoke service.

```
TALK    POST /api/streams?dst=ring&src=rtsp%3A%2F%2F127.0.0.1%3A8554%2Fmic
STOP    POST /api/streams?dst=ring&src=          # idempotent, 40/40 verified
LISTEN  gst-launch-1.0 rtspsrc location=rtsp://<go2rtc>:8554/ring protocols=tcp \
          latency=200 ! queue ! rtpopusdepay ! opusdec ! audioconvert ! \
          audioresample ! pulsesink
```

🔴 **Inbound MUST use GStreamer, never ffmpeg.** Measured twice, same stream,
same moment, samples outside ±1.0 on a float decode:

| Release | GStreamer | ffmpeg |
|---|---|---|
| Ubuntu 24.04 (1.24.2 / 6.1.1) | **0** bad samples | 44 404 |
| Ubuntu 26.04 (1.28.2 / 8.0) | **0** bad samples | 36 642 |

⚠️ **The rule stands; the old explanation does not.** This brief used to say the
cause was "ffmpeg's RTP Opus depacketiser mishandling Ring's ~60 ms frames".
That was inference, and it **fails to reproduce**: synthetic 60 ms Opus over RTP
decodes with zero bad samples through the same ffmpeg, as do six variants copying
Ring's shape (mono-coded/`/2`-declared, inband FEC, DTX, 40 ms, low-delay). The
differential above is the evidence for the rule; nothing rests on the theory.

Outbound stays on ffmpeg and needs no change — there it *packetises* and measures
clean at ~39 dB SNR. And **do not add post-processing**: the mono downmix, 7 kHz
lowpass and limiters in the git history existed only to mask corruption that the
GStreamer path does not have, and now only cost fidelity.

---

## 🔴 You are inside the devcontainer — these will bite

- The repo is `/workspaces/SmartHome` to you, but **`/home/dmorozov/Work/SmartHome`
  on the host**. Docker runs on the host (docker-outside-of-docker), so **every
  `docker run -v` bind path must be the HOST path**. Mounting `$PWD` mounts the
  wrong tree, silently. `appliance/test/run.sh` now takes `SH_REPO_ROOT` for
  exactly this; see `appliance/test/README.md`, "Driving it from the devcontainer".
- **Never run `docker compose up`/`down` from in here** — relative bind mounts
  resolve against a path the daemon does not have, and it will quietly adopt or
  wreck the stack. `docker restart <name>` is safe.
- Audio works: `PULSE_SERVER` and `PIPEWIRE_RUNTIME_DIR` are set, `pulsesink` and
  `pw-play` both verified. Smoke test: `pw-play example.wav`.
- ⚠️ **Changed 2026-08-09.** The `ring` stream now lives in **`go2rtc-dev`**,
  reachable directly as `http://go2rtc-dev:1984` / `rtsp://go2rtc-dev:8554/ring`
  from the devcontainer. The old advice — that it lived in the lab container
  `go2rtc-ring-test` and needed
  `docker network connect smarthome-dev-hub_default go2rtc-ring-test` — is
  **stale**; that container is not even running.
  **`go2rtc-dev`'s `ring_doorbell` is still the wrong target** — it is
  `rtsp://ring-mqtt:8554/…`, the video-only ring-mqtt restream, which structurally
  cannot carry talkback. `ring` is the one with the backchannel.

## Hard rules

- **Never print the Ring refresh token.** go2rtc's `/api/streams` responses **and**
  its `DBG … start producer url=` log lines embed it. Pipe everything through
  `sed -E 's/(refresh_token=)[^&[:space:]"]*/\1<REDACTED>/g'`, **including one-off
  commands** — that is exactly how a leak happened.
- Leave every change **unstaged**. Never `git add`, never `git commit` (`CLAUDE.md`).
- **Time-bound every stream probe inside the container that runs it.** A killed
  caller does not kill the work: an orphaned `curl` held the doorbell in live view
  for ~30 minutes and pulled 160 MB before anyone noticed.
- **Teardown checks must inspect the go2rtc consumer list, not just the process
  list.** `pgrep -a -x ffmpeg` would never have caught that stray `curl`.
  (`pgrep -fa <pattern>` also self-matches its own command line — use `-x`.)
- **Do not dial the doorbell casually.** Every live view costs battery and can
  suppress a real ding (HA core #177014). Ask first.
- **Audio verification needs real speech at the door.** Ring transmits digital
  silence (~−90 dBFS) on a quiet street, so a silent capture passes every test
  while proving nothing. Assert `speech > 5s` before trusting a pass.

---

## Work, in priority order

### ~~1. Converge the Ansible role~~ — ✅ **DONE 2026-08-08**
Full transcript in [`ring-audio-stack.md` §4.5](ring-audio-stack.md). Fresh-host
converge `ok=12 changed=8 failed=0` (reproduced on two fresh containers), second
run **`changed=0`**, `--check` clean on both a converged and a fresh host. And the
part that had never been observed: **lingering really does start PipeWire,
pipewire-pulse and WirePlumber for the `nologin` `cage` account** — `Sessions=`
empty, `/run/user/999/pulse/native` present, all of it surviving a restart with
nobody logging in.

**It also found and fixed a defect nobody had looked for.** PipeWire was running
with `Max realtime priority 0`, every thread `SCHED_OTHER` — a glitch generator
under load. `@pipewire` is the only group the rlimits file grants RT to and
nothing was in it, and PipeWire's usual fallback (RTKit) authorises via polkit's
`allow_active`, which a **seatless lingering user can never satisfy**. The role
now adds `kiosk_user` to `audio,pipewire`; re-measured, `pw-data-loop` runs
`SCHED_FIFO` priority 88. `alsa-utils` was added in the same pass, because the
converged box could not answer "does the kernel see a card" or "is it muted".

🔴 **What it does not prove: that any sound has ever been played.** PipeWire
enumerates no cards in a container (no udev), so every `pulsesink` test rendered
to WirePlumber's fallback **Dummy Output** — and that sink appears *whenever*
there is no hardware, including on a real Appliance with a dead card. **So
`gst … ! pulsesink → exit 0` is not an acceptance criterion.** On the real box
the criterion is **`wpctl status` showing a non-empty `Devices:` section**; see
the three ordered checks at the top of §7.2. That is **D7**.

### 1. Give the dev Hub's go2rtc its own `ring:` source — 🟢 **inbound done 2026-08-09**, one step left
The owner minted the second token (**B9**, now ticked) and worked the go2rtc
README. `go2rtc-dev` now serves `selftest`, `ring_doorbell`, `ring` and `mic`.
One live view on 2026-08-09 verified the new source end to end:

| | Result |
|---|---|
| V4 — `ring:` dials on **1.9.10** | `codec_name=h264`, `codec_name=opus`, `channels=2` |
| V5 — inbound via GStreamer | 33.3 s, **0 out-of-range samples**, peak −18.8 dBFS |
| V7 — teardown | `"consumers":[]`, no `id`/`sdp`/`remote_addr` |

**Version skew is settled for inbound; the pin does not need bumping.** The
talkback path is *byte-identical* v1.9.10↔v1.9.14 — `pkg/ring`'s `AddTrack`,
the speaker-enable `camera_options` message, the SDP offer, and
`internal/streams/api.go`'s `POST dst/src` branch. The three deltas in that
range all sit before audio, so a 1.9.10 failure would look like a dial/auth
error, not bad audio. (One 1.9.10-only defect exists and is inert here: the
`#backchannel=1&audio=…` channel-count typo in `pkg/core/codec.go`, fixed in
1.9.14. `mic` uses the RTSP-output `exec:` form and never touches it.)

🔴 **What is left: README Step 10 was skipped while Step 11 was applied.**
`mic` is enabled in `go2rtc.yaml`, but the container had no `PULSE_SERVER` and
no PulseAudio socket — the exact failure the README warns about, one that
surfaces *only* when somebody presses talk. The compose fix is applied and
unstaged (`hub/dev/compose.yaml`); it needs a **recreate from a host shell**,
because mounts and environment are fixed at create time and `docker compose`
from the devcontainer resolves relative bind mounts against a path the host
daemon does not have (confirmed: `docker compose config` in here resolves the
mount to `/tmp/user/1000/pulse`, the devcontainer's own `XDG_RUNTIME_DIR`):

```sh
cd hub/dev && docker compose up -d go2rtc talk-watchdog     # HOST shell
```

Then **V6 (talkback) is the only unrun check** — it needs somebody at the door.
Item 5 stays blocked until it passes.

### 2. Watchdog / dead-man switch — 🟢 **built 2026-08-09**, with one gap it cannot close
[`hub/talk-watchdog/`](../../hub/talk-watchdog/README.md) — one stdlib-only
Python file, wired into `hub/dev/compose.yaml` as `talk-watchdog`, 24 tests
against a scripted fake go2rtc (no doorbell, no network). Smoke-tested against
the live `go2rtc-dev`: startup stop `200`, quiet polls, `SIGTERM` → stop `200`.

Caps the microphone at `TALK_CAP_S` (default 45 s), stops at startup and on
`SIGTERM`, and stops a `ring` producer left live with no consumers and no talk.

🔴 **It cannot reap consumers, and this is not a shortcut — go2rtc has no
consumer-kill endpoint.** The orphaned `curl` in RESULTS.md was removed with
`pkill -9 -x curl` inside the container; no HTTP verb does that. `PUT`/`DELETE`
on `/api/streams` are worse than useless — they rewrite `go2rtc.yaml` on disk,
token included, and stop nothing. So a stalled consumer is **alerted, not
reaped**. Three ways to close it, none taken: own every consumer (which also
settles the `gst-launch-1.0`-versus-service question), restart the go2rtc
container (drops every camera; needs the docker socket and an owner yes), or
accept it. **That choice is the owner's** — see the list below.

Two findings from building it, both of which would have produced a wrong
watchdog:
- **`sendonly` audio medias appear on *consumers*.** A plain inbound RTSP
  listener reports `"audio, sendonly, ANY"` — that is go2rtc describing what it
  sends *to the listener*. Keying talk detection on `sendonly` would fire every
  time somebody merely watched the doorbell. Hot-mic is read off the `mic`
  stream's producer instead.
- **Consumers use `format_name`, not `format`**, and a live producer may carry
  `source` rather than `url`. RESULTS.md's rendering of the leaked consumer was
  a summary, not the JSON.

### 3. Panel wiring — 🟢 **outbound done 2026-08-09**; inbound untouched and blocked
`_startTalking`/`_stopTalking` are now ADR-0011's two HTTP calls and `_TalkCaption`
has real state. New seam at `panel/lib/ui/audio/talk.dart` (+ `talk_io.dart` /
`talk_web.dart`), modelled on the snapshot seam; new `talk:` binding carried
through `bindings_parser` → `house_loader` → `Device.talkStream`, because `dst`
is `ring` while `stream:` is `ring_doorbell` and nothing derives one from the
other. Full detail in [`ring-audio-stack.md`](ring-audio-stack.md) §6 item 4.

**Verified:** 457 VM tests + the Chrome subset, `flutter analyze` clean. The
doorbell golden was re-baked (the caption text changed) and shows the
unconfigured wording, which is correct — the golden rig names no go2rtc.

🔴 **The three bullets this item used to carry were all about inbound playback,
and none of them were addressed.** That is deliberate, not an oversight: the
Panel plays MJPEG, which carries no audio, so there is no inbound player to
attach a level meter to, no consumer to lose a PPS race, and no process needing
`XDG_RUNTIME_DIR`. They are restated in `ring-audio-stack.md` §6 item 4 and stay
open. **Whoever picks inbound up must answer the owner decision below first** —
who owns the inbound player — because it decides whether any of this lives in
the Panel at all.

Today's honest state, and the caption says exactly this: **talkback is one-way.**
You can speak to the door; you cannot hear it back.

### 4. The ffmpeg bug — 🔴 **not fileable**, and this changed
Do **not** file the report that the previous version of this brief asked for. Its
one concrete claim (60 ms frames) is now disproved, and its only reproduction is
"own this doorbell". [`ffmpeg-ring-opus-corruption.md`](../research/ffmpeg-ring-opus-corruption.md)
records what is known, what was ruled out, and the single ~20 s raw-Opus +
`tcpdump` capture that would turn the rest into offline analysis. **That capture
is an owner decision** — see below.

### 5. Delete the lab directories
`hub/dev/ring-twoway-lab/` and `hub/dev/ring-audio-test/` — **only after item 1**.
🔴 `ring-audio-test/go2rtc/go2rtc.yaml` holds a **live Ring token inside the repo
tree**, contrary to ADR-0010; that is its own reason to finish and remove it.
RESULTS.md's §B4g/§B4h conclusions are superseded by the research note, so nothing
of value is lost with the directory — but read it first.

### Not on this list: echo cancellation
There is **no echo path until inbound playback ships** — the Panel renders MJPEG,
which carries no audio by construction. Schedule AEC with item 3, not before. The
design is decided (half-duplex primary, WebRTC AEC underneath); every measured
number came from the dev laptop's chassis and **will not transfer** to Appliance
hardware. The packaging is settled and needs no new `audio_packages` entry:
`libspa-aec-webrtc.so` ships in `libspa-0.2-modules`, and
`libpipewire-module-echo-cancel.so` arrives as a hard dependency of `pipewire`.

---

## Do not decide these — they are the owner's

Tracked in `TODO.md` with stable IDs, except the last:

- ~~**B9** — the second Ring token~~ ✅ **done 2026-08-09**, verified by a dial.
- **NEW — may the watchdog restart the go2rtc container?** It is the only lever
  that certainly clears an unowned consumer, and it drops every camera in the
  house while it does. Needs the docker socket. Default until you say
  otherwise: **alert, do not act**.
- **NEW — who owns the inbound player?** Making the watchdog its parent settles
  the open `gst-launch-1.0`-versus-supervised-service question and closes the
  consumer-reaping gap in the same move, because reaping becomes a signal to a
  pid it holds. It also lands half-duplex for free.
- **D7** — speaker/microphone hardware. Now the **only** thing between the
  converged appliance audio stack and a sound coming out of it.
- **E9** — which account owns the Appliance's audio session. Recommendation on
  file: `kiosk_user`. New datum: `cage`'s uid is allocated dynamically
  (**999** on the test host), so the Hub stack's `/run/user/<uid>/pulse` mount
  cannot be written in advance — it has to be read off the box (`id -u cage`), or
  the role has to start pinning the uid.
- **A10** — verifying at the door on the Appliance. Its Ansible half is now closed.
- Whether shipped inbound playback uses `gst-launch-1.0` (upstream-documented as a
  debugging tool) or a small supervised service. Interacts with item 2.
- **NEW — one ~20 s doorbell capture**, to make the ffmpeg bug diagnosable and the
  upstream report fileable. Costs one live view; everything after it is offline.

## A note on method

Six theories about the audio artifacts were wrong before the seventh, and **the
seventh was wrong too** — it just failed later, at the point somebody tried to
reproduce it away from the doorbell. What survived all of it is the one thing that
was never a theory: two clients, one stream, one moment, count the bad samples.

The lesson worth carrying: when something sounds wrong, **find a path where it
sounds right first**, then bisect between them — and before writing a cause into
an ADR, **reproduce it without the device that started the argument.**
