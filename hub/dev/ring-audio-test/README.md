# Ring two-way audio — isolated experiment

Answers one question: can go2rtc's native `ring:` source carry this
laptop's own microphone to the real Front Door doorbell's speaker, well
enough to build the Panel's push-to-talk button (`device_popup.dart`,
variant D) on top of it? Nothing here is meant to outlive that answer —
either it gets promoted into `../compose.yaml` (this laptop's dev Hub) and
`../../compose.yaml` (the appliance stack), or this whole directory gets
deleted having proven the approach doesn't work.

**Status 2026-08-08: blocked at step 3, not yet answered either way.**
Steps 1 (mic capture) and 2 (Ring login, the hard way) are done and
verified — see below for the exact repeatable procedure, including two
go2rtc bugs hit and worked around along the way. Step 3 (actually opening
the `ring` stream) currently just stalls: no picture, no error, **nothing
at all** — not even at `log: {ring: trace}`, the most verbose go2rtc
offers — for 45+ seconds. The process itself is fine (its API stays
responsive throughout); this one dial path produces zero observable
signal. Not yet diagnosed further — see "Known rough edges" for what's
been ruled out and what hasn't been tried yet.

Full research trail (what HA/ring-mqtt do and don't expose, why go2rtc's
native `ring:` source is the better foundation than hand-rolling a service
against `ring-client-api`, the Frigate-version-parity conflict that put
this in its own container instead of `go2rtc-dev`) is in the conversation
that produced this — not duplicated here.

## Why a fourth go2rtc, touching nothing that exists today

- `../compose.yaml`'s `go2rtc-dev` is pinned to 1.9.10 on purpose — the
  exact version Frigate 0.17 embeds
  (`docs/research/frigate-amd-acceleration.md`), so the future NVR plan
  can point everything at Frigate's own go2rtc without a version seam.
  `ring:` needs 1.9.13+. Bumping `go2rtc-dev` would quietly break that
  already-recorded parity, so this is a separate container instead.
- Its Ring login must be its own, never `ring-mqtt-dev`'s stored
  `refresh_token`: Ring refresh tokens are single-use and rotate on first
  use, so two independent consumers racing to refresh the same one
  invalidate each other — a real risk to the doorbell integration that
  already works. `compose.yaml`'s header has the full reasoning.

## Bring-up

From a **host terminal — never the devcontainer's**. Relative bind mounts
in a compose file resolve against the wrong filesystem root from inside
the devcontainer (`../../../.devcontainer/compose.yaml`'s header explains
why: Docker runs on the host via docker-outside-of-docker, and the
devcontainer's `/workspaces/SmartHome` is not a path the host daemon has).

```sh
cd hub/dev/ring-audio-test
cp go2rtc/go2rtc.example.yaml go2rtc/go2rtc.yaml
docker compose up -d
open http://localhost:31984   # go2rtc's own web UI
```

## Procedure

1. **Confirm the mic producer works on its own first.** ✅ Done
   2026-08-08. The `mic` stream reads this laptop's built-in mic
   (`card 1: PCH [HDA Intel PCH], device 0: ALC287 Analog`, confirmed via
   `arecord -l`) through PipeWire's PulseAudio-compat socket — the first
   attempt bound the raw ALSA hardware device directly and failed with
   "Resource busy" (PipeWire already holds it, normal on any modern
   desktop); `compose.yaml`'s header and `go2rtc.example.yaml` have the
   fix. Verified end to end via the API, not just the UI: a real WebRTC
   consumer (a browser tab) showed up receiving live opus audio whose
   `parent` traced straight back to the mic producer's receiver.

2. **Log into Ring — NOT through the web UI's "Add > Ring".** That hits a
   currently-open go2rtc bug (github.com/AlexxIT/go2rtc issues #2261,
   #2096: "auth request failed with status 406", no fix as of writing).
   Routed around it using `ring-mqtt-dev`'s own vendored Ring library
   instead — the same one already proven working for this account, via a
   completely separate code path from go2rtc's broken one:

   ```sh
   docker exec -it ring-mqtt-dev node \
     /app/ring-mqtt/node_modules/@tsightler/ring-client-api/lib/ring-auth-cli.js
   ```

   Interactive (email/password/2FA) — a FRESH login, not ring-mqtt's
   stored token (same reasoning as always). Prints a `refresh_token`;
   paste it into `go2rtc.yaml`'s commented `ring:` line, then uncomment it
   and `docker compose restart` (or `down`/`up -d`) to pick it up.

   **Three params needed, not the two go2rtc's own README shows.**
   Learned the hard way 2026-08-08: with just `device_id`+`refresh_token`
   the stream registered but every attempt to open it failed with
   `"streams: ring: wrong query"` — traced to `pkg/ring/client.go`'s
   `Dial()`, which also requires `camera_id` (Ring's own numeric doorbot
   id) and errors if any of the three is empty. `device_id` (the MAC-like
   id, visible in `ring-mqtt-dev`'s logs) is NOT the same value as
   `camera_id` — getting the latter needed a one-off script against the
   vendored `RingApi` using the refresh_token from this step:
   `location.cameras[].data.id`. Front Door's is already known:
   `device_id=90486cf35236&camera_id=319156885`. `go2rtc.example.yaml`
   has the full `ring:` line shape with both filled in — only
   `refresh_token` is still yours to add.

3. **Check what codec go2rtc reports for the `ring` stream** on its WebUI
   info page once it's live. The `mic` producer's `libopus` is exec.go's
   documented pipe-transport option, not a confirmed Ring requirement —
   this is the first real unknown to resolve.

   **⚠️ Currently stuck here.** With all three query params correct (the
   "wrong query" error is gone — confirmed by its absence in the logs),
   dialing `ring` — tried both via `ffprobe rtsp://127.0.0.1:8554/ring`
   and go2rtc's own web UI player — produces **nothing**: no SDP, no
   error, no picture, no timeout message, for 45+ seconds. Turned on the
   most verbose logging go2rtc has (`log: {level: info, ring: trace}` in
   `go2rtc.yaml`, restart to apply) — still not one new log line during
   the entire stall. Ruled out:
   - **Not a deadlock.** `curl http://127.0.0.1:1984/api/streams` answers
     instantly throughout — the whole go2rtc process stays responsive,
     it's specifically this one dial path that's silent.
   - **Not network egress.** `curl https://oauth.ring.com/oauth/token`
     and `https://api.ring.com/` from inside this same container both
     return real HTTP responses (401/404 — reached Ring's servers fine,
     just without the right request shape, which is expected for a bare
     probe).
   - **Not a stray/duplicate process** — `ps aux` inside the container
     shows only `tini` and the one `go2rtc` process throughout.

   Not yet tried: a longer wait than ~45s (a battery/low-power Ring
   device can need a push-notification wake before it answers a live-call
   request, and this session — unlike `ring-mqtt-dev`'s — isn't
   subscribed to push notifications, so if that's what's needed here it
   may simply never arrive); checking whether `ring-mqtt-dev` waking the
   same physical doorbell right before dialing changes anything; filing
   this as a go2rtc issue upstream, since between this and the two bugs
   already hit, the `ring:` source is looking less production-ready than
   its README implies.

4. **Push the mic into the doorbell's backchannel:**

   ```sh
   curl -X POST 'http://localhost:31984/api/streams?dst=ring&src=mic'
   ```

   Verified from go2rtc's own `streams/api.go` source (not a guess): a
   `POST` with `dst` naming an existing stream and `src` naming another
   calls `stream.Play(src)` on it — the same mechanism the go2rtc README
   describes as "play audio files or live streams on any camera with
   two-way audio support." **Not yet verified: the call that stops it
   again.** Find that before this goes anywhere near the Panel's button —
   a mic left open on the doorbell's speaker with no way to close it is
   worse than the stub it would be replacing.

5. **Stand near the actual doorbell and listen.** This is the only step
   that answers the real question — nothing in the API responses proves
   sound left the speaker.

## Known rough edges going in

Found while researching, not guessed:

- go2rtc issue "Exec with backchannel does not work" — this feature has
  real reported breakage, not just missing docs.
- go2rtc's web UI "Add > Ring" login — hit this directly 2026-08-08:
  "auth request failed with status 406: 406 Not Acceptable"
  (github.com/AlexxIT/go2rtc issues #2261, #2096, both open, no fix).
  Worked around via `ring-auth-cli` (step 2 above) instead of waiting on
  it or retrying.
- go2rtc's own `internal/ring/README.md` example
  (`ring:?device_id=XXX&refresh_token=XXX`) is incomplete — silently
  missing `camera_id`, which `pkg/ring/client.go`'s `Dial()` requires just
  as much as the other two. Hit this directly too (step 2 above).
- Dialing `ring` with a syntactically-correct URL currently just stalls
  forever with zero diagnostics, even at the most verbose logging go2rtc
  offers (step 3 above) — the newest and least-understood of the three.
  Between this and the two bugs above, go2rtc's `ring:` source is looking
  less production-ready than its own docs suggest; worth weighing against
  the originally-passed-over alternative (a small custom service against
  `ring-client-api` directly, the path `homebridge-ring` actually ships)
  if this doesn't resolve.
- Real-world Ring two-way audio (checked `dgreif/ring`'s issue tracker,
  the most mature community implementation, used by `homebridge-ring`) has
  a history of garbled/distorted audio complaints even in mature
  implementations. Temper expectations of first-try clean audio.

## Once proven (or disproven)

- **If it works**: fold the version bump and the `ring:`+`mic` stream
  shape into `../compose.yaml` (this laptop's dev Hub, so `docker compose
  up` here matches what the devcontainer runs) and `../../compose.yaml`
  (the appliance stack) — as their own service, not a bump to the
  existing Frigate-pinned go2rtc. Owner rebuilds afterward (VS Code
  "Rebuild Container" for the devcontainer; the appliance separately).
  Then wire the Panel's push-to-talk button to the proven start/stop
  calls, and delete this directory.
- **If it doesn't**: delete this directory, record why in `TODO.md` or a
  new ADR so the next attempt doesn't re-walk the same dead end.
