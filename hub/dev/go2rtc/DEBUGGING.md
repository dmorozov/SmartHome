# Ring video and audio — debugging record

Everything learned chasing Ring doorbell **video** (green/frozen picture) and
**audio** (talkback and inbound) through go2rtc, including the theories that
turned out to be wrong. Written 2026-08-10.

**Read the "Disproven" sections before forming a theory.** Six explanations
died in this work, four of them in a single session, and each one cost a
round trip. They are recorded so nobody re-derives them.

- Setup and configuration: [`README.md`](README.md) (the runbook)
- Decision and rationale: [ADR-0011](../../../docs/adr/0011-ring-two-way-audio-via-go2rtc-half-duplex.md)
- Audio stack spec: [`ring-audio-stack.md`](../../../docs/plans/ring-audio-stack.md)
- The Panel side: [`panel/README.md`](../../../panel/README.md), "Live video in the Popup"

---

## 0. Rules that are not style

Each of these has already cost something real.

1. **Never print the Ring refresh token.** `/api/streams` responses **and**
   `DBG … start producer url=…` log lines embed it. Pipe **every** command,
   including one-offs, through:
   ```sh
   sed -E 's/(refresh_token=)[^&[:space:]"]*/\1<REDACTED>/g'
   ```
   Two leaks have already cost a re-mint. Do not read `go2rtc.yaml` to answer a
   question the API can answer.
2. **Time-bound every probe *inside* the container that runs it.** A killed
   caller does not kill the work: an orphaned `curl` held the doorbell live for
   ~30 minutes and pulled 160 MB.
3. **Check the consumer list, not the process list.** `pgrep -a -x ffmpeg`
   would never have caught that `curl`. (`pgrep -fa` also self-matches its own
   command line — use `-x`.)
4. **A browser tab left open holds the doorbell live indefinitely.** Observed
   at **357 MB** in one session. Nothing reaps it — go2rtc has no
   consumer-kill endpoint and the watchdog only watches `ring`/`mic`, not
   `ring_doorbell`. The Panel now bounds its own Popup
   (`kDevicePopupIdleReturn`, 5 min); nothing bounds anyone else's client.
5. **The Front Door is hardwired.** There is no battery to drain — corrected
   2026-08-10, and `appliance/commissioning/05-devices-cloud.md` records "no
   battery entity". The cost that *does* survive is HA core **#177014**: an
   open live session can suppress a real ding, and a bell that silently stops
   ringing has no other symptom. Do not dial casually.
6. **Never `docker compose up`/`down` from the devcontainer.** Relative bind
   mounts resolve against a path the host daemon does not have.
   `docker restart <name>` is path-free and safe from anywhere.

---

## 1. The stream, as measured

Front Door, go2rtc **1.9.10**, `ring_doorbell` (ring-mqtt RTSP restream),
measured 2026-08-10. Useful for telling "unusual" from "broken".

| | |
|---|---|
| Resolution | **1536×1536** — Ring's square sensor, 96×96 = **9216 macroblocks** |
| Frame rate | ~23–24 fps |
| Bitrate | ~274 KB/s |
| SPS | 48 bytes; profile `0x64` (High), constraints `0x00`, **level `0x32` = 5.0** |
| `avcC` box level | **`0x32` = 5.0** (agrees with the SPS) |
| go2rtc's MIME answer | **`avc1.640029` = level 4.1** ← disagrees, see §2.1 |
| Init segment | **699 bytes** (`ftyp:28` + `moov:671`), exactly one per session |
| Keyframe | ~112 KB (`moof:100` + `mdat`) |
| P-frames | ~0.5–21 KB |
| Resolution changes | **none** observed over a 30 s soak (683 frames) |

`mic` stream: **opus / 48000 Hz / 2 ch**, which is why ADR-0011's
`src=rtsp://127.0.0.1:8554/mic` is a passthrough with no re-encode.

---

## 2. Video — confirmed causes

### 2.1 go2rtc under-reports the H.264 level ✅ confirmed, worked around

**Symptom.** Nothing decodes at all. `totalVideoFrames: 0`, `readyState: 1`,
and:

```text
PIPELINE_ERROR_DECODE: Failed to send video packet for decoding:
  {timestamp=0 duration=1011 size=93997 is_key_frame=1 encrypted=0}
```

**Cause.** `pkg/h264/h264.go`:

