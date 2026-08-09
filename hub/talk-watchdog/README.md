# talk-watchdog — the dead-man switch for Ring talkback

go2rtc has **no idle timeout on internal producers**. Nothing in the stack
reaps a wedged microphone or an orphaned consumer, and either one holds the
doorbell in live view — on a battery device, over somebody's bandwidth, and
suppressing real dings while it lasts. A leaked `curl` once did exactly that
for **~30 minutes and 160 MB** before a routine `/api/streams` dump found it
([`../dev/ring-twoway-lab/RESULTS.md`](../dev/ring-twoway-lab/RESULTS.md),
§"INCIDENT — a leaked consumer held the doorbell live for ~30 minutes").

This service exists because **stop authority has to live on the server side**.
The Panel is the thing that starts a talk session, but it is also the thing
that might crash mid-press, and a process cannot promise to clean up after its
own death. So the cap does not live in the Panel.

Stdlib-only Python, one file, no dependencies — deliberately the least likely
thing in the stack to break.

---

## What it does

| | Trigger | Action |
|---|---|---|
| **Talk cap** | the `mic` stream's producer has been live for `TALK_CAP_S` | `POST /api/streams?dst=ring&src=` |
| **Startup stop** | process start, *before* the first poll | same |
| **Shutdown stop** | `SIGTERM` / `SIGINT` | same |
| **Orphaned producer** | `ring` producer live, no consumers, nobody talking, for `STALE_POLLS` polls | same, plus a log line |
| **Stalled consumer** | a consumer's `bytes_send` has not moved for `STALE_POLLS` polls | **log only** — see below |

The stop call is idempotent (verified 40/40 returning 200), so it is fired
liberally rather than carefully.

## 🔴 What this cannot do

**There is no consumer-kill endpoint in go2rtc.** Nothing in the lab ever
evicted a consumer over HTTP; the orphaned `curl` was removed with
`pkill -9 -x curl` *inside the container*. So a stalled or orphaned consumer is
**detected and reported, not reaped**. Do not read a running watchdog as a
guarantee that no client can hold the doorbell open — it is a guarantee that
the *microphone* closes, and an alarm for everything else.

The three ways to close that gap, none of them taken here:

1. **Own every consumer** — whatever plays inbound audio becomes a child of
   this process, so reaping is a signal to a pid it holds. This is the shape
   that also settles the open `gst-launch-1.0`-versus-supervised-service
   question, and it is the recommended direction.
2. **Restart the go2rtc container** — the only lever that certainly clears an
   unowned consumer, and it drops every camera in the house while it happens.
   Needs the docker socket, and needs the owner to say yes.
3. **Live with it**, on the grounds that the only observed orphan was created
   by a debugging session that no longer happens.

Until the owner picks one, the watchdog alerts and does not act.

**A second, smaller limit, on the stop call itself.** It stops producers pushed
*into* the destination stream — which is exactly what a wedged microphone is, so
the cap is solid. Whether it also clears a **ghost `ring:` producer**
(go2rtc#1961, a producer that outlives its last consumer — never reproduced in
the lab) is **unverified**. So a repeating `{"event":"stop","reason":"orphaned_producer"}`
is not "handled"; it means the producer is *not* being cleared, and the doorbell
is still live. Restart the go2rtc container and open an issue.
`"status": 200` on that line means the API accepted the call, nothing more.

**It also never issues `PUT` or `DELETE` on `/api/streams`.** Those are
`delete(streams, src)` + `app.PatchConfig(...)` — they rewrite `go2rtc.yaml`
on disk, *including the Ring refresh token in it*, and stop no producer. A test
asserts that only `GET` and `POST` ever reach the wire.

## Why "is the mic hot" is read off the `mic` stream

The obvious signal — a `sendonly` audio media on the `ring` producer — is
wrong, and measurably so. Read off a live go2rtc 1.9.10 on 2026-08-09, an
ordinary inbound RTSP *listener* reports:

