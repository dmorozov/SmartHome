import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/device_state.dart';
import '../../domain/house.dart';
import '../device_popup.dart';
import '../hub_controller.dart';
import 'floor_view.dart';
import 'iso.dart';

/// The Dollhouse: the house as stacked isometric Floors. One Floor is
/// expanded (full size, Device pins live); tapping a collapsed Floor
/// expands it instead.
class DollhouseView extends StatefulWidget {
  const DollhouseView({super.key, required this.controller});

  final HubController controller;

  @override
  State<DollhouseView> createState() => _DollhouseViewState();
}

class _DollhouseViewState extends State<DollhouseView> {
  late String _expandedFloorId;

  static const _collapsedScale = 0.45;
  static const _gap = 18.0;
  static const _anim = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    // Start with the lowest Floor (ground) expanded.
    _expandedFloorId = widget.controller.house.floors
        .reduce((a, b) => a.level <= b.level ? a : b)
        .id;
  }

  @override
  Widget build(BuildContext context) {
    final house = widget.controller.house;
    // Highest level first: upper Floors render above lower ones.
    final ordered = [...house.floors]
      ..sort((a, b) => b.level.compareTo(a.level));

    return LayoutBuilder(builder: (context, constraints) {
      // Fit to width, but never let the stack (one expanded + the rest
      // collapsed + gaps) overflow the height.
      final n = ordered.length;
      final gapsTotal = (n - 1) * _gap;
      final heightBudget = (constraints.maxHeight - gapsTotal) /
          (1 + (n - 1) * _collapsedScale);
      final isoWidth = math.min(
        constraints.maxWidth * 0.78,
        math.max(200.0, (heightBudget - FloorView.wallDepth) * 2),
      );
      final projection =
          IsoProjection.fitWidth(_unionPlanSize(house), isoWidth);
      final floorH = projection.size.height + FloorView.wallDepth;
      final left = (constraints.maxWidth - projection.size.width) / 2;

      final tops = <String, double>{};
      var y = 0.0;
      for (final floor in ordered) {
        tops[floor.id] = y;
        y += (floor.id == _expandedFloorId
                ? floorH
                : floorH * _collapsedScale) +
            _gap;
      }
      final topPad =
          ((constraints.maxHeight - (y - _gap)) / 2).clamp(0.0, double.infinity);

      return Stack(
        children: [
          for (final floor in ordered)
            AnimatedPositioned(
              key: ValueKey('floor-${floor.id}'),
              duration: _anim,
              curve: Curves.easeInOutCubic,
              left: left,
              top: topPad + tops[floor.id]!,
              child: GestureDetector(
                onTap: floor.id == _expandedFloorId
                    ? null
                    : () => setState(() => _expandedFloorId = floor.id),
                child: AnimatedScale(
                  duration: _anim,
                  curve: Curves.easeInOutCubic,
                  scale:
                      floor.id == _expandedFloorId ? 1.0 : _collapsedScale,
                  alignment: Alignment.topCenter,
                  child: AnimatedOpacity(
                    duration: _anim,
                    opacity: floor.id == _expandedFloorId ? 1.0 : 0.55,
                    child: FloorView(
                      floor: floor,
                      controller: widget.controller,
                      projection: projection,
                      expanded: floor.id == _expandedFloorId,
                      onRoomTap: widget.controller.toggleRoomLights,
                      onDeviceTap: (device) => _onDeviceTap(context, device),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }

  Size _unionPlanSize(House house) {
    var w = 0.0, d = 0.0;
    for (final floor in house.floors) {
      for (final room in floor.rooms) {
        w = math.max(w, room.bounds.right);
        d = math.max(d, room.bounds.bottom);
      }
    }
    return Size(w, d);
  }

  void _onDeviceTap(BuildContext context, Device device) {
    final state = widget.controller.stateOf(device.id);
    final isVideo = device.kind == DeviceKind.camera ||
        device.kind == DeviceKind.doorbell;
    if (!isVideo && (state is SwitchState || state is GarageDoorState)) {
      widget.controller.toggle(device.id);
    } else {
      showDevicePopup(context, device: device, state: state);
    }
  }
}