```go
level := byte(41)                 // default
switch conf[2] {
case 30, 31, 40:                  // 3.0, 3.1, 4.0 only
    level = conf[2]
}
```

go2rtc parses the real level from the SPS (**50**), finds it is not in that
whitelist, discards it, and falls back to **41**. So every stream above Level
4.0 is advertised as 4.1 — and 4.1 caps a frame at **8192** macroblocks while
this one is **9216**.

`MediaSource.isTypeSupported()` returns **true** regardless, because all it does
is parse the string. The decoder is then built for 4.1 and rejects the first
keyframe.

**Same stream, same socket, one byte different:**

| declared | `totalVideoFrames` | `readyState` | error |
|---|---|---|---|
| `avc1.640029` (4.1) | **0** | 1 | `PIPELINE_ERROR_DECODE` |
| `avc1.640033` (5.1) | **180+** | 4 | none, full clean picture |

**Workaround.** `raiseH264Level` in `panel/lib/ui/video/live_video.dart`
rewrites the level byte before `addSourceBuffer`, leaving profile and
constraint bytes untouched. A level in a MIME type is a *capability hint* — the
bitstream's SPS still governs decoding — so declaring more than a stream needs
costs nothing while declaring less is fatal. Unit-tested on the VM.

**Ring is not at fault here.** Its SPS correctly declares Level 5.0.

### 2.2 go2rtc emits samples with bogus durations on a warm join ✅ confirmed, mitigated

**Symptom.** Intermittent. First open after a page load works; **refresh and
reopen** fails with a part-decoded frame (green below the decoded region), or
"Live view unavailable". Sometimes self-heals.

```text
mse_media_error code=3 detail="PIPELINE_ERROR_DECODE: Failed to send video
  packet for decoding: {timestamp=124911 duration=11 size=20425 is_key_frame=0}"
  buffered_s=0.2 appends_failed=0 segments_dropped=0
```

Four separate failures, four different timestamps, always the same two facts:
**a sub-millisecond `duration`** and **`is_key_frame=0`**. `appends_failed=0
segments_dropped=0` proves the Panel delivered every byte intact — the samples
themselves are malformed.

**Cause.** `pkg/mp4/muxer.go`:

```go
func (m *Muxer) AddTrack(codec *core.Codec) {
    m.pts = append(m.pts, 0)                       // cursor starts at ZERO
}

duration := packet.Timestamp - m.pts[trackID]
...
if duration == 0 || duration > codec.ClockRate {
    duration = codec.ClockRate/1000 + 1            // placeholder
    m.pts[trackID] += duration
}
```

Every consumer gets a fresh muxer with `pts = 0`, so the first sample's
duration is the whole RTP timestamp. On a **warm** producer that is large →
`> ClockRate` → placeholder. On a **cold** producer the timestamps start near
zero → sane. That is the entire cold/warm pattern.

⚠️ **Partly inferred — be honest about which part.** `duration=1011 µs` is
exactly the placeholder (91 ticks at 90 kHz), so that one is proven.
`duration=11 µs` is **one** tick, which the placeholder does not produce; it is
consistent with either the `m.pts[trackID] += duration` corruption in that same
branch or two frames sharing a timestamp, but neither was confirmed. The
mechanism above explains the cold/warm split; the exact arithmetic of the 1-tick
cases does not.

**Mitigation.** The Panel cannot fix malformed samples. What it can do — and
what **go2rtc's own player already did** — is dial again. `_reconnect` in
`live_video_mse.dart` rebuilds the MediaSource and socket against the same
`<video>`, bounded to **three** attempts because every retry is another consumer
on the doorbell. A fresh muxer re-rolls the dice, which is empirically enough
because the anomaly is in the first samples a consumer is handed.

**This is fileable upstream.** Repro: attach an MSE consumer to an
already-running go2rtc stream and read the `trun` sample durations. Likely
one-line fix: seed `m.pts[trackID]` from the first packet's timestamp instead of
zero. ⚠️ Read against **1.9.14** source while **1.9.10** was running — diff that
file before filing.

### 2.3 Three defects in the Panel's own MSE pump ✅ confirmed, fixed

All in `live_video_mse.dart`, all of which looked like a decoder fault because
bytes kept arriving throughout.

