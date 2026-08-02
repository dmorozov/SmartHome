import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';
import '../device_popup.dart';
import '../device_presentation.dart';
import '../hub_controller.dart';
import 'floor_view.dart';
import 'iso.dart';

/// The Dollhouse: the house as stacked isometric Floors. One Floor is
/// selected (full size, Device pins live); tapping a neighbour selects it
/// instead.
///
/// The arrangement below is the winner of the floor-drift prototype: at
/// most three Floors on stage, the neighbours shrunk and drifted into the
/// selected Floor's empty isometric corners — the one above up and to the
/// right, the one below down and to the left.
class DollhouseView extends StatefulWidget {
  const DollhouseView({super.key, required this.controller});

  final HubController controller;

  @override
  State<DollhouseView> createState() => _DollhouseViewState();
}

class _DollhouseViewState extends State<DollhouseView> {
  late String _expandedFloorId;

  static const _anim = Duration(milliseconds: 300);

  /// Scale of the neighbouring Floors.
  static const _neighbourScale = 0.32;

  /// Horizontal drift of a neighbour, as a fraction of the projected plan
  /// width: the Floor above goes right, the one below goes left.
  static const _driftFactor = 0.26;

  /// Vertical spacing between Floors as a fraction of the selected Floor's
  /// height. Negative: the neighbours overlap into its empty corners.
  static const _gapFactor = -0.225;

  /// The selected Floor is sized against this spacing rather than the real
  /// (negative) [_gapFactor] — otherwise pulling the neighbours in just
  /// frees up height that the selected Floor grows into, leaving them
  /// exactly as far away as they started.
  static const _sizingGapFactor = 0.03;

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

    final expandedLevel =
        house.floors.firstWhere((f) => f.id == _expandedFloorId).level;
    // At most three Floors are on stage: the selected one plus its immediate
    // neighbours. Anything further away waits off-stage until one of those
    // neighbours is selected and becomes the new centre.
    final onStage = [
      for (final floor in ordered)
        if ((floor.level - expandedLevel).abs() <= 1) floor
    ];
    double scaleOf(Floor floor) =>
        floor.id == _expandedFloorId ? 1.0 : _neighbourScale;

    return LayoutBuilder(builder: (context, constraints) {
      // Fit to width, but never let the on-stage Floors (one selected + up
      // to two neighbours + spacing) overflow the height.
      final scaleTotal = onStage.fold(0.0, (sum, f) => sum + scaleOf(f));
      final heightBudget = constraints.maxHeight /
          (scaleTotal + (onStage.length - 1) * _sizingGapFactor);
      final isoWidth = math.min(
        constraints.maxWidth * 0.78,
        math.max(200.0, (heightBudget - FloorView.wallDepth) * 2),
      );
      final projection = IsoProjection.fitWidth(house.planExtent, isoWidth);
      final floorH = projection.size.height + FloorView.wallDepth;
      final planW = projection.size.width;
      final left = (constraints.maxWidth - planW) / 2;
      final gap = floorH * _gapFactor;

      final tops = <String, double>{};
      var y = 0.0;
      for (final floor in onStage) {
        tops[floor.id] = y;
        y += floorH * scaleOf(floor) + gap;
      }
      final stackH = y - gap;
      final topPad =
          ((constraints.maxHeight - stackH) / 2).clamp(0.0, double.infinity);

      // Off-stage Floors are parked beyond the near edge (and faded out) so
      // selecting a neighbour slides the next one into view rather than
      // popping it in.
      double topOf(Floor floor) {
        final onStageTop = tops[floor.id];
        if (onStageTop != null) return topPad + onStageTop;
        final parked = floorH * _neighbourScale;
        return floor.level > expandedLevel
            ? topPad - parked
            : topPad + stackH;
      }

      // A Floor scaled about its top centre leaves (1 - scale)/2 of the
      // plan width free on each side; drift into that slack (plus the
      // outer margin) and nothing can leave the viewport.
      double driftOf(Floor floor) {
        final slack = planW * (1 - scaleOf(floor)) / 2 + left;
        return ((floor.level - expandedLevel) * _driftFactor * planW)
            .clamp(-slack, slack);
      }

      return Stack(
        children: [
          for (final floor in ordered)
            AnimatedPositioned(
              key: ValueKey('floor-${floor.id}'),
              duration: _anim,
              curve: Curves.easeInOutCubic,
              left: left + driftOf(floor),
              top: topOf(floor),
              child: IgnorePointer(
                ignoring: !tops.containsKey(floor.id),
                child: GestureDetector(
                  onTap: floor.id == _expandedFloorId
                      ? null
                      : () => _selectFloor(floor),
                  child: AnimatedScale(
                    duration: _anim,
                    curve: Curves.easeInOutCubic,
                    scale: scaleOf(floor),
                    alignment: Alignment.topCenter,
                    child: AnimatedOpacity(
                      duration: _anim,
                      opacity: !tops.containsKey(floor.id)
                          ? 0.0
                          : floor.id == _expandedFloorId
                              ? 1.0
                              : 0.55,
                      child: FloorView(
                        floor: floor,
                        controller: widget.controller,
                        projection: projection,
                        expanded: floor.id == _expandedFloorId,
                        onRoomTap: widget.controller.toggleRoomLights,
                        onDeviceTap: (device) =>
                            _onDeviceTap(context, device),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }

  void _selectFloor(Floor floor) {
    Log.debug('ui', 'floor', {'id': floor.id, 'level': floor.level});
    setState(() => _expandedFloorId = floor.id);
  }

  void _onDeviceTap(BuildContext context, Device device) {
    final presentation = widget.controller.presentationOf(device);
    final toggles = presentation.tapBehaviour == DeviceTapBehaviour.toggle;
    // The branch is the Device's kind, not its live state, so a pin always
    // does the same thing; 'known' says whether the Hub had anything to say.
    Log.debug('ui', 'device', {
      'id': device.id,
      'kind': device.kind.name,
      'action': toggles ? 'toggle' : 'popup',
      'known': presentation.state != null,
    });
    if (toggles) {
      widget.controller.toggle(device.id);
    } else {
      showDevicePopup(context, presentation: presentation);
    }
  }
}
