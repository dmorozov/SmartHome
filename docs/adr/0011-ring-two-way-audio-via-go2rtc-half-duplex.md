# Ring two-way audio runs through go2rtc's native `ring:` source, half-duplex

The Panel's push-to-talk button has been a stub since it was drawn. Getting
audio to travel *to* the Front Door doorbell — not just from it — was the open
question, and it was researched hard before it was measured. Six specialist
research passes across go2rtc's source, Ring's protocol, community field
reports and an adversarial alternatives review converged on a confident
conclusion: go2rtc's `ring:` source was abandoned (14 commits ever, last
functional one 2025-05-21), it hung forever inside an unbounded
`connected.Wait()`, and the recommended path was a bespoke ~200-LOC service
built on `@tsightler/ring-client-api` in its own container. go2rtc-as-shipped
was ranked **last of eight options** and marked *"currently no — blocked at the
stall."*

**Direct measurement on 2026-08-08 falsified that.** With a freshly minted
refresh token, go2rtc 1.9.14's `ring:` source dialled the doorbell in **0.9 s**
and delivered a working stream: H.264 High 1536×1536 at 15 fps plus **Opus
48 kHz stereo**, 300 frames in 20.05 s with no dropouts. Seven of the
investigation's load-bearing hypotheses failed to reproduce — the unbounded
hang, the missing `clients_api/session` registration, the stale-User-Agent
Cloudflare block (identical `401` for both User-Agents, both reaching Ring's
origin rather than being blocked at the edge), the "H.264 advertised but empty"
report, the codec asymmetry (Ring chose Opus, exactly what go2rtc offers), and
the battery-draining ghost producer of go2rtc#1961/#1933, which tore down
cleanly on every one of the ~30 dials run that day. Outbound was then confirmed
by ear at the front door, twice: first a generated tone, then the live
microphone, the latter corroborated by a −22.6 dB capture measurement.

The lesson worth keeping is not that the research was careless — it was unusually
thorough, and its peer-review section correctly flagged its own weakest link. It
is that **an accumulation of consistent secondary sources is not evidence about
this device on this account**, and a two-minute experiment outranked all of it.
The plan's own instruction to "run A1 first, it decides the central question" was
right; running it earlier would have saved the rest.

**Decision (2026-08-08):** two-way audio with the Front Door doorbell uses
**go2rtc's native `ring:` source, as shipped and unpatched**. The Panel's
push-to-talk becomes two HTTP calls against go2rtc, with no new container, no
fork, and no new dependency:

```
START   POST /api/streams?dst=ring&src=rtsp%3A%2F%2F127.0.0.1%3A8554%2Fmic
STOP    POST /api/streams?dst=ring&src=          # empty src
```

`src` is the RTSP form deliberately: the `mic` stream already produces
`opus/48000/2` and Ring negotiates `opus/48000/2`, so this is a **passthrough
with no re-encode**. `ffmpeg:mic#audio=opus` also works and transcodes; a bare
`src=mic` does **not** (`HTTP 500 · unsupported scheme`) — `GetProducer()`
requires a scheme. Stop was verified empirically, not just derived from source:
`HTTP 200`, idempotent across repeated calls, clean teardown, and 40/40 calls
returning 200 across 20 press/release cycles with **zero** leaked ffmpeg
processes at every checkpoint.

