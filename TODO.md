# TODO

**IMPORTANT** This file should not be taken into account by AI agents!
It is for the future planning by the human, not by AI.
Reason: it is not prioritized and not cleanly defined.

Create a new user friendly documentation:

1. Configure / resolve network artifacts (search by MAC, giving names, Deco configuration, etc)
2. Integration API keys and App setup
- Ring doorbell
- Wyze cameras - RTSP
- Tesla wall charger
- Emporia
- ?
3. Configure HA
- Ring door bell integration
- Wyze cameras
- etc.
4. Run all required services (docker compose) 

Where to put all secrets?
~/.sh_keys/go2rtc/go2rtc.yaml


how to do backup for all keys / credentials?

1. Instructions of how to build HUB
2. How to build the flutter app
3. How to build the Sweet Home 3D plugin (our devices list to place in the house plan)

We need research for what the recommended cameras to work with HA:
- proper protocols easy to control
- support sound
- support different resolution / optimization for streaming.
i.e. low resolution for the dashboard and high resolution when open specific camera

cd /home/dmorozov/Work/SmartHome/panel

flutter run -d web-server --web-port 8080 --web-hostname 127.0.0.1 --profile \
  --dart-define=HUB=ha \
  --dart-define=HA_URL=http://localhost:8123 \
  --dart-define=HA_TOKEN="$(cat ~/.sh_keys/token)" \
  --dart-define=GO2RTC_URL=http://localhost:1984

or Linux (real HUB)

VIDEO_DECODERS=auto VIDEO_LOW_LATENCY=0 HUB=ha HA_TOKEN="$(tr -d '[:space:]' < ~/.sh_keys/token)" GO2RTC_URL=http://127.0.0.1:1984 flutter run -d linux --release

Then open http://localhost:8080.

Four things in there are load-bearing:

- --profile — a debug web-server build loads its modules and then waits for a debug connection before running main(), which only the Dart Debug Chrome extension provides. No extension, no app: blank page, empty console. (Drop it only if you want breakpoints and have the extension.)
- ~/.sh_keys/token, not hub/dev/token — that's the production HA token. The dev one authenticates against :18123 and will just fail here.
- 8123 / 1984, not 18123 / 11984 — the dev stack is production + 10000, and the Wyze cameras only exist in production's go2rtc.
- localhost is correct because the browser dials HA and go2rtc, and the browser is on this machine. From inside the devcontainer you'd keep localhost for the same reason, but you'd be pointing at the dev stack.

Stop it with q in that terminal.

Sanity check if something looks wrong: the boot line prints [panel] I popup.go2rtc url=http://localhost:1984 — if that says url=absent, the GO2RTC_URL define didn't take and every tile will say "Not wired up yet" regardless of the config.

### Manual evaluation between MJPEG-default and RTSP-default

One caveat recorded honestly in the handoff: the synthetic selftest pattern turned out to be a light workout (CPU settled near 0.6% and the position callbacks mostly stayed quiet — the same selftest oddity flagged in the first gauntlet), so the heavy-decode endurance evidence rests on the first soak's 20 clean minutes at ~55% CPU with five real cameras, plus your own live VIDEO_TRANSPORT=rtsp session. go2rtc's log was silent the whole window, so nothing server-side misbehaved — and on the wall, any real stall becomes a 15-second watchdog trip and a spaced ladder re-dial, which is now well-tested machinery.

Where that leaves the transport decision, which is yours: the two things standing between MJPEG-default and RTSP-default are your eyeball of the rounded-corner clipping in your live run, and your comfort with the evidence above. The flip itself is one line (defaultValue: 'rtsp' in main.dart), rollback is VIDEO_TRANSPORT=mjpeg in the environment — no rebuild — and after the flip has held for a while, N5's step 4 unlocks: retiring the five mjpeg/tiles transcodes from the live go2rtc config, which is the 52%→35% Hub CPU and ~450 MB memory win becoming permanent.

