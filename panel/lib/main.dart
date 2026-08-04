import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'boot.dart';
import 'config/hub_config.dart';
import 'config/runtime_env.dart';
import 'data/hub_client.dart';
import 'diagnostics/log.dart';
import 'ui/dollhouse/dollhouse_view.dart';
import 'ui/hub_controller.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Log.installErrorHandlers();
  // Read once, handed to both resolvers: `main()` is the only thing in the
  // Panel that touches the process environment, which is what keeps
  // `bootPanel` and `Log` reachable from plain data in a test.
  final environment = runtimeEnvironment();
  // Before the first line is emitted, or `LOG=off` could not silence the
  // boot lines it is asked to silence. Environment first, like the Hub
  // settings below: turning the logs up on a Panel already on the wall must
  // not mean rebuilding it.
  final logFrom = Log.applyLevel(environment);
  // Runtime environment first, build defines second (config/hub_config.dart).
  // The Hub's address is an operational setting, not a property of the
  // binary: on the appliance systemd supplies it, so a Hub that moves costs
  // a restart rather than a Flutter rebuild.
  final config = resolveHubConfig(
    environment: environment,
    buildKind: _buildHubKind,
    buildUrl: _buildHaUrl,
    buildToken: _buildHaToken,
  );
  Log.info('panel', 'start', {
    'hub': config.kind,
    'mode': kReleaseMode
        ? 'release'
        : kProfileMode
            ? 'profile'
            : 'debug',
    'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    'log': Log.level.name,
    // Which origin set it — the same argument as `hub.config`: with two
    // possible origins, `log=info log_from=build` on a run that exported
    // LOG=debug is how a web build says the environment was discarded.
    'log_from': logFrom,
  });
  // Which origin won, per setting. With two possible origins, a Panel
  // pointed at a stale address and a Panel pointed at a dead Hub look the
  // same on the badge; this line is what separates them. Origins only — the
  // token's *value* never appears (log.dart: Never log a secret). `env=` says
  // whether a process environment existed at all, because on web it does not
  // and a discarded `HA_URL=…` otherwise looks like a healthy default.
  Log.info('hub', 'config', {
    ...config.logFields,
    'env': environmentIsAvailable ? 'available' : 'unavailable',
  });
  // An ambient variable beating the flag the operator typed is the one
  // genuinely surprising consequence of environment-first order. Warn, don't
  // fail: the environment is still the answer we want, just not silently.
  if (config.overridden.isNotEmpty) {
    Log.warn('hub', 'config_override',
        {'settings': config.overridden.join(','), 'winner': 'environment'});
  }
  // The House Plan (ADR-0005): everything drawn — geometry and Device
  // Placements — generated into house.yaml, joined with the hand-maintained
  // Hub bindings.
  final boot = bootPanel(
    hubKind: config.kind,
    hubUrl: config.url,
    hubToken: config.token,
    houseYaml: await rootBundle.loadString('assets/house/house.yaml'),
    bindingsYaml: await rootBundle.loadString('assets/house/bindings.yaml'),
  );
  runApp(PanelApp(controller: boot.controller, hubLabel: boot.hubLabel));
}

/// What this build was compiled with, or null where the define was omitted —
/// `bool.hasEnvironment` is what separates "not passed" from "passed the
/// same string the default would have used", which is what lets the boot log
/// name the real origin.
///
/// Defaults live in `config/hub_config.dart`, not here, so the environment
/// path and the build path cannot drift apart. Pass `--dart-define=HUB=ha`
/// (plus `HA_URL` and `HA_TOKEN`) for a real Home Assistant, or set the same
/// names in the environment — see hub/dev/README.md.
const String? _buildHubKind =
    bool.hasEnvironment('HUB') ? String.fromEnvironment('HUB') : null;
const String? _buildHaUrl =
    bool.hasEnvironment('HA_URL') ? String.fromEnvironment('HA_URL') : null;
const String? _buildHaToken =
    bool.hasEnvironment('HA_TOKEN') ? String.fromEnvironment('HA_TOKEN') : null;

class PanelApp extends StatelessWidget {
  const PanelApp({
    super.key,
    required this.controller,
    required this.hubLabel,
  });

  final HubController controller;

  /// What the Hub badge calls the Hub. Passed in rather than read from the
  /// build's dart-defines, so this widget knows nothing about which Hub it
  /// was compiled against — and so a test can render the production scene.
  final String hubLabel;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Panel',
      debugShowCheckedModeBanner: false,
      theme: PanelTheme.data(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      controller.house.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: PanelTheme.ink,
                      ),
                    ),
                    const Spacer(),
                    ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => _HubBadge(
                        label: hubLabel,
                        status: controller.status,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Tap a floor to expand · tap a room to toggle its lights · tap a device to act',
                  style:
                      TextStyle(fontSize: 12, color: PanelTheme.inkFaint),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) =>
                        DollhouseView(controller: controller),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hub reachability, always visible: a wall display has nobody watching a
/// console, so "these readings are frozen" must be legible from across the
/// room — and so must the difference between a Hub that will come back on
/// its own and a token only a human can replace.
class _HubBadge extends StatelessWidget {
  const _HubBadge({required this.label, required this.status});

  final String label;
  final HubStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: PanelTheme.surfaceRaised,
        borderRadius: BorderRadius.circular(20),
        boxShadow: PanelTheme.raised(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // One dot colour per severity, so the across-the-room read
              // stays binary: green = live, red = stale. Which kind of
              // stale is what the text is for.
              color: status == HubStatus.up
                  ? const Color(0xFF4CAF50)
                  : const Color(0xFFE05A5A),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            switch (status) {
              HubStatus.up => label,
              HubStatus.retrying => '$label OFFLINE',
              // Names the action, not the diagnosis: whoever is standing
              // there needs to know what to do, and nothing else will.
              HubStatus.gaveUp => '$label NEEDS NEW TOKEN',
            },
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: PanelTheme.inkFaint,
            ),
          ),
        ],
      ),
    );
  }
}
