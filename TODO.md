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




The frozen camera wall is FIXED (2026-08-28): the cause was the Impeller renderer, the Flutter 3.47 Linux default, and the runner now pins Skia — reasoning, what it rules out, and the re-check before any SDK upgrade are in docs/adr/0012-panel-renders-with-skia-on-linux.md. Left for you: file the two upstream drafts in docs/upstream/ under your own account (the flutter one wants your `flutter doctor -v`), and decide whether the ~9 MB evidence PNGs stay in git.