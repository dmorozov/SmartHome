# go2rtc — development Hub

Stream definitions for `go2rtc-dev`, the restream layer the Panel pulls camera
and doorbell video from during development. This directory is its entire
configuration: the container mounts it at `/config` and reads nothing else.

**This is a runbook for configuring an unconfigured box from scratch.** Work
Steps 1–9 in order, then run the **Verification** section. Steps 10–11 add
talkback and are optional. **Troubleshooting** is at the end, indexed by the
error you actually see.

Everything here was measured on this machine or is cited to the document that
measured it.

---

## Before you start

**What must already exist:**

- A checkout of this repo, and Docker on the host.
- The dev Hub stack defined in `hub/dev/compose.yaml`. Steps 4 and 10 bring it
  up; nothing else here assumes it is already running.
- `ring-mqtt-dev` running and **already authenticated to Ring** — Step 7 borrows
  its bundled CLI to mint a token. If it is not authenticated yet, do that first
  (`TODO.md` **B2**, its web UI at `http://localhost:65123`).
- For the Ring steps: the doorbell's two ids. **For this house's Front Door they
  are already known and pre-filled in `go2rtc.example.yaml`** — you only supply
  the token. Step 6 covers finding them for any other camera.

**Know which go2rtc you are configuring.** There are three on this laptop, they
differ in version and config location, and running a command against the wrong
one is the most common mistake in this repo.

| Container | Version | Config it reads | What it is |
|---|---|---|---|
| `go2rtc` | 1.9.10 | `~/.sh_keys/go2rtc/go2rtc.yaml` | **Production.** Host networking, canonical ports. The real house. |
| **`go2rtc-dev`** | **1.9.10** | **`hub/dev/go2rtc/` ← this directory** | **This one.** Shifted ports, the dev sandbox. |
| `go2rtc-ring-test` | 1.9.14 | `hub/dev/ring-audio-test/go2rtc/` | Throwaway lab. Scheduled for deletion — see *Reference*. |

**Five rules that are not style.** Each has already cost something:

1. **Never print the refresh token.** Filter every command that touches
   `/api/streams` or the logs — **including one-off commands**. That is precisely
   how the last leak happened. Step 2 sets up the filter.
2. **Never `docker compose up`/`down` from inside the devcontainer.** Relative
   bind mounts resolve against `/workspaces/SmartHome`, a path the host daemon
   does not have; it silently creates empty directories and mounts those.
   `docker restart <name>` is path-free and safe from anywhere.
3. **Time-bound every stream probe inside the container that runs it.** Killing
   the caller does not kill the work.