┌──────────────────────────────────────────────────┬────────────┬───────────────┐
│                       Path                       │ go2rtc CPU │ go2rtc memory │
├──────────────────────────────────────────────────┼────────────┼───────────────┤
│ MJPEG — 5 tile transcodes (today's shipped path) │ 52%        │ 573 MiB       │
├──────────────────────────────────────────────────┼────────────┼───────────────┤
│ RTSP — 6 stream copies (the new fvp path)        │ 35%        │ 117 MiB       │
├──────────────────────────────────────────────────┼────────────┼───────────────┤
│ Idle reference                                   │ 0%         │ 18 MiB        │
└──────────────────────────────────────────────────┴────────────┴───────────────┘

And the RTSP figure flatters MJPEG: those 35% included selftest's own ffmpeg pattern generator, so the camera-only cost of serving RTSP copies is lower still. The reason is structural — on the MJPEG path go2rtc runs one ffmpeg per watched stream, re-encoding H.264 into JPEG frames at 10 fps forever; on the RTSP path it just relays the camera's already-encoded H.264 bytes. That's also the ~7× difference on the Wi-Fi: ~186 kB/s per MJPEG tile versus roughly 25–30 kB/s for the substream's H.264.

Panel-side is the unmeasured cell: the fvp prototype cost ~55% of one core for six streams including software-GL rendering under Xvfb (a real GPU session renders cheaper), while the MJPEG Panel path was never run through the same harness — but it does a JPEG decode per frame per tile on the CPU by construction, so theory points the same direction. If you want that cell filled before flipping the default, the fair test is running your live Panel once per transport and comparing ps on the panel process — two minutes of work, say the word.




Test Plan:

Here's the plan. I verified the Panel-side facts myself; the Hub-side commands come from the readers and are yours to run — I have not executed anything against the live Hub.

Start here: tap one floodlight camera pin, cold, with the journal open

Every timing assertion in the 646 tests sits on FakeGo2rtc, which returns instantly. On your house a cold dial is 4–7 s for a plain Wyze v3 and 17–18 s for the two floodlight units, while the RTSP first-frame watchdog is 25 s and the stall watchdog 15 s. The most likely real breakage is a rung or a watchdog firing inside a dial that was still warming up — and because the popup role is health-blind, there's no offline park to fall into. It just climbs, forever, at two camera connections per failed dial on the 2.4 GHz band.

cd ~/Work/SmartHome/panel
HUB=ha HA_URL=http://127.0.0.1:8123 HA_TOKEN="$(tr -d '[:space:]' < ~/.sh_keys/token)" \
  GO2RTC_URL=http://127.0.0.1:1984 LOG=debug \
  flutter run -d linux --release 2>&1 | tee /tmp/panel-lead.log

LOG=debug is required — cameras.popup_retry is a D line. Then tap a floodlight pin and read:

- I cameras.popup_open → picture, no popup_failed, no popup_retry = pass.
- W cameras.popup_failed then D cameras.popup_retry attempt=1 in_s=5 on a healthy camera = the bug, and the one this change can actually introduce.

Five minutes, and it's the test I'd run every time.

The tiers below it

Tier 0 — hermetic, ~2 min, I can run it. flutter test (646 green) plus flutter build web as a dart2js gate. Proves the policy machine, the copy, the health arithmetic. Proves nothing about latency or anything past the video seam.

Tier 1 — the wall with no faults, ~10 min, yours. Same run line; tap each camera, close, confirm exactly one popup_open / one popup_closed reason=view_closed per visit and that go2rtc's consumer count returns to zero. Watch the census with a script that prints only counts — never paste /api/streams raw, it embeds the Ring token and camera passwords.

Tier 2a — force a ladder climb, ~10 min. The safest injector is Panel-side, not Hub-side: point one camera's stream: in panel/assets/house/bindings.yaml at a name go2rtc doesn't serve. Blast radius is one Device in one Panel process, no camera is dialled at all so it costs zero airtime, and git checkout -- assets/house/bindings.yaml reverts it. You should see attempt=1 in_s=5 → 2 in_s=15 → 3 in_s=60 and, on the glass, "Connecting… try N" — never "Reconnecting", because no picture was ever up. That's CameraFace's sawPlaying latch (panel/lib/ui/video/camera_face.dart, one copy for the Popup, the tile and the zoom since 2026-09-02) doing its job.

Tier 2b — the actual phase-2a feature, ~10 min. This is the one I'd not skip, because Camera Health writes no journal line at all (zero Log. calls in camera_health.dart — I checked), so a tile that dials when it should have stayed parked is the only evidence the feature works. Force one probe off via the HA states API, then: confirm the tile parks → tap that camera's pin and let it play → reopen the Cameras view and look for cameras.tile_open with no probe transition in front of it. If the tile stays parked for ~60 s, the evidence isn't landing (since 2026-09-02 there is no fallback Director for a Popup to get — every surface takes the Panel's, required). A free alternative with zero writes: your .63 and .57 cameras die and recover on their own, several times a day.