1. **No `<video>` `error` listener at all.** The element's `error` event was
   never observed. A media element that errors sets `error`, and MSE's
   prepare-append algorithm then throws `InvalidStateError` on *every*
   subsequent `appendBuffer` — so a decode failure was invisible and surfaced
   only as its own aftermath. **This was the single most expensive omission in
   the whole investigation**: three theories died to it before it was added.
2. **`_trim` starved by its own backlog.** `_onUpdateEnd` returned early
   whenever staged segments waited, so under sustained load the SourceBuffer
   was never trimmed and grew until `appendBuffer` threw.
3. **One throw killed the pump permanently.** A throw means no update *started*,
   so no `updateend` fires — and `_onUpdateEnd` was the only thing draining the
   backlog. After a single throw the player was dead while every liveness signal
   stayed healthy.

Both loss paths were silent. They now log once with a running count:
`video.mse_segment_dropped`, `video.mse_append_failed`.

### 2.4 Green *is* uninitialised YUV

A hole in the picture is not "a green overlay". `Y=0, U=0, V=0` converts to
roughly `RGB(0, 135, 0)` — dark green. **Green means the decoder never wrote
those macroblocks**, so it always points at missing or rejected data, never at
a colour-space bug.

---

## 3. Video — disproven theories

Do not re-derive these.

| Theory | How it died |
|---|---|
| **Ring's encoder is non-conformant / the SPS overruns its own level** | Read the bitstream: SPS **and** `avcC` both say level 50 (5.0), which permits 22 080 macroblocks against this frame's 9216. go2rtc's MIME is the wrong one. |
| **The browser joins mid-GOP with no keyframe** | `pkg/mp4/consumer.go` already gates: `if !c.start { if !h264.IsKeyframe(...) { return } }`. go2rtc will not send media before a keyframe. |
| **`QuotaExceededError` — the SourceBuffer is full** | The failing append reported `buffered_s=0.2`. The buffer was nearly empty. |
| **The `<video>` element was detached from the document** | Plausible, and it *is* a real hazard (see §2.3), but the failing append reported `video_connected=true`. |
| **Hardware/GPU decoder fault at 1536×1536** | Reproduces with graphics acceleration **disabled**. The failing path is Chrome's software ffmpeg decoder (`avcodec_send_packet`). |
| **A fault in the Panel's player** | go2rtc's **own** reference player at `/stream.html?src=ring_doorbell` fails identically on the same machine — and recovers only because it reconnects. |

**Also ruled out by measurement:** no mid-stream resolution change, no second
init segment, exactly one `ftyp` per session over a 30 s soak.

---

## 4. Video — untried options

None of these were attempted; recorded so the next person does not have to
rediscover the option space.

| Option | Trade |
|---|---|
| **Transcode** — point the Panel at `ffmpeg:ring_doorbell#video=h264` | Clean, conformant timestamps *and* a level go2rtc reports correctly. Costs Hub CPU. Config change, no code. Probably the best fix. |
| **MJPEG on web** — use the transport the appliance branch already proves | Sidesteps H.264/MSE entirely. Higher bandwidth; needs the `ffmpeg:<name>#video=mjpeg` producer. |
| **`sourceBuffer.mode = 'sequence'`** | One line; the browser generates its own timestamps and ignores the container's, which would neutralise bogus durations. Changes live-edge and trimming semantics — do not ship unmeasured. |
| **Bump go2rtc** | The muxer bug is present in **1.9.14** (newer than the pinned 1.9.10), so this is not a fix. |

---

## 5. Audio — confirmed

### 5.1 Talkback is two HTTP calls, and it works ✅ V6 passed 2026-08-10

```sh
# START
curl -sS -X POST -G 'http://127.0.0.1:11984/api/streams' \
  --data-urlencode 'dst=ring' \
  --data-urlencode 'src=rtsp://127.0.0.1:8554/mic'
# STOP — idempotent, verified 40/40 returning 200
curl -sS -X POST 'http://127.0.0.1:11984/api/streams?dst=ring&src='
```

Verified at the door twice on 2026-08-10 — once by `curl`, once through the
Panel's push-to-talk button.

- **`dst` is `ring`, never `ring_doorbell`.** `ring_doorbell` is ring-mqtt's
  RTSP restream and structurally cannot carry talkback; `ring` is go2rtc's
  native source, the only one with a backchannel. The Panel carries both names
  (`stream:` and `talk:` in `bindings.yaml`) because neither derives from the
  other.
