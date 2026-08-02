import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/fake_hub.dart';
import 'data/ha_hub.dart';
import 'data/house_loader.dart';
import 'data/hub_client.dart';
import 'diagnostics/log.dart';
import 'domain/house.dart';
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
  final house = _loadHouse(
    houseYaml: await rootBundle.loadString('assets/house/house.yaml'),
    devicesYaml: await rootBundle.loadString('assets/house/devices.yaml'),
  );
  runApp(PanelApp(
    controller: HubController(house: house, hub: _hub(house)),
  ));
}

House _loadHouse({required String houseYaml, required String devicesYaml}) {
  try {
    final house = loadHouse(houseYaml: houseYaml, devicesYaml: devicesYaml);
    final devices = [for (final floor in house.floors) ...floor.devices];
    Log.info('house', 'loaded', {
      'name': house.name,
      'floors': house.floors.length,
      'rooms': house.floors.fold<int>(0, (n, f) => n + f.rooms.length),
      'devices': devices.length,
      // Devices with no `entity:` can never show state — worth knowing at a
      // glance, without hunting through devices.yaml.
      'bound': devices.where((d) => d.entityId != null).length,
    });
    return house;
  } catch (error, stack) {
    // A malformed House Plan is fatal, and on the kiosk nobody is standing
    // in front of the red screen. Leave one greppable line on the way out.
    Log.error('house', 'invalid', error: error, stack: stack);
    rethrow;
  }
}

/// Which Hub the build talks to. Defaults to the in-memory [FakeHub]; pass
/// `--dart-define=HUB=ha` (plus `HA_URL` and `HA_TOKEN`) for a real Home
/// Assistant — see hub/dev/README.md.
const _hubKind = String.fromEnvironment('HUB', defaultValue: 'fake');

HubClient _hub(House house) {
  const which = _hubKind;
  if (which == 'fake') return FakeHub(house);
  if (which != 'ha') {
    throw ArgumentError('unknown HUB "$which" (fake | ha)');
  }
  const url = String.fromEnvironment('HA_URL',
      defaultValue: 'http://localhost:8123');
  const token = String.fromEnvironment('HA_TOKEN');
  // `set`, never the token itself: these lines end up in logs.
  Log.info('hub', 'configured',
      {'url': url, 'token': token.isEmpty ? 'absent' : 'set'});
  if (token.isEmpty) {
    throw ArgumentError('HUB=ha needs --dart-define=HA_TOKEN=<long-lived '
        'token>; keep it out of the repo (hub/dev/token)');
  }
  return HaHubClient(
    house: house,
    url: HaHubClient.webSocketUrl(url),
    token: token,
  );
}

class PanelApp extends StatelessWidget {
  const PanelApp({super.key, required this.controller});

  final HubController controller;

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
                        label: _hubKind == 'fake' ? 'FAKE HUB' : 'HUB',
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
