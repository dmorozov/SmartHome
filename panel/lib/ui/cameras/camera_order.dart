import 'package:flutter/foundation.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';

/// The order the Cameras grid draws its tiles in.
///
/// Two facts decide it, and they are not equals. The House Plan's order is
/// where the grid starts; a person dragging a tile is what it becomes. In
/// between sits one rule the person cannot drag away: a camera nobody has
/// wired up sits last, behind a labelled rule, because a tile that can never
/// show a picture must not stand between somebody and the one they came to
/// look at. On this house that was literally true — plan order put the
/// unwired Office Cam ahead of the Ring Doorbell.

/// Whether the House Plan wired a picture up for this Device at all.
///
/// **The plan's fact, not the Director's verdict**, and the distinction is
/// the whole point: a camera whose RTSP daemon is dead right now is
/// *configured and offline*, and must not sink to the bottom of the wall
/// every time its firmware sulks — which on this fleet is often enough that
/// a health-driven sort would reshuffle the grid weekly. Only a Device the
/// plan never gave a `stream:` or a `snapshot:` is "not set up".
bool cameraIsWired(Device device) =>
    device.streamName != null || device.snapshotEntityId != null;

/// The cameras in two groups, in the order the grid draws them.
@immutable
class ArrangedCameras {
  const ArrangedCameras(this.wired, this.unwired);

  /// Everything with a picture to show, in the person's order.
  final List<Device> wired;

  /// Everything the plan never wired up. Drawn after [wired], behind the
  /// rule, and not draggable — ordering tiles that cannot show anything is
  /// a control with no job.
  final List<Device> unwired;

  List<Device> get all => [...wired, ...unwired];

  /// What gets saved: **both** groups, wired first.
  ///
  /// Keeping the tail's ids costs a few bytes and buys a real property — a
  /// camera that goes unwired for a week (a binding pulled while somebody
  /// re-does a mount) comes back to the slot the person gave it rather than
  /// to the end of the line.
  List<String> get ids => [for (final device in all) device.id];
}

/// Plan order + a saved arrangement → what the grid shows.
///
/// Three rules, in the order of who wins:
///  1. **Unwired last**, whatever the arrangement says. See
///     [cameraIsWired] for which cameras that is, and [moveCamera] for why
///     it is a wall rather than a tiebreak.
///  2. Inside a group, a saved rank beats no rank, and earlier beats later.
///  3. A Device the arrangement never heard of — a camera added to the plan
///     since the last drag — sorts by plan order, *behind* everything
///     arranged. Deliberate: a new camera appearing in the middle of
///     somebody's arrangement is a jump-scare, and appearing at the end is
///     a to-do.
///
/// A saved id that is no longer in the plan simply never matches, so a
/// removed camera evaporates from the arrangement with no cleanup pass —
/// which matters because nothing else would ever run one.
ArrangedCameras arrangeCameras(List<Device> plan, List<String> saved) {
  final rank = {for (var i = 0; i < saved.length; i++) saved[i]: i};
  final planRank = {for (var i = 0; i < plan.length; i++) plan[i].id: i};

  // Total and deterministic on purpose: Dart's sort is not stable, so a
  // comparator that returned 0 for two never-arranged cameras would let
  // the grid reshuffle itself between builds.
  int compare(Device a, Device b) {
    final ra = rank[a.id];
    final rb = rank[b.id];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null) return -1;
    if (rb != null) return 1;
    return planRank[a.id]!.compareTo(planRank[b.id]!);
  }

  return ArrangedCameras(
    [
      for (final device in plan)
        if (cameraIsWired(device)) device,
    ]..sort(compare),
    [
      for (final device in plan)
        if (!cameraIsWired(device)) device,
    ]..sort(compare),
  );
}

/// [order] with [id] moved to sit where index [toIndex] currently sits.
///
/// Remove-then-insert-at-[toIndex] is already the right arithmetic for
/// "dropped onto that slot" in both directions, with no oldIndex/newIndex
/// fudge — the grid's drop targets are the tiles themselves, so the index
/// handed in is the slot the finger let go over.
///
/// (Flutter's `ReorderableListView` uses the other convention, where the new
/// index is an insertion point in the *pre-removal* list and a one-slot
/// downward move means "stay put". Nothing here is built on that widget, and
/// this note exists so nobody ports its arithmetic in by reflex.)
///
/// **Why a wired camera cannot be dropped into the tail**: the two groups
/// are separate lists, so there is no index to hand in for a slot below the
/// rule. That is the design — "not set up" is a statement about the camera,
/// not a shelf a person puts things on. If that ever needs to soften, the
/// change is in [arrangeCameras]'s grouping, not here.
List<Device> moveCamera(List<Device> order, String id, int toIndex) {
  final next = [...order];
  final from = next.indexWhere((device) => device.id == id);
  if (from < 0) return order;
  final moved = next.removeAt(from);
  next.insert(toIndex.clamp(0, next.length), moved);
  return next;
}

/// Writes an arrangement wherever it survives a restart. Returns when the
/// write has landed, or throws — [CameraOrderStore] owns the failure.
typedef CameraOrderWriter = Future<void> Function(List<String> order);

/// The arrangement, held in memory and written through.
///
/// A seam rather than a call to a storage plugin, for the reason every other
/// seam in this app exists: the Cameras view must be testable without a
/// platform channel, and the Panel must keep working when the write fails.
/// `data/camera_order_prefs.dart` is the production binding;
/// `test/fixtures.dart` defaults to one with no writer at all.
///
/// **Loaded before the first frame** (`main()` awaits it), so the grid never
/// renders in plan order and then jumps once storage answers. That ordering
/// is the whole reason this holds a plain value rather than a Future.
class CameraOrderStore extends ValueNotifier<List<String>> {
  CameraOrderStore({
    List<String> initial = const [],
    this.write,
  }) : super(List<String>.unmodifiable(initial));

  /// Where an arrangement goes to survive a restart, or null for a store
  /// that only remembers while the app is running — which is what every
  /// hermetic fixture wants. Call [arrange], not this: it is public only
  /// because a private field cannot be a named initializing formal.
  final CameraOrderWriter? write;

  /// Set the order and persist it. Listeners hear about it on this frame;
  /// the write lands whenever it lands.
  ///
  /// Always a fresh list, which is what makes the notification fire —
  /// [ValueNotifier] compares with `==`, and assigning a list back to itself
  /// would be silently swallowed.
  void arrange(List<String> order) {
    value = List.unmodifiable(order);
    _persist(value);
  }

  /// Back to plan order — the arrangement forgotten, not inverted.
  void reset() => arrange(const []);

  /// **The write is not awaited by the caller and its failure is not an
  /// error the wall shows.** Losing an arrangement is a disappointment on
  /// the next boot; a dialog over the cameras because a disk was busy is a
  /// worse one. The log line is how it is diagnosed.
  Future<void> _persist(List<String> order) async {
    final writer = write;
    if (writer == null) return;
    try {
      await writer(order);
    } catch (error) {
      // Type only, never the exception's text: a storage error can carry a
      // path, and paths are the half of a message that leaks (log.dart).
      Log.warn('cameras', 'order_save_failed', {
        'error': error.runtimeType.toString(),
      });
    }
  }
}
