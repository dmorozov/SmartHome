// Where the Panel loads its graphics engine from — and the reason this file
// exists at all rather than being generated.
//
// Flutter's default is `https://www.gstatic.com/flutter-canvaskit/<rev>/`.
// The house may have no internet, and measured 2026-08-06 in Chromium with
// every non-LAN host blocked, a build pointing there rendered a BLANK WHITE
// PAGE — not degraded text, nothing at all. See panel/README.md, "The web
// build must not need the internet".
//
// `--no-web-resources-cdn` fixes it too, and both `flutter build web` and
// `flutter run -d web-server` accept it. It is deliberately NOT the mechanism
// relied on here: it is a command-line flag, so it holds only for as long as
// every command anyone ever writes remembers it — a CI job, a systemd unit, a
// colleague's shell. Offline-capability is a property of this application, so
// it is spelled in the application's own source, where nothing can forget it.
// The flag stays documented as the officially-supported route and is harmless
// alongside this; `config.canvasKitBaseUrl` outranks it either way.
//
// Rejected: `--dart-define=FLUTTER_WEB_CANVASKIT_URL=/canvaskit/`. It is still
// read in Flutter 3.44 but it is no longer what chooses the base URL, and on
// its own it leaves `buildConfig.useLocalCanvasKit` unset — so the loader goes
// to gstatic anyway while looking configured. A trap, not an alternative.
//
// Relative `canvaskit/`, not `/canvaskit/`: the value resolves against
// `document.baseURI`, so the relative form keeps working if the app is ever
// served under a sub-path (`<base href="/local/panel/">`, which is what
// hosting it from Home Assistant's own `/local/` would need).
//
// The two placeholders below are substituted by the Flutter tool — this file
// is a template, and both `flutter run` and `flutter build web` honour it in
// place of the generated default. It carries no version-pinned content, so it
// does not need revisiting on a Flutter upgrade; the offline check in the
// README does.
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
  },
});
