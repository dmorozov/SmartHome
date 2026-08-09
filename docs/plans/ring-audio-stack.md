# Audio stack for Ring two-way talkback — devcontainer and Appliance

**Status:** specification. The devcontainer and Ansible halves are **built and
converged** (§0, §4.5); nothing has run on Appliance hardware. Written 2026-08-08
from the measurements in `hub/dev/ring-twoway-lab/RESULTS.md` and the decision in
[ADR-0011](../adr/0011-ring-two-way-audio-via-go2rtc-half-duplex.md), and revised
the same day with the converge results.

Two-way audio with the Front Door doorbell is **proven working** on the dev
laptop — verified at the door in both directions. It works there only because
that machine runs a full desktop session that happens to provide everything
needed. **The Appliance has no audio stack at all**, and production runs Ubuntu
**Server** with no desktop environment. This document records exactly what has to
exist, so the devcontainer can be fitted first and tested, and the Ansible role
brought to match.

---

## 0. Implementation status — 2026-08-08 (converge results added same day)

| Piece | Status |
|---|---|
| Devcontainer packages + audio mounts | ✅ **done and verified** (§3) |
| GStreamer 1.24.2 handles Ring's stream where ffmpeg does not | ✅ **verified** — 0 bad samples vs ffmpeg's 44 404 |
| `pw-play` in the devcontainer | ✅ **done** — needed the native socket too; verified |
| Ansible: `audio_packages` + install | ✅ **converged** on Ubuntu 24.04 — §4.5 |
| Ansible: audio group + lingering | ✅ **converged, and PipeWire observed running** for the `nologin` user — §4.5 |
| Ansible: converge / idempotence / `--check` against `appliance/test` | ✅ **all three met** — §4.5 |
| Anything on real Appliance hardware | ⬜ **blocked** — no speaker/mic chosen yet (**D7**) |
| Hub stack's audio mount (the UID question) | ⬜ **not started** — §4.3, needs a decision (**E9**) |
| *Why* ffmpeg destroys the inbound audio | 🔴 **not established** — the 60 ms-frame explanation does **not** reproduce; §6 item 6 |

**What "verified" does and does not mean here.** The devcontainer results are
real measurements against the live doorbell. The Ansible results in §4.5 are a
real converge over real SSH against a real systemd, on the Appliance's own OS —
but inside a container, so they prove the *provisioning*, the *session* and the
*socket*. **No sound has been played**: PipeWire finds no cards there, so every
`pulsesink` in §4.5 rendered to a null sink. The role's own quality bar —
fresh-host converge, `changed=0` idempotence, `--check` — **is now met** for
these tasks; the hardware bar is untouched and still gated on **D7**.

---

## 1. The configuration being provisioned for

Three operations, all verified. `ADR-0011` explains the reasoning; this is the
mechanical summary.

```sh
# LISTEN — inbound audio, doorbell -> this machine's speakers
gst-launch-1.0 rtspsrc location=rtsp://127.0.0.1:8554/ring protocols=tcp latency=200 ! \
  queue ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! pulsesink

# TALK — outbound audio, this machine's mic -> doorbell speaker
curl -X POST -G 'http://127.0.0.1:1984/api/streams' \
  --data-urlencode 'dst=ring' --data-urlencode 'src=rtsp://127.0.0.1:8554/mic'

# STOP — idempotent, verified 40/40 calls
curl -X POST 'http://127.0.0.1:1984/api/streams?dst=ring&src='
```

### 🔴 Two constraints that are not stylistic

**Inbound MUST use GStreamer. Never ffmpeg.** ffmpeg destroys the audio —
**36 642** out-of-range samples versus GStreamer's **0** on the same stream, the
same moment (44 404 vs 0 on 24.04). See RESULTS.md §B4h. ⚠️ *Why* it does is
**not** established: the "~60 ms frames" explanation this document used to give
does not reproduce — [`docs/research/ffmpeg-ring-opus-corruption.md`](../research/ffmpeg-ring-opus-corruption.md).
The rule is unaffected; it rests on the differential, not on the theory.

**Outbound MUST stay on ffmpeg** (`exec:ffmpeg` producing the `mic` stream) and
needs no change. There ffmpeg is the *packetiser*, a different code path, and it
measures clean: 3 stray samples, ~39 dB SNR, tone recovery identical to
GStreamer's. See RESULTS.md §B5.

**No post-processing.** Mono downmix, 7 kHz lowpass, limiters and headroom
correction were all developed while chasing the ffmpeg bug. They masked
corruption that no longer exists and would only cost fidelity. Ship the raw
pipeline above.

---

## 2. Package requirements

