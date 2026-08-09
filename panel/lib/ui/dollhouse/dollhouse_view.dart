import 'package:flutter/material.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';
import '../device_popup.dart';
import '../device_presentation.dart';
import '../hub_controller.dart';
import '../audio/talk.dart';
import '../video/live_video.dart';
import '../video/snapshot.dart';
import 'floor_arrangement.dart';
import 'floor_view.dart';

/// The Dollhouse: the house as stacked isometric Floors. One Floor is
/// selected (full size, Device pins live); tapping a neighbour selects it
/// instead.
///
/// Where each Floor stands is [FloorArrangement]'s call; what is left here
/// is animating between the arrangements two selections produce, and how
/// present each Floor looks while it happens.
class DollhouseView extends StatefulWidget {
  const DollhouseView({
    super.key,
    required this.controller,
    required this.video,
    this.snapshots,
    this.talk = const TalkConfig(),
  });

  final HubController controller;

  /// Where go2rtc is, on its way to the Popup a camera pin opens. Carried
  /// rather than read here: this view neither plays nor decides anything
  /// about video, and [FloorView] is not on the path at all — it forwards
  /// [_onDeviceTap] and never learns what a tap turns into.
  final VideoConfig video;

  /// Where the Hub is, for the still the Popup falls back to while live video
  /// has no picture (issue #1). Carried for exactly the reason [video] is, and
  /// optional for the reason `showDevicePopup`'s copy is: a suite that stages
  /// a tap on a camera pin should not have to stage a Hub REST endpoint too.
  final SnapshotConfig? snapshots;

  /// Where the doorbell's push-to-talk pushes, forwarded for [video]'s reason.
  /// Defaulted rather than required, like `showDevicePopup`'s copy: a suite
  /// staging a tap on a *camera* pin has no talkback to stage, and an
  /// unconfigured default is the honest thing for it to get.
  final TalkConfig talk;

  @override
  State<DollhouseView> createState() => _DollhouseViewState();
}

class _DollhouseViewState extends State<DollhouseView> {
  late String _expandedFloorId;

  static const _anim = Duration(milliseconds: 300);

  /// How present a Floor looks. The arrangement decides where a Floor
  /// stands; dimming the neighbours so the selected Floor reads as the one
  /// in focus is this view's own, and its only, decision.
  static double _opacityOf(FloorRole role) => switch (role) {
        FloorRole.selected => 1.0,
        FloorRole.neighbour => 0.55,
        FloorRole.offStage => 0.0,
      };

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
    return LayoutBuilder(builder: (context, constraints) {
      final arrangement = FloorArrangement.fit(
        house: widget.controller.house,
        selectedFloorId: _expandedFloorId,
        viewport: Size(constraints.maxWidth, constraints.maxHeight),
        wallDepth: FloorView.wallDepth,
      );
      return Stack(
        children: [
          for (final placement in arrangement.placements)
            AnimatedPositioned(
              key: ValueKey('floor-${placement.floor.id}'),
              duration: _anim,
              curve: Curves.easeInOutCubic,
              left: placement.boxTopLeft.dx,
              top: placement.boxTopLeft.dy,
              child: IgnorePointer(
                ignoring: placement.role == FloorRole.offStage,
                child: GestureDetector(
                  onTap: placement.role == FloorRole.selected
                      ? null
                      : () => _selectFloor(placement.floor),
                  child: AnimatedScale(
                    duration: _anim,
                    curve: Curves.easeInOutCubic,
                    scale: placement.scale,
                    alignment: Alignment.topCenter,
                    child: AnimatedOpacity(
                      duration: _anim,
                      opacity: _opacityOf(placement.role),
                      child: FloorView(
                        floor: placement.floor,
                        controller: widget.controller,
                        projection: arrangement.projection,
                        expanded: placement.role == FloorRole.selected,
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
    // Ids raw, here and on `ui.device` below — the accepted residual argued in
    // `hub_controller.dart`'s `ui.room_lights`: an id that reaches the UI
    // survived the load, so a mis-paste cannot be here, and the id is the
    // whole content of the line.
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
      // No `dismissAfter`: a person tapped this, so a person closes it.
      // The controller rides along so the one body with hands — the
      // thermostat's setpoint controls — has them.
      showDevicePopup(context,
          presentation: presentation,
          video: widget.video,
          talk: widget.talk,
          controller: widget.controller,
          snapshots: widget.snapshots);
    }
  }
}
