# TODO

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



cd /home/dmorozov/Work/SmartHome/panel

flutter run -d web-server --web-port 8080 --web-hostname 127.0.0.1 --profile \
  --dart-define=HUB=ha \
  --dart-define=HA_URL=http://localhost:8123 \
  --dart-define=HA_TOKEN="$(cat ~/.sh_keys/token)" \
  --dart-define=GO2RTC_URL=http://localhost:1984

Then open http://localhost:8080.

Four things in there are load-bearing:

- --profile — a debug web-server build loads its modules and then waits for a debug connection before running main(), which only the Dart Debug Chrome extension provides. No extension, no app: blank page, empty console. (Drop it only if you want breakpoints and have the extension.)
- ~/.sh_keys/token, not hub/dev/token — that's the production HA token. The dev one authenticates against :18123 and will just fail here.
- 8123 / 1984, not 18123 / 11984 — the dev stack is production + 10000, and the Wyze cameras only exist in production's go2rtc.
- localhost is correct because the browser dials HA and go2rtc, and the browser is on this machine. From inside the devcontainer you'd keep localhost for the same reason, but you'd be pointing at the dev stack.

Stop it with q in that terminal.

Sanity check if something looks wrong: the boot line prints [panel] I popup.go2rtc url=http://localhost:1984 — if that says url=absent, the GO2RTC_URL define didn't take and every tile will say "Not wired up yet" regardless of the config.