- **`src` needs a scheme.** A bare `src=mic` is `HTTP 500 · unsupported
  scheme`; `GetProducer()` requires one.
- **`exec:` is refused over the API** — `HTTP 400 · source from insecure
  producer`. Any exec-based producer must be pre-declared in `go2rtc.yaml`.
  The Panel can never hand go2rtc a command at talk time.
- **Spell `src=` by hand.** Dart's `Uri.replace(queryParameters: {'src': ''})`
  renders a bare `src` with no `=`. Go's `net/url` very likely reads them
  alike, but "very likely" is the wrong standard for the call that closes a
  live microphone.

### 5.2 🔴 The PulseAudio socket mount goes stale — the trap that will recur

**Symptom.** Talkback fails *only* when somebody presses the button.
`PULSE_SERVER` is set, `docker inspect` shows the bind present and correct, and
`/run/user/1000/pulse/` **inside the container is empty**.

**Cause.** `/run/user/1000` is a systemd tmpfs. When the host's user session is
recreated (logout, reboot), the `pulse` directory gets a **new inode**, and any
container that bound the old one keeps mounting a directory that no longer
exists.

**Fix.** No compose needed:

```sh
docker restart go2rtc-dev
docker exec go2rtc-dev ls /run/user/1000/pulse/   # expect: native, pid
```

**Run that after any host reboot or re-login before trusting talkback.** It bit
on 2026-08-10 and would have wasted a trip to the door.

### 5.3 Inbound MUST use GStreamer, never ffmpeg ✅ confirmed, cause unknown

Same stream, same moment, samples outside ±1.0 on a float decode:

| Release | GStreamer | ffmpeg |
|---|---|---|
| Ubuntu 24.04 (1.24.2 / 6.1.1) | **0** bad samples | 44 404 |
| Ubuntu 26.04 (1.28.2 / 8.0) | **0** bad samples | 36 642 |

The rule rests on the differential, **not** on any explanation. Outbound stays
on ffmpeg and measures clean (~39 dB SNR) — there it is the *packetiser*, a
different code path.

**Do not add post-processing.** The mono downmix, 7 kHz lowpass and limiters in
the git history existed only to mask corruption the GStreamer path does not
have; they now only cost fidelity.

### 5.4 Silence is normal

Ring transmits near-digital-silence (~−90 dBFS) on a quiet street. **A silent
capture passes every test while proving nothing** — assert `speech > 5 s`
before trusting a pass, and never health-check on audio presence.

### 5.5 The watchdog's startup stop needed a retry

`depends_on:` waits for go2rtc's **container** to start, not for its HTTP
listener to bind, so `talk-watchdog` won the race and spent its one attempt on
`ECONNREFUSED` (observed 2026-08-10T03:25:53Z). Now retried for
`STARTUP_GRACE_S`. The cost was smaller than it looks — the poll loop already
caught both leak shapes — so it made cleanup *slower*, not absent.

---

## 6. Audio — disproven

| Theory | How it died |
|---|---|
| **ffmpeg mishandles Ring's ~60 ms Opus frames** | Does not reproduce: synthetic 60 ms Opus over RTP decodes with **zero** bad samples through the same ffmpeg, as do six variants copying Ring's shape (mono-coded/`/2`-declared, inband FEC, DTX, 40 ms, low-delay). ADR-0011 carries a dated amendment withdrawing it. |
| **A `sendonly` audio media on the `ring` producer means somebody is talking** | An ordinary inbound RTSP *listener* also reports `"audio, sendonly, ANY"`. Keying on it would report talk in progress every time somebody merely watched. The watchdog keys on the **`mic` stream's producer** being live instead. |
| **The watchdog can reap an orphaned consumer** | There is no consumer-kill endpoint. The leaked `curl` was killed with `pkill -9 -x curl` *inside the container*; `PUT`/`DELETE` on `/api/streams` rewrite `go2rtc.yaml` on disk (token included) and stop nothing. |

---

## 7. Diagnostic recipes

