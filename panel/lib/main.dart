import 'package:flutter/material.dart';

import 'data/demo_house.dart';
import 'data/fake_hub.dart';
import 'ui/dollhouse/dollhouse_view.dart';
import 'ui/hub_controller.dart';
import 'ui/theme.dart';

void main() {
  final house = demoHouse();
  runApp(PanelApp(
    controller: HubController(house: house, hub: FakeHub(house)),
  ));
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
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: PanelTheme.surfaceRaised,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: PanelTheme.raised(8),
                      ),
                      child: const Text(
                        'FAKE HUB',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                          color: PanelTheme.inkFaint,
                        ),
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
