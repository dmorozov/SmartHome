# Ring two-way audio — experiment results

Running record for the plan in `README.md`. One section per experiment: exact
command, raw output, what it ruled in or out. **This file does not modify the
plan.** Where a result contradicts the plan, that is recorded here, not there.

Host: dev laptop, host shell (not the devcontainer), repo at
`/home/dmorozov/Work/SmartHome`.

---

## Preflight — §2.1 environment checks · 2026-08-08

```sh
[ -e /.dockerenv ] && echo "SHELL: WRONG — inside a container" || echo "SHELL: OK — host shell"
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -i ring
ls -la "${XDG_RUNTIME_DIR:-/run/user/1000}/pulse/native"
ls -l ~/.sh_keys/ring-twoway-lab.env
```

```
SHELL: OK — host shell
go2rtc-ring-test	alexxit/go2rtc:1.9.14	Up 11 hours
ring-mqtt	tsightler/ring-mqtt:5.9.3	Up 36 hours
ring-mqtt-dev	tsightler/ring-mqtt:5.9.3	Up About an hour
srw-rw-rw- 1 dmorozov dmorozov 0 Aug  3 22:55 /run/user/1000/pulse/native
ls: cannot access '/home/dmorozov/.sh_keys/ring-twoway-lab.env': No such file or directory
```

**Status:** all §2.1 preconditions pass. `go2rtc-ring-test` (1.9.14) is already up
from the previous session, so Track A needs no `docker compose up`.

**§2.3 outstanding:** the lab token does not exist yet. Minting it is interactive
(email, password, 2FA), so it is the owner's step. A1 does not depend on it —
A1 deliberately uses an invalid token string and touches no credential.

Vendored library confirmed to be the exact build the plan names:

```sh
docker exec ring-mqtt-dev sh -c 'grep -o "\"version\": *\"[^\"]*\"" \
  /app/ring-mqtt/node_modules/@tsightler/ring-client-api/package.json | head -1'
```
```
"version": "14.3.1-beta.0"
```

`ring-auth-cli.js` is present at the path §2.3 gives.

---

## A1 — The User-Agent test · 2026-08-08 17:23 UTC

**Question (§3):** is Ring's Cloudflare WAF rejecting go2rtc specifically because
of its stale `User-Agent: android:com.ringapp`?

### Command

```sh
UUID=$(cat /proc/sys/kernel/random/uuid)
BODY='{"client_id":"ring_official_android","scope":"client","grant_type":"refresh_token","refresh_token":"deliberately-invalid"}'
for UA in 'android:com.ringapp' 'android:com.ringapp:3.98.0(70492092)'; do
  curl -si -X POST https://oauth.ring.com/oauth/token \
    -H 'Content-Type: application/json' -H '2fa-support: true' \
    -H "hardware_id: $UUID" -H "User-Agent: $UA" -d "$BODY"
done
```

Both requests used the same `hardware_id` (`4a2eb65e-…`) and differ **only** in
the `User-Agent` header. The refresh token is deliberately invalid so no real
token is consumed or rotated.

### Raw output

```
########## UA: android:com.ringapp ##########
HTTP/2 401
date: Sat, 08 Aug 2026 17:23:47 GMT
content-type: application/json
content-length: 84
cache-control: no-cache, no-store, max-age=0, must-revalidate
expires: Fri, 01 Jan 1990 00:00:00 GMT
pragma: no-cache
strict-transport-security: max-age=31536000; includeSubDomains
x-request-id: e4020794-c95b-42b7-9bb9-73bdb6ad2539
cf-cache-status: DYNAMIC
server: cloudflare
cf-ray: a28035fbcf88f7d9-LAX

{"error":"invalid_grant","error_description":"token is invalid or does not exists"}


########## UA: android:com.ringapp:3.98.0(70492092) ##########
HTTP/2 401
date: Sat, 08 Aug 2026 17:23:47 GMT
content-type: application/json
content-length: 84
cache-control: no-cache, no-store, max-age=0, must-revalidate
expires: Fri, 01 Jan 1990 00:00:00 GMT
pragma: no-cache
strict-transport-security: max-age=31536000; includeSubDomains
x-request-id: 26be9c4b-ee6f-4ba1-874b-141908ef1621
cf-cache-status: DYNAMIC
server: cloudflare
cf-ray: a28035fc8929cab0-LAX

{"error":"invalid_grant","error_description":"token is invalid or does not exists"}
```

### Result

| | go2rtc UA | ring-client-api UA |
|---|---|---|
| Status | **401** | **401** |
| Body | `{"error":"invalid_grant",…}` | `{"error":"invalid_grant",…}` |

**401 vs 401.** Responses are byte-identical apart from `x-request-id` and
`cf-ray`.

### What §3's table says this means

> **401 vs 401** → **Theory dead. The login 406 came from somewhere else.** → **A2.**

### What it rules in and out

- 🔴 **§1.1's User-Agent block is NOT reproducible on this host, this account,
  this endpoint, today.** The two-agent convergence on the stale UA does not
  survive direct measurement.
- **Neither request was blocked at the Cloudflare edge — both reached Ring's
  origin application.** This is stronger than the status code alone: the response
  carries a Ring-generated JSON error (`invalid_grant`), a Ring `x-request-id`,
  and `cf-cache-status: DYNAMIC`. A WAF bot-score mitigation returns a
  Cloudflare-generated HTML challenge/error page, not an application JSON body.
  So the WAF evaluated both signatures and **passed both through**.
- **401 is the correct, expected rejection** for a deliberately invalid refresh
  token. Both clients got the *auth-layer* answer, not a *reputation-layer* one.
- **This reproduces and extends the plan's own "honest counter-evidence"** in
  §1.1 (a bare curl returned 401, not 406). The new information is that the
  *versioned* UA is treated no differently — so there is no differential to
  explain anything.
