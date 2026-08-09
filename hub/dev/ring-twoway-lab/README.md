# Ring two-way audio — experiment lab

**Goal:** prove one repeatable way to get *full bidirectional* communication with
the Front Door Ring doorbell — visitor's video + voice arrives at this machine,
and this machine's microphone reaches the doorbell's speaker — then decide which
way the Panel's push-to-talk button gets wired to.

**Scope:** Ring doorbell only. Nothing here touches the Hub stack, the Panel, the
Ansible roles, or the appliance. Nothing here is meant to outlive the answer.

**Run everything in this document from a HOST terminal on the dev laptop.**
Not from the devcontainer. Two independent reasons, both hit for real earlier:

1. Relative bind mounts in a compose file resolve against the host's filesystem,
   which has no `/workspaces/SmartHome`. `docker compose up` from inside the
   devcontainer silently mounts the wrong paths.
2. The devcontainer has its own network namespace. `curl 127.0.0.1:31984` from
   in there cannot reach a host-published port. Everything below assumes you can
   reach `127.0.0.1` on the host directly.

---

## 0. Read this first — what we already got wrong

This section exists because the single most useful observation in this whole
investigation was noticing that **nobody on the internet has ever reported our
symptom**, and treating that as evidence against us rather than against go2rtc.
That was correct. Three of our four "findings" from the first attempt were
artifacts of our own setup.

### 0.1 🔴 "No log output even at maximum verbosity" was our misconfiguration

We concluded the `ring` stream stalled with *zero* diagnostic signal, having set:

```yaml
log:
  level: info
  ring: trace     # <-- this key does nothing
```

Both halves of that were wrong:

- **`log: {ring: trace}` is a no-op.** `internal/app/log.go`'s `GetLogger(module)`
  only applies a per-module level when something calls it with that module name.
  **Nothing in go2rtc ever calls `app.GetLogger("ring")`.** `internal/ring/ring.go`
  imports no logger at all, and `pkg/ring/*.go` contains *zero* logging statements —
  every debug line in the shipped source is commented out:

  ```go
  // fmt.Printf("ring: onWSMessage: %s\n", string(rawMsg))
  // fmt.Printf("ring: error: %s\n", err.Error())
  // fmt.Println("ring: disconnect")
  // fmt.Printf("ring: sendSessionMessage: %s: %s\n", method, string(rawMsg))
  ```

