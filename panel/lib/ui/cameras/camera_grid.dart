import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';
import '../theme.dart';
import 'camera_order.dart';

/// The Cameras grid, and the one gesture that rearranges it.
///
/// **Press and hold a tile, drag it onto another, let go.** No arrange mode,
/// no handles, no second screen to enter — the wall has one grid and it is
/// always the thing you are arranging. That was picked over the two
/// alternatives that were built and driven (an explicit Arrange mode that
/// stopped every stream, and a drag-handle rail beside a live grid): on a
/// screen you stand in front of, the shortest path from "that one should be
/// first" to it being first is to move it.
///
/// The lifted tile **keeps playing in the hole it came from**. See the
/// no-`childWhenDragging` note in [_CameraSlot] — it is a correctness point,
/// not a flourish.
///
/// This grid was suspect #1 in the 2026-08-27 frozen-wall hunt and came out
/// exonerated: the freeze was the renderer, not the widgets
/// (`docs/adr/0012-panel-renders-with-skia-on-linux.md`).
class CameraGrid extends StatefulWidget {
  const CameraGrid({
    super.key,
    required this.arranged,
    required this.tileBuilder,
    required this.onArrange,
  });

  /// The cameras, already split and sorted by [arrangeCameras].
  final ArrangedCameras arranged;

  /// Builds one camera's tile.
  ///
  /// The caller's own [ValueKey] on the tile is for finding it, not for
  /// moving it — see [_CameraGridState._slotKey] for what actually carries a
  /// live tile from one slot to another.
  final Widget Function(Device device) tileBuilder;

  /// The new full order — both groups, wired first — after a drop.
  final void Function(List<String> order) onArrange;

  @override
  State<CameraGrid> createState() => _CameraGridState();
}

class _CameraGridState extends State<CameraGrid> {
  /// The id of the tile currently riding somebody's finger, or null.
  String? _lifted;

  /// One [GlobalKey] per camera, stable for as long as this grid is up.
  ///
  /// **This is what makes a drop cost nothing**, and it has to be a *global*
  /// key. A sliver list is not a Row: `SliverChildListDelegate` builds by
  /// index and updates whatever element already sits at that index, so a
  /// [ValueKey] that no longer matches gets the old element deactivated and
  /// a new one inflated — which for a camera tile means `dispose()`,
  /// `CameraFeed.release()`, and a fresh dial on the other side of the drop.
  /// Measured before this was here: one two-tile swap opened a second go2rtc
  /// session and left both tiles saying "Connecting…" over a picture that
  /// had been up a moment earlier.
  ///
  /// A global key is re-taken rather than re-inflated when it turns up
  /// somewhere else in the same frame, so the tile's State — and the feed it
  /// holds — travels with it. `LiveVideoKeepAlive`'s 20 s linger would have
  /// hidden most of the cost on the wall, and hiding it is not the same as
  /// not paying it.
  final _slotKeys = <String, GlobalKey>{};

  GlobalKey _slotKey(String id) => _slotKeys.putIfAbsent(id, GlobalKey.new);

  /// How long a press has to last before a tile lifts.
  ///
  /// **The competing gesture is the scroll, not the tap**, and this was 300 ms
  /// on the strength of the opposite belief until it was measured. The grid
  /// does scroll on the wall — at 1280×800 the viewport is 687 px against
  /// 887 px of content — and the tiles *are* the scroll surface, so once the
  /// delayed recogniser wins, the Scrollable has lost that pointer. Measured
  /// at 300 ms: a finger resting 400 ms (an ordinary look-then-flick) and
  /// then flicking up moved a camera and scrolled nothing, and the new order
  /// was written to storage. The sweep put the boundary exactly here — 250 ms
  /// of rest scrolled, 300 ms rearranged.
  ///
  /// `kLongPressTimeout` is the platform's own answer to the same question
  /// and is what `ReorderableListView` uses for its touch drag, so a rest
  /// long enough to lift a tile is now a rest long enough to be deliberate
  /// everywhere else on the device too.
  ///
  /// **The residual is real and accepted**: rest a full half-second and then
  /// flick, and you still rearrange instead of scrolling. Two things make
  /// that survivable rather than alarming — the grid's rule and its
  /// not-set-up tail are inert scroll surface (~121 px of the viewport on
  /// this house), and the gesture is its own undo, with `Reset order` in the
  /// header for when it is not obvious what the old order was.
  static const _liftAfter = kLongPressTimeout;