```json
"medias": ["video, sendonly, ANY", "audio, sendonly, ANY"]
```

That is go2rtc describing what it sends *to the listener*. Keying on `sendonly`
would report talk in progress every time somebody merely watched the doorbell.
The `ring` producer's SDP offer also advertises the backchannel whether or not
anything is being pushed into it.

The `mic` stream's producer going live means an `ffmpeg` is capturing the
microphone. That is unambiguous, and it is the exact condition worth bounding.

## Liveness, precisely

A producer entry **always exists** — it is the configured source, carrying only
`url` when idle. It is connected only once it also has `id`, `sdp` and
`remote_addr`:

```json
idle   {"url": "ring:?device_id=…&camera_id=…&refresh_token=…"}
live   {"id": 52, "format_name": "ring/webrtc", "remote_addr": "54.213.119.18:48909 host", "sdp": "v=0…", …}
```

Testing for the producer *object* reports every configured stream as connected
to Ring. The code tests for `id`.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `GO2RTC` | `http://go2rtc:1984` | service name on the compose network |
| `TALK_STREAM` | `ring` | the talkback destination |
| `MIC_STREAM` | `mic` | the capture stream; its producer is the hot-mic signal |
| `TALK_CAP_S` | `45` | absolute cap, 30–60 s per the spec |
| `POLL_S` | `2` | |
| `STALE_POLLS` | `5` | consecutive polls before a condition is believed |
| `HTTP_TIMEOUT_S` | `5` | |

Logs are one JSON object per line on stdout. **Every line passes through a
redaction filter first** — `/api/streams` responses embed the live Ring refresh
token, and two accidental leaks have already cost a re-mint.

## Running it

Wired into [`../dev/compose.yaml`](../dev/compose.yaml) as `talk-watchdog`. It
needs no image build: the code is stdlib-only, so it is a stock `python:3.12-slim`
with this directory mounted read-only.

```sh
# From a HOST shell — never `docker compose` from the devcontainer.
cd hub/dev && docker compose up -d talk-watchdog
docker logs -f talk-watchdog-dev
```

Nothing about the *code* is dev-specific, but the **service block does not port
across unchanged**. Production go2rtc runs on **host networking**
(`hub/compose.yaml`), so `GO2RTC=http://go2rtc:1984` — a compose-network service
name — resolves to nothing there. The Appliance version needs
`network_mode: host` and `GO2RTC=http://127.0.0.1:1984`.

## Tests

No doorbell, no go2rtc, no network — a scripted fake serves `/api/streams` and
records every request.

```sh
cd hub/talk-watchdog && python3 -m unittest discover -s tests -t tests
```

24 tests. The ones worth knowing about, because each encodes something that was
learned the hard way:

- a consumer advertising `sendonly` audio is **not** talk in progress;
- a configured-but-not-dialled producer is **not** live;
- a **silent but flowing** consumer never alerts — Ring transmits
  near-digital-silence (~−90 dBFS) on a quiet street, and a watchdog that
  health-checks on audio presence would restart forever;
- a push-only call (talk with zero listeners) is **not** an orphaned producer;
- the cap **re-arms** if a stop does not take, so a silently-failing stop cannot
  leave the microphone hot indefinitely;
- no log line can carry a refresh token;
- `PUT`/`DELETE` never reach the wire.

## What it does not know about

**The Panel does not talk to this service.** It calls go2rtc directly, per
[ADR-0011](../../docs/adr/0011-ring-two-way-audio-via-go2rtc-half-duplex.md) —
this watches independently and enforces regardless of who started the session.
That keeps ADR-0011's two-HTTP-call contract intact and means a Panel bug
cannot disable the cap.

The alternative — the Panel posting to a control plane here, which proxies to
go2rtc — buys exact cap timing instead of timing quantised to `POLL_S`, and
gives one place to change. It is worth revisiting if `POLL_S` granularity ever
matters; it does not at a 45 s cap.
