import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'boot.dart';
import 'data/hub_client.dart';
import 'diagnostics/log.dart';
import 'ui/dollhouse/dollhouse_view.dart';
import 'ui/hub_controller.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Log.installErrorHandlers();
  Log.info('panel', 'start', {
    'hub': _hubKind,
    'mode': kReleaseMode
        ? 'release'
        : kProfileMode
            ? 'profile'
            : 'debug',
    'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    'log': Log.level.name,
  });
  // The House Plan (ADR-0004): generated geometry + hand-maintained devices.
  final boot = bootPanel(
    hubKind: _hubKind,
    hubUrl: _haUrl,
    hubToken: _haToken,
    houseYaml: await rootBundle.loadString('assets/house/house.yaml'),
    devicesYaml: await rootBundle.loadString('assets/house/devices.yaml'),
  );
  runApp(PanelApp(controller: boot.controller, hubLabel: boot.hubLabel));
}

/// Which Hub the build talks to. Defaults to the in-memory fake hub; pass
/// `--dart-define=HUB=ha` (plus `HA_URL` and `HA_TOKEN`) for a real Home
/// Assistant — see hub/dev/README.md.
const _hubKind = String.fromEnvironment('HUB', defaultValue: 'fake');
const _haUrl =
    String.fromEnvironment('HA_URL', defaultValue: 'http://localhost:8123');
const _haToken = String.fromEnvironment('HA_TOKEN');

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