Every package below was resolved from the actual binary providing each element on
the working host — not from documentation.

| Need | Package | Provides |
|---|---|---|
| `rtspsrc`, `rtpopusdepay`, `pulsesink`, `wavenc` | `gstreamer1.0-plugins-good` | the inbound pipeline's transport + sink |
| `opusdec`, `audioconvert`, `audioresample` | `gstreamer1.0-plugins-base` | Opus decode + format conversion |
| `queue` | `libgstreamer1.0-0` | pulled in as a dependency |
| `gst-launch-1.0`, `gst-inspect-1.0` | `gstreamer1.0-tools` | running and introspecting pipelines |
| PipeWire daemon | `pipewire`, `pipewire-audio` | the audio graph |
| PulseAudio compatibility | `pipewire-pulse` | what `pulsesink` and go2rtc's `-f pulse` talk to |
| Session manager | `wireplumber` | device/route policy; without it nothing is routed |
| `pw-play`, `pw-record` | `pipewire-bin` | diagnostics |
| `wpctl` | `wireplumber` | volume/route inspection |
| WebRTC echo canceller | `libspa-0.2-modules` | `spa-0.2/aec/libspa-aec-webrtc.so` |
| `module-echo-cancel` | `libpipewire-0.3-modules` | the AEC module itself |

**Note:** `pactl` is **not** installed on the working host and is not required —
it lives in `pulseaudio-utils`. Use `wpctl` instead. Several PipeWire recipes on
the internet assume `pactl`; they will not work as written.

AEC packages are needed only when inbound playback ships (see §6, item 3). They
are listed now because they are already present on the dev laptop and their
absence on the Appliance would otherwise be discovered late.

### ⚠️ Version skew is a real risk

Everything was measured on the **26.04** dev host. The devcontainer and the
Appliance are **24.04**. Both columns below are measured, not assumed — 24.04
figures come from `apt-cache policy` against that release's archives:

| | Dev host — Ubuntu 26.04 | Devcontainer + Appliance — Ubuntu 24.04 |
|---|---|---|
| GStreamer | 1.28.2 | **1.24.2** |
| PipeWire | 1.6.2 | **1.0.5** |
| WirePlumber | 0.5.13 | **0.4.17** |
| `libspa-0.2-modules` | 1.6.2 | **1.0.5** |

Every package resolves on 24.04; a `--no-install-recommends` dry-run of the
devcontainer set installs cleanly (164 packages, mostly GStreamer dependencies).

### ✅ The GStreamer gap is CLOSED — verified on 24.04, 2026-08-08

Whether GStreamer 1.24's `rtpopusdepay` would handle Ring's stream as 1.28's did
was the load-bearing risk. It
has now been measured **inside the rebuilt devcontainer** (Ubuntu 24.04,
GStreamer 1.24.2, ffmpeg 6.1.1), both clients on the same stream simultaneously,
with 24–28 s of real speech at the door:

| Client, on Ubuntu 24.04 | out-of-range | peak | spectral-std |
|---|---|---|---|
| **GStreamer 1.24.2** | **0** | 0.0 dB | **15.5 dB** |
| ffmpeg 6.1.1 | 44 404 | +11.2 dB | 56.7 dB |

**GStreamer 1.24.2 matches 1.28.2** (spectral-std 15.5 vs 15.4). The fix holds on
the Appliance's toolchain; the Ansible role can be written against it.

**And the ffmpeg behaviour spans major versions** — 44 404 bad samples on 6.1.1
here versus 36 642 on 8.0 on the dev host. It is long-standing, not a recent
regression. What it is *not* is diagnosed; see §6 item 6.

### ⚠️ Still open: WirePlumber crosses a major version

0.4.17 (24.04) → 0.5.13 (26.04) changed configuration format and default policy.
Nothing about routing or AEC config learned on the dev host should be assumed to
transfer; re-derive it on 24.04. This only bites when AEC ships (§6 item 3) — the
inbound pipeline verified above does not depend on WirePlumber configuration.

---

## 3. Devcontainer changes

The devcontainer does **not** run its own PipeWire. It connects to the **host's**
via the PulseAudio compatibility socket — the same mechanism
`hub/dev/ring-audio-test/compose.yaml` already proves works for go2rtc.

### 3.1 `.devcontainer/Dockerfile`

Add to the existing single apt layer, with a comment matching the file's
established "grouped by why" style:

```
        gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        pipewire-bin \
```

Rationale to record in the comment: *GStreamer is the only correct consumer for
the doorbell's inbound Opus (ffmpeg's depacketiser corrupts Ring's 60 ms frames —
ADR-0011); `pipewire-bin` supplies pw-play/pw-record for verification.*

