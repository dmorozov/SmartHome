import 'dart:io';

/// True wherever a process environment exists — everything except web.
/// Logged at boot so a run that expected `HA_URL=…` to be honoured and got
/// the default instead says so, rather than looking like a healthy FakeHub.
const environmentIsAvailable = true;

/// The real process environment — the appliance path.
///
/// The intent is that `cage@.service` will carry `Environment=HA_URL=…`, the
/// same seam ansible already uses for `WLR_DRM_DEVICES`. **Not wired yet**:
/// the unit template sets no HA_* variables and `kiosk_app` still points at
/// the spike app, so today this path serves `flutter run -d linux`, `flutter
/// test`, and any hand-started bundle. See the phase-0 open items.
Map<String, String> runtimeEnvironment() => Platform.environment;