- **Consequence for §1.10:** options **3** (patch go2rtc's UA + self-build) and
  **C2** lose their stated rationale. Patching the UA fixes a block that is not
  currently in effect. Do not spend a Go fork on it.
- **Consequence for §1.11:** the reconciliation there argued the 406 and the
  stall are two different defects, and that the UA explains the *login* 406 only.
  A1 goes further — **on current evidence the UA explains neither.** §1.11's
  instruction to run A2 regardless now applies with more force, not less: A2 is
  the only remaining probe of the stall, and A1 removed the one competing
  explanation for the login 406.

### Alternate reading, recorded honestly

dgreif/ring#1717 dates the 406 wave to ~2026-02-23 and tsightler's diagnosis to
2026-03-08. It is now **2026-08-08 — five months later.** A1 cannot distinguish
between:

1. the WAF rule never applied to us, or
2. the WAF rule existed in Feb–Mar 2026 and has since been withdrawn or retuned.

Both readings lead to the same operational conclusion — **the UA is not a
blocker today, and patching it buys nothing** — so this does not need resolving
before proceeding. It does mean §1.1 should not be called "wrong" retroactively,
only "no longer live."

**Open, and not answered by A1:** where the web-UI login 406 we actually hit came
from. It was worked around rather than diagnosed, and A1 has now removed the
leading candidate. Worth keeping in view, but it is not on the critical path to
the stall.

### Next

**A2** — re-dial at `level: debug` and watch for `start producer`. Per §6, A2
runs regardless of A1's outcome, and it is now the only open probe of the stall.

---

## A3 — Token shape · 2026-08-08 · answered incidentally

**Question (§3):** is the refresh token the base64-JSON envelope go2rtc expects,
or a raw token that silently blanks `hardware_id`?

Answered while locating which `go2rtc.yaml` the lab container reads, so it cost
nothing. Recorded here out of order because it closes a §1.5 hypothesis.

### Which file — resolved from the container's own mount, not inferred

```sh
docker inspect go2rtc-ring-test --format \
  '{{range .Mounts}}{{.Type}}  {{.Source}}  ->  {{.Destination}}  (rw={{.RW}}){{println}}{{end}}'
```
```
bind  /home/dmorozov/Work/SmartHome/hub/dev/ring-audio-test/go2rtc  ->  /config  (rw=true)
bind  /run/user/1000/pulse  ->  /run/user/1000/pulse  (rw=true)
```

So Track A's config is **`hub/dev/ring-audio-test/go2rtc/go2rtc.yaml`**, and the
token lives as a query param on the `ring:` stream line, not in an auth block:

```yaml
streams:
  ring: ring:?device_id=90486cf35236&camera_id=319156885&refresh_token=<REDACTED>
```

Distinct from Track B's token, which is `RING_REFRESH_TOKEN=` in
`~/.sh_keys/ring-twoway-lab.env` and reaches containers via `--env-file` only.

### Command and output

```sh
grep -o 'refresh_token=[A-Za-z0-9+/=_-]\{1,4\}' go2rtc/go2rtc.yaml | head -1
```
```
refresh_token=eyJy
```

Deliberately capped at 4 characters — that is the entire A3 test, and it keeps
the credential out of the transcript per ADR-0010.

### What it rules out

✅ **Correct envelope.** The token is base64 of `{"rt":"…","hid":"…"}`, so
`parseAuthConfig` took the good branch. **`hardware_id` is populated, not empty,
on every Ring call.** §1.5's silent-degradation trap did not fire, and the
"go2rtc is calling Ring with a blank `hardware_id`" hypothesis is dead.

Also confirms we did not walk into go2rtc#2281 (§0.3) — the `ring-auth-cli` token
was accepted into config in the correct form. That issue's reporter may still
have hit something real, but it is not our failure mode.

### 🔴 New question this raises — carry into A2

Ring rotates refresh tokens on use. The lab yaml's mtime is **`Aug 7 23:34`**,
and `go2rtc-ring-test` has been up **11 hours** — so the file has **not** been
rewritten since the token was pasted. Two readings:

1. go2rtc never successfully refreshed, or
2. go2rtc refreshed and **did not persist the rotated token back to config**.

If (2), the stored token is now spent and that is a candidate stall cause in its
own right — independent of everything in §1.1–§1.3. A2 should distinguish these:
a spent token produces an auth-layer failure, which per §1.11 would print a `WRN`
at `level: debug`, not a silent infinite wait.

### Housekeeping noted, not actioned

`hub/dev/ring-audio-test/go2rtc/go2rtc.yaml` is mode `-rw-r--r--` (world-readable)
while holding a live credential; `~/.sh_keys/go2rtc/go2rtc.yaml` is `600`. In-tree
already contradicts ADR-0010 (§2.2 acknowledges this and schedules the directory
for deletion), but the permissions are a free tightening: `chmod 600`.

### Still to run

`log: {level: info, ring: trace}` — the §0.1 dead-key config — is **still in
place** in this file. A2's first step replaces it. Until then, the broken-evidence
condition described in §0.1 still holds.

---

## 🔴 DEFECT IN THE PLAN — A2's config-rewrite snippet is destructive

Found by a guard assertion when running A2 as written. **No damage occurred**, but
the snippet in `README.md` §3/A2 must not be run verbatim.

### The bug

```python
s = re.sub(r'(?ms)^log:\n(?:[ \t]+.*\n)*', 'log:\n  level: debug\n', s)
#            ^^^ the `s` flag is the bug
```

`(?ms)` enables **DOTALL**, which makes `.` match newlines. So `[ \t]+.*\n` with a
greedy `.*` matches from the first indented character **to the last newline in the
file**, and `(?:…)*` consumes the entire remainder in one iteration. The
substitution then replaces *everything from `log:` onward* with a two-line log
block — **deleting `api:`, `streams:` (including the `ring:` line and the live
refresh token) and `webrtc:`**.

In this config `log:` sits at line 49 with all four top-level keys after it, so the
blast radius is the whole functional config. The file is the only copy; the token
would have had to be re-minted.

### How it surfaced

The write was gated behind assertions added before running it:

```python
assert 'refresh_token=' in s, "ABORT: ring line lost"
```
```
AssertionError: ABORT: ring line lost
```

`p.write_text(s)` is after the asserts, so nothing was written. Verified
post-abort: log block unchanged, `ring:` line and token intact.

### The fix

Drop the `s` flag — `(?m)` is what was meant. MULTILINE alone gives `^` per-line
behaviour while `.` stops at newlines, so `(?:[ \t]+.*\n)*` matches only the
indented continuation lines of the `log:` block and stops at the blank line.

```python
s = re.sub(r'(?m)^log:\n(?:[ \t]+.*\n)*', 'log:\n  level: debug\n', s)
```

Applied with integrity guards; result verified — all four top-level keys present
(`log:` 49, `api:` 52, `streams:` 56, `webrtc:` 81), token intact, 72 bytes removed
(exactly the old `level: info` + `ring: trace` lines).

**Action:** fix §3/A2 in `README.md` before anyone re-runs it. Not done here — the
instruction was not to overwrite the plan.

---

## 🔴 Incidental — go2rtc rewrites `go2rtc.yaml` and appears to rotate the token

Not an experiment; observed from file sizes and mtimes while doing the above. It
bears directly on A3's open question, so it is recorded.

### Observations

| Moment | Size | mtime | Actor |
|---|---|---|---|
| Owner pastes fresh token | 6183 | 10:33 | owner |
| After `docker compose restart` | 6149 | — | **go2rtc** (−34) |
| After the log-block edit | 6077 | — | this session (−72, expected) |
| Moments later, **no restart issued** | 6111 | 10:35 | **go2rtc** (+34) |

`/config` is bind-mounted `rw=true`, so go2rtc can write it, and the compose header
already documents that its `PUT /api/streams` handler calls `app.PatchConfig`.

The ±34-byte deltas track the `refresh_token=` value changing length, and the
6077→6111 change happened with **no restart from this session**. Token fingerprint
after: `len=1204`, `sha256[0:12]=6ae67df50dae`.

### Why this matters

Ring rotates refresh tokens on use. If go2rtc is writing a *new* token back into
the config, then **go2rtc is successfully authenticating and completing token
refresh** — which independently corroborates §1.11's central reconciliation:

> auth succeeds; the stall is downstream of it.

It would also retire the "the stored token is spent" theory raised under A3.

### Caveats — do not over-read this yet

- Size deltas and mtimes are **circumstantial**. Nothing here has read the token
  value across two points in time to prove rotation (deliberately — ADR-0010).
  The A2 run captures the fingerprint at four checkpoints, which will settle it.
- An alternative explanation is that go2rtc normalises/rewrites config for
  unrelated reasons and the length coincidence is noise.
- Confirmed either way by A2's debug log: a successful refresh is visible there.

### Operational consequence, independent of the cause

**The owner's pasted token is not necessarily the token in the file.** Any future
step that assumes the config still holds the hand-pasted value — or that copies
this token elsewhere — must re-read it at point of use. And restarting this
container is not side-effect-free on the credential.

**Confirmed during A2.** The rewrite at `17:35:38` was 23 s after go2rtc's
`17:35:15` start, and it *preserved* the `level: debug` edit this session had made
seconds earlier while changing only the `ring:` line — i.e. a surgical
`app.PatchConfig`, not a whole-file dump of in-memory state. The fingerprint then
held constant (`len=1204 sha=6ae67df50dae`) across all four A2 checkpoints, so
there was no further rotation during the run. **go2rtc authenticates and completes
Ring's token refresh successfully.**

---

## A2 — Re-dial with logging that actually works · 2026-08-08 17:37 UTC

# 🟢 RESULT: THE DIAL SUCCEEDS. go2rtc's `ring:` SOURCE WORKS ON THIS DOORBELL.

**This falsifies the central premise of the plan.** There is no stall.

### Setup

`log: {level: info, ring: trace}` → `log: {level: debug}` (via the corrected
regex above), then `docker compose restart` **so the running process actually
reloads it** — the first restart in this session happened *before* the edit and
would have run at `info`.

Dial: `ffprobe -v info -rtsp_transport tcp rtsp://127.0.0.1:8554/ring`, observed
for a full 3 minutes per the plan.

### Raw log

```
17:37:02.553 INF go2rtc platform=linux/amd64 revision=b5948cf version=1.9.14
17:37:02.734 DBG [rtsp] new consumer stream=ring
17:37:04.358 DBG [streams] start producer url=ring:?device_id=90486cf35236&camera_id=319156885&refresh_token=<REDACTED>
17:37:06.798 DBG [rtsp] handle error=EOF
17:37:06.798 DBG [streams] stop producer url=ring:?device_id=90486cf35236&camera_id=319156885&refresh_token=<REDACTED>
17:37:06.799 DBG [rtsp] disconnect stream=ring
```

Nothing further for the remaining ~3 minutes. Token fingerprint unchanged at every
checkpoint.

### ffprobe — the actual answer

```
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/ring':
  Metadata:
    title           : go2rtc/1.9.14
  Stream #0:0: Video: h264 (High), yuvj420p(pc, bt709, progressive),
                      1536x1536 [SAR 1:1 DAR 1:1], 15 fps, 15 tbr, 90k tbn
  Stream #0:1: Audio: opus, 48000 Hz, stereo, fltp
```

Preceded by `[h264 @ …] concealing 5645 DC, 5645 AC, 5645 MV errors in I frame` —
a partially-received first I-frame, i.e. **real H.264 payload was decoded**, not an
empty track.

### 🔴 The misreading this nearly caused

`handle error=EOF` followed 2.4 s after `start producer` looks like a failure and
resembles the plan's "consumer gave up first" row. **It is not.** `ffprobe` had
*finished* — probing, printing the stream table and exiting is its entire job. The
`EOF` is ffprobe's own normal close, and go2rtc correctly tore the producer down
behind it. A2's result table has no row for "it simply worked", which is what made
this ambiguous; A2b was run to remove all doubt.

### Reading against §3's A2 table

| Table row | Observed? |
|---|---|
| `new consumer` yes, `start producer` never | ❌ — both appeared |
| Both appear, then **silence forever** (`connected.Wait()`, root cause #1) | ❌ — **did not reproduce** |
| `WRN` at ~45–100 s | ❌ — no `WRN` at all |
| `stop producer` ~34 s after start (h3nnes's shape) | ❌ — 2.4 s, and by consumer exit |

**None of the four predicted outcomes occurred.** The real outcome is a fifth the
plan did not anticipate: a clean, fast, successful dial.

---

## A2b — Sustained inbound capture · 2026-08-08 17:41 UTC

**Question:** ffprobe proves negotiation and one I-frame. Does media actually
*sustain*?

**Receive-only.** No backchannel, no mic, nothing pushed to the doorbell speaker.

### Command

```sh
docker exec go2rtc-ring-test sh -c \
  'ffmpeg -v info -rtsp_transport tcp -i rtsp://127.0.0.1:8554/ring -t 20 -c copy /tmp/ring.mkv'
```

### Result

```
frame=  300 fps= 16 q=-1.0 Lsize=  3152KiB time=00:00:20.06 bitrate=1286.8kbits/s
video:3074KiB audio:72KiB muxing overhead: 0.174325%

duration=20.050000   size=3227768   bit_rate=1287887
index=0  h264   video  1536x1536
index=1  opus   audio  48000 Hz  2 ch
```

```
17:41:08.102 DBG [rtsp] new consumer stream=ring
17:41:09.027 DBG [streams] start producer url=ring:?…&refresh_token=<REDACTED>
17:41:29.645 DBG [rtsp] handle error="read tcp …:8554->…:42092: read: connection reset by peer"
17:41:29.645 DBG [streams] stop producer url=ring:?…&refresh_token=<REDACTED>
17:41:29.646 DBG [rtsp] disconnect stream=ring
```

**300 frames over 20.05 s = 15 fps sustained, zero dropouts.** 3.0 MB video +
72 KiB Opus audio (~29 kbit/s). Producer came up in **0.9 s** this time
(17:41:08.102 → 17:41:09.027), faster than A2's 1.6 s.

---

## What A2/A2b settle — several plan hypotheses die at once

| Plan claim | Status after A2/A2b |
|---|---|
| §1.2 — `connected.Wait()` unbounded hang is the root cause | 🔴 **Did not reproduce.** Dial completed in 0.9–1.6 s |
| §1.3 — missing `clients_api/session` causes silent refusal (*"promoted to the leading stall hypothesis"*) | 🔴 **Moot.** Ring answered `live_view` without it |
| §1.11 — codec asymmetry: go2rtc offers Opus only; if Ring answers PCMU it has nothing to negotiate | ✅ **Resolved in go2rtc's favour.** Ring chose **Opus 48000/2** — exactly what go2rtc offers |
| §1.9 / A4 — H264 track advertised but empty; only HEVC carries data (h3nnes) | 🔴 **Does not apply.** H264 High carried 300 real frames |
| §1.8 / #1961 / #1933 — ghost producer never stops, drains battery | 🔴 **Did not reproduce.** `stop producer` fired ~1 ms after the consumer left, both times; `/api/streams` shows `consumers: []` and no live producer |
| §1.10 row 4 — *"go2rtc `ring:` as shipped — currently no, blocked at the stall"* | 🔴 **Wrong.** Inbound works as shipped, unpatched, on 1.9.14 |
| §1.1 — stale User-Agent | 🔴 Already dead at A1; go2rtc authenticated fine with the bare UA |

**Answers to the §9.4 handoff questions, so far:**

1. **A1:** 401 vs 401.
2. **A2:** `start producer` appeared — and was followed by a complete, working
   media stream.
3. **B1's real question, answered without running Track B:** `usingOpus` = **true**.
   Ring picked **Opus 48 kHz stereo**.
4. **B2:** not yet — that is the first step that pushes audio *out* of the doorbell.

### What changed since the previous session

Unproven, but the strong candidate is simply **the freshly-pasted refresh token**.
Supporting evidence in the container's own log history, from before this session:

```
06:26:21.030 WRN [rtsp] error="streams: ring: wrong query" stream=ring
```

That is go2rtc **#1781**'s signature (bibliography, *"`wrong query`, unanswered"*)
— a **bounded, named, `WRN`-level** failure at `level: info`, not the silent
error-free hang §1.2 describes. Its presence sits awkwardly with §0.1's account of
the earlier attempt seeing no output; it suggests the previous session's failure
was a URL/query-parse rejection that *was* visible, rather than the infinite wait.

**Not investigated further** — the config now parses and the dial works, so the
old failure is no longer reproducible here. Recorded because §0.1's diagnostic
record is what the rest of the plan was built on.

### 🔴 What is still NOT proven

**The entire outbound direction.** Everything above is the doorbell talking to us.
The goal in §7 line 1 — *"someone standing at the front door hears this laptop's
microphone"* — is untested. Untested with it: the `dst=ring&src=mic` push (§1.6),
the `camera_options`/`stealth_mode:false` speaker activation (§1.4), the stop call,
and echo cancellation (§1.8, still unresearched).

Inbound working is necessary but not sufficient, and §1.9 warns explicitly that
"I got Ring audio working" reports conflate the two directions. **This result is
the easy direction.**

---

## Outbound prep — mic sanity + stop-call rehearsal · 2026-08-08 17:47 UTC

Owner chose a stop-first, capped approach to the outbound test. These two steps
push **nothing** to the doorbell.

### Step 1 — the `mic` producer works, and the codec is a native match

```sh
docker exec go2rtc-ring-test sh -c \
  'ffmpeg -v warning -rtsp_transport tcp -i rtsp://127.0.0.1:8554/mic -t 5 -c copy /tmp/mic.mka'
```
```
codec_name=opus   codec_type=audio   sample_rate=48000   channels=2
duration=5.016000   size=27682
```

go2rtc's exec producer log confirms the conversion end to end:
```
17:47:29.326 DBG [exec] Stream mapping: Stream #0:0 -> #0:0 (pcm_s16le (native) -> opus (libopus))
17:47:29.375 DBG [exec]   Stream #0:0: Audio: opus, 48000 Hz, stereo, s16, 48 kb/s
17:47:29.374 DBG [exec] run rtsp launch=157.188778ms
```

**🟢 `mic` = `opus/48000/2`. Ring answered `opus/48000/2` (A2). Exact match.**

§1.6 warns `Codec.Match` compares name+rate+channels exactly and recommends an
`ffmpeg:mic#audio=opus` wrapper to transcode on demand. **Not needed here** — the
existing `mic` stream already lands precisely on Ring's negotiated codec, so the
backchannel can be fed with no transcode tax. Worth keeping the wrapper in mind
only if PipeWire's default source ever changes channel count.

Also note `launch=157ms` for the exec producer — far below §1.8's 2.1 s/4.1 s
cold-start warning, because this is a `lavfi`/pulse capture rather than a network
camera. The "pre-warm on popup open, not on press" advice may be less critical for
the mic side than the plan assumed.

### Step 2 — the stop call is real, and idempotent

§1.6 derives the stop from `Play()`'s source but never ran it. Now measured:

```sh
curl -X POST 'http://127.0.0.1:1984/api/streams?dst=mic&src='   # empty src
```
```
HTTP 200
body: {"producers":[{"url":"exec:ffmpeg -re -f pulse -i default …"}],"consumers":[]}
```
Repeat call: `HTTP 200`.

✅ **Confirmed:** the empty-`src` POST is accepted (not rejected as a malformed
request), returns 200, and is safe to call repeatedly — §1.6's trap-3 idempotency
claim holds. Rehearsed against `mic` rather than `ring` so nothing reached the
doorbell.

### Method note for future leak checks

`pgrep -fa ffmpeg` **self-matches** the `sh -c pgrep -fa ffmpeg` wrapper and
reports a false positive. Use `pgrep -a -x ffmpeg` (exact process name) for the
§7 item-4 leaked-ffmpeg check, or the 20-cycle test will look dirty when it is
clean.

---

## B2-equivalent — OUTBOUND AUDIO · 2026-08-08 18:11 UTC

# 🟢🟢 CONFIRMED BY EAR: SOUND CAME OUT OF THE DOORBELL SPEAKER.

Owner, standing at the front door: **"I heard the tone at the door."**

Combined with A2/A2b, **full two-way audio+video with the Front Door doorbell is
working through go2rtc's `ring:` source, as shipped, unpatched, on 1.9.14.**

### Attempt 1 — failed, and the failure is a finding

```sh
src=exec:ffmpeg -re -f lavfi -i sine=... -f rtsp {output}
```
```
start -> HTTP 400
body: streams: source from insecure producer
```

**go2rtc refuses `exec:` sources supplied over the API** — it would be arbitrary
command execution via HTTP. `exec:` is only honoured from the config file. This is
not in the plan and it constrains the Panel's design: **the Panel can never hand
go2rtc an arbitrary `exec:` command at talk time.** Any exec-based producer must be
pre-declared in `go2rtc.yaml`.

Owner heard nothing during this attempt — correctly, since no audio was ever
generated. A null result, not a negative one.

### Which `src` forms the API accepts

| `src` | Result | Note |
|---|---|---|
| `mic` | **HTTP 500** `streams: unsupported scheme: mic` | ✅ §1.6 trap 2 **confirmed** — a bare stream name is rejected; it needs a scheme |
| `exec:…` | **HTTP 400** `source from insecure producer` | 🔴 **New.** Not in the plan |
| `ffmpeg:mic#audio=opus` | **HTTP 200** | ✅ §1.6's recommended form works |
| `ffmpeg:/tmp/tone.wav#audio=opus` | **HTTP 200** | the one used below |
| `rtsp://127.0.0.1:8554/mic` | **HTTP 200** | also viable |

The insecure-producer guard blocks `exec:` but **not** `ffmpeg:`.

### Attempt 2 — the successful push

```sh
# 14s 880 Hz tone, generated inside the container
ffmpeg -f lavfi -i sine=frequency=880:sample_rate=48000:duration=14 -ac 2 -c:a pcm_s16le /tmp/tone.wav

# ring producer brought up first by an inbound consumer, then:
curl -X POST -G 'http://127.0.0.1:1984/api/streams' \
  --data-urlencode 'dst=ring' \
  --data-urlencode 'src=ffmpeg:/tmp/tone.wav#audio=opus'
```

```
start -> HTTP 200
body: {"producers":[{"id":52,"format_name":"ring/webrtc","protocol":"ws+udp",
       "remote_addr":"54.213.119.18:48909 host",
       "url":"ring:?device_id=90486cf35236&camera_id=319156885&refresh_token=<REDACTED>",
       "sdp":"v=0\r\no=- 3494852903 1786212672 IN IP4 0.0.0.0\r\ns=-\r\nt=0 0\r\n
              a=group:BUNDLE 0 1\r\n …
```

```
18:11:11.548 DBG [rtsp]    new consumer stream=ring
18:11:12.584 DBG [streams] start producer url=ring:?…&refresh_token=<REDACTED>
18:11:19.598 DBG [exec] run rtsp args=["ffmpeg","-hide_banner","-v","error",
   "-readrate_initial_burst","0.001","-re","-i","/tmp/tone.wav",
   "-c:a","libopus","-application:a","lowdelay","-min_comp","0","-vn",
   "-user_agent","ffmpeg/go2rtc","-rtsp_transport","tcp","-f","rtsp",
   "rtsp://127.0.0.1:8554/4e48bf3e8d19ea9c75b9808aaa675e6c"]
18:11:19.724 DBG [exec] run rtsp launch=126.17195ms
>>> STOP 18:11:35Z
stop -> HTTP 200
```

Note go2rtc's own transcode profile for the backchannel:
`-c:a libopus -application:a lowdelay -min_comp 0` — it selects Opus **lowdelay**
mode automatically. Producer `id=52`, `format_name=ring/webrtc`, `protocol=ws+udp`,
peered to **`54.213.119.18`** (AWS us-west-2 — Ring's cloud). Wrapper launch
**126 ms**.

### Teardown verified after the fact

```
stray ffmpeg (pgrep -a -x ffmpeg): (none — clean)
/api/streams?src=ring:  {"producers":[{"url":"…<REDACTED>"}],"consumers":[]}
```

No `id`/`sdp`/`remote_addr` on the producer entry ⇒ **not connected**. 🟢 **No ghost
producer** (§1.8 / #1961 / #1933 did not reproduce), **no leaked ffmpeg**.

### What this proves, and what it retires

| Plan position | Status |
|---|---|
| §1.10 row 4 — go2rtc `ring:` *"Currently no — blocked at the stall"* | 🔴 **Wrong. It is the working answer.** |
| §1.10 row 1 — bespoke `@tsightler/ring-client-api` service, *"the recommended path"* | **Unnecessary.** Track B solves a problem that does not exist |
| §1.10 row 3 — patch UA + self-build | **Unnecessary** (A1 + this) |
| Track C / Scrypted | **Unnecessary** |
| §1.11 — *"talkback requires a native go2rtc source carrying a backchannel"* | ✅ **Upheld, and satisfied** — `ring:` *is* that native source |
| §1.6 — stop is `dst=<stream>&src=` (empty) | ✅ **Confirmed empirically**: HTTP 200, idempotent, clean teardown |
| §1.4 — speaker activation (`stealth_mode:false`) is mandatory and one-shot | ✅ Implicitly confirmed — go2rtc's `AddTrack` did it correctly; audio was **not** silently discarded |

**Consequence for the Panel:** §1.7's recommendation stands and gets simpler —
`_startTalking()` / `_stopTalking()` become two HTTP POSTs to go2rtc. **No bespoke
service, no second container, no fork, no new dependency.**

### 🔴 Incident — partial credential exposure by this session

While probing the `src` forms, an ad-hoc command printed the raw `/api/streams`
body **without the redaction filter** used everywhere else in this file. A
**~115-character prefix** of the 1204-character refresh token was printed into the
session transcript.

- **Scope:** truncated by `head -c 200`; under 10% of the token. Not reconstructable
  into a working credential.
- **Cause:** the redaction discipline lived in the prepared scripts, and was dropped
  when a quick one-off command was run outside them. Exactly the ADR-0010 G3 shape:
  a credential inside a *URL value*, printed for an unrelated reason.
- **Action:** owner advised to re-mint the lab token (§2.3). Re-minting invalidates
  the exposed one regardless of when it happens.
- **Process fix:** every command touching `/api/streams` must pipe through
  `sed -E 's/(refresh_token=)[^&"]*/\1<REDACTED>/g'` — including one-liners.

### Still not proven

1. **The live microphone.** The tone proves the *path*; it does not prove the mic
   end-to-end or intelligibility. The `mic` stream is separately proven to produce
   `opus/48000/2` (prep step 1), so the remaining risk is low — but §7 line 1 says
   *"someone at the front door hears this laptop's microphone"*, and that is
   untested.
2. **§7 line 4** — 20 press/release cycles with no leaked ffmpeg and no ghost
   producer. Two cycles are clean; twenty are not yet run.
3. **Echo cancellation** (§1.8) — still entirely unresearched, and now the single
   largest open design question.
4. **Duplex behaviour** — the tone was pushed while an inbound consumer was
   running, but nobody verified inbound audio stayed intact *during* the push.

---

## B3-equivalent — LIVE MICROPHONE · 2026-08-08 18:15 UTC

# 🟢🟢 CONFIRMED: "I heard my microphone."

Owner, at the front door. **§7 line 1 is satisfied** — *"Someone standing at the
front door hears this laptop's microphone."*

### Method — a solo-verifiable loop

Laptop speakers play a distinctive alternating 700/1400 Hz beep pattern → laptop
mic captures it → go2rtc pushes `mic` to the doorbell → owner hears it at the door.
One person can run it; no second helper, no reliance on ambient room noise.

```sh
curl -X POST -G 'http://127.0.0.1:1984/api/streams' \
  --data-urlencode 'dst=ring' \
  --data-urlencode 'src=rtsp://127.0.0.1:8554/mic'
```

**`src=rtsp://…/mic`, not `ffmpeg:mic#audio=opus`** — since `mic` is already
`opus/48000/2` and Ring negotiated `opus/48000/2`, this is a **passthrough with no
re-encode**: better quality and lower latency than routing through the `ffmpeg:`
wrapper. Confirmed working.

### Result

```
>>> START MIC PUSH 18:15:32Z  (passthrough, no re-encode)
start -> HTTP 200
{"producers":[{"id":63,"format_name":"ring/webrtc","protocol":"ws+udp",
  "remote_addr":"54.213.119.18:58525 host", …
>>> BEEPS PLAYING 18:15:47Z
>>> beeps finished  18:16:03Z
>>> STOP 18:16:06Z
stop -> HTTP 200
```

go2rtc's mic pipeline, from its own log:
```
18:15:32.341 [exec] Input #0, pulse, from 'default':
             Stream #0:0: Audio: pcm_s16le, 48000 Hz, stereo, s16, 1536 kb/s
18:15:32.342 [exec] Stream mapping: pcm_s16le (native) -> opus (libopus)
18:15:32.389 [exec] Output: Audio: opus, 48000 Hz, stereo, s16, 48 kb/s
18:15:32.389 [exec] run rtsp launch=167.38225ms
```

### Objective corroboration — not just "I heard it"

The `mic` stream was captured in parallel and measured:

```
mean_volume:    -22.6 dB
max_volume:       0.0 dB
histogram_0db:     2372
```

22.0 s of `pcm_s16le/48000/2`. Silence would read ≈ −91 dB. **The mic demonstrably
carried the signal**, independent of the human report.

*(Method note: the first attempt at this measurement printed nothing because
`ffmpeg -v error` suppresses `volumedetect`, which logs at info level. Use
`-hide_banner` without `-v error`.)*

### 🔴 A hard data point for the echo-cancellation question (§1.8)

`max_volume: 0.0 dB` with **2372 clipped samples**. Laptop speakers at 100% into
the same chassis' microphone **saturated the input**.

§1.8 flags AEC as unresearched, with Panel speaker and mic ~30 cm apart. This
measurement says the coupling in that geometry is not marginal — it is strong
enough to clip. **Any duplex design that plays the visitor's voice out of a speaker
next to an open mic will feed it straight back to the doorbell.** That pushes AEC
(PipeWire `echo-cancel`) or half-duplex (mute the speaker while talking) from
"open question" to "required", and it is now the largest unresolved item.

*(Caveat: this measured laptop-speaker → laptop-mic coupling deliberately, as the
test signal. It is a proxy for the Panel's geometry, not a measurement of it.)*

### Teardown

```
stray ffmpeg (pgrep -a -x ffmpeg): (none — clean)
/api/streams: {"mic":{…,"consumers":[]},"ring":{…,"consumers":[]}}
```

Neither producer shows `id`/`sdp`/`remote_addr` ⇒ both disconnected. 🟢 Clean, for
the third consecutive cycle.

---

# SUMMARY — the investigation's answer

**Full two-way audio + video with the Front Door doorbell works today through
go2rtc's `ring:` source, as shipped, unpatched, on the container already running.**

| §7 "done" criterion | Status |
|---|---|
| 1. Someone at the door hears this laptop's mic | ✅ **Proven** (B3, by ear + −22.6 dB measurement) |
| 2. This laptop shows their video and plays their voice | ✅ **Proven inbound** (A2b: 300 frames + Opus). Not yet *played* to speakers |
| 3. Start and stop both proven, repeatable, survive the service dying | 🟡 Start/stop proven and idempotent; "survives the service dying" untested |
| 4. 20 press/release cycles leave no leaked ffmpeg / no ghost producer | 🟡 **3 of 20.** All three clean |
| 5. Written up, directory deleted, outcome in TODO.md or an ADR | ⬜ This file; the ADR is not written |

### The recommended path, revised

**Option 4 in §1.10 — "go2rtc `ring:` as shipped", ranked last and marked
"Currently no" — is the answer.** Track B, Track C and the private fork are all
unnecessary. `_startTalking`/`_stopTalking` become:

```
START  POST /api/streams?dst=ring&src=rtsp%3A%2F%2F127.0.0.1%3A8554%2Fmic
STOP   POST /api/streams?dst=ring&src=
```

### Remaining work

1. **Echo cancellation** — now the biggest item, with measured evidence it matters.
2. **The 20-cycle leak test** (§7 line 4).
3. **Duplex verification** — inbound audio intact *during* an outbound push.
4. **Dead-man switch / watchdog** — §1.8's "no idle timeout on internal producers"
   still stands; nothing observed here contradicts it.
5. **Re-mint the lab token** (credential-exposure incident above).
6. **Write the ADR** and delete this directory.

---

# ITEM 1 — Echo cancellation · investigated 2026-08-08 18:30–18:45 UTC

§1.8 left AEC as *"an unresearched open question"*. This closes it with
measurements rather than opinion.

## 1.0 First, an architecture correction that makes this tractable

§1.7 and §1.8 both discuss "the Panel's speaker and mic". `CONTEXT.md` settles
what that means:

> **Appliance:** The always-on computer hosting the Hub **and** driving the Panel —
> the Intel dev laptop during development, the Ryzen AI mini PC in production.

**The Hub and the Panel are the same machine.** go2rtc's `mic` capture and the
Panel's speaker therefore live in one PipeWire graph, which is why a local AEC can
work at all. Had they been separate boxes, no amount of AEC would have helped —
the reference signal would have been on the wrong machine.

## 1.1 🔴 The echo problem does not exist yet — and that reframes its priority

The Panel has **no audio code** and plays MJPEG, *"a format that carries no audio
by construction"* (§1.7). Inbound audio playback — plan step **B4** — was never
built. Nothing on this machine currently plays the visitor's voice out of a
speaker.

**So there is no echo path today.** The talkback proven earlier in this file is
unaffected by any of what follows. **AEC is a prerequisite for B4, not for the
push-to-talk that already works.** It should be scheduled with B4, not ahead of it.

## 1.2 Capability inventory — everything needed is already installed

| Component | Status |
|---|---|
| PipeWire | **1.6.2** |
| WirePlumber | **0.5.13** |
| `libpipewire-module-echo-cancel.so` | ✅ present |
| `spa-0.2/aec/libspa-aec-webrtc.so` | ✅ present — the **full WebRTC AEC**, not just speexdsp |
| `libwebrtc-audio-processing-1.so.3` | ✅ 1.3-3build2 |
| `monitor.mode` support in this build | ✅ present in the 1.6.2 binary |

WebRTC tunables exposed by the plugin: `webrtc.gain_control`,
`webrtc.noise_suppression`, `webrtc.high_pass_filter`,
`webrtc.transient_suppression`, `webrtc.voice_detection`, `webrtc.mobile_mode`.

Module arguments, read from the binary rather than documentation:
`remote.name`, `node.latency`, `audio.rate`, `audio.channels`, `audio.position`,
`library.name`, `aec.args`, `capture.props`, `source.props`, `sink.props`,
`playback.props`.

**Nothing needs installing.** No sudo, no new packages.

## 1.3 Test rig — non-invasive by construction

A **second, standalone PipeWire instance** hosting only the echo-cancel module,
adapted from the stock `/usr/share/pipewire/filter-chain.conf` module-host
skeleton and run as `pipewire -c <conf>`. It creates `aec_sink` / `aec_source` /
`aec_capture` / `aec_playback`, and everything vanishes when the process is killed.

**The user's running PipeWire was never restarted, no persistent config was
written, and the hardware sink/source volumes were left at their baseline
(1.00 / 0.27) — verified after teardown.** Only the *virtual* sink's own volume
was adjusted.

Method: record the **raw hardware mic** and the **AEC-cleaned source**
*simultaneously* while one beep pattern plays, so the delta is attributable to the
AEC alone rather than to run-to-run variation.

*Two method traps worth recording:* `pw-play`/`pw-record --target <numeric id>`
silently mis-targets — **use node names**. And the module only processes when
**both** sides have clients; with nothing reading `aec_source`, the sink→playback
path stays idle and produces no sound at all (this produced a completely null
first run).

## 1.4 Measurements

### Run A — realistic level (`aec_sink` 0.6, hw sink 1.00)

| | Raw hw mic | AEC source | Δ |
|---|---|---|---|
| Overall RMS | **−30.3 dBFS** | **−48.3 dBFS** | **18.0 dB** |
| Peak | **−2.0 dBFS** | **−19.4 dBFS** | **17.4 dB** |
| Loudest 0.5 s window | **−14.3 dBFS** | **−36.2 dBFS** | **21.9 dB** |
| Noise floor | ≈ −45 dBFS | ≈ −65 dBFS | 20 dB |

**ERLE ≈ 18–22 dB.**

### Run B — low level (`aec_sink` 0.22)

Raw mic showed **no beep pattern above the room-noise floor** (all windows
−42…−45, flat). The echo was already inaudible before any cancellation.
No ERLE measurable. Useful negative: **the coupling is strongly level-dependent**,
and at modest playback volumes the problem largely self-solves.

### Run C — near-end preservation (signal played to the hw sink, bypassing `aec_sink`)

The AEC has no reference for this signal, so it must treat it as the operator's
own voice. If the AEC crushed it, outbound audio would arrive at the doorbell too
quiet — which would make AEC a cure worse than the disease.

| | Raw hw mic | AEC source | Δ |
|---|---|---|---|
| Peak | −2.8 dBFS | −6.2 dBFS | **3.4 dB** |
| Loudest 0.5 s window | −14.8 dBFS | −28.4 dBFS | 13.6 dB |

**Discrimination:** echo peak attenuated **17.4 dB**, near-end peak attenuated only
**3.4 dB** → roughly **14 dB of genuine echo-vs-voice discrimination**. The AEC is
really cancelling, not merely turning everything down. The 20 dB noise-floor drop
is `webrtc.noise_suppression` and is a **bonus** for voice clarity.

## 1.5 Interpretation — AEC helps, but is not sufficient alone

- **~20 dB of echo suppression is real but modest.** Comfortable intercoms
  generally want 30–40 dB before the far end stops hearing itself. A residual at
  **−36 dBFS is audible**.
- **The mic clipped at −2.0 dBFS at realistic playback levels.** Clipping is
  nonlinear, and *no linear echo canceller can model a nonlinearity* — this caps
  what any AEC can achieve here, and it is a property of the hardware geometry,
  not of the algorithm.
- **Double-talk was not tested.** It is where AECs are weakest, and it is exactly
  the case a doorbell conversation produces.

## 1.6 🟢 Recommendation — half-duplex primary, AEC as a complement

**1. Half-duplex is the answer, and it is nearly free.** The Panel's control is
already a *hold-to-talk* button — `_PushToTalkButton` in
`panel/lib/ui/device_popup.dart:933` with `onStart`/`onStop`, and
`panel/test/device_popup_test.dart:1028` describes *"holding the button"*. While
the button is held, **mute or duck the inbound playback**. That removes the echo
path *by construction* rather than attenuating it statistically, it matches how
every intercom and walkie-talkie behaves, and it needs no AEC at all.

Implementation notes: mute **before** the mic starts and unmute **after** it stops,
with a short guard interval, or the speaker's tail leaks into the first packets.
Ducking to ≈ −30 dB rather than hard mute keeps some situational awareness.

**2. Enable the WebRTC AEC anyway, as defence in depth.** It costs nothing (already
installed), it buys ~20 dB during any overlap the guard intervals miss, and its
noise suppression measurably cleans the outbound voice (floor −45 → −65 dB).
Change go2rtc's `mic` stream to capture from the cleaned source:

```yaml
mic: >-
  exec:ffmpeg -re -f pulse -i aec_source -c:a libopus -b:a 48k
  -rtsp_transport tcp -f rtsp {output}
```

**3. Keep playback volume moderate.** Run B showed the echo vanishing below the
noise floor at low level. This is the cheapest lever available and it is worth
setting a sane default cap rather than shipping at 100%.

**4. `monitor.mode = true` is worth evaluating for integration.** It captures the
default sink's monitor as the reference instead of requiring playback to be routed
through a virtual sink — considerably simpler to wire, since inbound audio could
then go to the normal sink. Not measured here; Runs A–C used the explicit
virtual-sink form.

## 1.7 🔴 Integration gap this surfaced — the appliance has no audio stack at all

`appliance/ansible` provisions packages, the `cage` user, PAM and the kiosk unit.
A grep across `appliance/` for `audio|pulse|pipewire|speaker|sound` returns
**nothing relevant**. And per `appliance/README.md`, the production Appliance runs
**Ubuntu Server 24.04, "no desktop environment at all"** — so PipeWire is not
merely unconfigured, it is likely absent, with no user session to host it.

Consequences to plan for, none of them blocking today's result:

- PipeWire + WirePlumber + `libspa-0.2-modules-extra` (which carries the AEC
  plugin) must be provisioned for the appliance, and run as a **user service for
  the kiosk user**, which is a `nologin` system account — that needs
  `loginctl enable-linger` or a system-wide PipeWire instance.
- `hub/dev/ring-audio-test/compose.yaml` mounts
  `${XDG_RUNTIME_DIR:-/run/user/1000}/pulse` — **UID 1000 is the dev user.** The
  kiosk user's UID differs, so the production mount path is not the same value.
- The dev laptop works today only because it runs a full desktop session.

**This is a larger unknown than the echo cancellation itself**, and it belongs in
the ADR.

## 1.8 Caveats on these numbers

- Measured on the **dev laptop's own chassis**, speaker and mic ~10 cm apart —
  *tighter* coupling than §1.8's 30 cm Panel geometry, so ERLE there should be no
  worse. But the production Ryzen mini PC will have entirely different
  speaker/mic hardware, and these numbers do not transfer to it.
- Test signal was **tones, not speech**. Speech has different spectral and
  temporal statistics; WebRTC's AEC is tuned for speech and may perform better.
- **Double-talk untested** — and it is the case half-duplex is chosen to avoid.

---

# §7 item 4 — 20 press/release cycles · 2026-08-08 18:42 UTC · ✅ PASS

Run against the **re-minted** token (`sha=a25026d42a3b`, distinct from the leaked
`6ae67df50dae`; correct `eyJy` envelope, 1204 chars).

```
baseline ffmpeg: 0
after cycle  5: ffmpeg procs = 0
after cycle 10: ffmpeg procs = 0
after cycle 15: ffmpeg procs = 0
after cycle 20: ffmpeg procs = 0
cycles done  start 200s=20/20  stop 200s=20/20
all 40 calls returned 200
ffmpeg procs now: 0   (none — clean)
/api/streams: mic consumers[] , ring consumers[]  — no live producer
```

✅ **40/40 calls returned 200. Zero ffmpeg accumulation at every checkpoint. No
ghost producer.** §7 line 4 is satisfied.

**Unplanned bonus:** the inbound consumer died early in this run (see below), so
the ring producer was torn down and re-established by *each* cycle — meaning this
inadvertently exercised **20 consecutive Ring live-call setups/teardowns** rather
than 20 pushes into one call. All succeeded. No sign of the rate-limiting that
HA core#167406 documents for multiple Ring clients. Stronger evidence than
intended, though not a test worth repeating deliberately.

⚠️ **Caveat on what the 200s prove.** `POST …&src=…` returns 200 once `Play()`
accepts the source; it does not by itself prove Ring answered the call each time.
The leak/ghost findings are solid; "20 successful Ring calls" is inferred.

---

# §7 item 3 — Duplex · 2026-08-08 18:45 UTC · ✅ PASS

**Question:** does inbound video+audio survive while outbound pushes start and stop?

### v1 failed to produce evidence — recorded so it is not mistaken for a pass

The first attempt's capture died ~6 s in, *before* the cycles began
(`handle error=EOF` 18:42:40 vs cycles starting 18:42:46):

```
[h264] non-existing PPS 0 referenced
[h264] no frame!
[out#0/matroska] Could not write header (incorrect codec parameters ?)
```

The consumer attached before the H.264 parameter sets arrived and gave up.
**Fix: warm the producer with a throwaway dial first**, and use
`-analyzeduration 10M -probesize 10M`. Worth knowing for the Panel — a video
consumer that attaches at the wrong moment can fail this way at startup.

### v2 — the real result

```
capture file size after 8s: 1048576 bytes
  cycle 1: start=200 stop=200  capture now 2359296 bytes
  cycle 2: start=200 stop=200  capture now 4194304 bytes
  cycle 3: start=200 stop=200  capture now 6029312 bytes
  cycle 4: start=200 stop=200  capture now 7340032 bytes
  cycle 5: start=200 stop=200  capture now 9175040 bytes
```

```
duration=50.040000   size=15414603
index=0 h264  video
index=1 opus  audio  channels=2
video frames: 1200
inbound audio: mean_volume -29.7 dB   max_volume 0.0 dB
ffmpeg procs: 0 ; ring consumers[] , no live producer
```

✅ **Inbound survived.** The capture ran its full 50.04 s with **both** tracks
intact and **1200 video frames**, and the file grew **monotonically across every
one of the five push cycles** — inbound never stalled, dropped a track, or
renegotiated. Outbound start/stop is transparent to the inbound consumer.

Minor decode noise (`left block unavailable`, one `Error parsing Opus packet
header`) — consistent with joining mid-GOP and occasional loss; not fatal, and
the stream continued.

### 🔴 An observation that deserves follow-up, stated as a hypothesis

Inbound audio measured **max_volume 0.0 dB** — clipping. No test tone was played
locally during this run, so the loud inbound content is either genuine outdoor
noise, or **our own pushed audio returning via the doorbell's own speaker→mic
path**.

If the latter, there is a **second echo loop that half-duplex on our side does not
fix**: our mic → doorbell speaker → doorbell mic → back to us. Ring's hardware
presumably has its own AEC (it is a two-way product), and the visitor-facing
direction is what matters most — but this was not isolated and should be checked
before anyone concludes the echo question is fully closed. **Not claimed as a
finding; flagged as unverified.**

---

# DECISION — accepted by the owner, 2026-08-08

Owner: *"I'm agree with the recommendation."*

**Adopted:** go2rtc's native `ring:` source as shipped, driven by two HTTP POSTs,
with **half-duplex push-to-talk as the primary echo control** and the WebRTC AEC
enabled as defence in depth.

Recorded as **ADR-0011**. Scope boundary respected: no changes made to the Panel,
Ansible, the appliance, compose files, or the Hub stack — those remain the owner's
gate per §7 and the standing instruction.

### §7 scorecard at close

| # | Criterion | Status |
|---|---|---|
| 1 | Someone at the door hears this laptop's mic | ✅ by ear + −22.6 dB measurement |
| 2 | This laptop shows their video and plays their voice | 🟡 inbound **received** (1200 frames + Opus); **playback to speakers not built** (plan step B4) |
| 3 | Start and stop proven, repeatable, survive the service dying | 🟡 start/stop proven + idempotent; **"survives the service dying" still untested** |
| 4 | 20 cycles, no leaked ffmpeg, no ghost producer | ✅ 40/40 · 0 procs |
| 5 | Written up; outcome in an ADR; directory deleted | 🟡 this file + ADR-0011 written; **directory not yet deleted** |

### Carried forward (not done here, and outside this lab's scope)

1. **B4** — play inbound audio to the Panel's speakers. This is what *creates* the
   echo path; AEC and half-duplex ship with it, not before it.
2. **The appliance has no audio stack at all** (§1.7 above) — the largest
   remaining unknown, bigger than the echo question.
3. **Watchdog / dead-man switch** — §1.8's "no idle timeout on internal producers"
   was never contradicted; nothing here closes it.
4. **Panel wiring** — `_startTalking`/`_stopTalking`, `_TalkCaption`.
5. **Delete `hub/dev/ring-audio-test/` and this directory** once ADR-0011 is
   accepted. Note `ring-audio-test/go2rtc/go2rtc.yaml` still holds a live token
   in-tree, contrary to ADR-0010.

---

# B4 — INBOUND PLAYBACK · 2026-08-08 18:59–19:06 UTC · ✅ WORKS

**Goal:** hear the visitor. Doorbell audio out of this machine's speakers.

## The command

Run inside the go2rtc container, which already has the PipeWire/Pulse socket
mounted and `PULSE_SERVER` set:

```sh
docker exec go2rtc-ring-test ffmpeg -nostdin -hide_banner -v error \
  -rtsp_transport tcp -analyzeduration 10M -probesize 10M \
  -i rtsp://127.0.0.1:8554/ring -vn \
  -f pulse -device default 'ring-doorbell'
```

✅ **Confirms §1.7's claim** — *"the Pulse socket already mounted for capture also
carries playback with no compose change."* No compose edit was needed. Verified in
the graph:

```
91. Lavf62.3.100
     74. output_FR  > ALC287 Analog:playback_FR  [active]
     80. output_FL  > ALC287 Analog:playback_FL  [active]
```

`-analyzeduration 10M -probesize 10M` and a warm-up dial are needed for the same
reason as the duplex capture — a consumer attaching before SPS/PPS arrive dies
with `non-existing PPS 0 referenced`.

## 🔴 The silence, and two wrong turns worth recording

Initial samples read **mean −90.3 dB / max −71.2 dB** — digital silence, not a
live mic's noise floor. Two hypotheses were formed and **both were wrong**:

1. ~~The `max 0.0 dB` inbound seen during the duplex run was our own audio
   returning via the doorbell's speaker→mic path.~~ **Refuted by timing:** that
   audio ran t≈41–50 s while the pushes ran t≈8–35 s — *after* they stopped.
2. ~~Audio doesn't start until ~40 s into a call.~~ **Refuted by a push-free 100 s
   call**, which contained a −11 dB spike at t≈92 s and a low rise at t≈20–28 s
   with no push at all.

### The actual explanation: Ring gates the audio hard

| Sample | Result |
|---|---|
| 12 s, quiet street | mean −90.3 dB, max −71.2 dB |
| 15 s, quiet street | mean −90.3 dB, max −72.2 dB |
| 100 s, push-free | baseline −88…−93 dB, one −11 dB burst at t≈92 s |
| 50 s duplex capture | −99/−100 dB for 41 s, then real audio |

**A quiet environment transmits as near-digital-silence; real sound arrives in
bursts.** The audio track is always negotiated (`opus/48000/2` present in every
capture) — it simply carries nothing when there is nothing to carry.

The silent outbound push added to trigger `camera_options{stealth_mode:false}`
(§1.4) turned out to be **unnecessary** — audio flows without it. Harmless, but
not the mechanism.

## The verification — owner spoke at the doorbell

Session t=0 = 19:04:09Z, 0.5 s windows:

```
t=0 … 9.5s  : -92 -93 -92 -92 -93 … -94        silence
t=9.5 … 35s : -14 -38 -12 -16 -13 -7 -12 -10 -8 -6 -11 -9 -8 -14 -10 -16 -9 …
t=35s …     : -91 -90 -89 -88 -87              silence
```

**Peak −6.0 dBFS, overall RMS −17.0 dBFS.** Rapid level variation with natural
gaps — the signature of speech — beginning and ending exactly with the owner's
trip to the door. ✅ **A person at the front door is captured at a healthy level
and reaches this machine.**

The captured segment was then replayed through the speakers so the owner could
judge intelligibility directly, having been at the door during the live pass.

## 🔴 Design consequences — these change the Panel's behaviour

1. **Silence is normal and must not be reported as failure.** `_TalkCaption` and
   any "audio connected" indicator must not infer a broken stream from a quiet
   line. §1.8/ADR-0007 already argue the UI must not lie about state; this is a
   concrete instance. A **level meter** driven by actual sample levels would
   communicate honestly where a boolean cannot.
2. **Do not use audio presence as a health check.** A watchdog that restarts the
   stream on "no audio" would restart constantly on a quiet street.
3. Ring's gating means **no VAD of our own is needed** on the inbound side.

## Still to do on this path (per ADR-0011)

Playback currently goes to the **default sink**. ADR-0011 requires it to go to
the AEC's sink so the canceller has its reference, with the `mic` stream reading
from `aec_source`, plus **ducking playback while the talk button is held**. None
of that is wired yet — and per §7 it is gated on the owner, since it touches
`go2rtc.yaml`'s `mic` line and needs a persistent PipeWire AEC config.

**Also unchanged:** the appliance has no audio stack at all (§1.7 above), so none
of this runs on the production box yet.

---

# B4b — 🔴 CLIPPING: Ring's audio exceeds full scale, and naive playback distorts it

Owner's verdict on B4: *"it does work… I can hear my test by the door… an actually
some sound spikes/pitches that makes a bit hard to understand speaking. But
inbound playback 100% works."*

**The artifacts are ours, not Ring's, and they are fixable.**

## Diagnosis

Two candidates were measured against each other:

| Suspect | Evidence | Verdict |
|---|---|---|
| Opus packet damage | **one** `Error parsing Opus packet header` in a 50 s capture | ❌ not the cause |
| Clipping | `histogram_0db: 90464` in a 28 s clip — ~1.7 % of 5.38 M samples pinned at full scale | ✅ **the cause** |

Hard clipping generates broadband harmonic distortion — precisely the "spikes and
pitches" described.

## Root cause — a general trap for *any* Ring audio consumer

**Opus decodes to float, and this stream's true peak is ≈ +2.8 dBFS** — above full
scale. Ring's AGC runs hot, and lossy codecs add inter-sample overshoot. Proof:
attenuating 6 dB before the 16-bit conversion yields `max_volume −3.2 dB` and the
`histogram_0db` line **disappears entirely** — so the float signal is *not* itself
hard-clipped; the damage is introduced by the conversion.

And the live path had exactly the same defect:

```
$ ffmpeg -h muxer=pulse
    Default audio codec: pcm_s16le.
```

**ffmpeg's pulse muxer defaults to `pcm_s16le`**, so the B4 playback command was
clipping in real time, not only in the recordings.

## Measured fix

| Path | max_volume | top-bucket samples |
|---|---|---|
| A — opus → s16 direct (what B4 ran) | 0.0 dB | **3472** — hard-clipped |
| B — opus → float → `volume=-3dB` → pulse | −0.2 dB | 50 — none clipped |
| opus → float → `volume=-6dB` | −3.2 dB | **0** |

`alimiter` was also tried and only halved it (3472 → 1612): a 5 ms attack lets
transients through. **Static headroom beats a limiter here.**

### The corrected inbound command

```sh
ffmpeg -nostdin -hide_banner -v error \
  -rtsp_transport tcp -analyzeduration 10M -probesize 10M \
  -i rtsp://127.0.0.1:8554/ring -vn \
  -af "volume=-6dB" -c:a pcm_f32le \
  -f pulse -device default 'ring-doorbell'
```

`-c:a pcm_f32le` keeps the chain in float so there is no 16-bit stage to clip
against (the pulse muxer accepts it — verified), and `volume=-6dB` gives real
margin rather than the 0.2 dB that `-3dB` leaves.

## 🔴 Method error worth recording

The limiter was first applied to `yv.wav`, a file **already clipped at capture
time**, and unsurprisingly changed nothing (90464 → 90636). A limiter prevents
clipping; it cannot undo it. Any correction must act **before** the s16
conversion, in the float domain. The owner's voice recording is permanently
damaged and cannot be repaired — only re-captured.

**Consequence for the record:** every dB figure measured from a `pcm_s16le`
capture in this file is taken from a clipped signal. The *relative* comparisons
(ERLE, echo vs near-end, speech vs silence) remain valid because both sides of
each comparison were clipped identically, but absolute peak figures reading
`0.0 dB` should be read as "at or above full scale", not as true peaks.

## For the ADR

This is not specific to our pipeline: **Ring's audio can exceed 0 dBFS, so any
consumer that converts to 16-bit without headroom will distort it.** Worth
capturing so the Panel's eventual implementation — and anyone reusing the `mic`
or `ring` streams — does not rediscover it.

---

# B4c — Audio quality: what the artifacts actually are

Owner, on the first clean playback: *"it sounds like I was speaking and half of
sounds become high pitch metallic sound"*, and *"still a lot of spikes"*.

Six variants were tried against one 42 s recording of the owner speaking at the
door. **This section exists mostly to stop the next person re-running them.**

## 🔴 Clipping was a real defect but NOT the cause of the artifacts

Established, and then falsified as the explanation:

| Finding | Value |
|---|---|
| True peak (float) | **+8.6 dBFS** |
| Samples above full scale | **159 182 / 4 032 000 = 3.9 %** |
| Flat factor (float) | **0.0** — source not hard-clipped; the damage is ours |
| RMS | −12.3 dB · crest factor ≈ 21 dB |

So any 16-bit conversion without headroom really does distort. **But the
loudness-normalised render — `max_volume −1.5 dB`, zero clipped samples — still
had the spikes.** Clipping is a genuine bug worth fixing; it is not what the
owner is hearing.

⚠️ **My −6 dB recommendation in B4b was wrong** and is superseded. It was
calibrated against a +2.8 dBFS peak measured from a short, quiet clip; louder
speech peaks at **+8.6 dBFS**, so −6 dB still clipped. This is why the float
capture mattered — a 16-bit recording hides the true peak behind a flat 0.0 dB
ceiling, and every earlier `max_volume: 0.0 dB` in this file should be read as
"at or above full scale", not as a true peak.

## The variants, and the owner's verdicts

| # | Chain | Measured | Verdict |
|---|---|---|---|
| raw | opus → s16 | mean −12.4, 159 182 clipped | harsh |
| — | flat `volume=-10dB` | mean −22.6, clean | *"not better but opposite"* — too quiet |
| — | `loudnorm=I=-16:TP=-1.5` | mean −21.4, max −1.5, clean | *"still has the spikes"* |
| — | `acompressor`+`alimiter` | loud, clean | *"a little bit better"* |
| **D** | **mono + `lowpass=7000` + compress** | 455 → **229** impulsive events | ✅ *"easier understand… more recognizable speech"* |
| E | D + `adeclick` | 229 → 217 (5 %), re-clipped | ✗ *"same as D or maybe slightly worse"* — **dropped** |

**D is the configuration.** Level-based fixes (attenuation, loudness
normalisation) all failed; the two things that worked were **mono downmix** and
**low-passing the artifact band**.

## Why D works — two measured facts

**1. Ring's "stereo" is one microphone duplicated.** The L−R difference measures
**−91.0 dB** — the channels are identical. So `pan=mono` is **lossless**: it
discards no information and averages down the decorrelated coding noise between
the two channels. Roughly half of Ring's bitrate is spent encoding a redundant
copy.

**2. "High pitch metallic" is codec starvation, and the lowpass removes its
band.** Speech intelligibility lives below ~7 kHz; Opus's musical noise at low
bitrate lives above it. Cutting there costs clarity nothing and removes the
artifact.

## Root cause — DTX plus a starved encoder

Live producer stats during a call:

```
medias:  video, recvonly, H264
         audio, recvonly, OPUS/48000/2
         audio, sendonly, OPUS/48000/2      <- the backchannel
receivers: opus  bytes 17186  packets 181   (~12 s)
```

**181 packets in ~12 s ≈ 15/s, against Opus's normal 50/s.** Ring uses **DTX
(discontinuous transmission)** — it sends nothing during silence.

That single fact explains three separate observations in this file: the −90 dBFS
"digital silence" on a quiet street (B4), the abrupt −91 dB → −15 dB window
transitions, and the impulsive events — **DTX on/off transitions are a classic
click source**. Together with ~38 kbit/s spread across a pointless stereo pair,
it accounts for the artifacts without invoking packet loss.

⚠️ **Loss was not ruled out.** go2rtc exposes no `packets_lost`/`nack`/`jitter`
counters on the ring producer, so this is an inference from DTX being sufficient,
not proof that loss is absent.

## The recommended inbound chain

```sh
ffmpeg -nostdin -hide_banner -v error \
  -rtsp_transport tcp -analyzeduration 10M -probesize 10M \
  -i rtsp://127.0.0.1:8554/ring -vn \
  -af "pan=mono|c0=0.5*c0+0.5*c1,highpass=f=90,lowpass=f=7000,\
acompressor=threshold=-20dB:ratio=3:attack=5:release=80:makeup=8,alimiter=limit=0.95" \
  -c:a pcm_f32le -f pulse -device default 'ring-doorbell'
```

Do **not** add `adeclick`. Do **not** use flat attenuation.

## 🔴 SUPERSEDED — "negotiate mono to double the bits per channel"

This section originally proposed forking go2rtc to offer mono, arguing that
~38 kbit/s was being split across a redundant stereo pair. **That was wrong, and
it was tested and disproved — see B4e below.** Ring already sends mono. There are
no bits to reclaim.

**Everything post-processing can do has been done.** The residual spikes are
damage inflicted before the audio reaches this machine.

---

# B4d — Is it the recording or the playback? (owner's question)

A fair challenge: every fix above assumed the artifacts were in the captured
audio. That was never isolated. It has now been.

## The playback chain is innocent

Suspicion was raised that the Bose QC35 II might be in **HSP/HFP** — mono,
band-limited, and a textbook source of "metallic". The presence of a
`bluez_input` source seemed to support it, since A2DP is output-only.

**That inference was wrong.** The active profile is high quality:

```
api.bluez5.codec   = aac
api.bluez5.profile = a2dp-sink
```

Modern PipeWire exposes the input node regardless; the profile is what matters,
and it is A2DP/AAC. A synthetic-tone control file was also played through the
identical chain as a positive control.

## The recording is faithful

The artifacts are measurable **in the captured data**, and none of them can be
introduced downstream by a player:

| Evidence | Implication |
|---|---|
| 455 impulsive events in a render with **zero** clipped samples | not our clipping, not our level handling |
| L−R = **−91 dB** (bit-identical channels) | property of Ring's encode, not playback |
| ~15 Opus packets/s vs a normal 50 | Ring's DTX, measured at the receiver |
| −90 dBFS digital silence between phrases | present in the bitstream |

The capture was `pcm_f32le` — float, with no 16-bit stage to clip against — so it
is lossless relative to what go2rtc delivered.

## Conclusion

**Order of damage: Ring's encoder and transmission → capture → playback.** The
artifacts are already present when the audio arrives. Re-running the recording
would faithfully capture the same damaged audio, so it is not worth doing.

The only capture-side change with real upside is **negotiating mono in the SDP**
(above), which needs the go2rtc fork ADR-0011 rejected. Everything else has been
tried and measured.

*(B4e disproved this. Ring already sends mono; there is no upside.)*

---

# B4e — The mono SDP fork: BUILT, TESTED, DISPROVED · 2026-08-08

Owner asked to try the fork rather than leave it as speculation. Good call — it
was wrong, and only building it showed why.

## What was built

go2rtc **v1.9.14** cloned and patched, binary compiled with Go 1.25 and dropped
into the stock `alexxit/go2rtc:1.9.14` image replacing only
`/usr/local/bin/go2rtc` — so ffmpeg and everything else stayed byte-identical and
the SDP offer was the single changed variable. Run as `go2rtc-ring-mono` on the
same ports and the same config (the stereo container was **stopped** first: two
instances sharing one refresh token would rotate it apart).

Three attempts were needed:

1. **`Channels: 2 → 1`** in `pkg/ring/client.go:179`. Binary verified running by
   sha256. **No effect** — the offer still said `opus/48000/2`.
2. **`FmtpLine: "…;stereo=0;sprop-stereo=0"`** on the same codec. Build failed
   because the author's commented-out debug prints are **stale** — uncommenting
   `fmt.Printf(... string(rawMsg))` in `ws.go:240` leaves `rawMsg` undefined (its
   declaration is commented too) and `encoding/json` unimported. *(Worth knowing
   before anyone runs plan §A5, which instructs exactly this uncomment.)*
   🔴 **My build script did not fail on the compile error**, so it silently
   redeployed the previous binary and produced a meaningless "unchanged" result.
   Fixed by gating on build success and comparing sha256 of built vs running.
3. **Fixed build**, with the offer SDP printed and the author's debug prints live.

## What the SDP actually says — the decisive evidence

**Our offer:**
```
m=audio 9 UDP/TLS/RTP/SAVPF 101 0 8
a=rtpmap:101 opus/48000/2
a=fmtp:101 minptime=10;useinbandfec=1
a=sendrecv
```

**Ring's answer:**
```
m=audio 9 UDP/TLS/RTP/SAVPF 101
a=rtpmap:101 OPUS/48000/2
a=fmtp:101 useinbandfec=1
a=sendonly            <- the backchannel
```

### Finding 1 — `core.Codec.FmtpLine` is ignored on this path

The offer carries pion's default `minptime=10;useinbandfec=1`. **The
`stereo=0;sprop-stereo=0` never reached the wire.** The WebRTC offer is generated
from pion's `MediaEngine` registration, not from the `core.Codec` struct
`pkg/ring` builds. Changing it in `pkg/ring` cannot work; a real attempt would
have to patch `pkg/webrtc`'s media-engine registration.

### Finding 2 — 🟢 Ring already sends mono, so there is nothing to win

Per **RFC 7587**, `stereo` and `sprop-stereo` both **default to 0** when absent.
Ring's answer omits both. **Ring is declaring a mono stream.** The `/2` in the
rtpmap is Opus's mandatory SDP convention and is *not* a channel count.

This also explains the bit-identical L/R (−91 dB) measured in B4c: a mono Opus
stream rendered by the decoder as dual-mono.

**So the premise was false.** No bitrate is being spent on a second channel, and
a mono offer would reclaim nothing. The metallic artifacts are simply what Ring's
encoder produces at its chosen bitrate with DTX — not a channel-layout problem.

### Finding 3 — 🔴 correction to the plan's §1.11

The plan states: *"go2rtc offers only Opus 48k stereo, hardcoded, with no PCMU
fallback. If this doorbell answers PCMU, go2rtc has nothing to negotiate."*

**The offer is `m=audio … 101 0 8` — payload 0 is PCMU and 8 is PCMA.** go2rtc
*does* offer both, via pion's default media engine. That candidate stall cause
never existed. (Ring chose 101/Opus and dropped both.)

## Outcome

**ADR-0011's rejection of the private fork stands, on stronger evidence than
when it was written.** It was rejected as unnecessary maintenance cost; it is now
also known to be *ineffective* — the one quality improvement it was being held
open for does not exist.

Environment fully reverted: `go2rtc-ring-mono` removed, `mic` back to stereo,
stock `alexxit/go2rtc:1.9.14` running (binary sha `60384f15…` vs patched
`3ef919bc…`). The patched tree remains in the session scratchpad only — nothing
in the repo was changed.

**Inbound audio quality is therefore at its ceiling.** D's mono downmix +
7 kHz lowpass remain the correct mitigation, and the residual artifacts are
Ring's, permanently.

*(B4f overturns this. The artifacts are NOT Ring's — see below.)*

---

# B4f — 🔴 THE ARTIFACTS ARE OURS, NOT RING'S · 2026-08-08

## The observation that changes everything

Owner rebooted the doorbell, cleaned its microphone, and ran a **control through
the Ring app** — someone at the door, owner talking back:

> *"There was no any metallic sounds but I noticed the sound was a bit
> unnatural."*

Same doorbell, same encoder, same AGC and noise suppression. **The Ring app has
no metallic artifacts; our path does.** The "unnatural" quality is Ring's own
AGC + noise suppression and is expected.

**Therefore the metallic artifacts are introduced on our side.** Every conclusion
in B4c/B4e that blamed Ring's encoder is wrong.

## Four measurements, and what each killed

### 1. No packet loss, and it is NOT DTX

Per-2-second receiver stats during continuous speech:

```
t=  4s   17.5 pkt/s   13.5 kbit/s     (quiet)
t= 30s   17.5 pkt/s   62.7 kbit/s     (speech)
t= 60s   17.5 pkt/s   63.3 kbit/s
t= 72s   17.5 pkt/s   28.9 kbit/s
```

**The packet rate never varies** — 17.0–19.0/s throughout, silence and speech
alike. Loss would show dips; DTX would drop to zero in silence. Ring sends
packets continuously and varies **bitrate** instead.

🔴 **Corrects B4c**, which attributed the low packet count to DTX. It is
packetisation: 17.5/s ≈ one packet per ~57 ms, i.e. **~60 ms Opus frames** rather
than the usual 20 ms.

### 2. The bitrate is healthy — "starved encoder" is dead

**60–70 kbit/s during speech**, mono. That is good quality territory for Opus.
🔴 **Corrects B4c's "~38 kbit/s starved encoder" claim.**

### 3. 🔴 The decoder emits impossible values — a real defect

Float capture of 100 s of speech:

```
NaN: 0    Inf: 0
|v| > 1.0 : 42272  (0.4403%)
max finite: 2172442.75   (+126.7 dBFS)
```

Values six orders of magnitude past full scale, in **10 829 separate impulse
runs** (~108/s). Not audio — the signature of an Opus decoder whose internal
state has diverged. The **same stream captured as a raw Opus bitstream
(`-c:a copy`) and decoded offline peaks at only +3.6 dBFS**, so the frames are
sane and the live path is producing the garbage.

**But repairing all 42 272 samples by interpolation did NOT fix the metallic
sound** — owner: *"still sounds like playing E before. A lot of high pitch
metallic sounds."* So these impulses are a genuine bug **and** a red herring for
the metallic quality. Both things are true.

### 4. Not reordering, and no comb structure

`-reorder_queue_size 500 -max_delay 2000000` vs default, 30 s ambient each:
**0 out-of-range samples in both.** (Ambient only — the impulses appear during
speech, so this is not conclusive, merely unhelpful.)

Spectral analysis of a speech segment:
- **No comb notches** — spectral autocorrelation peaks at 58–105 Hz, which is
  just voice harmonics.
- Smooth rolloff, content to 12 kHz, no spectral holes.
- **Frame-to-frame spectral variance 25–29 dB in every band** — the signature of
  *musical noise*, which is what "metallic" sounds like.

## Where this leaves the diagnosis

Known: the damage is on our side, it is not loss, not bitrate, not clipping, not
reordering, and not (only) the impulse bug. It looks like spectral/musical noise.

**Two candidate culprits remain, and neither has been tested:**

1. **go2rtc's WebRTC→RTSP repackaging.** Everything measured so far came through
   `rtsp://127.0.0.1:8554/ring`. go2rtc's own **web UI serves the same stream over
   WebRTC**, bypassing that repackaging entirely.
   → `http://localhost:31984/stream.html?src=ring`. If that is clean, the RTSP
   path is the culprit and the fix is local.
2. **go2rtc's `pkg/ring` RTP handling of Ring's unusual ~60 ms Opus frames.**
   Tested by comparing against a completely independent client — the plan's
   **`probe/probe.mjs`** (`@tsightler/ring-client-api`), which exists in this
   directory but has never been run because **§2.3's separate token was never
   minted**. It must be its own token; sharing go2rtc's would rotate them apart.

---

# B4g — 🟢 ROOT CAUSE FOUND: go2rtc's RTSP output corrupts Ring's Opus

## The decisive observation

Owner opened go2rtc's own web UI — `http://localhost:31984/stream.html?src=ring`,
which serves the stream over **WebRTC** — and reported:

> *"it sounds clean. The sounds was PERFECT!"*

**Same doorbell, same go2rtc process, same moment, same Wi-Fi.** WebRTC output is
perfect; RTSP output is metallic. go2rtc *receives* Ring's audio correctly — its
**WebRTC→RTSP repackaging** is what destroys it. Every measurement in B4a–B4f went
through RTSP, which is why nothing upstream ever helped.

Wi-Fi ruled out too: owner reports **RSSI −66 dBm**, and the WebRTC path is
flawless over that same link.

## Proof that the frames — not the decode — are corrupted

The same RTSP stream captured two ways simultaneously during 50 s of speech:

| | out-of-range | peak | rms | spectral-std |
|---|---|---|---|---|
| **A** decoded live | 50 944 | +67.8 dB | +16.0 dB | 58.6 dB |
| **B** `-c:a copy`, decoded **offline** | **50 944** | **+67.8 dB** | **+16.0 dB** | 58.9 dB |

**Bit-for-bit identical.** Decoding the stored frames at leisure produces exactly
the same damage, so this is not jitter, timing, buffering or decoder scheduling —
**the Opus frames delivered over RTSP are already corrupt.**

`rms = +16 dB` means the *average* sample is above full scale. That is not audio.

Likely mechanism: Ring sends **~60 ms Opus frames** (17.5 packets/s). go2rtc's
RTSP RTP packetiser very probably assumes conventional 20 ms framing and
mis-splits them. This is a genuine **upstream go2rtc bug**, consistent with
`pkg/ring` being abandoned since 2025-05-21.

## Escape routes tested and closed

| Route | Result |
|---|---|
| `?audio=pcma` / `pcmu` / `aac` on the RTSP URL | **404** — go2rtc will not transcode for RTSP output |
| `/api/stream.mp4?src=ring` | *"Output file does not contain any stream"* — the MP4/MSE muxer cannot carry Opus |
| RTSP over UDP | **461 Unsupported transport** — go2rtc's RTSP server is TCP-interleaved only |
| `-reorder_queue_size` / `-max_delay` | no change |
| `ffmpeg:ring#audio=…` transcode stream | would consume `ring` over RTSP internally — same corrupt path |

**Only WebRTC carries Ring's Opus intact.** `/api/webrtc?src=ring` exists (returns
500 to a deliberately malformed offer, not 404).

## Also learned: the doorbell has its own AEC

An attempt to loop audio out of the doorbell speaker so its mic would feed speech
back returned **−84.5 dB — silence**. Ring's hardware cancelled its own speaker
output from its microphone. Good news for the duplex design, and it means
loopback cannot be used as a test signal generator.

## What a fix looks like

*(Superseded by B4h below — the fix turned out to be free. Left for the record.)*

1. A headless WebRTC→PulseAudio bridge consuming `/api/webrtc?src=ring`.
2. Fix go2rtc's Opus RTP packetiser and run a fork.
3. Panel-side WebRTC — rejected by §1.7 on Linux-freeze grounds.

---

# B4h — 🟢🟢 SOLVED: it is **ffmpeg's** Opus depacketiser, not go2rtc

## The test

The same RTSP stream consumed **simultaneously** by two different clients during
50 s of speech at the door:

| Client | out-of-range | peak | rms | spectral-std |
|---|---|---|---|---|
| **ffmpeg** | **36 642** | +34.9 dB | −14.4 dB | 56.5 dB |
| **GStreamer** | **0** | **0.0 dB** | −34.7 dB | **15.4 dB** |

```
gst-launch-1.0 rtspsrc location=rtsp://127.0.0.1:38554/ring protocols=tcp latency=200 ! \
  queue ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! ...
```

**Zero corrupt samples, bounded peak, and spectral variance down from 56.5 dB to
15.4 dB** — the musical-noise signature is gone. Owner confirmed by ear:
*"the playback is good. no any extra pitch sounds."*

Speech was verified present in the capture (20.5 s above −45 dBFS between
t=15.5 s and t=54 s, loudest window −21.3 dBFS), so this is a like-for-like
comparison, not a quiet-stream artefact.

## Root cause

**ffmpeg's RTP Opus depacketiser mishandles Ring's ~60 ms Opus frames.**
GStreamer's `rtpopusdepay` handles them correctly. go2rtc is **exonerated** — its
RTSP output is fine; the consumer was wrong all along.

This also explains B4g's "identical A/B" result: both A and B were captured *by
ffmpeg*, so both carried the same depacketiser damage. That test correctly proved
the damage was in the frames as ffmpeg produced them — I wrongly attributed those
frames to go2rtc.

## 🔴 Corrections to earlier sections of this file

| Claim | Status |
|---|---|
| B4c: "artifacts are Ring's, permanently" | **Wrong** — ffmpeg's depacketiser |
| B4c: DTX / starved encoder / wasted stereo | **Wrong** — packet rate constant, 60–70 kbit/s, already mono |
| B4b: clipping is the cause | **Wrong** — a real but separate bug |
| B4f: "go2rtc's WebRTC→RTSP repackaging corrupts the frames" | **Wrong** — go2rtc's RTSP is fine |
| B4f: decoder impulses (+126 dBFS) | **Real, and explained** — they were the depacketiser's corrupt frames decoding to garbage |
| B4c/D: mono downmix + 7 kHz lowpass | **No longer needed.** They masked corruption that no longer exists; keeping them would only cost fidelity |

Five wrong theories before the right one. The thing that finally cracked it was
the owner's own control — testing the Ring app and go2rtc's WebRTC page — which
proved the audio was clean *somewhere*, and turned an open-ended "why is Ring bad"
into a bounded "which of our components breaks it".

## The corrected inbound command

```sh
gst-launch-1.0 rtspsrc location=rtsp://127.0.0.1:38554/ring protocols=tcp latency=200 ! \
  queue ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! \
  pulsesink client-name=ring-doorbell sync=false
```

No filters, no headroom tricks, no fork, no new component — and it plays straight
to PulseAudio. **Do not use ffmpeg to consume `ring`'s audio over RTSP.**

⚠️ **This applies to the outbound path too, and is untested there.** The `mic`
stream is an `exec:ffmpeg` producer, so ffmpeg is *packetising* rather than
depacketising and is likely unaffected — but talkback was only ever verified by
ear, never measured. Worth re-checking with the same rigour.

⚠️ **Worth reporting upstream** to ffmpeg (or at least go2rtc), with the clean
reproduction this file now contains. It will bite anyone consuming a 60 ms-framed
Opus RTSP stream.

---

# 🔴 INCIDENT — a leaked consumer held the doorbell live for ~30 minutes

While probing go2rtc's alternate outputs, two `curl` processes were started
inside the container against `/api/stream.mp4` and `/api/stream.m3u8`. The
enclosing tool call timed out and was killed **on the host side**, but the
`curl` processes **kept running inside the container**:

```
consumer id:127  format:mp4  protocol:http  user_agent:"curl/8.17.0"
bytes_send: 159,882,785
```

**~160 MB pulled, and the Ring producer held open continuously for roughly half
an hour** — the doorbell in live view the whole time, on somebody's battery and
bandwidth, entirely unnoticed until a routine `/api/streams` dump showed it.

Cleaned with `pkill -9 -x curl` inside the container; verified only the intended
GStreamer consumer remained.

## Why this matters beyond the apology

This is **§1.8's warning happening for real**:

> *"go2rtc has no idle timeout on internal producers. Nothing closes a wedged mic
> for you. A server-side dead-man switch is mandatory, not optional."*

It was written about the outbound mic. It applies just as much to **inbound
consumers**: a dead or orphaned client keeps the Ring producer alive indefinitely,
and go2rtc will never reap it. Two concrete requirements follow:

1. **The watchdog must reap idle/orphaned consumers, not just stop the mic.** Any
   consumer with no live reader should be dropped, and the producer torn down when
   the last real consumer goes.
2. **Every probe or diagnostic must be time-bounded at the far end** — `timeout`
   inside the container, not merely on the calling side. A killed caller does not
   kill the work.

The teardown checks used throughout this file (`pgrep -a -x ffmpeg`,
`/api/streams` consumer counts) only ever looked for **ffmpeg**. They would never
have caught a stray `curl`. **Check the consumer list, not just the process
list.**

---

# B5 — OUTBOUND path, measured to the same standard · ✅ CLEAN

B4h left open whether ffmpeg's Opus bug also affects talkback. It does not, and
the reason is instructive.

## Method

Chain under test: `mic` → `exec:ffmpeg` (Opus encode + **RTP packetise**) →
go2rtc. Note the asymmetry — outbound, ffmpeg is the **packetiser**; the inbound
bug was in its **depacketiser**, a different code path.

A known reference (700/1400 Hz beeps) was played into the room so the microphone
captured a signal with known content, and the `mic` stream was then captured by
**both** clients simultaneously. Default source confirmed as
`44. Built-in Audio Analog Stereo` (the laptop mic, not the Bluetooth headset).

## Result

| Consumer of `mic` | out-of-range | peak | rms | spectral-std | 700 Hz | 1400 Hz | SNR |
|---|---|---|---|---|---|---|---|
| ffmpeg | **3** | +1.1 dB | −33.5 dB | 29.4 dB | 19.3 dB | 16.4 dB | ≈39 dB |
| GStreamer | **0** | −0.0 dB | −33.4 dB | 21.0 dB | 19.3 dB | 16.4 dB | ≈39 dB |

**Tone recovery is identical to the decimal in both clients**, at ~39 dB SNR. The
outbound chain delivers the reference signal intact.

ffmpeg's 3 out-of-range samples against **36 642** on the inbound path is the
difference between negligible and catastrophic.

## 🟢 This pins the root cause precisely

Our `mic` stream is encoded by ffmpeg with its **default ~20 ms Opus framing**, so
the depacketiser bug never triggers. Ring sends **~60 ms frames** (17.5 packets/s),
which is what breaks it.

**The bug is frame-size-specific.** That explains the whole asymmetry — outbound
was always fine, inbound was always destroyed, on the same machine, same codec,
same containers.

## What remains unmeasurable from here

The last hop — go2rtc → Ring over WebRTC → the doorbell's speaker — cannot be
instrumented from this machine; nothing on our side can hear what the speaker
emits. It is covered by the **subjective** end-to-end confirmation already on
record (owner at the door: *"i heard my microphone"*), and no metallic quality was
reported on that direction.

**Conclusion: outbound needs no change.** `src=rtsp://127.0.0.1:8554/mic` stays
as ADR-0011 specifies, and it does **not** need the GStreamer treatment inbound
requires.

## 🔴 ADR-0011 needs amending

The ADR does not yet mention inbound audio quality, but B4c/B4e's conclusion
("Ring's fault, at the ceiling, permanently") is recorded in this file and is
**wrong**. Do not carry it into the ADR. Inbound quality is an **open defect on
our side**, and its resolution may affect whether go2rtc remains the right
choice — which is exactly the kind of evidence ADR-0011's "re-check this decision
if" clause exists for.