**Echo control is half-duplex first, AEC second.** PipeWire 1.6.2 on this host
already ships the full WebRTC canceller (`spa-0.2/aec/libspa-aec-webrtc.so`),
and it measurably works — **18–22 dB** of echo return loss, with genuine
discrimination rather than blanket attenuation (a near-end signal it had no
reference for lost only 3.4 dB of peak against the echo's 17.4 dB), plus a 20 dB
noise-floor improvement as a bonus. But 18–22 dB is not enough on its own:
intercoms want 30–40 dB before the far end stops hearing itself, a −36 dBFS
residual is audible, and at realistic volume the microphone **clipped at
−2.0 dBFS** — a nonlinearity no linear canceller can model. So the primary
mechanism is to **mute or duck inbound playback while the talk button is held**,
which removes the echo path by construction rather than attenuating it
statistically. This costs nothing: the control is already a hold-to-talk button
(`_PushToTalkButton`, `onStart`/`onStop`), and it is how every intercom behaves.
The AEC is enabled underneath as defence in depth for the guard intervals, by
pointing the `mic` stream at `-f pulse -i aec_source`.

**Rejected, and why.** The **bespoke `ring-client-api` service** — the research's
first choice — solves a problem that does not exist; it would add a container, a
second Ring session and a dependency to maintain, to reach a capability go2rtc
already has. **Scrypted** was second choice on the strength of a single 2023
report, against a documented multi-user pattern of corrupted Ring audio running
through 2026-01; it fails precisely at the condition it was being held in reserve
for. **Patching go2rtc's User-Agent and self-building** rested on a Cloudflare
block that does not reproduce, and would buy a private Go fork of an abandoned
module, maintained indefinitely. **`ring-mqtt → RTSP → go2rtc`** cannot carry
talkback at all: a generic RTSP restream has no backchannel, which is why every
Ring+go2rtc report ever posted is video-only. **`flutter_webrtc` in the Panel**
stays rejected on its own merits (Linux UI freeze, issue #2070) and is now moot —
keeping audio server-side also keeps **stop authority** server-side, where a
watchdog must live anyway, because a wedged microphone must close even if the
Panel process dies.

**Consequences.**

`exec:` sources are refused over go2rtc's API (`HTTP 400 · source from insecure
producer`) — it would be arbitrary command execution over HTTP. `ffmpeg:` is
allowed. **The Panel can never hand go2rtc a command at talk time**; any
exec-based producer must be pre-declared in `go2rtc.yaml`. That is a constraint
on the Panel's design, and a sound one.

go2rtc **rewrites `go2rtc.yaml` itself**, patching the `ring:` line in place when
Ring rotates the refresh token — observed 23 s after startup, preserving an
unrelated edit made seconds earlier. So the token in the file is not necessarily
the one that was pasted, restarting the container is not side-effect-free on the
credential, and anything reading that value must read it at point of use. Note
also that go2rtc's `/api/streams` responses and its `DBG … start producer url=…`
log lines **echo the full producer URL, refresh token included** — every command
touching them needs redaction. That hazard produced a real partial-credential
exposure during this work; the token was re-minted.

**The appliance has no audio stack at all, and this is the largest remaining
unknown** — larger than the echo question. `appliance/ansible` provisions no
audio whatsoever, and production runs Ubuntu **Server** 24.04 with no desktop
environment, so PipeWire is likely absent with no user session to host it. The
kiosk user is a `nologin` system account, needing `loginctl enable-linger` or a
system-wide instance; and `hub/dev/ring-audio-test/compose.yaml` mounts
`${XDG_RUNTIME_DIR:-/run/user/1000}/pulse`, where **UID 1000 is the dev user, not
the kiosk user**. Today's result depends on the dev laptop having a full desktop
session. This must be solved before any of the above ships.

Sequencing follows from that. Inbound audio is *received* today but never
*played* — the Panel renders MJPEG, a format that carries no audio by
construction. **There is therefore no echo path in the system right now**, and
the AEC work belongs with the inbound-playback step, not ahead of it. Duplex
itself is already proven: a 50 s inbound capture kept both tracks and 1200 frames
while five outbound pushes started and stopped, growing monotonically throughout.

**Inbound playback must use GStreamer, not ffmpeg — this is not a preference.**
Inbound audio now works and was verified at the door, but only after a long
detour: played through ffmpeg it was badly distorted ("high pitch metallic"), and
five successive theories — clipping, a starved encoder, wasted stereo, DTX, packet
loss — were each measured and disproved. What settles the choice is a direct
comparison: the same `rtsp://…/ring` stream consumed **simultaneously** by both
clients, where ffmpeg produced **36 642** out-of-range samples with a +34.9 dBFS
peak and 56.5 dB spectral variance while GStreamer produced **zero**, a bounded
0.0 dBFS peak, and 15.4 dB. Repeated on 24.04 with ffmpeg 6.1.1: 44 404 versus
zero. go2rtc is not at fault, and neither is Ring — the giveaway was that both
the Ring app and go2rtc's own WebRTC page sounded perfect on the identical
stream. So:

```sh
gst-launch-1.0 rtspsrc location=rtsp://127.0.0.1:38554/ring protocols=tcp latency=200 ! \
  queue ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! pulsesink
```

No filtering, no headroom correction, no transcode. Any post-processing invented
while chasing this (mono downmix, 7 kHz lowpass, limiters) existed only to mask
the corruption and should **not** be carried forward — it would cost fidelity for
nothing. The appliance therefore needs GStreamer alongside PipeWire, which adds to
the provisioning gap above.

**Amendment, 2026-08-08 — the *cause* is not established, only the choice.** This
decision originally named the mechanism: *"ffmpeg's RTP Opus depacketiser
mishandles Ring's unusual ~60 ms Opus frames."* That was inference from the one
variable that lined up (Ring sends a constant 17.5 packets/s, ≈ 57 ms, against
Opus's usual 50/s; our own ffmpeg-encoded outbound uses 20 ms and is clean), and
it **fails to reproduce**. Synthetic 60 ms Opus over RTP, fed to the same
ffmpeg 6.1.1 binary in the same devcontainer that destroys Ring's stream, decodes
with **zero** out-of-range samples — as does every variant that copies Ring's
shape more closely: mono-coded but `/2`-declared, inband FEC, DTX, 40 ms,
restricted low-delay. The measured differential in the paragraph above is
unaffected and the decision stands unchanged; what is withdrawn is the
explanation. Details and the reproduction:
[`docs/research/ffmpeg-ring-opus-corruption.md`](../research/ffmpeg-ring-opus-corruption.md).

The practical consequence is that **the upstream report cannot be filed yet** —
its one concrete claim is now known to be wrong, and its only reproduction
requires owning this doorbell. Settling it needs a single ~20 s raw-Opus capture
(plus, ideally, a `tcpdump` of the RTSP TCP stream), after which every remaining
question is offline analysis with no further Ring traffic. That capture puts the
doorbell in live view, so it is the owner's call.

Two things remain explicitly unproven and should not be assumed. **"Start and
stop survive the service dying"** was never tested; the idle-timeout gap that
makes a server-side dead-man switch mandatory was never contradicted. And during
the duplex run the *inbound* audio measured `max_volume 0.0 dB`, which may be
ordinary outdoor noise or may be **our own audio returning through the doorbell's
own speaker→mic path** — a second echo loop that half-duplex on our side would
not fix. It was not isolated. Check it before calling the echo question closed.

**Re-check this decision if** go2rtc's `ring:` source breaks again — it remains
an abandoned module with four issues in its entire tracker history, and the
failure that started this investigation is still not fully explained (the
container's own log carries a `streams: ring: wrong query` warning, go2rtc#1781's
signature, from before the token was replaced). The fallback ladder is unchanged
and now better understood: the bespoke `ring-client-api` service is the next
option, and it is genuinely viable — it is simply unnecessary while this works.
