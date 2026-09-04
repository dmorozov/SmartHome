import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';
import '../device_popup.dart';
import '../device_presentation.dart';
import '../hub_controller.dart';
import '../theme.dart';
import '../audio/talk.dart';
import '../video/snapshot.dart';
import '../video/stream_director.dart';
import 'floor_arrangement.dart';
import 'floor_view.dart';

/// How much of the finger's travel the stack leans by while a Floor drag is
/// in progress.
///
/// A **preview, not the move**: the move is the 300 ms slide that runs when
/// the gesture commits, exactly as it does for a tap. Following 1:1 would
/// carry the stack most of the way there and then jump when the real
/// animation took over; following not at all would make the gesture feel
/// broken, which is the whole reason it exists.
///
/// Owner-set 2026-08-15, and expected to want one pass on real glass: no
/// touchscreen is attached to the Appliance yet (`TODO.md` A7), so this was
/// chosen against a mouse drag, which is not the same gesture. That is why it
/// is a named constant and not a literal.
const kFloorDragFollow = 0.6;

/// The furthest the stack may lean, however far the finger goes.
const kFloorDragLeanMax = 60.0;

/// How much of the Dollhouse's height a drag must cover to change Floors,
/// and the floor under that fraction.
///
/// A fraction rather than a fixed distance because the Panel is not only the
/// wall — the web build is a second-screen target, and 15% of a short browser
/// window is a very different gesture from 15% of 800 px. The minimum is what
/// stops it becoming a twitchy 30 px flick on the shortest ones. On the wall
/// this lands around 105 px.
const kFloorDragThresholdFraction = 0.15;
const kFloorDragThresholdMin = 72.0;

/// Extra damping applied when the drag is going nowhere — already at the
/// attic and pulling for a Floor above it, or at the ground and pulling
/// below. Halving [kFloorDragFollow] gives the resistance that says "this is
/// the top of the house"; refusing to move at all would be indistinguishable
/// from a Panel that had stopped responding.
const kFloorDragEndResistance = 0.5;

/// How long the stack takes to settle back after the finger lifts — whether
/// or not the drag committed. Shorter than the 300 ms Floor slide on purpose:
/// the lean is undoing a preview, not performing a move.
const kFloorDragSpringBack = Duration(milliseconds: 200);

/// How far **up and to the left of its own slab** a Floor's name sits.
///
/// Constant on screen, not scaled with the Floor: a neighbour is drawn at a
/// third of full size, and a label that shrank with it was ~4 px tall and
/// unreadable — which defeats the only reason a collapsed Floor is labelled
/// at all. The Dollhouse draws these itself for the same reason it decides
/// opacity: how present a Floor looks is the stage's call, not the Floor's.
///
/// **Both push the name away from the slab, never into it**, and that is the
/// whole of the 2026-08-15 correction. The first attempt nudged +6 *inward*
/// and lifted by 16 — but the name is about 16 px tall at 12/w700, so its
/// bottom edge landed exactly on `slabBounds.top` with nothing to spare. That
/// reads as clean on a plain diamond and as an overlap on a Floor whose
/// bounding-box corner is actually occupied, which the ground floor's is: its
/// garage wing reaches into the very corner the name was sitting in.
///
/// [kFloorLabelLift] therefore clears the name's own height plus a gap, and
/// [kFloorLabelNudge] is subtracted rather than added.
const kFloorLabelNudge = 32.0;
const kFloorLabelLift = 30.0;

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
    required this.director,
    this.snapshots,
    this.talk = const TalkConfig(),
  });

  final HubController controller;

  /// The Stream Director, on its way to the Popup a camera pin opens — the
  /// pin's Popup attaches a managed feed ([FeedRole.popup]) to it, and where
  /// go2rtc is travels inside it. Carried rather than read here: this view
  /// neither plays nor decides anything about video, and [FloorView] is not
  /// on the path at all — it forwards [_onDeviceTap] and never learns what
  /// a tap turns into. Required, like every video surface's: there is no
  /// Popup-built fallback for a forgotten argument to fall into.
  final StreamDirector director;

  /// Where the Hub is, for the still the Popup falls back to while live video
  /// has no picture (issue #1). Carried for exactly the reason [director]
  /// is, and optional for the reason `showDevicePopup`'s copy is: a suite
  /// that stages a tap on a camera pin should not have to stage a Hub REST
  /// endpoint too.
  final SnapshotConfig? snapshots;

  /// Where the doorbell's push-to-talk pushes, forwarded for [director]'s
  /// reason. Defaulted rather than required, like `showDevicePopup`'s copy: a
  /// suite staging a tap on a *camera* pin has no talkback to stage, and an
  /// unconfigured default is the honest thing for it to get.
  final TalkConfig talk;

  @override
  State<DollhouseView> createState() => _DollhouseViewState();
}