- **`level: info` suppresses the only three lines this path can emit.** They are
  all `DBG`, from the `streams`/`webrtc` modules, not from `ring`:

  ```
  DBG [webrtc] new consumer src=ring
  DBG [streams] start producer url=ring:?camera_id=...
  DBG [streams] stop producer url=ring:?camera_id=...
  ```

  (Verbatim from h3nnes's log in go2rtc#1961, running `level: debug`.)

**So "not one new log line" was the designed behaviour of that config and carried
no information whatsoever.** Strike it from the diagnostic record. Experiment A2
re-runs the same dial with logging that actually works.

### 0.2 🔴 The Frigate-parity conflict does not exist

`hub/dev/ring-audio-test/README.md`, its `compose.yaml` header, and the project
memory all say *"`ring:` needs go2rtc 1.9.13+, so bumping `go2rtc-dev` would break
the deliberate Frigate-0.17 parity pin at 1.9.10."*

**That is false, verified two independent ways:**

- `internal/ring/README.md`'s "new in v1.9.13" claim is untrue, and that README
  did not exist in the shipped release —
  `raw.githubusercontent.com/AlexxIT/go2rtc/v1.9.14/internal/ring/README.md`
  returns **HTTP 404**, while `pkg/ring/client.go` returns **HTTP 200** at tags
  **v1.9.9, v1.9.10, v1.9.12, v1.9.13**.
- `main.go` at tag **v1.9.10** contains `ring.Init() // ring source`.

**The `ring:` source shipped in v1.9.9 (2025-03-10). `go2rtc-dev` at 1.9.10 has
had this feature all along.** The entire justification for standing up a separate
fourth container was a false constraint. (The *other* reason — a separate Ring
login, because refresh tokens rotate on use — remains completely valid.)

This also removes an argument we were using *against* go2rtc. Whatever we decide,
it must not rest on a version conflict that isn't real.

### 0.3 🔴 The `ring-auth-cli` workaround is reported broken on our exact version

go2rtc issue **#2281** (open, 2026-05-27, zero maintainer replies): a user mints a
token with `npx -p ring-client-api ring-auth-cli` — *exactly what we did* — pastes
it into **go2rtc 1.9.14** — *exactly our version* — and gets "invalid token", having
tried the JSON pair, quoted, unquoted, and manually base64-encoded. Filed by
`inquisitev`, **the same person who had recommended that workaround in #2261 ten
days earlier.**

We are not the first to walk this path. We are the second, and the first one
didn't get out either.

### 0.4 ✅ One thing we got right, confirmed from source

Our mid-session reversal on `#backchannel=1` was correct. `pkg/pcm/backchannel.go`
proves it creates a **sink**: one `sendonly` media, `GetTrack` hard-fails with
`core.ErrCantGetTrack`, and `AddTrack` opens `StdinPipe()` and writes incoming RTP
payloads into the child process. It plays audio *out locally*; it does not capture
a mic to send upstream.

---

## 1. Executive summary — what the research actually concluded

Six specialist research passes (go2rtc source forensics, Ring protocol
engineering, community field reports, an adversarial alternatives review, and
last-mile integration mechanics) ran independently on 2026-08-08. Their
load-bearing conclusions:

### 1.1 The root cause of the login 406 — a stale User-Agent

> ⚠️ **Read with §1.11.** This explains the **web-UI login 406** we hit and worked
> around. Peer review concluded it does **not**, on current evidence, explain the
> **stall** — those are two separate defects. Don't let this section's strength
> pull you into treating them as one.


**Two agents converged on this by completely different methods, without seeing
each other's work.**

| Client | User-Agent sent to `https://oauth.ring.com/oauth/token` | Status on our account |
|---|---|---|
| go2rtc `pkg/ring/api.go` — **identical in v1.9.10 / v1.9.13 / v1.9.14 / master** | `android:com.ringapp` | **406 Not Acceptable** |
| `@tsightler/ring-client-api@14.3.1-beta.0` (vendored in `ring-mqtt-dev`) | `android:com.ringapp:3.98.0(70492092)` | **✅ works, 2026-08-08** |

Everything else is identical between them: same endpoint, same `hardware_id`
header, same `2fa-support: true`, same `api_version: 11`, same
`client_id: ring_official_android`, same scope. go2rtc sets the bare UA in **four
places** (`api.go` lines 263, 429, 551, 612).

**Independent corroboration from Ring's own ecosystem:** dgreif/ring issue
**#1717** (opened 2026-03-06, **still open**, 21 comments) reports that from
~2026-02-23 noon PST `oauth.ring.com/oauth/token` began returning **406 from
Cloudflare**. In-thread on 2026-03-08/09 tsightler establishes this is **not** an
endpoint migration but a **Cloudflare WAF bot-score**, and that the fix which
worked was sending the full versioned Android User-Agent.
`@tsightler/ring-client-api@14.3.1-beta.0` was published **2026-03-08 — two days
after that issue was filed** — carrying exactly that UA, and `ring-mqtt v5.9.3`
shipped 2026-03-09 noting *"minor changes to attempt to address sporadic
authentication issues."*

**Our doorbell works today partly because of that patch. go2rtc never got it.**

**Historical precedent:** two independent projects fixed a Ring 406 with this
exact header in the same week of April 2023 — Scrypted PR #698 *"ring: fix login
406 error"* (merged 2023-04-06) and a dgreif/ring commit *"Add user agent to auth
request headers"* (2023-04-07). Ring has form for gating on this header, and
`android:com.ringapp` is the most-copied Ring UA string on the internet — exactly
what an anti-abuse team blocklists.

**Honest counter-evidence:** our own bare `curl` probe to `oauth.ring.com` returned
**401, not 406**. So Ring is not 406-ing every unrecognised client. That is
consistent with a *blocklist of known-abused signatures* rather than an allowlist —
but it means the theory is not proven. **Experiment A1 settles it in two minutes.**

### 1.2 Where the code actually hangs

`Dial()`'s last statement, `pkg/ring/client.go`:

```go
	if err = client.wsClient.sendSessionMessage("live_view", offerPayload); err != nil {
		client.Stop()
		return nil, err
	}
	sendOffer.Done(nil)
	if err = client.connected.Wait(); err != nil {   // <-- blocks here
		return nil, err
	}
	return client, nil
```

`connected` is a `core.Waiter` — a bare `sync.WaitGroup` with **no deadline, no
context, no default case**. **There is no timeout anywhere in go2rtc's ring
source.** `Done()` has five reachable call sites (PC connected; PC failed;
`onError`; `onClose`; sdp/ice error branches). If the WebSocket stays open and no
`sdp` answer arrives, **none fire** — and `ws.go` actively keeps the socket alive
with `time.NewTicker(5 * time.Second)` sending `ping`, so `onClose` can't rescue
it either. That is a permanent, silent, error-free hang, on the consumer's
goroutine — which is why `/api/streams` stayed responsive throughout.

**A separate agent, reading the *Ring library* rather than go2rtc, predicted this
signature blind:** *"go2rtc likely has the same `await onCallAnswered` shape with
no timeout, which would produce exactly the 'no picture, no error, nothing at all
for 45+ s' signature."* Both `ring-client-api`'s `transcodeReturnAudio` (which
awaits `isUsingOpus` → `onCallAnswered`) and go2rtc's `connected.Wait()` have the
identical unbounded-wait flaw.

**And go2rtc almost certainly threw away Ring's explanation.** `onWSMessage`
handles only four methods — `sdp`, `ice`, `close`, `pong` — but `ws.go` *declares
types it never handles*:

```go
type NotificationMessage struct {
	Method string
	Body   struct { SessionBody; IsOK bool; Text string }
}
type StreamInfoMessage struct { ...; TranscodingReason string; ... }
```

Neither `"notification"` nor `"stream_info"` appears in the switch. **A Ring
`notification` carrying `is_ok:false` and a human-readable `Text` — the field
literally designed to say why live view was refused — falls through and is
discarded with no log line.** Experiment A5 un-comments four `fmt.Printf` lines to
see it.

### 1.3 A hypothesis that exists only in the gap between two reports

`ring-client-api`'s pre-call sequence has a step go2rtc's package inventory does
not appear to contain:

```
1. POST https://oauth.ring.com/oauth/token                          — go2rtc: yes
2. POST https://api.ring.com/clients_api/session                    — go2rtc: NOT FOUND
     body: {device:{hardware_id, metadata:{api_version:11,
            device_model:'ring-client-api'}, os:'android'}}
     re-created every 12h
3. POST .../clap/ticket/request/signalsocket                        — go2rtc: yes
4. WSS api.prod.signalling.ring.devices.a2z.com/ws?...              — go2rtc: yes
5. send {method:'live_view', body:{doorbot_id, stream_options, sdp}} — go2rtc: yes
```

The library's own comment on step 2: *"This is what makes the account look like a
registered Android app instance."* **If go2rtc skips it, Ring may accept the
ticket, accept the WebSocket, and then simply never answer `live_view`** — a silent
refusal, delivered as precisely the `notification` message go2rtc discards.

This was not found by any single agent. It fell out of comparing two reports.
Experiment A5 tests it directly. *(Confidence: moderate. `pkg/ring/api.go` was not
exhaustively grepped for `clients_api/session`; verify before relying on it.)*

### 1.4 Ring's two-way audio protocol — ground truth

Read from `dgreif/ring` at HEAD (`638d528`, 2026-08-04), with the real SDP offer
generated by **executing werift 0.22.9 locally** using the library's exact config.

**The offer:**
```
m=audio 9 UDP/TLS/RTP/SAVPF 96 0
a=sendrecv                          <-- the two-way channel
a=rtpmap:96 opus/48000/2
a=rtpmap:0 PCMU/8000

m=video 9 UDP/TLS/RTP/SAVPF 98 99
a=recvonly
a=rtpmap:98 H264/90000
a=fmtp:98 packetization-mode=1;profile-level-id=640029;level-asymmetry-allowed=1
```

| Direction | Codec | Rate / channels | Payload type |
|---|---|---|---|
| **Client → doorbell speaker**, preferred | **Opus** | **48000 Hz, 2 ch** | 96 |
| **Client → doorbell speaker**, fallback | **PCMU (G.711 µ-law)** | **8000 Hz, 1 ch** | **0 (hard-pinned)** |
| Doorbell → client audio | Opus **or** PCMU — Ring picks | 48000/2 or 8000/1 | mirrors offer |
| Doorbell → client video | H.264 High 4.1 | 90000 | 98 (+rtx 99) |

**Not Opus 8k/16k. Not AAC. Not G.722.** Exactly two audio codecs are offered and
Ring chooses one. **Which one is detected by string-sniffing the answer:**
`this.onUsingOpus.next(sdp.toLocaleLowerCase().includes(' opus/'))` — and that
choice changes the encoder, channel count *and* sample rate downstream.

**go2rtc offers only Opus 48k stereo, hardcoded, with no PCMU fallback.** If this
doorbell answers PCMU, go2rtc has nothing to negotiate. *(This is a real
divergence between the two clients and a candidate stall cause in its own right.)*

**Speaker activation is mandatory and one-shot:**
```go
activateCameraSpeaker() {
  // Fire and forget ... (which might not happen)
  this.onCameraConnected.pipe(take(1)).subscribe(() =>
    this.sendSessionMessage('camera_options', { stealth_mode: false }))
}
```
It **queues on `camera_connected` and fires exactly once**. Without it the doorbell
stays in stealth mode and outbound audio is **silently discarded at the device**.
There is **no timeout and no re-arming** — the `cameraSpeakerActivated` boolean
latches; to re-toggle you must end and restart the call.

go2rtc does the equivalent, in `AddTrack`:
```go
	if media.Kind == core.KindAudio {
		speakerPayload := map[string]interface{}{ "stealth_mode": false }
		_ = c.wsClient.sendSessionMessage("camera_options", speakerPayload)
	}
```

**Wake semantics — there is no wake step, and no push subscription is needed.**
Searched for specifically and not found: no `POST .../live_view` REST call, no
`/vod`, no app-session ping, no FCM round-trip. `subscribeToDingEvents` /
`subscribeToMotionEvents` are entirely orthogonal and **no code path makes
`startLiveCall` depend on them.** The `live_view` WebSocket message *is* the wake
trigger — it reaches Ring's cloud, which holds the persistent low-power link and
pokes the device. **You can start a live call on an idle, un-rung, sleeping
battery doorbell.** Budget 2–5 s wired, up to ~10 s cold battery. **This kills our
earlier "maybe it needs a push notification to wake" theory.**

### 1.5 The identifier trap

| Name | Our value | Identifies | Sent on the wire? |
|---|---|---|---|
| `hardware_id` | UUIDv5 of **our host machine's** OS UUID | the **client** | OAuth headers, `clients_api/session`, all requests |
| `camera.id` / `doorbot_id` | **`319156885`** | the **doorbell** | `live_view` / `ice` / session messages |
| `CameraData.device_id` | **`90486cf35236`** | doorbell hardware serial | 🔴 **never sent by ring-client-api** |
| `device_id` (liveview REST field) | `319156885` | the doorbell | **a misleading field name holding `camera.id`** |

`getHardwareId()` is a **UUIDv5 of `systeminformation`'s `uuid().os`** — on Linux
`/sys/class/dmi/id/product_uuid` or `/etc/machine-id` — **not a MAC address**. It is
**cached inside the refresh token itself** (`AuthConfig{rt, hid, pnc}`), so a token
minted on machine A carries machine A's `hid`.

**Our earlier hypothesis — "maybe go2rtc's `device_id` wants a client id, not the
camera's" — is resolved: partially right, in a way that matters.**
`ring-client-api` **never sends `90486cf35236` anywhere.** go2rtc requires it as a
mandatory query param. Whatever go2rtc does with that value has no counterpart in
the working library, and `simple-webrtc-session.ts` shows the exact naming trap
that makes this easy to get wrong:

```ts
      json: {
        session_id: this.sessionId,
        device_id: this.camera.id,     // <-- 319156885, NOT 90486cf35236
        sdp,
        protocol: 'webrtc',
      },
```

**Also worth checking the token's shape.** `parseAuthConfig` silently degrades:
```go
	if err := json.Unmarshal(decoded, &config); err != nil {
		return &AuthConfig{RT: refreshToken}, nil     // <-- HID silently becomes ""
	}
```
A correct `ring-auth-cli` token is **not a JWT** — it is base64 of
`{"rt":"…","hid":"…"}`, so it **begins `eyJy`** and ends `=`/`==`. If ours doesn't,
`hardware_id` is empty on every Ring call. **Experiment A3, 30 seconds.**

### 1.6 The last mile is solved — both open questions from the old README are closed

**The stop call exists.** `POST /api/streams?dst=<stream>&src=` — same endpoint,
**empty `src`**. Proven from `Play()`'s prologue in `internal/streams/play.go`:

```go
func (s *Stream) Play(urlOrProd any) error {
	s.mu.Lock()
	for _, producer := range s.producers {
		if producer.state == stateInternal && producer.conn != nil {
			_ = producer.conn.Stop()
		}
	}
	s.mu.Unlock()
	...
		if source = urlOrProd.(string); source == "" {
			return nil
		}
```

All `stateInternal` producers stop, *then* the empty source returns early. The
empty-`src` POST reaches it because the early return is guarded
`if src == "" && r.Method != "POST"`, and `Validate("")` returns `nil`. go2rtc's
own README line 879 confirms: *"you can stop active playback by calling the API
with the empty `src` parameter."*

**Four traps:**
1. 🔴 **`DELETE /api/streams?src=X` is NOT the stop.** It is `delete(streams, src)`
   + `app.PatchConfig(...)` — it **rewrites `go2rtc.yaml` on disk** and never
   touches producers, leaking the ffmpeg. Same for `PUT`. **Never create/destroy
   the mic stream per button press.**
2. **`src` must carry a scheme.** `GetProducer()` requires a colon, so `src=mic`
   **fails**. Use `ffmpeg:mic#audio=opus`, URL-encoded as `ffmpeg:mic%23audio=opus`.
3. **Stop is idempotent** — safe to spam from a watchdog. Corollary: it is global
   per destination, so one panel's stop kills another's talk.
4. ~1 s teardown tail by design (`time.Sleep(time.Second)` before `dst.Stop()`).

**go2rtc never transcodes on the backchannel path.** `Codec.Match` is exact
name+rate+channels. **But it fails loudly, not silently** — HTTP **500** with
`can't find consumer`, or `streams: codecs not matched: X => Y` naming both lists.
Use the `ffmpeg:` wrapper to transcode on demand instead: one `mic` stream serves
every camera, and you pick the codec at push time.

**go2rtc's web-UI "microphone" is not a button.** It is a connection-time media
parameter acted on once inside `createOffer()`. **To stop the mic you must close
the PeerConnection — which also drops the video.** No mic-only stop exists on that
path. Decisive argument for `dst`/`src`.

### 1.7 Flutter on Linux — keep audio out of the Panel entirely

`flutter_webrtc` **1.6.0** (2026-08-03) does now have a real Linux implementation
(`pulse_loopback_capturer.cc`, links `PkgConfig::PULSE`, `platform:linux` granted).
**But issue #2070 (OPEN, updated 2026-08-08): on Linux, `setLocalDescription` and
`close` freeze the UI thread ~10 s after the first PeerConnection closes.** A
push-to-talk button that builds and tears down a PeerConnection per press walks
straight into it. No evidence anyone has run it under `cage`.

**The decisive evidence is in our repo:** the Panel has **no `flutter_webrtc`
dependency**, plays **MJPEG** natively (`live_video.dart`'s platform seam — a
format that carries no audio by construction), has **no audio code anywhere**, and
already has the seam stubbed as `_startTalking` / `_stopTalking`.

> **Recommendation: Flutter never touches audio. `_startTalking()`/`_stopTalking()`
> become two HTTP calls.**

The app and the audio hardware are the same machine, so routing audio *through*
Flutter buys nothing: the mic is already proven working in a container; **the Pulse
socket already mounted for capture also carries playback with no compose change**;
it removes #2070, the CPU-copy texture path, the `libwebrtc.so` m144 dependency and
the AEC question from the critical path; and it keeps **stop authority server-side**,
where the watchdog must live anyway — a wedged mic must close even if the Panel
process dies, which Flutter cannot guarantee about itself.

Alternatives are worse: `webview_flutter` has **no Linux support**;
`desktop_webview_window` never handles `permission-request`, so `getUserMedia`
silently never prompts on Linux (issue #404, open since 2025-04-18); `record` on
Linux shells out to `parecord` and **explicitly lacks echo cancellation**.

### 1.8 Timing and lifecycle facts that will bite

- **Cold start is 2.1 s (4.1 s cold), already measured in our own repo** —
  `live_video_mjpeg.dart` documents it for go2rtc's on-demand ffmpeg. An `exec:`
  mic producer pays the same. **A button that starts ffmpeg on press drops the
  first 2–4 seconds of every sentence. Pre-warm on popup open, not on press.**
- **go2rtc has no idle timeout on internal producers.** Nothing closes a wedged
  mic for you. A server-side dead-man switch is mandatory, not optional.
- **No reconnect loop on the internal producer** — it is
  `go func(){ _ = src.Start(); s.RemoveProducer(src) }()`. A dropped mic ends
  silently, so the UI must poll producer state or it will lie to whoever is
  standing at the door. (This is `device_popup.dart`'s own ADR-0007 argument.)
- 🔴 **Ghost producer, go2rtc#1961 and #1933, both open:** the ring producer
  **never stops after the last consumer leaves** — doorbell stuck live-recording,
  blue ring lit, **draining a battery device**, recoverable only by restarting
  go2rtc. seydx's unmerged `fix-ghost-producer` branch is the attempted fix.
  **If we ship go2rtc's `ring:`, we ship this bug.**
- 🔴 **Echo cancellation is an unresearched open question.** Panel speaker and mic
  will be ~30 cm apart, and with audio handled server-side by ffmpeg there is
  **no AEC anywhere in the path.** Likely needs a PipeWire `echo-cancel` module,
  or half-duplex behaviour (mute the speaker while the button is held).

### 1.9 The state of the ecosystem, from field reports

- **go2rtc's `ring:` source has exactly 4 issues in its entire tracker history.**
  Three are login failures; one is #1961. That is the true measure of its user base.
- **`pkg/ring` has 14 commits ever.** Twelve are seydx's. **Last functional commit
  2025-05-21 — 14½ months stale.** seydx is *still active in go2rtc* (2026-07-13) —
  on Wyze and docs. He didn't abandon the project, he abandoned Ring. He has an
  unmerged `fix-ghost-producer` branch and has just launched a competing project,
  `seydx/rtsp` (pushed 2026-08-06), described as a media relay *"with two-way audio."*
- **Exactly one person has ever publicly reported go2rtc `ring:` two-way audio
  working** — h3nnes, go2rtc#1961, 2025-11-30, on a **Ring Battery Doorbell Plus**,
  and only via a workaround: *"As soon as I immediately close and reopen the live
  view so that the producer is still on, the correct hevc stream is used this time
  and displayed and **I get working two way audio**."* **The H264 track go2rtc
  advertised was empty; only HEVC carried data.** Experiment A4 tests both halves.
- **Two-way audio *is* proven working in go2rtc 1.9.10/1.9.11** by a different
  reporter (bandeirad, #1933) with a real byte counter: senders `opus/48000/2`,
  `"bytes": 182071, "packets": 4024`. So the feature is not vapour — it worked, on
  the version we already run, before the Cloudflare WAF change of Feb 2026.
- **Home Assistant's own docs:** *"Two-way audio in camera live view is not
  currently supported."* Two HA issues about Ring rejecting a `sendrecv` SDP with
  **"Incompatible send direction"** (frontend#29057 2026-01-18, core#163874
  2026-02-23) were both **closed as not planned**.
- **ring-mqtt will never do this.** A working return-audio PR
  (tsightler/ring-mqtt#1098, 2026-06-22, `mirkokg`: *"I've been using the feature
  for quite some time, and it is very useful!"*) was **closed unmerged in 53
  minutes**. And the strategic signal: tsightler, 2026-06-23 — *"**I may not
  continue to include live streaming support in future versions.**"*
- **There is no official Ring API for this.** `developer.ring.com` is live in 2026
  with a real partner program and a WHEP live-video endpoint, and states explicitly
  **"Video only — no audio."** Alexa/Google/HomeKit talkback works because those
  are **first-party Amazon/Ring cloud bridges on internal interfaces**. Every
  self-hosted option is strictly reverse-engineered.
- **Ring blocks VPS/VPN networks** (tsightler, 2025-11-17). Run from home.
- 🔴 **Nobody on Reddit has ever mentioned go2rtc's `ring:` source — zero hits
  across 919 archived posts** spanning r/homeassistant, r/ring, r/frigate_nvr,
  r/selfhosted, r/homeautomation, r/Scrypted, r/homebridge, r/HomeKit, current to
  2026-08-07. Every Ring+go2rtc usage found is `Ring → ring-mqtt → go2rtc → RTSP`,
  **video-only** — with a ~9 s cold start (2026-05-06) and recurring
  `webrtc/offer i/o timeout` failures. See §1.11 for why that pipeline
  *structurally* cannot carry talkback.
- **Zero mentions of a Ring 406 anywhere on Reddit, HN or StackOverflow.** What
  Reddit shows instead is a real breakage wave with no diagnosis attached —
  "Ring-mqtt not working after update" (2025-12-05), "All my Ring cameras stop
  working with HA" (2025-12-13), "Ring-MQTT Authenticator" (2026-02-11),
  "Ring-MQTT app not working?" (2026-03-12). Users describe the symptom; the
  diagnosis only ever appears in the dgreif/ring issue tracker.
- **Every working talkback report in 2025–26 is non-Ring**: Reolink (go2rtc +
  AlexxIT/WebRTC card, score 65, 2026-04-14), Amcrest AD410, Dahua VTO, Tapo,
  Unifi, Hikvision.
- **The HA Android companion app does not pass the microphone** even where Chrome
  does (2026-05-21, unresolved). Irrelevant to our native kiosk, but a useful
  reminder that "works in a browser" does not generalise.
- ⚠️ **Beware the inbound/outbound conflation — it is everywhere in these
  threads.** r/homeassistant `1njwiw2` (2025-09-18): *"I was able to get **audio
  locally in Frigate** but the picture quality was beyond terrible… selling off my
  Ring cameras and buying Reolink."* **That is hearing the visitor, not talking
  back.** Read every "I got Ring audio working" claim for which direction it means
  before counting it.
- **`talkback`/`backchannel`: 26 posts in the corpus, not one about Ring** — all
  Reolink, UniFi, Tapo, Dahua, Amcrest, Aqara, Hikvision, VIGI.
- HN, 2024-01-24, on using Ring third-party: *"Short answer is **no**… the long
  answer is '**kinda in a hacky way, with a lot of work, and Ring is gonna fight
  you the whole way**.'"*
- **The community's #1 recommendation is to replace the hardware with a Reolink
  PoE doorbell.** Noted for completeness; out of scope here.

### 1.10 The ranked options

| # | Option | Two-way? | Effort | Risk |
|---|---|---|---|---|
| **1** | **Bespoke service on `@tsightler/ring-client-api`** | **Yes** — the path `homebridge-ring` ships; **the only component proven to authenticate on this account today** | ~200 LOC + 1 container | **Low.** dgreif/ring last commit **2026-08-04** |
| 2 | **Scrypted + Webhook plugin** | In source, yes — `ScryptedInterface.Intercom`; ffmpeg→PCM-mulaw→SRTP. **In the field: one 2023 report, contradicted since** | Whole new platform + ~20 LOC Script | 🔴 **High** — Ring plugin stale since 2025-06-14, UA status unverified, **and Ring audio documented corrupted by 5 users through 2026-01** |
| 3 | Patch go2rtc's UA + self-build | Probably | Fork + Go toolchain + private image forever | High — inherits the battery-draining ghost producer |
| 4 | go2rtc `ring:` as shipped | **Currently no** | — | Blocked at the stall |
| 5 | homebridge-ring + HomeKit bridge | HomeKit only | — | Absurd for a Flutter kiosk |
| 6 | ring-mqtt | **No** — none in any release, maintainer declined | — | Keep as-is for video + sensors |
| 7 | HA native `ring` | **No** — documented as unsupported | — | Dead end |
| 8 | Frigate 0.16/0.17 | Only by delegating to go2rtc + a browser | — | Dead end for a non-browser kiosk |

**Scrypted's non-browser API problem is genuinely solved**, which is why it holds
second place: the first-party Webhook plugin exposes any interface method as a
plain HTTP GET —
`http://host/endpoint/@scrypted/webhook/<id>/<token>/stopIntercom` — validated
against `allInterfaceMethods`, which includes `startIntercom`/`stopIntercom`. A
Flutter `http.get()` suffices. *Catch:* `startIntercom` takes a non-serialisable
`MediaObject`, so **starting** needs ~20 lines of JS in a Scrypted Script;
**stopping** works over the webhook directly. `@scrypted/server` is ISC-licensed
and free; only NVR is paid.

---

### 1.11 🔴 Peer review — what is settled, what is contested, what is new

Six independent research passes were cross-examined against each other. This
section records the outcome, because **confidence levels change what you should do
first**, and two of the reconciliations below are not visible in any single
finding above.

#### Settled — multiple agents, independent evidence types

| Claim | Independent confirmations | Confidence |
|---|---|---|
| `ring:` **can** do two-way audio (`DirectionSendRecv`, Opus 48k stereo, plus a real 4024-packet byte counter at 1.9.10/1.9.11) | 4 | **Capability near-certain; reliability near-zero** |
| The `ring:` module is **abandoned** | 4 — via commit log, PR history, issue count, and *total Reddit silence* | **Highest-confidence claim in the review** |
| **No official Ring API** for third-party talkback | 3 | Certain |
| Community consensus is **replace the hardware** | 2, reached independently | Certain as a description of the field |
| **Our own two errors** (§0.1, §0.2) | 2 | Certain |

#### 🔴 Contested, and it changes the plan: the 406 and the stall are **two different defects**

This is the single most important reconciliation, and no individual pass could
have made it.

The stall is inside `connected.Wait()` — **after** auth, **after** the socket
ticket, **after** the WebSocket opened, **after** `live_view` was sent (§1.2). And
a 406 on the auth or ticket path **produces a visible `WRN` at `level: info`** —
that is the exact shape in issue #2096:

```
WRN [rtsp] error="streams: failed to fetch socket ticket: session validation failed:
  authentication failed while creating session: auth request failed with status 406" stream=ring
```

**We saw no `WRN`.** Therefore go2rtc's token-based auth almost certainly
*succeeded*, bare User-Agent and all.

> **The User-Agent block explains the web-UI login 406 we hit and worked around.
> On current evidence it does NOT explain the stall.** The stall is Ring accepting
> our session and then never answering `live_view`.

Consequences you must carry into Track A:
- **A1 confirming the UA block does not close the investigation.** Run A2 anyway.
- **§1.3 (missing `clients_api/session` registration) is promoted to the leading
  stall hypothesis**, because it predicts exactly this: ticket accepted, socket
  accepted, `live_view` silently unanswered.
- One dissent is recorded and was correct to hold: the source-forensics pass
  refused to link the 406 to the stall — *"I found no evidence linking them, and I
  will not assert one."* That refusal is what surfaced this reconciliation.

#### 🔴 New — a structural rule that eliminates a whole class of approaches

**Talkback requires a *native go2rtc protocol source that carries a backchannel*.
A generic RTSP restream can never carry it, no matter how it is configured.**

Two independent derivations:
- **From source:** `Codec.Match` is exact name+rate+channels and `MatchMedia`
  requires opposite directions; there is no ffmpeg in `Play()` or `AddConsumer()`.
  go2rtc cannot synthesise a backchannel that the source doesn't expose.
- **From the field:** the `tapo://` rule — *"If you want 2 way audio to work in
  frigate you must use the `tapo://` go2rtc configuration for your main stream
  instead of the usual `rtsp://`."* (HN, 2025-09-16.)
- **From a third direction**, a Scrypted user asked the same question and got the
  same law in Scrypted's own terms: *"**Not possible through RTSP itself, need to
  use ONVIF.**"* (r/Scrypted `1nzabkd`, 2025-10-06.) **Ring exposes no ONVIF, and
  no user report of its native go2rtc source exists.**

**This kills `ring-mqtt → RTSP → go2rtc` as a category** — and explains why *every*
Ring+go2rtc report ever posted is video-only. Only two candidate paths survive:
go2rtc's native `ring:` source, and Scrypted's `Intercom` interface.

#### 🔴 New — a codec asymmetry nobody had noticed

`ring-client-api` offers **two** audio codecs and lets Ring choose:
`m=audio … 96 0` → `opus/48000/2` **and** `PCMU/8000`. **go2rtc offers Opus only,
hardcoded, with no PCMU fallback.** If this doorbell answers PCMU, go2rtc has
nothing to negotiate — an independent candidate cause of a silent non-answer.
**Experiment B1 measures which one Ring actually picks**, which is why it is
worth running even if Track A resolves first.

#### Scrypted — the tie-break, and it is weak

The capability is verified in source (`ScryptedInterface.Intercom`, ffmpeg →
PCM-mulaw → SRTP), and Scrypted self-grades Ring Talkback "A". Against that:

- **Exactly one user report of Ring talkback working, anywhere, ever** —
  r/Scrypted `18sbono`, **2023-12-27**, score 1, **zero replies**, 2.5 years stale:
  *"(Two way works inside scrypted)… I can get two way audio working in HomeKit
  (sometimes laggy though)"*.
- Against one *recent* failure — 2025-11-02, `PHONE_REGISTRATION_ERROR` (Ring
  Intercom, same plugin), whose thread OP added *"it did not seem like anyone made
  this work."*
- **Structural tell:** r/Scrypted has ~15 two-way-audio threads. All are Reolink,
  Tapo, Amcrest, Hikvision, VIGI — including a celebratory 21-comment
  *"Scrypted Adds support for Reolink Doorbell Two Way Audio"*. **Ring has exactly
  one talkback thread ever, with zero replies.**

- 🔴 **And Scrypted's Ring audio path is documented broken through 2026.**
  r/Scrypted [`1lkb2yy`](https://www.reddit.com/r/Scrypted/comments/1lkb2yy/),
  "HKSV working for Ring doorbell but audio glitches" (2025-06-25) — **five users
  over seven months, still open**: "Same" (2025-07-04), "I have the same issue"
  (2025-08-27), "Same issue" (2025-11-22), "same **audio chirping / glitching**…
  running Scrypted through HomeAssistant" (2025-11-30), and **2026-01-20: "Video
  is fine but **audio is corrupted**."** That is *inbound* audio failing — the
  easier direction.

**Ruling: one stale, unreplicated 2023 positive, contradicted by a current
multi-user pattern of Ring audio corruption.**

🔴 **This breaks the reason Scrypted held second place.** It was staked as
insurance for one specific scenario — *"if the bespoke service authenticates fine
but the talkback itself is unusably garbled, Scrypted's independently debugged
implementation becomes the only other working implementation of the exact thing
that's broken."* **Scrypted is now documented to produce garbled Ring audio. It
fails at precisely the condition it was being held in reserve for.** It stays at
#2 only because nothing better occupies that slot — not because it is likely to
work. If Track B's audio is garbled, expect to debug it in our own service rather
than switching.

#### Blind cross-validations worth trusting

These raise confidence more than any single pass, because neither side could see
the other:

1. The Ring-protocol pass predicted go2rtc's exact failure signature *from the
   library side* — "the same `await onCallAnswered` shape with no timeout" — while
   the source-forensics pass independently found precisely that in
   `pkg/core/waiter.go`.
2. Two passes reached the User-Agent finding by opposite methods — a Go/JS source
   diff, and issue-tracker archaeology with npm publish timestamps.
3. Two passes independently struck the Frigate-parity claim (§0.2).
4. Two field passes independently reached "replace the hardware."

#### Still unresolved

- Is this doorbell **H265-only**? → A4.
- **Does Scrypted's vendored fork carry the working User-Agent?** Unverifiable —
  it is a git submodule and `raw.githubusercontent.com` 404s on every path. **If
  it doesn't, Scrypted hits the identical 406.** Check before committing to C1.
- **Echo cancellation** — speaker and mic ~30 cm apart, no AEC anywhere in the
  planned path. Unresearched, and a real wall-panel design question.
- Does **ring-mqtt contention** matter? → A6.

#### Search-coverage boundaries, stated honestly

Reddit's web surface is **hard-blocked by 13 routes** (tool-level blocks, 403s on
datacenter IPs, a "Prove your humanity" CAPTCHA wall in a real browser, and seven
dead redlib mirrors). Coverage was achieved through the **`arctic-shift`
archive API** — 919 posts + 30 full comment threads, current to 2026-08-07.
**Gaps:** comment-body search in r/homeassistant returns HTTP 422 (the sub is too
large for that index); r/homebridge and r/HomeKit were cut short by rate-limiting.
**StackOverflow/ServerFault/SuperUser are a clean total negative** — `go2rtc` has
exactly one SO question in history. Do not expect answers there.

---

## 2. Prerequisites

### 2.1 🔴 The right shell, and the right path

```sh
# 1. Confirm you are NOT in the devcontainer
[ -e /.dockerenv ] && echo "WRONG SHELL — you are inside a container" || echo "OK: host shell"

# 2. Use the REAL host repo path. This is not cosmetic — see below.
cd /home/dmorozov/Work/SmartHome/hub/dev/ring-twoway-lab
```

**`/workspaces/SmartHome` is the devcontainer's view of the repo. ADR-0010
records that a stray, unrelated, mostly-empty `/workspaces/SmartHome` also exists
on the real host disk** — not a symlink, not a bind mount, a completely separate
directory that happens to be there. Anything run from the host against that path
silently reads and writes the wrong tree. Always use
`/home/dmorozov/Work/SmartHome` from a host shell.

```sh
# 3. The reference implementation must be running (we compare against it)
docker ps --format '{{.Names}}\t{{.Image}}' | grep ring-mqtt

# 4. The PipeWire/Pulse socket — this is what makes mic capture work in a container
ls -la "${XDG_RUNTIME_DIR:-/run/user/1000}/pulse/native"
```

### 2.2 Where credentials live on this laptop

Per **ADR-0010** (`docs/adr/0010-secrets-consolidated-outside-the-repo.md`), every
secret whose path our own compose files or Ansible roles control lives **outside
the repository tree** at **`~/.sh_keys`** — literally `/home/dmorozov/.sh_keys` on
this laptop. The production stack resolves it through `SH_KEYS_DIR` in
`hub/.env`, pinned to the literal host path rather than `${HOME}`, because
`${HOME}` inside the devcontainer is `/home/vscode` and a nonexistent bind-mount
source gets silently auto-created as an empty directory instead of erroring.

| What | Host path | Notes |
|---|---|---|
| **Production Ring refresh token** | `~/.sh_keys/ring-mqtt/ring-state.json` | 🔴 **Never reuse.** See 2.3. |
| Production go2rtc config | `~/.sh_keys/go2rtc/go2rtc.yaml` | Stream URLs embed camera credentials |
| Production MQTT password file | `~/.sh_keys/mosquitto/passwd` | |
| Production broker passwords | `~/.sh_keys/broker-passwords.env` | |
| Panel HA long-lived token | `~/.sh_keys/token` | Deployed to `/etc/smarthome/panel.env` on the appliance |
| **Dev-stack** Ring refresh token | `hub/dev/ring-mqtt-data/` | 🔴 **Never reuse.** Gitignored, in-tree (dev convention predates ADR-0010) |
| Dev-stack HA token | `hub/dev/token` | Gitignored |
| Dev-stack go2rtc config | `hub/dev/go2rtc/go2rtc.yaml` | Gitignored |
| HA account credentials (Ecobee, Rachio, Emporia, …) | `hub/ha-config/.storage` | Explicit ADR-0010 exception — not relocatable |
| **This lab's Ring token** | **`~/.sh_keys/ring-twoway-lab.env`** | Create it in 2.3 |

⚠️ **`hub/dev/ring-audio-test/go2rtc/go2rtc.yaml` currently holds a live Ring
refresh token inside the repo tree.** It is gitignored, so it was never
git-exposed — but it sits exactly where ADR-0010 says secrets must not sit, and
for exactly the reason ADR-0010 gives: an agent reading that file for an
unrelated reason prints the credential into its own transcript. That directory
gets deleted at the end of this work anyway; until then, don't `cat` it.

### 2.3 Mint this lab a token of its own

**Do not reuse ring-mqtt's stored token, dev or production.** Ring refresh tokens
are single-use and rotate on first use — two independent consumers refreshing the
same stored token invalidate each other, which would break the doorbell
integration that already works. `ring-client-api`'s own README says so:
*"Ring has restricted refresh tokens so that they expire shortly after use."*

```sh
# Mint a FRESH, independent login (interactive: email, password, 2FA code)
docker exec -it ring-mqtt-dev node \
  /app/ring-mqtt/node_modules/@tsightler/ring-client-api/lib/ring-auth-cli.js
```

It prints a `refreshToken`. Put it outside the tree, ADR-0010 style:

```sh
mkdir -p ~/.sh_keys
umask 077
cat > ~/.sh_keys/ring-twoway-lab.env <<'EOF'
RING_REFRESH_TOKEN=<paste the refreshToken value here>
EOF
chmod 600 ~/.sh_keys/ring-twoway-lab.env
```

Every `docker run` below therefore uses:

```sh
--env-file ~/.sh_keys/ring-twoway-lab.env
```

**Paste it into the file directly, never into a chat window.** A token pasted
into a prompt lives in the session transcript on disk forever. If you must hand
one to a tool interactively, `docker exec -it` reads from your terminal and
leaves no transcript trace.

The token should begin **`eyJy`** — it is base64 of `{"rt":"…","hid":"…"}`, not a
bare JWT. If it starts with anything else, see §1.5 and experiment A3.

### 2.4 Known values for Front Door

No lookup needed — these were resolved in the previous session.

| Field | Value | Used by |
|---|---|---|
| `camera_id` / `doorbot_id` | **`319156885`** | go2rtc query param; **the only id `ring-client-api` sends** |
| `device_id` (hardware serial) | **`90486cf35236`** | go2rtc query param only; **`ring-client-api` never sends it** |

---

## 3. TRACK A — Diagnose the go2rtc stall

**Purpose:** answer "did we do something wrong?" cheaply, before building
anything. Ordered strictly by information-per-minute. **Stop as soon as you have
an answer** — you do not need to finish the track.

Track A reuses the existing `hub/dev/ring-audio-test/` container. Bring it up
from a host terminal:

```sh
cd ../ring-audio-test && docker compose up -d && cd ../ring-twoway-lab
```

---

### A1 — The User-Agent test ⏱ 2 min · **highest information-per-minute in this document**

**Question:** is Ring's Cloudflare WAF rejecting go2rtc specifically because of its
stale User-Agent?

**Why it matters:** if yes, this is the root cause of the **login** 406 we hit, it
is unfixable by upgrading (identical in every released version), and it makes
options 3 and 4 in §1.10 non-starters without a private fork.

🔴 **Read §1.11 before interpreting the result.** A 406/401 split confirms the
fingerprint block but does **not** explain the stall — those are two separate
defects, and conflating them is the easiest mistake available here.

```sh
UUID=$(cat /proc/sys/kernel/random/uuid)
BODY='{"client_id":"ring_official_android","scope":"client","grant_type":"refresh_token","refresh_token":"deliberately-invalid"}'

echo "=== go2rtc's User-Agent ==="
curl -si -X POST https://oauth.ring.com/oauth/token \
  -H 'Content-Type: application/json' -H '2fa-support: true' \
  -H "hardware_id: $UUID" \
  -H 'User-Agent: android:com.ringapp' \
  -d "$BODY" | head -1

echo "=== ring-client-api's versioned User-Agent ==="
curl -si -X POST https://oauth.ring.com/oauth/token \
  -H 'Content-Type: application/json' -H '2fa-support: true' \
  -H "hardware_id: $UUID" \
  -H 'User-Agent: android:com.ringapp:3.98.0(70492092)' \
  -d "$BODY" | head -1
```

| Result | Meaning | Next |
|---|---|---|
| **406 vs 401** | ✅ UA fingerprint block **confirmed** — explains the web-UI login 406. **Does not explain the stall** (§1.11): a 406 on go2rtc's auth or ticket call would have printed a `WRN` at `level: info`, and none appeared. | **A2** — the stall is still open. Then Track B. |
| **401 vs 401** | Theory dead. The login 406 came from somewhere else. | **A2**. |
| **406 vs 406** | Broader block — this IP, or the endpoint itself. | Check you're not on a VPN (Ring blocks VPS/VPN ranges), then **A2**. |

> The invalid refresh token is deliberate — we want the *rejection shape*, and this
> must not consume or rotate a real token.

---

### A2 — Re-dial with logging that actually works ⏱ 5 min · **repairs our broken evidence**

**Question:** where does the dial actually stop — before the producer starts, or
inside `Dial()`?

**Why it matters:** §0.1. Our previous "no logs at all" observation was
meaningless. This is the first honest look at the failure.

```sh
cd ../ring-audio-test

# Replace the log block. `ring: trace` is a dead key — remove it.
python3 - <<'PY'
import re, pathlib
p = pathlib.Path('go2rtc/go2rtc.yaml')
s = p.read_text()
# (?m) NOT (?ms): DOTALL makes `.` match newlines, so the greedy `.*` eats the
# whole rest of the file — api:, streams: (incl. the live token) and webrtc:.
s = re.sub(r'(?m)^log:\n(?:[ \t]+.*\n)*', 'log:\n  level: debug\n', s)
if 'level: debug' not in s:
    s = 'log:\n  level: debug\n\n' + s
p.write_text(s)
print(s.split('streams:')[0])
PY

docker compose restart
sleep 3

# Dial and wait a FULL 3 minutes — long enough to pass gorilla's 45s handshake
# timeout, which is an uncomfortably good match for our previous "45+ seconds".
docker exec -d go2rtc-ring-test sh -c \
  'ffprobe -v info -rtsp_transport tcp rtsp://127.0.0.1:8554/ring > /tmp/probe.log 2>&1'

for i in 1 2 3; do sleep 60; echo "--- t=${i}m ---"; docker logs --since 4m go2rtc-ring-test 2>&1 | tail -30; done

echo "=== ffprobe ==="; docker exec go2rtc-ring-test cat /tmp/probe.log
```

**Read the result against this table:**

| Observation | Diagnosis |
|---|---|
| `DBG [rtsp] new consumer` appears, `DBG [streams] start producer` **never** does | Wedged before the producer even starts — look upstream of `Dial()` |
| Both appear, then **silence forever** | ✅ Confirms `connected.Wait()` — Ring accepted the WS and never answered `live_view`. **Root cause #1.** |
| A `WRN` appears around ~45–100 s | Bounded failure — read the message. Auth/ticket/WS handshake, **not** the infinite wait |
| `stop producer` appears ~34 s after `start producer` | Consumer gave up first (this is h3nnes's shape) — go to **A4** |

---

### A3 — Token shape ⏱ 30 sec

**Question:** is our refresh token the base64-JSON envelope go2rtc expects, or a
raw token that silently blanks `hardware_id`?

```sh
grep -o 'refresh_token=[A-Za-z0-9+/=_-]\{1,24\}' go2rtc/go2rtc.yaml | head -1
```

- Starts **`refresh_token=eyJy`** → ✅ correct envelope, `hid` present.
- Starts anything else (e.g. `eyJh`, a bare JWT) → 🔴 `parseAuthConfig` fell into
  the legacy branch and **`hardware_id` is empty on every Ring call**. Re-mint with
  `ring-auth-cli` and confirm you copy the `refreshToken` value, not a nested JWT.

---

### A4 — The warm re-dial and the H265 question ⏱ 5 min

**Question:** does a *second* dial against a still-warm producer succeed, and is
this doorbell H265-only?

**Why it matters:** this is the **only** published workaround from the **only**
person who ever got go2rtc `ring:` two-way audio working. Both halves are cheap.

```sh
# Part 1 — warm re-dial (h3nnes's workaround)
docker exec -d go2rtc-ring-test sh -c 'timeout 20 ffprobe -rtsp_transport tcp rtsp://127.0.0.1:8554/ring >/tmp/p1.log 2>&1'
sleep 22
docker exec -d go2rtc-ring-test sh -c 'timeout 40 ffprobe -rtsp_transport tcp rtsp://127.0.0.1:8554/ring >/tmp/p2.log 2>&1'
sleep 42
echo "=== first dial ==="; docker exec go2rtc-ring-test cat /tmp/p1.log
echo "=== second dial (warm) ==="; docker exec go2rtc-ring-test cat /tmp/p2.log

# Part 2 — what media does go2rtc think the stream has?
docker exec go2rtc-ring-test curl -s 'http://127.0.0.1:1984/api/streams?src=ring'
```

- Second dial succeeds where the first didn't → matches #1961 exactly. Not a fix,
  but a very strong signal, and it tells us the failure is a race, not a block.
- The `/api/streams` dump shows `medias` — look for whether an **H264 track is
  advertised but empty**. go2rtc's offer is H264-only and hardcoded; h3nnes's
  Battery Doorbell Plus only ever carried data on HEVC.

---

### A5 — See what Ring is actually saying ⏱ 30–45 min · **the definitive answer**

**Question:** what is in the `notification` message go2rtc discards?

**Why it matters:** §1.2 and §1.3. go2rtc is structurally incapable of showing us
Ring's own explanation. This is a ~4-line patch that makes it visible, plus a
1-line UA fix to test §1.1, plus a grep to test §1.3.

**Only run this if A1–A4 didn't settle it.**

```sh
cd /tmp && rm -rf go2rtc-dbg && git clone --depth 1 --branch v1.9.14 \
  https://github.com/AlexxIT/go2rtc.git go2rtc-dbg && cd go2rtc-dbg

# §1.3 — does go2rtc register a control-center session at all?
grep -rn "clients_api/session" pkg/ring/ || echo ">>> ABSENT — hypothesis §1.3 stands"

# Un-comment the debug prints the author left behind
sed -i 's|^\(\s*\)// \(fmt\.Print.*ring:.*\)$|\1\2|' pkg/ring/client.go pkg/ring/ws.go
grep -n 'fmt.Print' pkg/ring/client.go pkg/ring/ws.go

# §1.1 — the one-line UA fix
sed -i 's|"android:com.ringapp"|"android:com.ringapp:3.98.0(70492092)"|g' pkg/ring/api.go
grep -n 'com.ringapp' pkg/ring/api.go   # expect 4 lines, all versioned

docker build -t go2rtc:ring-debug .
```

Then point the experiment container at `go2rtc:ring-debug` and re-run A2.

**What to look for in the output:**
- `ring: onWSMessage: {"method":"notification","body":{...,"is_ok":false,"text":"..."}}`
  → **`text` is the answer.** Ring is telling us why, in English.
- The UA change alone clearing the stall → §1.1 confirmed end to end.
- No `notification` at all, just silence after `live_view` → Ring is ignoring us
  entirely; §1.3 (missing session registration) becomes the leading theory.

---

### A6 — Contention check ⏱ 3 min

**Question:** does `ring-mqtt-dev` holding its own session block ours?

**Why it matters:** HA core#167406 (open, 2026-04-04) documents a real
rate-limiting clash from running two Ring clients simultaneously. Both consumers
hold independent tokens, so this would be device-side, not token-side.

```sh
docker stop ring-mqtt-dev
sleep 10
# re-run A2's dial
docker start ring-mqtt-dev   # <-- do not forget; the doorbell integration depends on it
```

---

## 4. TRACK B — The bespoke service (the recommended path)

**Why this is first choice regardless of how Track A ends:** we already have the
only component empirically proven to authenticate against this account today.
`@tsightler/ring-client-api@14.3.1-beta.0` is sitting in `ring-mqtt-dev` and worked
on 2026-08-08. Every other option requires *assuming* some other client can still
log in. It is also the smallest diff to a working system — one container, its own
token, two HTTP endpoints — and it puts us on the fastest-repairing dependency
(dgreif/ring committed 2026-08-04; go2rtc's ring module, 2025-05-21).

**Build it stop-first.** An un-closable open mic on a doorbell is worse than the
stub it replaces.

---

### B1 — Protocol probe ⏱ 5 min · **the single highest-value experiment in Track B**

**Question:** does a live call to this doorbell answer at all, and **which codec
does Ring pick — Opus or PCMU?**

**Why it matters:** the codec choice changes the encoder, channel count and sample
rate for everything downstream. And if this *does* answer where go2rtc doesn't,
the whole go2rtc question is settled by demonstration.

`probe/probe.mjs` in this directory does exactly this and nothing else. Run it in
a throwaway Node container — `--network host` matters, because Ring must see your
home IP (it blocks VPS/VPN ranges):

```sh
docker run --rm -it --network host \
  -v "$PWD/probe:/probe" \
  --env-file ~/.sh_keys/ring-twoway-lab.env \
  node:22-alpine sh -c 'apk add --no-cache ffmpeg >/dev/null && cd /probe && npm i --silent && node probe.mjs'
```

It pins `@tsightler/ring-client-api@14.3.1-beta.0` — **deliberately that exact
build**, not `latest` and not upstream `ring-client-api`. It is the one carrying
the versioned User-Agent (§1.1), and the one already proven working on this
account. `beta.1` reverted that UA; upstream never had it.

Expected on success:
```
✓ authenticated
✓ found camera 319156885 "Front Door"  (battery: true)
→ startLiveCall()
✓ answered in 3.2s
✓ usingOpus = true          <-- THE ANSWER
✓ camera_connected
```

If it hangs with no answer, the guard fires at 30 s — **and that tells us the
problem is Ring-side or account-side, not go2rtc-specific**, which is enormously
useful. If it answers, go2rtc's `ring:` source is conclusively the broken part.

---

### B2 — Outbound audio, file first ⏱ 10 min

**Question:** can we make a sound come out of the doorbell at all?

Use `transcodeReturnAudio` with a plain WAV, per the library's own
`return-audio-example.ts`. **Trap:** `ffmpegOptions.input` is spliced **after**
`-i` in `transcodeReturnAudio` but **before** `-i` in `startTranscoding` — the same
field name has opposite semantics. So `input: ['/probe/test.wav']` works and
`input: ['-f','pulse','default']` does not.

```sh
docker run --rm -it --network host -v "$PWD/probe:/probe" --env-file ~/.sh_keys/ring-twoway-lab.env \
  node:22-alpine sh -c 'apk add --no-cache ffmpeg >/dev/null && node /probe/probe.mjs --play /probe/test.wav'
```

**Stand at the door.** This is the step that answers the real question — nothing in
an API response proves sound left the speaker.

---

### B3 — Live mic ⏱ 20 min

`transcodeReturnAudio` cannot take a live input (B2's trap). Bypass it and drive
`sendAudioPacket` directly, exactly as `homebridge-ring/camera-source.ts:256-271`
does: run our own ffmpeg to `-f rtp rtp://127.0.0.1:<port>`, wrap the port in the
library's `RtpSplitter`, and push each datagram through
`call.sendAudioPacket(RtpPacket.deSerialize(message))`.

Encoder chosen from B1's answer:
- `usingOpus = true` → `-acodec libopus -ac 2 -ar 48k`
- `usingOpus = false` → `-acodec pcm_mulaw -ac 1 -ar 8k`

Capture from PipeWire via the Pulse socket, as already proven: `-f pulse -i default`.

### B4 — Inbound half

Independent of the button, and should start when the popup opens. Simplest form,
no backchannel machinery and no codec-matching tax, since ffmpeg decodes Opus
natively:

```sh
ffmpeg -nostdin -hide_banner -rtsp_transport tcp -i rtsp://127.0.0.1:8554/ring \
       -vn -f pulse -device default ring-lab
```

### B5 — The service shape

```
POST /talk/stop     → implement and verify FIRST
POST /talk/start
GET  /talk/status   → drives the Panel caption; never let the button drive it
```

State machine `idle → starting → talking → stopping`, single-flight (drop, don't
queue, presses during transitions), **absolute talk cap 30–60 s**, keepalive-driven
dead-man switch, unconditional stop on popup close *and* app shutdown, and a
watchdog that fires stop liberally — including once at startup to clear anything a
previous crash left open.

---

## 5. TRACK C — Fallbacks

Only if Track B's talkback itself proves broken or unusably garbled — i.e. the
defect is in `ring-client-api`'s SRTP/audio path rather than our plumbing.

### C1 — Scrypted · 🔴 read this before spending a day on it

The original case was: Scrypted stops being "another platform" and becomes "the
only other working implementation of the exact thing that's broken" — an
independently debugged ffmpeg → PCM-mulaw → SRTP → `audioSplitter` path on a
different fork.

**That case no longer holds cleanly.** Scrypted's *Ring* audio is documented
broken by five users through 2026-01-20 (§1.11) — chirping, glitching, "video is
fine but audio is corrupted". **If you arrive here because Track B's audio is
garbled, you are switching to a stack with a documented garbled-audio problem on
the same camera.** Expect to debug our own service instead.

Two gates before committing any real time:

1. **Verify its vendored `@koush/ring-client-api` carries the versioned
   User-Agent.** The research could not check this — it is a git submodule and
   `raw.githubusercontent.com` 404s on every path. If it doesn't, Scrypted hits
   the identical 406 and the whole option is dead on arrival. Check by installing
   Scrypted and reading the resolved `node_modules`, or by watching whether its
   Ring plugin authenticates at all.
2. **Reproduce the audio-glitch thread's symptom** on a throwaway install before
   integrating anything. If Scrypted's inbound Ring audio is corrupted here too,
   its outbound path is not worth pursuing.

Still true and still valuable if both gates pass: the Webhook plugin gives a
non-browser Flutter kiosk `stopIntercom` as a plain HTTP GET, which is the one
genuinely hard integration problem it solves.

### C2 — Patched go2rtc
Only if A5's patch works *and* the ghost-producer bug (#1961/#1933) can be
mitigated. Note the cost: a private Go fork of an abandoned module, maintained
indefinitely.

---

## 6. Decision tree

**Run A1 and A2 both, in that order, regardless of A1's result** — §1.11 shows
they answer two different questions. A1 explains the login 406; only A2 speaks to
the stall.

```
A1: 406 vs 401 on oauth.ring.com?
├── YES → UA fingerprint block confirmed. Explains the LOGIN 406 only.
│         Rules out options 3 & 4 (§1.10) without a private fork.
└── NO  → the login 406 came from somewhere else. Note it and move on.
                            │
                            ▼
A2: dial at level:debug, wait 3+ minutes
├── `start producer` appears, then silence forever
│     → CONFIRMS connected.Wait(). Ring accepted the session and never
│       answered live_view. Leading cause: §1.3 missing clients_api/session.
│       → A4 (warm re-dial + H265 check) → A6 (contention) → A5 (the answer)
├── `new consumer` appears but `start producer` never does
│     → wedged upstream of Dial(). Different problem; read the surrounding lines.
├── a WRN appears at ~45–100s
│     → bounded failure with a name. Read it. Likely ticket/WS, not the wait.
└── `stop producer` ~34s after `start producer`
      → consumer gave up first (h3nnes's shape) → A4

Track B — B1: does startLiveCall() answer?
├── YES, usingOpus=true  → go2rtc is conclusively the broken part.
│                          Build the service. B2 → B3 → B5.
├── YES, usingOpus=false → go2rtc is broken AND §1.11's codec asymmetry is live:
│                          go2rtc offers Opus only, Ring wants PCMU. That is a
│                          second, independent reason `ring:` can never work here.
│                          Build the service; encode pcm_mulaw 8k mono.
└── NO                   → the problem is NOT go2rtc-specific. Check, in order:
                           VPN? live_view_disabled in Ring app Modes? token
                           rotated? ring-mqtt holding a session (A6)?
                           Then Track C1 — but verify Scrypted's UA first (§1.11).
```

---

## 7. What "done" looks like

1. Someone standing at the front door hears this laptop's microphone.
2. This laptop shows their video and plays their voice.
3. Start **and stop** are both proven, repeatable, and survive the service dying.
4. 20 press/release cycles leave no leaked ffmpeg (`pgrep -fa ffmpeg` back to
   baseline) and no ghost producer on the doorbell.
5. Written up, and this directory deleted — with the outcome recorded in `TODO.md`
   or a new ADR either way, so the next attempt doesn't re-walk this ground.

**Only after all five:** wire `_startTalking`/`_stopTalking` in
`panel/lib/ui/device_popup.dart`, update `_TalkCaption` (currently "isn't wired up
yet"), and only then touch the compose files, Ansible, and the devcontainer — the
owner rebuilds, per the standing gate.

**Note that §0.2 changes the shape of that last step:** there is no Frigate-parity
conflict to resolve, so if the answer turns out to involve go2rtc at all, no
version bump is required.

---

## 8. Bibliography

All accessed 2026-08-08.

**go2rtc — source (raw.githubusercontent.com/AlexxIT/go2rtc/…)**
- `pkg/ring/client.go` — `Dial()`, `connected.Wait()`, `onWSMessage`, `AddTrack`, the hardcoded H264/Opus media
- `pkg/ring/ws.go` — ping loop, the unhandled `NotificationMessage` / `StreamInfoMessage` types
- `pkg/ring/api.go` — `parseAuthConfig`, host constants, **`User-Agent: android:com.ringapp` at lines 263/429/551/612**
- `pkg/core/waiter.go` — `Waiter` is a bare `sync.WaitGroup`, no timeout
- `internal/app/log.go` — `GetLogger`/`modules`, proving `log: {ring: trace}` is a no-op
- `internal/streams/play.go` — `Play()`'s stop prologue (**the stop call**)
- `internal/streams/api.go` — POST/PUT/DELETE semantics and `app.PatchConfig` side effects
- `internal/streams/add_consumer.go` — `DirectionSendonly` backchannel wiring
- `pkg/pcm/backchannel.go` — proof `#backchannel=1` is a stdin **sink**
- `pkg/core/codec.go` — `Codec.Match`, proving no transcoding
- `internal/ffmpeg/ffmpeg.go` — built-in `opus`/`pcmu`/`pcma` transcode templates
- `www/video-rtc.js` — the mic as a connection-time parameter, not a button
- `v1.9.10/main.go` — `ring.Init()`, disproving the version claim
- `v1.9.14/internal/ring/README.md` — **HTTP 404**, proving the README post-dates the release

**go2rtc — issues**
- [#1933](https://github.com/AlexxIT/go2rtc/issues/1933) — working two-way audio on 1.9.10/1.9.11 (opus sender, 4024 packets); producer never stops
- [#1961](https://github.com/AlexxIT/go2rtc/issues/1961) — the only two-way success report; empty H264 track; warm re-dial workaround; ghost producer drains battery
- [#2096](https://github.com/AlexxIT/go2rtc/issues/2096) — the 406 bug, open, 18 comments, seydx silent since 2026-02-24
- [#2261](https://github.com/AlexxIT/go2rtc/issues/2261) — closed as duplicate, not fixed
- [#2281](https://github.com/AlexxIT/go2rtc/issues/2281) — **`ring-auth-cli` token rejected on 1.9.14**, open, no reply
- [#1781](https://github.com/AlexxIT/go2rtc/issues/1781) — `wrong query`, unanswered
- [PR #1567](https://github.com/AlexxIT/go2rtc/pull/1567) — the source added, +1305 lines, merged in <24h
- `api.github.com/repos/AlexxIT/go2rtc/commits?path=pkg/ring` — 14 commits ever, last functional 2025-05-21
- `github.com/seydx/go2rtc` branch `fix-ghost-producer` — unmerged; `github.com/seydx/rtsp` — his new project

**Ring / ring-client-api**
- `github.com/dgreif/ring` @ `638d528` (2026-08-04) — `rest-client.ts`, `ring-camera.ts`, `util.ts`, `streaming/{streaming-session,webrtc-connection,peer-connection,simple-webrtc-session}.ts`, `packages/examples/return-audio-example.ts`, `packages/homebridge-ring/camera-source.ts`
- npm tarballs `ring-client-api@14.3.0`, `@tsightler/ring-client-api@{14.3.1-beta.0,14.3.1-beta.1}` — diffed; **streaming tree byte-identical, delta is the User-Agent**
- [dgreif/ring#1717](https://github.com/dgreif/ring/issues/1717) — **the Cloudflare 406 / User-Agent diagnosis**, open since 2026-03-06
- [dgreif/ring#1712](https://github.com/dgreif/ring/issues/1712) — crash applying `in` to a 406 text/plain body
- [tsightler/ring-mqtt#1098](https://github.com/tsightler/ring-mqtt/issues/1098) — working return-audio PR, closed unmerged in 53 min; *"I may not continue to include live streaming support"*
- `tsightler/ring-mqtt` wiki, Video Streaming — "~2-3 second" stream start
- [ring-mqtt disc. #1029](https://github.com/tsightler/ring-mqtt/discussions/1029) — Ring IP-blocks VPS/VPN networks
- [ring-mqtt disc. #1094](https://github.com/tsightler/ring-mqtt/discussions/1094) — outbound-audio PoC; "Opus (48k stereo) or PCMU (8k mono)"
- `developer.ring.com` + `developer.amazon.com/docs/ring/api-documentation.html` — official partner API, **"Video only — no audio"**

**Scrypted**
- `koush/scrypted` `plugins/ring/src/{camera,location}.ts` — `startIntercom`/`stopIntercom`, ffmpeg→mulaw→SRTP
- `plugins/webhook/src/main.ts` — `/endpoint/@scrypted/webhook/<id>/<token>/<method>`, `allInterfaceMethods`
- `api.github.com/repos/koush/scrypted/commits?path=plugins/ring` — last 2025-06-14
- [PR #698](https://github.com/koush/scrypted/pull/698) — "ring: fix login 406 error", 2023-04-06 (precedent)
- `docs.scrypted.app/scrypted-nvr/` — NVR paid; server + plugins free (ISC)

**Reddit / HN / StackExchange** (Reddit web surface is blocked by 13 routes; reached
via the `arctic-shift.photon-reddit.com/api` archive, 919 posts, current 2026-08-07)
- [r/Scrypted 18sbono](https://www.reddit.com/r/Scrypted/comments/18sbono/) — **the only user report of Ring talkback working in Scrypted**, 2023-12-27, score 1, zero replies
- [r/homeassistant 1nj8xy0](https://www.reddit.com/r/homeassistant/comments/1nj8xy0/) — Scrypted Ring add-on fails, `PHONE_REGISTRATION_ERROR`, 2025-11-02
- [r/homeassistant 1t5d1x5](https://www.reddit.com/r/homeassistant/comments/1t5d1x5/) — Ring→ring-mqtt→go2rtc, **video only**, 9 s warmup, 2026-05-06
- [r/homeassistant 1skxiy0](https://www.reddit.com/r/homeassistant/comments/1skxiy0/) — Reolink two-way working, go2rtc + WebRTC card, 2026-04-14
- [r/homeassistant 1n7n5o8](https://www.reddit.com/r/homeassistant/comments/1n7n5o8/) — "Ring… two-way audio is not supported", 2025-09-03
- [r/homeassistant 1plqhca](https://www.reddit.com/r/homeassistant/comments/1plqhca/) — Ring cameras broke; "may need fixing in the Ring API", 2025-12-13
- [r/frigate_nvr 1nx59i2](https://www.reddit.com/r/frigate_nvr/comments/1nx59i2/) — Ring via Scrypted restream into Frigate, video only, 2025-10-03
- [r/Scrypted 1lkb2yy](https://www.reddit.com/r/Scrypted/comments/1lkb2yy/) — **Ring+Scrypted audio glitching, 5 users, 2025-06-25 → 2026-01-20, unresolved**
- [r/Scrypted 1nzabkd](https://www.reddit.com/r/Scrypted/comments/1nzabkd/) — "Not possible through RTSP itself, need to use ONVIF", 2025-10-06
- [r/Scrypted 1uwcvwn](https://www.reddit.com/r/Scrypted/comments/1uwcvwn/) — Tapo/Reolink two-way works, "I used to have ring, it was awful", 2026-07-14
- [r/homeassistant 1njwiw2](https://www.reddit.com/r/homeassistant/comments/1njwiw2/) — best consensus thread; Scrypted→Frigate audio bridge fails; "reolink will win this fight", 2025-09-18
- [HN 45256972](https://news.ycombinator.com/item?id=45256972) — **the `tapo://` rule**: talkback needs a native go2rtc source, not RTSP, 2025-09-16
- [HN 39120376](https://news.ycombinator.com/item?id=39120376) — "Ring is gonna fight you the whole way", 2024-01-24
- `api.stackexchange.com`, 12 queries across SO/ServerFault/SuperUser — **zero relevant results**; `go2rtc` has one SO question in history

**Home Assistant**
- `home-assistant.io/integrations/ring/` — *"Two-way audio in camera live view is not currently supported."*
- [frontend#29057](https://github.com/home-assistant/frontend/issues/29057), [core#163874](https://github.com/home-assistant/core/issues/163874) — Ring rejects `sendrecv` SDP, "Incompatible send direction", both closed as not planned
- [core#167406](https://github.com/home-assistant/core/issues/167406) — rate-limiting clash running two Ring clients at once
- [community 1004936](https://community.home-assistant.io/t/1004936) — Pi kiosk + Ring two-way audio: failed, owner replaced the doorbell

**Flutter / Linux**
- `pub.dev/packages/flutter_webrtc` 1.6.0 (2026-08-03), real `linux/` implementation
- flutter-webrtc [#2070](https://github.com/flutter-webrtc/flutter-webrtc/issues/2070) — **OPEN: Linux UI freeze ~10 s on `setLocalDescription`/`close`**
- MixinNetwork/flutter-plugins #404 — Linux mic permission never prompts, open since 2025-04-18

**This repo**
- `panel/lib/ui/device_popup.dart` — `_PushToTalkButton`, `_startTalking`/`_stopTalking` stubs
- `panel/lib/ui/video/live_video.dart`, `live_video_mjpeg.dart` — the MJPEG native path, **measured 2.1 s / 4.1 s cold start**
- `panel/lib/ui/video/live_video_keepalive.dart` — the existing keepalive pattern to copy
- `hub/dev/ring-audio-test/` — the first attempt; mic capture proven, Ring login proven, stalled at the dial
- `docs/research/frigate-amd-acceleration.md` — the go2rtc-1.9.10 Frigate-parity rationale (**see §0.2 — it was never a blocker for `ring:`**)

---

## 9. Handoff — starting a fresh Claude Code session on the host

This document is written to be the **entire** context. A new session needs no
memory of the conversation that produced it.

### 9.1 Before you start

```sh
# Host terminal — NOT the devcontainer, and NOT /workspaces/SmartHome
cd /home/dmorozov/Work/SmartHome
[ -e /.dockerenv ] && echo "WRONG SHELL" || echo "OK: host shell"

# Token in place (ADR-0010 location, outside the repo)
ls -l ~/.sh_keys/ring-twoway-lab.env || echo "MISSING — do §2.3 first"

claude
```

### 9.2 The opening prompt

Paste this verbatim:

> Read `hub/dev/ring-twoway-lab/README.md` end to end before doing anything —
> it is a complete experiment plan and contains all the research findings, so
> you need no other context. Then read `docs/adr/0010-secrets-consolidated-outside-the-repo.md`
> and `CLAUDE.md`.
>
> Context you must hold onto:
> - We are running on the **host laptop**, not the devcontainer. The repo is at
>   `/home/dmorozov/Work/SmartHome`. A stray unrelated `/workspaces/SmartHome`
>   also exists on this host — never touch it.
> - The Ring refresh token is at `~/.sh_keys/ring-twoway-lab.env`. **Never print
>   it, never echo it, never read the file into your context.** Pass it to
>   containers with `--env-file` only.
> - Goal: full two-way audio+video with the Front Door Ring doorbell
>   (`camera_id=319156885`). Scope is the doorbell only — do not touch the Hub
>   stack, the Panel, Ansible, or the appliance.
> - Per `CLAUDE.md`: leave every change unstaged. Never `git add`, never
>   `git commit`.
>
> Start with **Track A, experiment A1** (the User-Agent test in §3). It is two
> minutes and it decides the central question. Report the exact HTTP status
> codes you get from both requests, tell me what §3's result table says that
> means, and then stop and wait for me before moving on.
>
> As we go, append results to a new `RESULTS.md` in that directory — one section
> per experiment, with the exact command, the raw output, and what it ruled in or
> out. That file is the record; do not overwrite the plan.

### 9.3 The five-line version, if you want to move fast

> Read `hub/dev/ring-twoway-lab/README.md` — it's a self-contained experiment
> plan with all findings. We're on the host laptop at
> `/home/dmorozov/Work/SmartHome`; the Ring token is at
> `~/.sh_keys/ring-twoway-lab.env` and must never be printed. Run Track A
> experiments A1 through A4 in order, log everything to `RESULTS.md`, and stop
> after each one to show me the result. Leave all changes unstaged.

### 9.4 What to hand back to this session afterwards

Whatever `RESULTS.md` says, plus the answers to these four, which are what the
remaining decisions turn on:

1. **A1:** 406 vs 401, or 401 vs 401?
2. **A2:** did `DBG [streams] start producer` appear, and did anything at all
   follow it?
3. **B1:** did `startLiveCall()` answer, and was `usingOpus` true or false?
4. **B2:** did sound actually come out of the doorbell?
