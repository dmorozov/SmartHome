import 'package:flutter/material.dart';

import '../domain/device_state.dart';
import '../domain/house.dart';
import 'theme.dart';

/// Popup — a transient overlay on the Panel (CONTEXT.md). Cameras and the
/// doorbell show a live-view placeholder (the go2rtc stream lands there in
/// phase 1); other Devices show their current state.
Future<void> showDevicePopup(
  BuildContext context, {
  required Device device,
  required DeviceState? state,
}) {
  final isVideo =
      device.kind == DeviceKind.camera || device.kind == DeviceKind.doorbell;
  final isLocal = device.connectivity == Connectivity.local;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (context) => Dialog(
      backgroundColor: PanelTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: PanelTheme.surfaceRaised,
                      shape: BoxShape.circle,
                      boxShadow: PanelTheme.raised(8),
                    ),
                    child: Center(
                      child: Icon(deviceIcon(device.kind),
                          color: PanelTheme.ink),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.name,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: PanelTheme.ink,
                          ),
                        ),
                        Text(
                          isLocal ? 'Local Device' : 'Cloud Device',
                          style: TextStyle(
                            fontSize: 12,
                            color: isLocal
                                ? const Color(0xFF4CAF7D)
                                : PanelTheme.inkFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (isVideo)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ColoredBox(
                      color: const Color(0xFF2A2F3E),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.videocam,
                                color: Colors.white38, size: 40),
                            SizedBox(height: 8),
                            Text(
                              'Live view placeholder — go2rtc stream',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              else
                Text(
                  statusText(state),
                  style:
                      const TextStyle(fontSize: 15, color: PanelTheme.ink),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String statusText(DeviceState? state) => switch (state) {
      SwitchState s => s.on ? 'On' : 'Off',
      GarageDoorState g => g.open ? 'Open' : 'Closed',
      ThermostatState t =>
        '${t.currentC.toStringAsFixed(1)} °C now · target ${t.targetC.toStringAsFixed(1)} °C',
      PowerState p => p.watts >= 1000
          ? '${(p.watts / 1000).toStringAsFixed(2)} kW'
          : '${p.watts.round()} W',
      StatusState s => s.status,
      null => 'Unknown',
    };