class _DollhouseViewState extends State<DollhouseView>
    with SingleTickerProviderStateMixin {
  late String _selectedFloorId;

  static const _anim = Duration(milliseconds: 300);

  /// The Dollhouse's own height, taken from the last layout, because the
  /// commit threshold is a fraction of it and a drag callback has no
  /// constraints to hand.
  double _viewportHeight = 0;

  /// Finger travel accumulated in the gesture in progress, positive
  /// downwards. Reset at every drag start, not at drag end, so a gesture that
  /// wanders back and forth is judged on where it ended up.
  double _drag = 0;

  /// How far the stack is currently leaning, in pixels.
  double _lean = 0;

  /// Where the lean was when the finger lifted — the value [_springBack]
  /// animates away from.
  double _leanFrom = 0;

  late final AnimationController _springBack = AnimationController(
    vsync: this,
    duration: kFloorDragSpringBack,
  );

  late final Animation<double> _springCurve = CurvedAnimation(
    parent: _springBack,
    curve: Curves.easeOut,
  );

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
    // Start with the lowest Floor (ground) selected.
    _selectedFloorId = widget.controller.house.floors
        .reduce((a, b) => a.level <= b.level ? a : b)
        .id;
    _springBack.addListener(() {
      setState(() => _lean = _leanFrom * (1 - _springCurve.value));
    });
  }

  @override
  void dispose() {
    _springBack.dispose();
    super.dispose();
  }

  /// Every Floor of the House, lowest level first — the order a drag walks.
  ///
  /// By index rather than by arithmetic on `level`, so a House whose levels
  /// skip a number (a mezzanine numbered 5, a basement at -1 with no 0)
  /// still steps one Floor at a time instead of finding nothing at
  /// `level + 1` and refusing to move.
  List<Floor> get _byLevel =>
      [...widget.controller.house.floors]..sort((a, b) => a.level - b.level);

  /// What this much travel would select, or null when there is no such Floor
  /// — the top or the bottom of the house.
  ///
  /// **Content follows the finger** (owner's call): dragging *down* slides
  /// the stack down, which brings the Floor drawn *above* into the centre —
  /// and the Floor drawn above is the higher level, because
  /// [FloorArrangement] orders the stack level-descending. So a downward
  /// drag goes upstairs. That is the scroll-view convention and, more to the
  /// point, it is what the eye expects when a visible stack of things is
  /// being pushed around.
  Floor? _targetFor(double drag) {
    if (drag == 0) return null;
    final ordered = _byLevel;
    final index = ordered.indexWhere((f) => f.id == _selectedFloorId);
    final next = drag > 0 ? index + 1 : index - 1;
    if (index < 0 || next < 0 || next >= ordered.length) return null;
    return ordered[next];
  }

  /// How far a drag must travel to change Floors — see
  /// [kFloorDragThresholdFraction].
  double get _threshold => math.max(
    kFloorDragThresholdMin,
    _viewportHeight * kFloorDragThresholdFraction,
  );

  void _onDragStart(DragStartDetails details) {
    // A second gesture landing mid-settle takes over from wherever the stack
    // has got to, rather than jumping back to zero under the finger.
    _springBack.stop();
    _drag = 0;
    _leanFrom = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _drag += details.delta.dy;
    // Damped harder when there is nothing that way to select: the stack still
    // moves, so the gesture is visibly alive, but it says "no" while doing it.
    final follow = _targetFor(_drag) == null
        ? kFloorDragFollow * kFloorDragEndResistance
        : kFloorDragFollow;
    setState(
      () =>
          _lean = (_drag * follow).clamp(-kFloorDragLeanMax, kFloorDragLeanMax),
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final target = _targetFor(_drag);
    // Distance only — no velocity term (owner's call). A fling that has not
    // covered the ground has not asked for anything, and one gesture never
    // moves more than one Floor: skipping would animate *through* a Floor
    // that was never on stage, which is the thing [FloorArrangement]'s
    // off-stage parking exists to prevent.
    if (target != null && _drag.abs() >= _threshold) {
      _selectFloor(target, by: 'drag');
    }
    _drag = 0;
    _leanFrom = _lean;
    _springBack.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportHeight = constraints.maxHeight;
        final arrangement = FloorArrangement.fit(
          house: widget.controller.house,
          selectedFloorId: _selectedFloorId,
          viewport: Size(constraints.maxWidth, constraints.maxHeight),
          wallDepth: FloorView.wallDepth,
        );
        return GestureDetector(
          // The whole Dollhouse, empty space included (owner's call): a hand at
          // a wall panel grabs wherever it lands, and dead zones around the
          // pins would make the gesture feel unreliable in exactly the places
          // the eye is drawn to. `opaque` is what extends it past the slabs.
          //
          // Nothing inside loses its taps. The gesture arena settles this the
          // ordinary way: a press that stays put is a tap and goes to whichever
          // Room or pin is under it, a press that travels past slop becomes
          // this drag. That is also what keeps a drag begun on a Device pin
          // from opening its Popup.
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: Transform.translate(
            // The lean. A paint-time transform on the whole stack, so no Floor
            // has to know the gesture exists and [FloorArrangement] stays a
            // pure function of *which* Floor is selected.
            offset: Offset(0, _lean),
            child: Stack(
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
                            : () => _selectFloor(placement.floor, by: 'tap'),
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
                              selected: placement.role == FloorRole.selected,
                              onRoomTap: widget.controller.toggleRoomLights,
                              onDeviceTap: (device) =>
                                  _onDeviceTap(context, device),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // The Floor names, drawn after the Floors so nothing paints
                // over them, and outside every `AnimatedScale` so they keep
                // one size whatever a Floor is scaled to. Anchored to
                // `slabBounds` — this Floor's *own* outline — so a name sits
                // a fixed distance from the Floor it names rather than from
                // the shared plan box, which is where they all used to queue
                // up regardless of how big their Floor was.
                for (final placement in arrangement.placements)
                  AnimatedPositioned(
                    key: ValueKey('floor-label-${placement.floor.id}'),
                    duration: _anim,
                    curve: Curves.easeInOutCubic,
                    // Clamped at the viewport's own left edge: a Floor drifted
                    // hard left would otherwise put its name at a negative x,
                    // and the Stack clips. Losing the nudge on that one Floor
                    // beats losing the first letters of its name.
                    left: math.max(
                      0,
                      placement.slabBounds.left - kFloorLabelNudge,
                    ),
                    top: placement.slabBounds.top - kFloorLabelLift,
                    child: AnimatedOpacity(
                      duration: _anim,
                      opacity: _opacityOf(placement.role),
                      // A name is not a target: a tap here has always meant
                      // "select this Floor", and it still reaches the slab
                      // underneath.
                      child: IgnorePointer(
                        child: Text(
                          placement.floor.name,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: PanelTheme.inkFaint,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// [by] is `tap` or `drag` — the two ways in, and the only evidence in
  /// journald of which one the house is actually being driven with. That
  /// matters while the drag is unproven: no touchscreen is attached to the
  /// Appliance yet (`TODO.md` A7), so "does anyone use it" is a question the
  /// log will answer before anybody can be asked.
  void _selectFloor(Floor floor, {required String by}) {
    // Ids raw, here and on `ui.device` below — the accepted residual argued in
    // `hub_controller.dart`'s `ui.room_lights`: an id that reaches the UI
    // survived the load, so a mis-paste cannot be here, and the id is the
    // whole content of the line.
    Log.debug('ui', 'floor', {'id': floor.id, 'level': floor.level, 'by': by});
    setState(() => _selectedFloorId = floor.id);
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
      showDevicePopup(
        context,
        presentation: presentation,
        director: widget.director,
        talk: widget.talk,
        controller: widget.controller,
        snapshots: widget.snapshots,
      );
    }
  }
}
