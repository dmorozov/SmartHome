/// False on web: there is no process environment here.
///
/// Exposed as a const so `main()` can say so out loud. Without it, running
/// `HA_URL=… flutter run -d chrome` produces a Panel on `FakeHub` at
/// `localhost:8123` that looks exactly like a healthy default — the variables
/// were discarded, and nothing said so.
const environmentIsAvailable = false;

/// Web has no process environment. Returning empty (rather than throwing)
/// keeps the resolution rule identical on every platform: the environment
/// simply never supplies anything, so the build's dart-defines win.
Map<String, String> runtimeEnvironment() => const <String, String>{};
