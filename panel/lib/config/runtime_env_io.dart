import 'dart:io';

/// True wherever a process environment exists — everything except web.
/// Logged at boot so a run that expected `HA_URL=…` to be honoured and got
/// the default instead says so, rather than looking like a healthy FakeHub.
const environmentIsAvailable = true;

/// The real process environment — the appliance path.
///
/// `cage@.service` supplies it: `Environment=HUB=`/`HA_URL=` from ansible
/// vars, the same seam already used for `WLR_DRM_DEVICES`, and `HA_TOKEN`
/// from an `EnvironmentFile=` at mode 0600 — a secret must not sit on an
/// `Environment=` line, which `systemctl show` reads out to any local user.
/// See `appliance/ansible/roles/kiosk/`.
///
/// `kiosk_app` still launches the spike app, which ignores all three; the
/// wiring goes live unchanged when it points at the Panel bundle. This path
/// also serves `flutter run -d linux`, `flutter test`, and any hand-started
/// bundle.
Map<String, String> runtimeEnvironment() => Platform.environment;