Tier 3 — audio across a re-dial, ~10 min, ears required. Scope it first so you don't test the wrong build: only the RTSP player has a real setMuted; MJPEG, MSE and settled sessions are all no-ops, and the doorbell can never reach the ladder anyway. So this is a Wyze camera Popup on the Linux bundle only. Open, hear it, kill that producer mid-watch, and listen at the moment the picture returns. Silent = the feed-level mute intent didn't reach the real player.

Tiers 4–5 — web/MSE and the freeze rig. Skip both on a normal day. One thing to know about the rig: it cannot open a Popup. CAMERAS_OPEN=auto is the only navigation knob in the codebase, there's no POPUP_OPEN, and no synthetic-input tool is installed — so it can only re-check that the Cameras wall still plays under Skia. Also a footgun I verified: kRtspRestreamPort is a compile-time 8554, so a -d linux run ignores the port in GO2RTC_URL and dials production go2rtc even when you point it at the dev sandbox.

One hole the exercise exposed, which I closed

Working through what proves what, the readers found that no test ever passed a real Director into a Popup — every green Popup case ran the fallback that builds its own. Drop director: from any of main.dart's forwarding sites and the Popup still plays, still logs the whole cameras.popup_* vocabulary, still ladders — while its Director has health: null, so Camera Health silently never hears from a Popup again and the census stops counting. Nothing went red.

There's now a test in dollhouse_test.dart that pumps the real PanelApp with a Director that has a health source, taps a camera pin, and asserts the outcome reaches that Director. I verified it by mutation: deleting director: from main.dart:437 fails it. 646 tests green, analyzer clean.

Closed for good on 2026-09-02 (the architecture review's candidate #1): `director` is required on every video surface, the two surface-built fallbacks and main()'s second VideoConfig are gone, and the tests build their one Director in `test/support/hermetic_director.dart` — the same seam the wall runs. A dropped `director:` is now a compile error, not a mutation a test has to catch.

The two open questions

Q1 (exit-window dial) is settleable in ~15 min and worth doing: set up the 2a bindings fault so it sits on the 5 s rung, then open-and-close the Popup ~5 s in, 10–20 times. The tell is a cameras.popup_open after the dismissal with its popup_closed under ~200 ms later — normal teardown is one open and one close seconds apart. Corroborate with the census: it goes 1 → 0 → 1 again with no Panel surface alive to explain it.

Q2 (MSE rebuild wording) is only partly settleable, in a browser, and how to force an MSE element rebuild on demand is not established. Worth knowing: the empirical answer tells you how often it happens, not what the copy should say — and the tile carries the identical rule, so changing one and not the other is the likelier regression.

Two things to know before you grep anything

The journal vocabulary changed: popup.stream_* is gone, the family is cameras.popup_*, reason=popup_closed is now view_closed, and go2rtc_unconfigured split into no_go2rtc_url / bad_go2rtc_url on all three prefixes. Any saved grep keyed on the old strings is silently dead. And doorbell testing genuinely costs: every fake ding opens a real Ring session, and an open session suppresses the next real ding — everything kind-independent here (ladder, copy, latch, mute intent, dialOutcome) is camera behavior, so test it on a Wyze.

The full plan, with the exact Hub-side commands, redaction one-liners, and blast radii, is at /tmp/claude-1000/-home-dmorozov-Work-SmartHome/f5552aa5-df42-4f78-881c-4faf650d8135/scratchpad/test-plan.md — say the word if you'd like it kept in docs/ instead of a temp dir.