`ffmpeg` is already present and stays — outbound depends on it.

### 3.2 `.devcontainer/compose.yaml`

Add to the `workspace` service:

```yaml
    environment:
      TZ: ${TZ:-UTC}
      PULSE_SERVER: unix:/run/user/1000/pulse/native
    volumes:
      - ${XDG_RUNTIME_DIR:-/run/user/1000}/pulse:/run/user/1000/pulse
```

Two things to get right, both already learned the hard way elsewhere in this
repo:

- The bind source resolves on the **host** (docker-outside-of-docker), so
  `${XDG_RUNTIME_DIR}` is the host operator's, and the in-container path is
  fixed at `/run/user/1000` regardless — exactly the pattern
  `ring-audio-test/compose.yaml` uses.
- Relative paths in this file resolve against `hub/dev/`, not `.devcontainer/`
  (see that file's own header). The mount above is absolute, so it is unaffected,
  but do not "tidy" it into a relative path.

### 3.3 What the devcontainer can and cannot prove

**Can:** that the packages resolve on Ubuntu 24.04; that the GStreamer pipeline
builds and runs; that `rtpopusdepay` on GStreamer 1.24 handles Ring's 60 ms
frames correctly (**the important one**); that audio reaches the host's sink.

**Cannot:** anything about the Appliance's own PipeWire, the kiosk user's session,
lingering, or device permissions — the devcontainer borrows the host's session
and so bypasses every hard problem in §4.

---

## 4. Appliance / Ansible changes

`appliance/ansible/roles/kiosk` currently provisions **no audio whatsoever** — a
grep of `appliance/` for `audio|pulse|pipewire|speaker|sound` returns nothing
relevant.

### 4.1 Packages — the easy part

✅ **Landed** as `audio_packages` in `appliance/ansible/group_vars/all.yml`, and
converged (§4.5). The list as shipped:

```yaml
  - pipewire
  - pipewire-audio
  - pipewire-pulse
  - pipewire-bin
  - wireplumber
  - libspa-0.2-modules
  - gstreamer1.0-tools
  - gstreamer1.0-plugins-base
  - gstreamer1.0-plugins-good
  - alsa-utils          # added 2026-08-08 — diagnosis only, see §4.5
```

### 4.2 🔴 The hard problem: PipeWire is a *user* service, `kiosk_user` is `nologin`

The role creates the kiosk user as a **system account with
`shell: /usr/sbin/nologin` and `password_lock: true`**. PipeWire and WirePlumber
are `systemd --user` services. A nologin system account has **no user session**,
therefore no `systemd --user` instance, therefore no `XDG_RUNTIME_DIR`, therefore
no PipeWire and no `/run/user/<uid>/pulse/native` socket for anything to connect
to.

Two ways out. **Decided: Option A**, implemented, and now measured working —
§4.5 is the transcript, and §5 item 1 records the decision. The reasoning is kept
below because it is what would have to be revisited if lingering ever proves
unworkable under `cage`. ⚠️ One correction the converge forced: the premise
"a nologin account never gets a session" holds only *until cage runs* — the
role's own `cage.pam` ends in `pam_systemd.so`, so a running cage does give this
account a logind session on a seat. Lingering is still required (audio has to
exist before cage starts and outlive it for the Hub's go2rtc), but the
seat-dependent reasoning below changes once `kiosk_enable` is true, and that
combination has never been exercised.

**Option A — enable lingering.** `loginctl enable-linger {{ kiosk_user }}` makes
systemd start a user manager for the account at boot without a login, creating
`/run/user/<uid>` and running the user services. This is the conventional answer
and keeps PipeWire's normal per-user model. Ansible can do it with
`ansible.builtin.command` guarded by a `creates:`-style check on
`/var/lib/systemd/linger/{{ kiosk_user }}`.

**Option B — a system-wide PipeWire instance.** Supported but explicitly
discouraged upstream; it complicates permissions and has no session policy. Only
worth it if lingering proves unworkable under `cage`.

Whichever is chosen, the group membership and device access for `kiosk_user` must
be provisioned too. The role does both — `audio` for `/dev/snd/*` (verified with a
control in §4.5) and `pipewire` for realtime scheduling (a defect the converge
caught: without it PipeWire runs at priority 0, and RTKit cannot rescue a
seatless user).

### 4.3 🔴 The second hard problem: which user owns the audio session?

`hub/dev/ring-audio-test/compose.yaml` mounts
`${XDG_RUNTIME_DIR:-/run/user/1000}/pulse`. **UID 1000 is the dev operator.** On
the Appliance the kiosk user is a *system* account with a different, unpredictable
UID, and the Hub containers may be started by yet another account.

So there are two distinct identities in play:

- whoever runs `docker compose up` for the Hub stack (go2rtc lives here, and it
  is go2rtc that captures the mic), and
- `kiosk_user`, which runs `cage` and the Panel and owns the screen.

go2rtc must reach **the same PipeWire session that owns the speakers and
microphone**. That means the Hub stack's bind mount has to point at the audio
owner's runtime directory, whichever account that is, and the path cannot stay
hard-coded to `/run/user/1000`. Expect a new variable in `hub/.env` alongside
`SH_KEYS_DIR`, resolved to a literal path for the same reason ADR-0010 pins that
one.

### 4.4 Hardware does not exist yet

`docs/roadmap.md` records *"mic-array hardware near the panel TBD"*. The
Appliance mini PC has no speaker or microphone specified. **Nothing above can be
verified on real Appliance hardware until that is chosen and fitted.** The
measured echo behaviour (§6 item 3) will also change completely with different
hardware and geometry.

### 4.5 ✅ The converge — measured 2026-08-08

Everything in §4.1 and §4.2 has now been run. Target: the `appliance/test`
container (Ubuntu **24.04**, systemd as PID 1, real sshd), converged over real
SSH from a throwaway `python:3.12-slim` controller carrying `ansible-core 2.21.2`.
`kiosk_user` = `cage`, allocated **uid 999** by `useradd --system` on that host.

**The role's own three bars, all met:**

| Run | Recap |
|---|---|
| Fresh-host converge | `ok=12 changed=8 failed=0` — reproduced on two fresh containers |
| Second converge (idempotence) | `ok=10 changed=0 failed=0` — **the bar** |
| `--check` on the converged host | `ok=10 changed=0 failed=0`, exit 0 |
| `--check` on a fresh host | passes — see the apt-cache caveat in `appliance/test/README.md` |

apt selected exactly the versions §2's skew table predicted: PipeWire
**1.0.5-1ubuntu3.3**, WirePlumber **0.4.17-1ubuntu4.1**, GStreamer **1.24.2**.
All eight elements the inbound pipeline needs resolve (`rtspsrc`,
`rtpopusdepay`, `opusdec`, `audioconvert`, `audioresample`, `pulsesink`,
`queue`, `wavenc`), `wpctl` and `pw-play` are present, and `pactl` is absent —
as §2 says it should be.

**`alsa-utils` was added to `audio_packages` as a result of this run.** The
converged box could not answer either of the two questions a headless Appliance
with no sound will need answered — *does the kernel see a card* and *did it come
up muted* — because `aplay -l`, `amixer` and `alsactl` were all absent. It is not
part of the pipeline and PipeWire needs none of it. Worth knowing: `aplay -l`
reads `/proc/asound` directly and so lists cards even where PipeWire's udev-driven
enumeration finds none, which makes it exactly the right first probe when the
speaker arrives (**D7**).

⚠️ **`--check` proves less than the row above suggests.** `ansible.builtin.command`
is *skipped* under check mode, so the lingering task gets **zero** check-mode
coverage; and `ansible.cfg` sets `display_skipped_hosts = False`, so it does not
even appear in the output. Check mode covers the apt, `user`, `copy`, `stat` and
`template` tasks and nothing else.

#### 🟢 Lingering works, and this is the part that had never been observed

§4.2's whole argument was that a `nologin` system account has no session,
therefore no `systemd --user`, therefore no PipeWire. Lingering was written
against that reasoning and never watched. Now it has been:

```
loginctl show-user cage   ->  State=lingering  Linger=yes
                              RuntimePath=/run/user/999  Service=user@999.service
                              Sessions=            <- empty. Nobody logged in.
systemctl is-active user@999.service                       -> active
systemctl --user is-active pipewire pipewire-pulse wireplumber
                                                           -> active active active
ls /run/user/999/pulse/native                              -> present
```

`/run/user/999/pulse/native` is the exact socket `pulsesink` and go2rtc's
`-f pulse` connect to, and a client reaches it: `wpctl status` run as `cage`
answers `PipeWire 'pipewire-0' [1.0.5, cage@appliance-test]` with WirePlumber
attached.

**And it survives a restart.** Re-measured on the same container these numbers
come from: PID 1 age 2 s, `loginctl list-sessions` empty, `user@999.service`
active, all three units active, the socket recreated, a `pulsesink` pipeline
still exiting 0. That is the property the Appliance actually needs — audio
present at boot, with nobody ever logging in. (`docker inspect .RestartCount`
stays 0 through a manual `docker restart`; it counts only policy restarts, so it
is not evidence either way. PID 1's age is.)

**No per-unit enablement is needed** — confirmed, though the credit belongs to
the packages, not the role: nothing in the role enables anything, and all five
units report `enabled/enabled` because `deb-systemd-helper` installs
`/etc/systemd/user/default.target.wants/{pipewire,pipewire-pulse}.service` and
`/etc/systemd/user/pipewire.service.wants/wireplumber.service` at install time.
No task asserts this, so a packaging change upstream would break it silently.

#### 🔴 A real defect the converge exposed: no realtime scheduling

The first run started PipeWire and stopped there. Looking at *how* it was
running showed `Max realtime priority 0` and every thread `SCHED_OTHER` — a
glitch generator under load, and invisible to any "is it active?" check.

`pipewire-bin` ships `/etc/security/limits.d/25-pw-rlimits.conf`, which grants
`rtprio 95 / nice -19 / memlock 4G` to **`@pipewire`** and to nobody else; the
`pipewire` package's postinst creates that group and puts no one in it. On a
desktop this does not matter, because PipeWire falls back to **RTKit** — but
RTKit authorises through polkit's `allow_active`, and **a seatless lingering
user has no active session**, so that fallback is closed here by construction.
(RTKit also simply failed to start in this container.)

**Fixed in the role**: the kiosk user now joins `audio,pipewire`. Re-measured
after a restart:

```
id cage      ->  groups=992(cage),29(audio),105(pipewire)
/proc/<pipewire>/limits   ->  Max realtime priority  95
thread pw-data-loop       ->  SCHED_FIFO|SCHED_RESET_ON_FORK, priority 88
```

🔴 **Supplementary groups are resolved once, at user-manager start.** On a fresh
converge the task ordering saves us. On a host that is *already* lingering,
adding a group changes nothing until `user@<uid>.service` restarts — i.e. a
reboot. The role deliberately does not do that for you, because it would kill
cage and the Panel with it.

#### Three package facts this settled

- **The WebRTC canceller is in `libspa-0.2-modules`.**
  `dpkg -S /usr/lib/x86_64-linux-gnu/spa-0.2/aec/libspa-aec-webrtc.so` →
  `libspa-0.2-modules:amd64`. `libspa-0.2-modules-extra` does not exist on
  noble at all, so the lab notes' reference to it was a guess, not a variant.
  `audio_packages` needs no change. The other half,
  `libpipewire-module-echo-cancel.so`, comes from `libpipewire-0.3-modules`,
  which `pipewire` **Depends** on — guaranteed without being listed.
- **The user D-Bus session arrives without being asked for, but not by a hard
  guarantee.** Lingering is useless without `/run/user/<uid>/bus`. `wireplumber`
  Depends on the OR-group `default-dbus-session-bus | dbus-session-bus`; only
  `dbus-user-session` provides the first, but `dbus-x11` also provides the
  second, so a resolver could in principle satisfy it without delivering
  `dbus.socket`. In practice apt picks `dbus-user-session` (Priority: important)
  and did here. If a converge ever comes up with no user bus, look at this first.
- **The role installs *with* Recommends; §2's validation was done without them.**
  The apt task does not set `install_recommends`, so it takes apt's default
  (true) — a larger set than the `--no-install-recommends` dry-run §2 quotes.
  `rtkit`, `pipewire-alsa` and `dbus-user-session` are all Recommends of
  `pipewire-bin`, i.e. they arrive by default and would silently vanish if
  anyone "tightened" that task.

#### 🔴 What the converge does **not** prove

- **No sound has been played.** PipeWire enumerates **no cards** in the
  container — `systemd-udevd` is inactive (`ConditionPathIsReadWrite=/sys` fails)
  and `/run/udev` does not exist, so its udev-driven ALSA monitor sees nothing —
  leaving WirePlumber's fallback **Dummy Output** as the only sink and no
  sources at all. `gst-launch … ! pulsesink` exiting 0 proves the client reached
  the server and the graph accepted the stream. It does **not** prove a speaker
  moved.
  🔴 **And that test cannot fail.** WirePlumber creates the Dummy Output
  *whenever there is no other sink* — which is equally true of an Appliance
  whose card is absent, unenumerated, or unopenable. So `exit 0` is not an
  acceptance criterion for the real box. **The criterion there is `wpctl status`
  showing a non-empty `Devices:` section**, not a sink and not an exit code.
- **The `/dev/snd` result is real but narrow.** The `audio` grant is genuinely
  demonstrated, with a control: `cage` can write `/dev/snd/controlC0`,
  `daemon` and `nobody` cannot, and the node is plain `0660 root:audio` with no
  ACL involved. But `run.sh` starts the container `--privileged`, so those nodes
  are the **dev laptop's**, leaked in from the host — nothing about the mini
  PC's devices, or about permissions under a non-privileged runtime, follows.
  What is untested is not the *grant* but its *consumption*: PipeWire never
  reaches the point of opening a card, so device discovery, open and ACP profile
  selection have never run as this user.
- **The Opus/RTP pipeline run here is GStreamer→GStreamer.** It shows the
  elements load and run under this user; it re-verifies nothing about the ffmpeg
  behaviour in §1, which is a property of consuming *Ring's* stream.
- **cage itself never started** (`kiosk_enable: false`), so nothing has checked
  that the process which will actually play the audio can find PipeWire.
  `cage@.service` is a **system** unit with `User={{ kiosk_user }}`, and systemd
  does not set `XDG_RUNTIME_DIR` for system units — whether the Panel inherits a
  usable one is an open question and belongs with §6 item 4.
- **`cage`'s uid is allocated dynamically** (999 on this host). So the Hub
  stack's `/run/user/<uid>/pulse` bind mount (§4.3, **E9**) cannot be written in
  advance — it has to be read off the box (`id -u cage`), or the role has to
  start pinning the uid, which `ansible.builtin.user` supports and this role
  currently declines to do. Note also that `/run/user/<uid>` is a per-boot tmpfs
  owned by `user-runtime-dir@<uid>.service`: a container bind-mounting it will
  hold a stale inode if that service ever restarts.
- Nothing about cage/DRM, touch, or the Panel — the standing limits in
  `appliance/test/README.md`.

---

## 5. Decisions needed from the owner

1. ~~**Lingering vs system-wide PipeWire** (§4.2).~~ **Decided: lingering**, and
   implemented in the role. Conventional, keeps upstream's model, and measured
   sufficient — `pipewire{,-pulse}.{socket,service}` and `wireplumber.service`
   are all `enabled` by default, so no per-unit enablement is needed. Reversible
   if it proves unworkable under `cage`; nothing else depends on the choice.
2. **Which account owns the audio session** (§4.3), and therefore what the Hub
   stack mounts. Recommendation: `kiosk_user`, since it already owns the display
   and the Panel; the Hub stack then mounts that user's runtime dir. Two facts
   from §4.5 bear on how that mount is written: the uid is **allocated
   dynamically** (999 on the test host), and `/run/user/<uid>` is a **per-boot
   tmpfs** owned by `user-runtime-dir@<uid>.service`. So either read the uid off
   the box after a converge and pin it in `hub/.env` as ADR-0010 pins
   `SH_KEYS_DIR`, or have the role pin the uid itself — `ansible.builtin.user`
   takes `uid:`, which would make the path knowable in advance and identical on
   every Appliance. Pinning is a one-word change on a fresh host and a
   file-ownership migration on one that already has the account, which is why it
   is a decision and not a fix.
3. **Speaker and microphone hardware** (§4.4) — blocks all on-device verification.
4. **`gst-launch-1.0` vs a real service.** `gst-launch-1.0` is upstream-documented
   as a debugging tool, not for production. It is fine for the lab and for the
   devcontainer test, but the shipped Panel integration should either run a small
   supervised GStreamer process or a purpose-built one. This interacts with the
   watchdog requirement (§6 item 2).

---

## 6. Outstanding items

Ordered by what blocks what. Items 1–3 are prerequisites for shipping; 4–7 are
cleanup and follow-through.

### 1. 🟡 Appliance audio stack — **converged**, three things left
Everything in §4 has now been run, and §4.5 is the transcript: the packages, the
group memberships, the lingering, the user manager and the PulseAudio socket all
exist and come back after a restart with nobody logged in. What is left:

- **Hardware (§4.4, D7).** No sound has been played by anything, anywhere. This
  is the whole remaining risk on the audio side.
- **The UID / mount question (§4.3, E9).** Unchanged, now with the two facts it
  needs — see §5 item 2.
- **cage has never started with any of this in place.** `cage@.service` is a
  *system* unit running as `kiosk_user`, and systemd sets no `XDG_RUNTIME_DIR`
  for system units. Every client command in §4.5 supplied it by hand. Whether the
  Panel inherits a usable one, and therefore finds PipeWire at all, is untested —
  and it belongs with item 4, not here, because the answer may be a line in
  `cage@.service.j2`.

### 2. 🔴 Watchdog / dead-man switch — mandatory, not optional
§1.8 of the lab plan warned go2rtc has **no idle timeout on internal producers**,
and this session proved it for real: a leaked `curl` consumer held the doorbell in
live view for ~30 minutes and pulled 160 MB before anyone noticed
(RESULTS.md, incident section). Requirements:

- Reap **orphaned consumers**, not just stop the mic. A dead client keeps the Ring
  producer alive indefinitely.
- Fire `dst=ring&src=` liberally — it is idempotent (verified 40/40 → HTTP 200).
- Stop unconditionally on popup close **and** app shutdown, and once at startup to
  clear anything a previous crash left open.
- Absolute talk cap (30–60 s).
- **Monitor the consumer list, not just the process list** — the checks used
  throughout the lab looked only for `ffmpeg` and would never have caught a stray
  `curl`.

### 3. Echo cancellation — only once inbound playback ships
There is **no echo path today** (the Panel plays MJPEG, which carries no audio).
AEC belongs with inbound playback, not ahead of it. When it lands:

- **Half-duplex is primary** — duck or mute playback while the talk button is
  held. The control is already hold-to-talk (`_PushToTalkButton`,
  `onStart`/`onStop`), so this is nearly free and removes the echo path by
  construction.
- **WebRTC AEC underneath** as defence in depth: measured **18–22 dB** ERLE with
  genuine echo/near-end discrimination (3.4 dB near-end loss vs 17.4 dB echo).
  Not sufficient alone — comfortable intercoms want 30–40 dB.
- Point go2rtc's `mic` at the cleaned source: `-f pulse -i aec_source`.
- All AEC numbers were measured on the **dev laptop's chassis** (~10 cm coupling)
  and **do not transfer** to different Appliance hardware.
- **Double-talk was never tested** — and is exactly what half-duplex avoids.

### 4. Panel wiring
`panel/lib/ui/device_popup.dart` — `_startTalking` / `_stopTalking` become the two
HTTP calls in §1, and `_TalkCaption` (currently "isn't wired up yet") needs real
state. Two behaviours the measurements demand:

- **Silence is normal.** Ring transmits near-digital-silence (~−90 dBFS) when the
  street is quiet. The UI must not report a broken stream, and must not use audio
  presence as a health check — a watchdog restarting on "no audio" would restart
  constantly. A level meter would communicate honestly where a boolean cannot.
- **Stream start can fail at the wrong moment.** A consumer attaching before
  H.264 parameter sets arrive dies with `non-existing PPS 0 referenced`. Warm the
  producer, or retry.
- **The Panel may not be able to find PipeWire at all.** New from §4.5:
  `cage@.service` is a *system* unit with `User={{ kiosk_user }}`, and systemd
  does not populate `XDG_RUNTIME_DIR` for system units — every client command in
  §4.5 supplied it by hand. Whichever process ends up playing inbound audio
  (§5 item 4) needs `XDG_RUNTIME_DIR=/run/user/<uid>` or
  `PULSE_SERVER=unix:/run/user/<uid>/pulse/native` handed to it explicitly, most
  likely as an `Environment=` line in `cage@.service.j2`. Check this before
  writing any Panel-side audio code — it is cheap to test and it decides the
  shape of the rest.

### 5. "Survives the service dying" — never tested
§7 line 3 of the lab plan requires start/stop to survive the service dying. Start,
stop and idempotency are proven; this specific property is not.

### 6. 🔴 The ffmpeg bug — **not fileable yet**, and the reason is new
This item used to read *"`RESULTS.md` contains a clean reproduction — file it
against ffmpeg."* It does not. `RESULTS.md` contains a clean **differential**
(same stream, two clients, 36 642 bad samples vs 0), which is what the GStreamer
decision rests on, and a **diagnosis that has since failed to reproduce**:
synthetic 60 ms Opus over RTP decodes cleanly through the very ffmpeg 6.1.1 that
mangles Ring's stream, as do six variants copying Ring's shape more closely.

An upstream report needs an input a maintainer can run. Getting one costs a
single ~20 s raw-Opus capture (`-c:a copy`) plus a `tcpdump` of the RTSP TCP
stream, after which the whole question — TOC bytes, frames per packet, timestamp
deltas — is offline analysis with **no further Ring traffic**. That capture puts
the doorbell in live view, so it is the owner's call, not an agent's.

Everything measured, and the exact next experiments, are in
[`docs/research/ffmpeg-ring-opus-corruption.md`](../research/ffmpeg-ring-opus-corruption.md)
— which is also where this survives the deletion of the lab directory (item 7).

### 7. Delete the lab directories
`hub/dev/ring-twoway-lab/` and `hub/dev/ring-audio-test/`, once this document and
ADR-0011 are accepted. 🔴 **`hub/dev/ring-audio-test/go2rtc/go2rtc.yaml` still
holds a live Ring refresh token inside the repo tree**, contrary to ADR-0010 —
that alone is reason to finish and remove it. Note also that go2rtc **rewrites
that file itself** when Ring rotates the token, so the value there is not the one
that was pasted.

---

## 7. Verification procedure

### 7.1 In the devcontainer (do this first)

```sh
# 1. elements resolve on 24.04?   -> all six ok, verified 2026-08-08
for e in rtspsrc rtpopusdepay opusdec audioconvert audioresample pulsesink; do
  printf '%-16s' "$e"; gst-inspect-1.0 $e >/dev/null 2>&1 && echo ok || echo MISSING
done

# 2. can it reach the host's audio?   -> plays a tone, exit 0
#    NOT pw-play: that speaks the NATIVE pipewire protocol on
#    /run/user/1000/pipewire-0, which is deliberately not mounted. Only the
#    PulseAudio-compat socket is — which is what pulsesink, and go2rtc's
#    `-f pulse`, actually use. pw-play fails here with
#    "pw_context_connect() failed: Host is down" and that is EXPECTED.
gst-launch-1.0 audiotestsrc num-buffers=50 freq=440 ! audioconvert ! pulsesink

# 3. THE test — inbound audio, clean?
gst-launch-1.0 rtspsrc location=rtsp://<go2rtc>:8554/ring protocols=tcp latency=200 ! \
  queue ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! \
  audio/x-raw,format=F32LE,rate=48000,channels=2 ! wavenc ! filesink location=/tmp/t.wav
```

**Reaching the right go2rtc.** The workspace sits on `smarthome-dev-hub_default`,
where `go2rtc-dev` offers only `ring_doorbell` — and that is
`rtsp://ring-mqtt:8554/…`, the **video-only** ring-mqtt restream, not the native
`ring:` source. The stream that matters lives in the lab container
`go2rtc-ring-test`, on its own compose network. For the test, join it:

```sh
docker network connect smarthome-dev-hub_default go2rtc-ring-test
```

Runtime-only, reversible with `network disconnect`. 🔴 **Once the lab directories
are deleted (§6 item 7), the `ring:` source needs a permanent home in the dev
Hub's own go2rtc** — otherwise this verification cannot be re-run, and the dev
stack has no way to exercise talkback at all. That is a new dependency between
item 7 and everything else.

⚠️ **And there is a version skew nobody has looked at.** Everything in ADR-0011
was measured against `go2rtc-ring-test`, which runs **1.9.14**. Both
`hub/compose.yaml` and `hub/dev/compose.yaml` pin **1.9.10**, deliberately. The
ADR's own "re-check this decision if" clause is about the `ring:` module being
abandoned and fragile — which makes a four-patch difference in exactly that
module the wrong thing to assume away. Whoever moves the source into the dev Hub
should either bump that stack's pin or re-run the dial on 1.9.10 first, and
record which.

Then measure `/tmp/t.wav` the way RESULTS.md does — **count samples with
`|v| > 1.0`**. The pass criterion is objective:

| | out-of-range | peak | spectral-std |
|---|---|---|---|
| **Pass** (GStreamer, measured) | 0 | ≤ 0.0 dB | ~15 dB |
| **Fail** (ffmpeg, measured) | 36 642 | +34.9 dB | 56.5 dB |

There must be **real speech** in the window — Ring sends digital silence on a
quiet street, and a silent capture passes trivially while proving nothing.

### 7.2 On the Appliance

Not possible until §5 items 2 and 3 are settled and hardware exists. When it is:
repeat 7.1 on the device, then re-verify both directions by ear at the door,
since the last hop (go2rtc → Ring → doorbell speaker) cannot be instrumented from
this side.

**Run these three first, in this order — they are the ones §4.5 could not.**
Each has a criterion that can actually fail, which the container's could not:

```sh
# 0. does the KERNEL see a card? (reads /proc/asound; needs no udev, no PipeWire)
aplay -l                       # FAIL if "no soundcards found"

# 1. does PIPEWIRE see it, as the kiosk user? THIS is the acceptance criterion —
#    not "a sink exists": WirePlumber invents a Dummy Output whenever there is
#    none, so a sink proves nothing.
sudo -u <kiosk_user> XDG_RUNTIME_DIR=/run/user/$(id -u <kiosk_user>) wpctl status
                               # FAIL if the `Devices:` section is empty

# 2. did it come up muted? (the classic silent-appliance cause)
amixer -c 0 scontents | grep -i 'playback.*\[o' | head
```

Only then is `gst-launch … ! pulsesink` worth running, and only then does it mean
anything.