All safe to copy. From the devcontainer, `go2rtc-dev:1984` is reachable;
`localhost:11984` is **not** (that is the host's published port).

**Stream census, token-safe:**
```sh
docker exec talk-watchdog-dev python3 -c "
import json,urllib.request
d=json.load(urllib.request.urlopen('http://go2rtc:1984/api/streams', timeout=5))
print({k:{'live':sum(1 for p in (v.get('producers') or []) if p.get('id') is not None),
          'cons':len(v.get('consumers') or [])} for k,v in d.items()})
"
```

**Is the microphone actually capturing?** (opens the mic locally; touches no
Ring session)
```sh
docker exec -d go2rtc-dev sh -c 'timeout 15 ffmpeg -loglevel quiet \
  -rtsp_transport tcp -i rtsp://127.0.0.1:8554/mic -t 12 -f null - >/dev/null 2>&1'
# then watch bytes_recv climb on the `mic` producer via the census above
```

**Teardown check — consumers, then processes:**
```sh
docker exec go2rtc-dev sh -c 'pgrep -a -x ffmpeg || echo none'
```

**Read the codec go2rtc actually offers** (browser console, any page):
```js
const ws = new WebSocket('ws://go2rtc-dev:1984/api/ws?src=ring_doorbell');
ws.binaryType = 'arraybuffer';
ws.onopen = () => ws.send(JSON.stringify({type:'mse', value:'avc1.640029,avc1.640033'}));
ws.onmessage = e => { if (typeof e.data === 'string') console.log(e.data); };
```

**Read the SPS and `avcC` level out of the init segment.** Find the ASCII
`avcC` in the first binary message; the four bytes after it are
`version, profile_idc, profile_compat, level_idc`, and the SPS follows at
`+8`, itself `nal_header, profile_idc, constraints, level_idc`.

**Identify a message by its boxes.** Walk top-level ISO-BMFF boxes —
`ftyp`+`moov` is the init segment (699 bytes here), `moof`+`mdat` is media.

**Never trust the frame counters.** `totalVideoFrames` and
`corruptedVideoFrames` both read healthy over a green picture. Draw the video
to a canvas and sample pixels down a middle column instead.

**The single best discriminator: go2rtc's own player.**
`http://localhost:11984/stream.html?src=ring_doorbell` from a host browser. If
it fails too, the fault is not in the Panel. This is what finally placed the
bug upstream, and it should have been the *first* test rather than the last.

---

## 8. Method notes — what actually worked

Written down because the same mistake was made four times in one session.

1. **Instrument before theorising.** Six theories died here, and every single
   one died to a log field that had not been added yet. Reasoning about specs
   produced confident wrong answers; adding one field produced the truth.
2. **A diagnostic that names the error without naming the state around it is
   half a diagnostic.** `error=JSObject` cost a round trip (Dart's
   `runtimeType` is `JSObject` for everything crossing the interop boundary).
   `InvalidStateError` alone cost another, because it has four possible causes.
   Only `media_state` + `source_buffers` + `updating` + `video_connected`
   together located it.
3. **Compare against the reference client early.** One 10-second test placed a
   fault that hours of code reading had not.
4. **Counters lie; pixels do not.** See §7.
5. **"It auto recovered" was worth more than any hypothesis.** The user's
   offhand observation named the fix directly — go2rtc's player reconnects.
   Ask what the working thing does differently.
6. **Failure to reproduce is a finding, not a dead end.** Seven clean runs in
   the devcontainer, against a failing run on the host, is what isolated the
   variable.

---

## 9. Still open

- **File the go2rtc muxer bug** (§2.2). Diff `pkg/mp4/muxer.go` 1.9.10 ↔ 1.9.14
  first.
- **File the level whitelist bug** (§2.1) — `GetProfileLevelID` silently
  downgrades anything above Level 4.0.
- **Why ffmpeg destroys inbound Opus** (§5.3). One ~20 s raw-Opus + `tcpdump`
  capture would make it offline-analysable — owner decision, costs one live
  view. See `docs/research/ffmpeg-ring-opus-corruption.md`.
- **Inbound audio in the Panel does not exist.** The Panel plays MJPEG, which
  carries no audio, so talkback is **one-way** and the caption says so. Who
  owns the inbound player is an open owner decision, and it gates the level
  meter, the PPS-0 warm-up and the `XDG_RUNTIME_DIR` question in
  `cage@.service.j2`.
- **`flutter test --platform chrome` hangs in this devcontainer** (stalls at
  `loading …`, leaves `chrome_crashpad` zombies). Four real bugs hid in that
  blind spot in one session. Repairing it is worth more than any individual
  patch above.