  /// Never `setState` from here without this check.
  ///
  /// [Draggable.onDraggableCanceled] is called **unguarded** by the framework
  /// (`_DraggableState._startDrag`), unlike `onDragEnd` beside it — the
  /// recogniser is deliberately kept alive past dispose so a Draggable *can*
  /// be removed mid-drag, and the callback's own doc puts the `mounted` check
  /// on the caller. Reproduced before this guard: one finger holds a tile
  /// past the lift delay while a second finger taps another tile, which
  /// zooms and replaces this grid; releasing the first finger anywhere that
  /// is not a drop target then threw `setState() called after dispose()`.
  /// A touchscreen on a wall is a multi-touch device and that is not an
  /// exotic sequence.
  void _setLifted(String? id) {
    if (mounted) setState(() => _lifted = id);
  }

  void _drop(String id, int toIndex) {
    final wired = moveCamera(widget.arranged.wired, id, toIndex);
    Log.info('cameras', 'rearranged', {'device': id, 'to': toIndex});
    widget.onArrange(ArrangedCameras(wired, widget.arranged.unwired).ids);
  }

  @override
  Widget build(BuildContext context) {
    final unwired = widget.arranged.unwired;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The shipped geometry, unchanged: the wall is 1280 wide and takes
        // three columns; anything narrower (the web second screen, a phone
        // holding a browser) takes two.
        final columns = constraints.maxWidth > 900 ? 3 : 2;
        // Slivers rather than one GridView, because a full-width rule
        // between two grids is not something GridView can hold.
        return CustomScrollView(
          slivers: [
            SliverGrid.count(
              crossAxisCount: columns,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 16 / 11,
              children: [
                for (var i = 0; i < widget.arranged.wired.length; i++)
                  _CameraSlot(
                    key: _slotKey(widget.arranged.wired[i].id),
                    device: widget.arranged.wired[i],
                    index: i,
                    lifted: _lifted,
                    liftAfter: _liftAfter,
                    onLift: _setLifted,
                    onDrop: _drop,
                    child: widget.tileBuilder(widget.arranged.wired[i]),
                  ),
              ],
            ),
            if (unwired.isNotEmpty) ...[
              const SliverToBoxAdapter(child: NotSetUpRule()),
              SliverGrid.count(
                crossAxisCount: columns,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 16 / 11,
                children: [
                  // Dimmed and inert: no [Draggable], no drop target. A
                  // tap still zooms, because the zoomed body is where the
                  // Panel says *why* there is no picture at a size somebody
                  // can read.
                  for (final device in unwired)
                    Opacity(opacity: 0.6, child: widget.tileBuilder(device)),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// One draggable slot in the grid: a tile that can be lifted, and a target
/// another tile can be dropped onto.
class _CameraSlot extends StatelessWidget {
  const _CameraSlot({
    super.key,
    required this.device,
    required this.index,
    required this.lifted,
    required this.liftAfter,
    required this.onLift,
    required this.onDrop,
    required this.child,
  });

  final Device device;
  final int index;
  final String? lifted;
  final Duration liftAfter;
  final void Function(String? id) onLift;
  final void Function(String id, int toIndex) onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isLifted = lifted == device.id;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != device.id,
      onAcceptWithDetails: (details) => onDrop(details.data, index),
      builder: (context, candidate, _) => Stack(
        children: [
          Positioned.fill(
            child: LongPressDraggable<String>(
              data: device.id,
              delay: liftAfter,
              onDragStarted: () => onLift(device.id),
              onDragEnd: (_) => onLift(null),
              onDraggableCanceled: (_, _) => onLift(null),
              feedback: _LiftedGhost(device: device),
              // Centre the ghost on the finger, rather than Flutter's
              // default of holding it at the point the tile was grabbed.
              //
              // The default measures the *child* — a 400×275 grid cell — and
              // draws the 200×138 ghost at `pointer - grabPoint`, so a press
              // near a tile's corner puts the ghost a long way from the hand
              // and, near the top-left of the grid, mostly off the screen.
              // Measured. It never changed where a drop landed (the drop
              // target is the tile under the *finger*, and the ring marks
              // it), but a wall panel is watched from arm's length and a
              // picture floating somewhere else is a picture of the wrong
              // thing.
              dragAnchorStrategy: (_, _, _) =>
                  const Offset(_LiftedGhost.width / 2, _LiftedGhost.height / 2),
              // **No `childWhenDragging`, deliberately.** Handing one in
              // replaces this tile's whole subtree, which unmounts the
              // `CameraTile` inside it — and its `dispose()` releases the
              // feed. Every drag would kill the camera's stream and dial it
              // again on the drop; the 20 s keep-alive would hide most of
              // that (the reopen re-attaches the session still running),
              // but paying a teardown per drag and trusting a linger to
              // catch it is not a thing to build on purpose. Leaving the
              // child in place keeps the element, so the picture plays on
              // in the hole while its ghost rides the finger.
              // **Nothing wraps the tile.** The lifted look is a sibling
              // scrim below, not an `Opacity` or a `Transform` around this
              // subtree, and that is a rule about video rather than a
              // preference: a playing tile is an external texture (an fvp
              // `Texture` on the appliance, a real `<video>` element on the
              // web), and a compositing effect above one is the class of
              // thing that renders blank or stale instead of dimmed. It also
              // keeps this subtree byte-identical to the grid that shipped
              // before tiles could be dragged, so a rendering fault can
              // never be this feature's fault.
              child: child,
            ),
          ),
          // The hole the lifted tile came out of: the wall showing through,
          // painted over the tile as a sibling. `IgnorePointer` so the slot
          // underneath still answers a drop.
          if (isLifted)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: PanelTheme.surface.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          // Which slot a release would land on. Colour is allowed here by
          // the Panel's own rule — `accent` is the ready state, and a drop
          // target is exactly that.
          if (candidate.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: PanelTheme.accent, width: 3),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What rides the finger: a still card with the camera's icon and name,
/// never the live picture.
///
/// A second widget pointing at the same fvp Texture (or the same MSE
/// platform view on the web build) is not a thing to hand the drag overlay.
/// The tile it came from is still playing anyway, one hole away.
class _LiftedGhost extends StatelessWidget {
  const _LiftedGhost({required this.device});

  /// Deliberately smaller than a tile: half a grid cell clears the hand
  /// holding it. Named because [_CameraSlot] centres it on the finger and
  /// needs the same numbers.
  static const width = 200.0;
  static const height = 138.0;

  final Device device;

  @override
  Widget build(BuildContext context) {
    // The one Material widget in this file, transparent and elevation-free:
    // the drag overlay sits outside the route's own Material, and a bare
    // [Text] there has no default style to inherit. It brings no ink, no
    // radius and no elevation onto the wall — the card below is the Panel's
    // own raised surface (CLAUDE.md asks that this be said where it is done).
    return Material(
      color: Colors.transparent,
      child: Opacity(
        opacity: 0.92,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
            boxShadow: PanelTheme.raised(22),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                deviceIcon(device.kind),
                size: 32,
                color: PanelTheme.inkFaint,
              ),
              const SizedBox(height: 8),
              Text(
                device.name,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: PanelTheme.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The labelled line the unwired tail sits behind.
///
/// It is drawn rather than implied, because a dimmed tile at the bottom of a
/// grid with no explanation reads as a bug — and because the rule is the one
/// part of the order a person cannot change by dragging, which is worth
/// saying out loud exactly once.
class NotSetUpRule extends StatelessWidget {
  const NotSetUpRule({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const Text(
            'NOT SET UP',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: PanelTheme.inkFaint,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: const Color(0xFFD3D9E6))),
        ],
      ),
    );
  }
}