4. **Check the consumer list, not the process list**, when confirming teardown.
5. **Do not dial the doorbell casually.** Every live view costs battery and can
   suppress a real ding (HA core #177014).

---

## Step 1 — Create the live config from the tracked example

A fresh checkout has **no `go2rtc.yaml`** — only the tracked starter. The live
file is gitignored because it will hold credentials.

```sh
cd hub/dev/go2rtc
cp go2rtc.example.yaml go2rtc.yaml
```

Out of the box that gives you one working stream, `selftest`, and every Ring line
commented out. That is deliberate: it means Step 4 can prove the container,
ports, and web UI all work **before** any credential exists.

## Step 2 — Set your shell variables

Every command below assumes these two. Set them once, in whichever shell you are
working in.

🔴 **`G2` differs depending on where you stand, and getting it wrong is the
single most common failure.** It does not look like a URL problem — it looks like
a connection refusal (see *Troubleshooting*).

```sh
# Pick exactly ONE. Pasting both leaves you with the second.
G2=http://127.0.0.1:11984      # a HOST shell        (published port)
G2=http://go2rtc-dev:1984      # in the devcontainer (container name)

# The redaction filter — go2rtc echoes the full producer URL, token included.
R='s/(refresh_token=)[^&[:space:]"]*/\1<REDACTED>/g'
```

Full address table, for reference:

| From | API / Web UI | RTSP | WebRTC |
|---|---|---|---|
| Host shell | `http://127.0.0.1:11984` | `rtsp://127.0.0.1:28554` | `127.0.0.1:28555` |
| Devcontainer | `http://go2rtc-dev:1984` | `rtsp://go2rtc-dev:8554` | — |
| Inside the container | `http://127.0.0.1:1984` | `rtsp://127.0.0.1:8554` | — |

Host ports are **shifted**, never canonical — the production stack owns the
canonical ones on this same laptop. That reading is the point: a browser tab on
`:1984` can never quietly be the sandbox.

## Step 3 — Start the container

**From a host shell** (rule 2):

```sh
cd hub/dev && docker compose up -d go2rtc
```

## Step 4 — Prove the base works, before adding any credential

```sh
docker inspect go2rtc-dev --format \
  '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
curl -s "$G2/api/streams"
```

Expect exactly one bind ending `hub/dev/go2rtc -> /config`, and a JSON body
containing `selftest`. If the path shows `ring-audio-test`, you are on the lab
container, not this one.

Open `http://localhost:11984` in a host browser and play `selftest`. A moving
picture there means the container, the ports, the WebRTC candidate and
`api.origin` are all correct — everything that is not Ring-specific. **Do not
skip this**: debugging a doorbell stream on top of a broken base is how the
last two false starts began.

## Step 5 — Add the video-only doorbell stream

This is the stream the Panel actually binds to. It carries **video only** — a
generic RTSP restream has no backchannel, which is why talkback needs the
separate `ring:` source in Step 8.

In `go2rtc.yaml`, uncomment:

```yaml
  ring_doorbell: rtsp://ring-mqtt:8554/90486cf35236_live
```

`ring-mqtt` here is a **container name on the compose network**, not a host — the
doorbell's RTSP server lives inside the stack. No credential is involved:
`ring-mqtt-dev` already holds its own Ring session.

## Step 6 — (only for a camera other than Front Door) Find its two ids

Front Door's are pre-filled in the example, so **skip this step for the doorbell**.

🔴 **`ring:` needs all three of `device_id`, `camera_id` and `refresh_token`**,
and go2rtc's own `internal/ring/README.md` is wrong about that — it shows only
two. `pkg/ring`'s `Dial()` errors if any is empty, and the symptom is the
misleading `wrong query` warning. The two ids are different values and different
kinds of thing:

| Param | What it is | Where to read it |
|---|---|---|
| `device_id` | the MAC-like id | `docker logs ring-mqtt-dev` → `New device: Front Door (90486cf35236)`, or the ring-mqtt web UI |
| `camera_id` | Ring's own **numeric** doorbot id | the vendored `RingApi`: `location.cameras[].data.id` (`.data.device_id` is the other one) |

⚠️ **Looking up `camera_id` consumes a refresh token** — Ring rotates them on
use. So do the lookup with a *throwaway* token and mint a second one in Step 7
for go2rtc; the token you looked up with will not still work.

## Step 7 — Mint the Ring refresh token

Owner work — interactive email, password and 2FA, with no headless path
(`TODO.md` **B9**).

```sh
docker exec -it ring-mqtt-dev node \
  /app/ring-mqtt/node_modules/@tsightler/ring-client-api/lib/ring-auth-cli.js
```

🔴 **It must be its own token, not `ring-mqtt-dev`'s.** Ring rotates refresh
tokens on use, so two consumers sharing one invalidate each other.

## Step 8 — Add the two-way `ring:` stream

Open `go2rtc.yaml` **in an editor** — never paste a token into a chat window, and
never through a shell command that lands in history. Uncomment the `ring:` line
and replace `TOKEN`, keeping it on **one physical line**:

```yaml
  ring: ring:?device_id=90486cf35236&camera_id=319156885&refresh_token=<the token>
```

A wrapped line or a lost `&` produces a specific warning — see *Troubleshooting*,
`wrong query`.

## Step 9 — Lock the file down, then restart

```sh
chmod 600 hub/dev/go2rtc/go2rtc.yaml     # it is created 664 — world-readable
docker restart go2rtc-dev                # safe from the devcontainer
```

go2rtc reads its config **at start only**, so nothing you did in Steps 5–8 is
live until that restart. Two things to know about it:

- **go2rtc rewrites `go2rtc.yaml` itself.** When Ring rotates the token it
  patches the `ring:` line in place — observed 23 s after startup, surgically,
  preserving an unrelated edit made seconds earlier (`app.PatchConfig`, and
  `/config` is mounted `rw`). So the value on disk is *not* the one you pasted,
  restarting is not side-effect-free on the credential, and anything consuming it
  must read it at point of use.
- The `ring:` producer is **on-demand**. Restarting does not dial the doorbell;
  the first consumer does.

🔴 **On where this credential lives.** The file is gitignored, so the token is not
committed — **but it is on disk inside the repo tree**, which is exactly what
[ADR-0010](../../../docs/adr/0010-secrets-consolidated-outside-the-repo.md) moved
every other credential *out* of. The production stack keeps its go2rtc config at
`~/.sh_keys/go2rtc/`; this one does not, and that asymmetry has a real cost: **any
tool that reads or diffs this file puts the token in front of whoever is
watching.** That has happened twice, both by accident, both costing a re-mint.

- **Re-mint the token whenever it is displayed anywhere** — a chat window, a
  screen share, a pasted diff. Re-minting invalidates the exposed one, and that
  is the only remedy that works.
- **Recommended follow-up:** move this config to `~/.sh_keys/go2rtc-dev/` (a
  `hub/dev/compose.yaml` change, mirroring what `hub/compose.yaml` already does
  with `SH_KEYS_DIR`) and the hazard closes for good.

**Configuration is complete. Go to Verification.** Steps 10–11 are only needed
for talkback.

## Step 10 — (talkback) Give go2rtc access to the microphone

The TALK call reads from a `mic` stream that captures through PipeWire's
PulseAudio socket. Out of the box `go2rtc-dev` has neither that socket mounted
nor `PULSE_SERVER` set.

Add to the `go2rtc` service in `hub/dev/compose.yaml`, mirroring what
`ring-audio-test/compose.yaml` already proves works:

```yaml
    environment:
      PULSE_SERVER: unix:/run/user/1000/pulse/native
    volumes:
      - ${XDG_RUNTIME_DIR:-/run/user/1000}/pulse:/run/user/1000/pulse
```

## Step 11 — (talkback) Enable the `mic` stream and recreate

Uncomment the `mic` block in `go2rtc.yaml`:

```yaml
  mic: >-
    exec:ffmpeg -re -f pulse -i default -c:a libopus -b:a 48k
    -rtsp_transport tcp -f rtsp {output}
```

Then recreate the container. 🔴 **`docker restart` is not enough** — mounts and
environment are fixed at create time — and **this must be run from a host
shell**, because `docker compose` from the devcontainer is rule 2:

```sh
cd hub/dev && docker compose up -d go2rtc
```

Do **not** uncomment `mic` without Step 10. That produces a stream which fails
*only* at the moment somebody presses talk, which is the worst possible moment to
find out.

---

## Verification

Run these in order. Each has an expectation that can genuinely fail.

### V1 — The API answers

```sh
curl -s -o /dev/null -w '%{http_code}\n' "$G2/api/streams"
```

**Expect:** `200`. Anything else means `G2` is wrong for the shell you are in, or
the container is not running — see *Troubleshooting*.

### V2 — The running process has your config

```sh
docker inspect go2rtc-dev --format 'started: {{.State.StartedAt}}'
stat -c 'config: %y  mode: %a' hub/dev/go2rtc/go2rtc.yaml
```

**Expect:** `started` is **newer** than `config`, and `mode` is **600**. If
`started` is older, the edits are not loaded — repeat the restart in Step 9.

### V3 — The streams exist

```sh
curl -s "$G2/api/streams" | sed -E "$R"
```

**Expect:** `selftest`, plus `ring_doorbell` (Step 5) and `ring` (Step 8), each
with a `producers` entry. `ring`'s producer URL must show
`refresh_token=<REDACTED>` — if the raw token appears, your filter is not applied
and you have just leaked it.

**Expect `mic` only after Steps 10–11.** Its absence before that is correct, not
a misconfiguration.

### V4 — The `ring:` source actually dials Ring

🔴 **This puts the doorbell in live view.** Keep it short, and keep the timeout
*inside* the container.

```sh
docker exec go2rtc-dev sh -c 'timeout 15 ffprobe -v error -rtsp_transport tcp \
  -show_entries stream=codec_name,channels rtsp://127.0.0.1:8554/ring'
```

**Expect:** `codec_name=h264` and `codec_name=opus` with `channels=2`.
**If it reports nothing**, suspect the version skew first — every talkback
measurement was taken on go2rtc **1.9.14** and this container runs **1.9.10**
(see *Troubleshooting*).

### V5 — Inbound audio is audible and clean

🔴 **Use GStreamer. Never ffmpeg** — not a preference; see *Troubleshooting*,
*inbound audio*. The devcontainer is already equipped and needs nothing
installed: `rtspsrc`, `rtpopusdepay`, `opusdec` and `pulsesink` all resolve,
`PULSE_SERVER` is set, and the host's PulseAudio socket is mounted at
`/run/user/1000/pulse/native`.

```sh
# From the DEVCONTAINER — plays out of the host's speakers
timeout 30 gst-launch-1.0 rtspsrc location=rtsp://go2rtc-dev:8554/ring \
  protocols=tcp latency=200 ! queue ! rtpopusdepay ! opusdec \
  ! audioconvert ! audioresample ! pulsesink

# From a HOST shell — same thing, host-published RTSP port
timeout 30 gst-launch-1.0 rtspsrc location=rtsp://127.0.0.1:28554/ring \
  protocols=tcp latency=200 ! queue ! rtpopusdepay ! opusdec \
  ! audioconvert ! audioresample ! pulsesink
```

**Expect:** a person speaking at the door is audible and *not* metallic.

🔴 **Silence is neither a pass nor a failure.** Ring transmits
near-digital-silence on a quiet street and real sound arrives in bursts, so a
silent run proves nothing either way. **Have someone speak at the door.**

Second opinion when the result is ambiguous: the web UI at
`http://localhost:11984` plays the same stream over **WebRTC**, bypassing the
RTSP path entirely. Clean there and bad over RTSP is a real, previously-observed
combination.

### V6 — Talkback

Check the prerequisite first:

```sh
curl -s "$G2/api/streams" | grep -o '"mic"' || echo 'no mic stream — do Steps 10-11'
```

Then the two calls
([ADR-0011](../../../docs/adr/0011-ring-two-way-audio-via-go2rtc-half-duplex.md)):

```sh
# TALK
curl -X POST -G "$G2/api/streams" \
  --data-urlencode 'dst=ring' --data-urlencode 'src=rtsp://127.0.0.1:8554/mic'

# STOP — idempotent, verified 40/40 calls returning 200
curl -X POST "$G2/api/streams?dst=ring&src="
```

**Expect:** `200` from both, and someone at the door hears your microphone.

⚠️ **The two URLs in the TALK call are resolved by different machines**, and they
do not move together:

- the one you `curl` is `$G2` — resolved by **your shell**, changes with where
  you stand;
- `src=rtsp://127.0.0.1:8554/mic` is resolved by **go2rtc inside its own
  container** — so `127.0.0.1:8554` is correct no matter which shell fired the
  request, and "fixing" it to `28554` or `go2rtc-dev` breaks it.

`src` is the RTSP form deliberately: `mic` produces `opus/48000/2` and Ring
negotiates `opus/48000/2`, so this is a **passthrough with no re-encode**.

### V7 — Nothing was left running

Run this after anything that touched `ring`.

```sh
curl -s "$G2/api/streams" | sed -E "$R"
```

**Expect:** `ring` shows `"consumers":[]` (or `null`) and a producer entry with
**no `id`, `sdp` or `remote_addr`**. Those three fields appearing is what "still
connected to Ring" looks like — and nothing on the process list would have told
you.

---

## Reference

### The streams

| Stream | Video | Audio in | Audio **out** (talkback) | Notes |
|---|---|---|---|---|
| `selftest` | ✅ synthetic | — | — | Two producers on purpose: H.264 for the web build, MJPEG for `-d linux`. Point video work here. |
| `ring_doorbell` | ✅ real | ❌ | ❌ **impossible** | ring-mqtt's RTSP restream. A generic restream has no backchannel. **The Panel binds to this one.** |
| `ring` | ✅ real | ✅ | ✅ | go2rtc's native `ring:` source. The only stream here that can send audio *to* the doorbell. |
| `mic` | — | — | (the source of talkback) | Local capture. Steps 10–11. |

Both Ring streams point at the same physical doorbell through **two independent
Ring sessions**. Keeping both is deliberate — the Panel's binding is not being
changed as part of this work.

### Files in this directory

| File | Tracked? | What it is |
|---|---|---|
| `go2rtc.example.yaml` | ✅ tracked | The starter, and the documentation of every stream shape. Step 1 copies it. |
| `go2rtc.yaml` | ❌ **gitignored** (`hub/dev/.gitignore: go2rtc/*`) | The live config. **Holds credentials.** |
| `README.md` | ✅ tracked | This file. |

### Why the version is pinned to 1.9.10

It is the version Frigate 0.17 embeds
(`docs/research/frigate-amd-acceleration.md`), and the production stack pins it
for parity; the dev stack matches production deliberately. ⚠️ This has a
consequence for Ring talkback — see *Troubleshooting*, *version skew*.

### On the name `mic`, since it looks inconsistent beside the others

Nothing binds it. Grepped 2026-08-08: the string appears in ADR-0011, the two
plan documents, these two config files and this README — and **in no code at
all** (`panel/`'s `mic` hits are `Icons.mic`, the push-to-talk button's Flutter
icon; `_startTalking` is still a stub and has never named a stream). Renaming is a
docs-only sweep across five files, one of which is an accepted ADR and would want
a dated amendment rather than a silent edit.

Worth keeping anyway, for a reason beyond inertia: **`mic` is a role, not a
device.** The naming here is not one scheme — `ring` and `ring_doorbell` name
*sources*, `selftest` names a *purpose*, `mic` names a *role* — and that third
kind earns its keep at the one change already planned. ADR-0011 puts the WebRTC
echo canceller underneath by pointing this stream at the cleaned capture:

```yaml
mic: exec:ffmpeg -re -f pulse -i aec_source ...     # was: -i default
```

The source changes; the stream name does not, and neither do the TALK calls in
the ADR, the plans, or the Panel code that will eventually make them. `ring_mic`
would bind a local capture device to the one consumer that happens to use it
today, and be wrong as soon as there is a second of either.

### What the API accepts as `src`

| What you send | What happens | Why |
|---|---|---|
| `src=mic` | **500** `unsupported scheme: mic` | `GetProducer()` requires a scheme; a bare stream name is not one. |
| `src=exec:…` | **400** `source from insecure producer` | `exec:` over HTTP would be arbitrary command execution. **Only honoured from the config file** — so the Panel can never hand go2rtc a command at talk time; pre-declare it. |
| `src=ffmpeg:mic#audio=opus` | **200** | Works, and transcodes. |
| `src=rtsp://127.0.0.1:8554/mic` | **200** | Works, passthrough. **Preferred.** |
| `src=` (empty) | **200** | The stop call. Idempotent — verified 40/40. |

### The lab sub-projects this replaces

Two throwaway directories sit beside this one. Both answered questions that this
stream now inherits, and **both are scheduled for deletion once `ring` is proven
working here** — read them first; they are the only record of how the answers
were reached.

**[`../ring-audio-test/`](../ring-audio-test/README.md) — the isolated
experiment.** A fourth go2rtc (`go2rtc-ring-test`, **1.9.14**) in its own compose
file, built to ask one question without touching anything that existed: *can
go2rtc's native `ring:` source carry this laptop's microphone to the doorbell's
speaker?* **Read it for** the exact repeatable bring-up — minting a Ring login
the hard way, two go2rtc bugs hit and worked around, and the PipeWire/PulseAudio
socket mount that makes microphone capture work inside a container. **That mount
is exactly what Step 10 needs**; its `compose.yaml` is the working reference.
🔴 Its `go2rtc/go2rtc.yaml` holds a **live Ring token in the repo tree** — its own
reason to finish and remove the directory. Its status line ("blocked at step 3")
is **stale**; that stall was later found not to exist.

**[`../ring-twoway-lab/`](../ring-twoway-lab/README.md) — the plan and the
results.** The full investigation: a ~72 KB plan with three candidate tracks
(go2rtc as shipped, a bespoke `ring-client-api` service, Scrypted), a decision
tree, and `probe/probe.mjs`, an independent client never run because its separate
token was never minted. **Read `RESULTS.md`, not the plan** — the plan records
what was *believed*, the results what was *measured*, and they contradict each
other repeatedly. `RESULTS.md` holds every experiment, including **seven wrong
theories and their corrections** (User-Agent blocking, an unbounded hang,
clipping, a starved encoder, wasted stereo, DTX, packet loss), the
credential-exposure incident and the leaked-consumer incident. It exists mainly
so the wrong turns are not re-walked. ⚠️ Its §3/A2 contains a **destructive
config-rewrite snippet** — a regex with a DOTALL flag that deletes everything
from `log:` to end of file, token included. Do not run it verbatim; the fix is
recorded beside it in `RESULTS.md`.

### Documents that outlive both

| Document | What it is for |
|---|---|
| [ADR-0011](../../../docs/adr/0011-ring-two-way-audio-via-go2rtc-half-duplex.md) | The decision: go2rtc's `ring:` as shipped, two HTTP calls, half-duplex echo control. What was rejected, and why. |
| [`docs/plans/ring-audio-stack.md`](../../../docs/plans/ring-audio-stack.md) | The spec — packages, the Appliance's audio stack, verification procedure. §0 is a status table. |
| [`docs/plans/ring-audio-next-session.md`](../../../docs/plans/ring-audio-next-session.md) | The work queue, in priority order, with what is blocked on whom. |
| [`docs/research/ffmpeg-ring-opus-corruption.md`](../../../docs/research/ffmpeg-ring-opus-corruption.md) | Why inbound must use GStreamer, and why the cause is still unknown. Read before filing anything upstream. |

---

## Troubleshooting

Indexed by what you actually see. Each of these was hit for real.

### `curl: (7) Failed to connect to 127.0.0.1 port 11984`

Not a go2rtc failure at all — **you are in the devcontainer**, and `11984` is
published on the *host*. The devcontainer has its own network namespace and
reaches the service by name: `http://go2rtc-dev:1984`. Same trap in reverse for
`28554` vs `8554`. Setting `G2` once per shell (Step 2) removes the whole class.

### `wrong response on DESCRIBE`

**The `src` stream does not exist.** go2rtc's RTSP *client* connected to go2rtc's
own RTSP *server*, sent `DESCRIBE /<name>`, and got a 404; a non-200 DESCRIBE
surfaces as that message. **It never reached Ring.** The error names neither the
stream nor the 404, which is why it reads like a transport problem.

The usual cause is firing TALK before Steps 10–11, so `mic` does not exist.
Measured 2026-08-08 from a host shell and from the devcontainer, **identical both
times** — which is itself the confirmation that `src` is resolved inside the
container, so where you called from cannot change it. If an error *does* differ
between shells, it is the `$G2` half, not the `src` half.

🟢 **It leaves nothing running.** Checked immediately after: `ring` reported
`"consumers":[]` with no `id`/`sdp`/`remote_addr` — the doorbell was not left in a
call. (Whether it dialed briefly and tore down is not distinguishable at the
default `level: info`, where `start producer` is a DBG line.) Prefer V5 for
exploratory testing anyway; a bad `src` on `dst=ring` is not a shape worth
relying on being harmless.

### `WRN [rtsp] error="streams: ring: wrong query" stream=ring`

go2rtc **#1781**, and it has two causes that look identical:

1. **A malformed line** — wrapped, or a `&` lost. It must be one physical line.
2. **A missing parameter.** `pkg/ring`'s `Dial()` requires all three of
   `device_id`, `camera_id` and `refresh_token`, and errors if any is empty —
   even though go2rtc's own `internal/ring/README.md` documents only two. See
   Step 6.

Note this is a *bounded, named* failure that appears even at `level: info`; a
silent hang is a different problem.

### Edits appear to do nothing

go2rtc reads config at start only. Restart (Step 9), then run **V2** — comparing
the container start time against the file mtime is what catches this.

### A call failed and the log says nothing about it

Expected at the default level. The interesting lines — `start producer`,
`stop producer`, `new consumer` — are all **DBG**. Raise it and restart:

```yaml
log:
  level: debug        # `ring: trace` is a DEAD KEY; it silently does nothing
```

### The file changed and nobody edited it

Expected. go2rtc patches the token in place on rotation (Step 9). ±34-byte size
deltas track the token's length changing.

### Inbound Ring audio is distorted — "high pitch metallic"

🔴 **You are consuming it with ffmpeg. Use GStreamer** (V5). Measured on the same
stream at the same moment: ffmpeg **36 642** out-of-range samples (44 404 on
24.04) against GStreamer's **0**.

No filters, no headroom correction, no transcode. Any post-processing you find in
the git history — mono downmix, 7 kHz lowpass, limiters — existed only to mask
this and now only costs fidelity. **Outbound is unaffected**: there ffmpeg
*packetises*, a different code path, measured clean at ~39 dB SNR.
⚠️ *Why* ffmpeg breaks is **not known**; the "~60 ms Opus frames" explanation was
disproved —
[`ffmpeg-ring-opus-corruption.md`](../../../docs/research/ffmpeg-ring-opus-corruption.md).

### `non-existing PPS 0 referenced` / `no frame!` / `Could not write header`

The consumer attached before the H.264 parameter sets arrived and gave up. Warm
the producer with a throwaway dial first, and add
`-analyzeduration 10M -probesize 10M`. Relevant to the Panel: a video consumer
that attaches at the wrong moment fails this way at startup.

### The audio is silent

🔴 **Probably correct.** Ring transmits near-digital-silence (~−90 dBFS) on a
quiet street and real sound arrives in bursts; the Opus track is always negotiated
but often carries nothing. **Never treat quiet as broken, and never use audio
presence as a health check** — a watchdog restarting on "no audio" would restart
constantly. Verify with real speech at the door, and assert more than 5 s of it
before trusting a pass.

### Browser video fails, with no error frame

`api.origin: "*"` is required, and the example ships it. go2rtc **403s any
WebSocket upgrade carrying an `Origin` header** unless told otherwise, and a
browser always sends one. The tighter alternative — naming the exact origin — is
**broken in 1.9.10**: it 403s the very origin it was given. There is no
allowlist; it is `"*"` or no video. Accepted deliberately (root README, **E8**),
because the network boundary is the control.

### Escape routes that do not exist

All measured, all closed — do not spend time rediscovering them:

| Attempt | Result |
|---|---|
| `?audio=pcma` / `pcmu` / `aac` on the RTSP URL | **404** — go2rtc will not transcode for RTSP output |
| `/api/stream.mp4?src=ring` | "Output file does not contain any stream" — the MP4/MSE muxer cannot carry Opus |
| RTSP over UDP | **461 Unsupported transport** — go2rtc's RTSP server is TCP-interleaved only |
| `ffmpeg:ring#audio=…` | consumes `ring` over RTSP internally — same path, same result |

### The doorbell stayed live and nobody noticed

🔴 **Nothing reaps an orphaned consumer.** go2rtc has **no idle timeout on
internal producers**. Two stray `curl`s once held the doorbell in live view for
**~30 minutes and pulled 160 MB** before a routine `/api/streams` dump found them.
Consequences that are not optional:

- Time-bound every probe **inside the container that runs it** (`timeout …`), not
  merely on the calling side.
- Check the **consumer list**, not the process list (V7). `pgrep -a -x ffmpeg`
  would never have caught that `curl` — and `pgrep -fa <pattern>` self-matches its
  own command line, so use `-x`.
- A server-side dead-man switch is required before any of this ships. It does not
  exist yet.

### It worked in the lab but not here — version skew

⚠️ **`ring:` was never tested on 1.9.10.** Every talkback measurement in ADR-0011
was taken against `go2rtc-ring-test`, which runs **1.9.14**; this container runs
**1.9.10**. `ring:` is precisely the module the ADR flags as abandoned (14 commits
ever, last functional one 2025-05-21), so four patch releases are not safely
assumed neutral there. Bump the pin or re-run the dial on 1.9.14, and record
which.

### Dings started going missing

⚠️ **Two Ring sessions now exist on this laptop** — `ring-mqtt-dev`'s and this
one, each with its own token. That combination has never been load-tested.
Suspect it first (HA core #177014 on open streams suppressing dings; #167406 on
multiple Ring clients).
