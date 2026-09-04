import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';
import '../close_button.dart';
import '../edge_tab.dart';
import '../hub_controller.dart';
import '../idle_return.dart';
import '../still_watching.dart';
import '../theme.dart';
import '../video/camera_face.dart';
import '../video/snapshot.dart';
import '../video/stream_director.dart';
import 'camera_grid.dart';
import 'camera_order.dart';

/// How long the Cameras view stays up with nobody touching it before it
/// slides back to the Dollhouse.
///
/// This is a real trade, owned rather than hidden (phase-7 §B3): it caps a
/// *forgotten* live doorbell tile — the one state with a cost beyond
/// bandwidth, because an open Ring session suppresses dings (#177014) — and
/// it also interrupts a *deliberate* long watch. [kCamerasIdleWarning] is
/// the softening: the view asks before it acts, and one tap per five
/// minutes is the price of holding a Ring session open on purpose.
const kCamerasIdleReturn = Duration(minutes: 5);

/// How long "Still watching?" is on screen before an unanswered prompt
/// returns the view. Part of [kCamerasIdleReturn], not added to it.
const kCamerasIdleWarning = Duration(seconds: 30);

/// How often an off tile refreshes its still face — either source. For the
/// HA-held JPEG (`SnapshotConfig`) the fetch never wakes a device and the
/// only budget is LAN chatter. For go2rtc's frame grab
/// (`Go2rtcStillsConfig`, phase-8 A7) a cache-miss on a cold camera costs
/// one keyframe dial (~3 s of camera stream), which is why that source is
/// gated by the Director's verdict (`CameraFeed.stillGrabAllowed`) and the
/// URL carries a cache window.
///
/// **Must stay longer than [kGo2rtcStillCache]** — the ordering is what
/// makes each tick a fresh frame while remounts inside the window stay
/// free; its doc carries the failure modes, and a test pins the ordering.
const kCamerasSnapshotRefresh = Duration(seconds: 60);

/// Route events for the Cameras route, so the view can hear a Popup ride
/// over it. `didPushNext` is the one honest "something covers the grid"
/// signal there is — a visibility callback is blind to routes pushed on top
/// (google/flutter.widgets #29/#295) — and it feeds
/// [StreamDirector.overlaid], whose debounce is sized so a routine 30 s
/// ding Popup never churns producers. Registered on [MaterialApp] by
/// `PanelApp`; a test that pumps the view bare simply never hears it.
final camerasRouteObserver = RouteObserver<ModalRoute<void>>();

/// The right-edge handle on the Dollhouse that opens the Cameras view.
///
/// Renders nothing when the House has no video Device — a tab onto an empty
/// grid is furniture. Sits in `PanelApp`'s Stack rather than inside
/// `DollhouseView`, which neither plays nor decides anything about video.
///
/// Kept as its own name rather than folded into [EdgeTab] at the call site:
/// "the Cameras tab" is a thing the suite and the plans both talk about, and
/// `find.byType(CamerasTab)` is how a test says it without asserting which
/// glyph is on it.
class CamerasTab extends StatelessWidget {
  const CamerasTab({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      EdgeTab(icon: Icons.videocam_outlined, label: 'Cameras', onTap: onTap);
}

/// Slides the Cameras view out over the Dollhouse, leftward, full screen —
/// the owner-specified shape (phase-7 §B2). A route rather than a Popup: it
/// is navigated to, not raised by an event, and the Popup's registry and
/// deadline machinery solve problems this view does not have. What it keeps
/// from the Popup is the session discipline — every tile's feed dies with
/// the route, because tiles release in `dispose()`, which runs however the
/// route leaves.
///
/// [director] is the Stream Director every tile attaches to — `main()`'s
/// process-wide one on the wall, the fixture-built one in a hermetic scene
/// (`test/support/hermetic_director.dart`). Required, with no view-built
/// fallback: a view that built its own would dial the same go2rtc and play
/// the same picture while Camera Health and the census silently stopped
/// hearing from it (measured by the 2026-09-02 review).
Future<void> showCamerasView(
  BuildContext context, {
  required HubController controller,
  required StreamDirector director,
  required SnapshotConfig snapshots,
  required Go2rtcStillsConfig stills,
  required CameraOrderStore order,
}) {
  if (_onWall != null) {
    // The tap is dropped rather than queued. It is worth a line because a
    // person who taps and gets nothing has no other evidence, and because
    // the window this happens in is invisible from outside — see [_onWall].
    Log.info('cameras', 'open_ignored', {'why': 'one already on the wall'});
    return Future.value();
  }
  final route = _CamerasRoute(
    builder: (_) => CamerasView(
      controller: controller,
      director: director,
      snapshots: snapshots,
      stills: stills,
      order: order,
    ),
  );
  // Claimed after the push, not before: `Navigator.of` throws when there is
  // no Navigator above this context, and a claim staked before that throw
  // would latch the wall shut for the rest of the process with no route
  // left alive to release it. The claim is still synchronous, so the frame
  // between here and the view's `initState` stays covered.
  final opening = Navigator.of(context).push(route);
  _onWall = route;
  return opening;
}

/// The Cameras route currently on the wall, or null when the Dollhouse is
/// alone. Written only by [showCamerasView] and [_CamerasRoute.dispose].
///
/// **One Cameras route at a time**, which until 2026-09-03 was an assumption
/// the code stated and nothing enforced. `showCamerasView` had no guard, and
/// the window is easy to hit without meaning to: for the 300 ms of the close
/// slide the leaving route ignores pointers, so the edge tab underneath is
/// live again and a second tap pushed a whole second view over the first.
///
/// Two of them on the stack is not a cosmetic problem. The lower view hears
/// `didPushNext` and sets [StreamDirector.overlaid], and the Director is
/// shared — so the *visible* grid is the one whose tiles get paused, showing
/// a wall of stills nobody asked to freeze. And `deactivate()`'s census
/// ([_closingLive]) folds over the Director by role, so each view counts the
/// other's tiles and `cameras.closed live=` reports a number that was never
/// true of either.
///
/// Held as the route rather than a mounted-view flag because the route is
/// the thing whose lifetime actually matches the rule. It is set
/// synchronously, before `push` returns — a mount-time flag would leave the
/// first frame unguarded — and cleared in `dispose()`, which the Navigator
/// runs once the route is off the stack for good, slide included. A test
/// that pumps a bare [CamerasView] never touches it, and a Navigator torn
/// down mid-route disposes its own entries, so nothing leaks between cases.
_CamerasRoute? _onWall;

/// The Cameras route: the owner-specified leftward slide, and the half of
/// [_onWall] that knows when the wall is clear again.
class _CamerasRoute extends PageRouteBuilder<void> {
  _CamerasRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, _, _) => builder(context),
          transitionsBuilder: (_, animation, _, child) => SlideTransition(
            position: animation.drive(
              Tween(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeInOutCubic)),
            ),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 300),
        );

  @override
  void dispose() {
    // Identity, not a bare clear, so this route can only ever retract its
    // own claim. Nothing today can put a second Cameras route on the stack
    // while this one lives — that is what [_onWall] is for — so the check is
    // not load-bearing yet. It is what keeps `dispose` correct on its own
    // terms instead of by appeal to a guard in another function.
    if (identical(_onWall, this)) _onWall = null;
    super.dispose();
  }
}

/// The full-screen grid of camera tiles. Which tiles stream is the Stream
/// Director's decision (phase-8): tiles state a want and render the verdict,
/// the doorbell's stays idle at entry (`KindSpec.autoLive`, the safety half
/// of the vocabulary row, now policy data), and closing the view releases
/// every feed.
class CamerasView extends StatefulWidget {
  const CamerasView({
    super.key,
    required this.controller,
    required this.director,
    required this.snapshots,
    required this.stills,
    required this.order,
  });

  final HubController controller;

  /// The Director the tiles attach to — see [showCamerasView]. Where go2rtc
  /// is travels inside it ([StreamDirector.video]); nothing on this route
  /// holds a go2rtc address of its own.
  final StreamDirector director;
  final SnapshotConfig snapshots;

  /// The go2rtc frame-grab source for tiles with no HA-held snapshot (the
  /// Wyze fleet). Required for [snapshots]'s reason: a default here would
  /// be a test-fixture fact wearing a Panel costume — `test/fixtures.dart`
  /// is where it defaults, and it defaults to unconfigured.
  final Go2rtcStillsConfig stills;

  /// The person's tile order, held across route opens and app restarts.
  /// Required for [stills]'s reason — a default here would be a test-fixture
  /// fact wearing a Panel costume, and `test/fixtures.dart` is where it
  /// defaults, to a store that remembers nothing past the process.
  final CameraOrderStore order;

  @override
  State<CamerasView> createState() => _CamerasViewState();
}

class _CamerasViewState extends State<CamerasView> with RouteAware {
  late final List<Device> _devices;
  late final DateTime _openedAt;

  /// The Director the tiles attach to — [CamerasView.director], never one of
  /// this view's own. Not owned here: it outlives every route, and disposing
  /// it would cancel the Popup path's census with it.
  StreamDirector get _director => widget.director;

  /// This view's own route, captured so the idle return can refuse to pop
  /// blind — the same discipline `device_popup.dart` keeps for its
  /// deadline. Measured before the fix: an unconditional `pop()` at fire
  /// time took a doorbell Popup that had opened on top, and — raced
  /// against a non-tap pop of the view itself — took the Dollhouse home
  /// route, leaving an empty Navigator on the wall.
  ModalRoute<void>? _route;

  /// The idle bound's clockwork, shared with the Popup since 2026-09-03
  /// (`ui/idle_return.dart`). What stays here is this view's own: the
  /// constants, the pointer `Listener`, and [_fireIdle] — how a surface may
  /// pop is route mechanics, and this one is `RouteAware`.
  late final IdleReturn _idle;

  /// The retry a blocked fire arms, which is NOT the module's: it is the
  /// obstructed-route half of [_fireIdle]. Cancelled wherever the bound is
  /// rearmed, because a touch resets the whole dismissal state — an idle
  /// return that fired against an obstruction must not outlive the answer
  /// to its own prompt (the Popup's rule, and the same reasoning).
  Timer? _idleBlockedRetry;

  /// The one camera filling the screen, or null while the grid is up.
  ///
  /// **Why this is a mode of this view and not a route pushed over it.**
  /// Zooming has to *stop the grid*, and that is the whole point of it on
  /// this house: five tiles at 640×360 is what the Wi-Fi carries, and one
  /// tile at 1920×1080 is what a person looking closely wants — but not both
  /// at once. Replacing the grid unmounts every tile, so each one's
  /// `dispose()` releases its feed; a pushed route would leave them mounted
  /// and streaming behind the picture, which is the bandwidth this feature
  /// exists to reclaim.
  ///
  /// Coming back is cheap despite the unmount, because `LiveVideoKeepAlive`
  /// holds a closed stream for [kLiveVideoLinger] (20 s) and re-attaches a
  /// reopen to the one still running. So a glance at one camera and back
  /// costs no restart — the grid is live again on the next frame rather than
  /// paying 5 s, or 17 s on a floodlight.
  Device? _zoomed;

  /// The closing census — how many streams the teardown is about to release
  /// — read off the Director in [deactivate] and logged in [dispose].
  ///
  /// Two hooks, because of Flutter's teardown order: a removed subtree is
  /// deactivated parent-first and unmounted children-first, so at
  /// `deactivate()` every tile and zoom feed is still attached with its live
  /// phase, while by `dispose()` the tiles have released theirs. Until
  /// 2026-09-03 the view kept this count itself — a set the tiles and the
  /// zoom reported into through a callback, cleared at zoom-in and pruned
  /// at zoom-out, with the unmount order explained in four places and once
  /// wrong (handoff D6, the ghost grid). The Director sets every phase; it
  /// answers the count ([StreamDirector.activeFeeds]) — by role, so this is
  /// "this view's feeds" only because the wall shows one Cameras route at a
  /// time. That was an assumption until 2026-09-03 and is now enforced by
  /// [_onWall], whose doc carries what a second view did to this number.
  var _closingLive = 0;

  @override
  void initState() {
    super.initState();
    _openedAt = DateTime.now();
    // Plan order, captured once. What the grid actually draws is this run
    // through [arrangeCameras] with the person's saved arrangement — see
    // [_arranged], which is recomputed rather than stored so that a plan
    // change and a drag cannot disagree about which list is current.
    _devices = [
      for (final floor in widget.controller.house.floors)
        for (final device in floor.devices)
          if (specOf(device.kind).video) device,
    ];
    _idle = IdleReturn(
      returnAfter: kCamerasIdleReturn,
      warnFor: kCamerasIdleWarning,
      onFire: _fireIdle,
    )..prompting.addListener(_onPrompting);
    widget.order.addListener(_onOrderChanged);
    Log.info('cameras', 'opened', {
      'tiles': _devices.length,
      'auto_live': _devices
          .where(
            (d) =>
                _director.policy.autoLive(d) &&
                _director.video.urlFor(_director.policy.tileStream(d)) != null,
          )
          .length,
    });
    _rearmIdle();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      if (_route != null) camerasRouteObserver.unsubscribe(this);
      if (route != null) camerasRouteObserver.subscribe(this, route);
    }
    _route = route;
  }

  /// A route rode over this one — a ding Popup, most days. The Director's
  /// overlay debounce decides what that costs; this widget only reports the
  /// fact, because visibility callbacks cannot see routes.
  @override
  void didPushNext() => _director.overlaid = true;

  @override
  void didPopNext() => _director.overlaid = false;

  /// The grid as it is drawn right now: plan order, put through the
  /// person's arrangement, with anything the plan never wired up held last.
  ArrangedCameras get _arranged => arrangeCameras(_devices, widget.order.value);

  void _onOrderChanged() {
    if (mounted) setState(() {});
  }

  void _onPrompting() {
    if (mounted) setState(() {});
  }

  @override
  void deactivate() {
    // Parent-first, so the tiles' and the zoom's feeds are all still
    // attached — see [_closingLive]. Only this view's roles: the wall's
    // Director is shared with the Popup, and a ding riding over the grid is
    // not a stream this teardown releases.
    _closingLive = _director.activeFeeds(
      roles: const {FeedRole.tile, FeedRole.zoom},
    );
    super.deactivate();
  }

  @override
  void dispose() {
    widget.order.removeListener(_onOrderChanged);
    camerasRouteObserver.unsubscribe(this);
    _idle.prompting.removeListener(_onPrompting);
    _idle.dispose();
    _idleBlockedRetry?.cancel();
    // The tiles release their own feeds in their `dispose()`; this line is
    // the summary a log reader greps for, not the mechanism.
    Log.info('cameras', 'closed', {
      'open_s': DateTime.now().difference(_openedAt).inSeconds,
      'live': _closingLive,
    });
    // Leaving the route is also leaving the overlay state behind: the
    // Director outlives this route (`main()`'s on the wall, the fixture's
    // in a test — never this view's own) and must not stay paused because
    // the thing that was covered is gone. Its timers are its owner's to
    // cancel.
    _director.overlaid = false;
    super.dispose();
  }

  void _zoomIn(Device device) {
    Log.info('cameras', 'zoom_in', {
      'device': device.id,
      // Both names, because the point of the zoom is that they differ: the
      // grid was playing the left one and the screen is about to play the
      // right one. A reader chasing bandwidth wants to see the swap.
      'from': _director.policy.tileStream(device),
      'to': _director.policy.zoomStream(device),
    });
    setState(() => _zoomed = device);
  }

  void _zoomOut() {
    final device = _zoomed;
    if (device == null) return;
    Log.info('cameras', 'zoom_out', {'device': device.id});
    setState(() => _zoomed = null);
  }

  void _rearmIdle() {
    _idleBlockedRetry?.cancel();
    _idleBlockedRetry = null;
    _idle.rearm();
  }

  /// The unanswered prompt's verdict — and it may only ever pop **this**
  /// route. `Navigator.pop()` takes whatever is on top: a doorbell Popup
  /// that opened over the prompt (a ding is not a pointer event, so
  /// nothing re-armed), or — when a non-tap pop raced the timer — the
  /// Dollhouse itself. Both were measured, not imagined.
  void _fireIdle() {
    if (!mounted) return;
    final route = _route;
    if (route == null || !route.isActive) return; // already on its way out
    if (!route.isCurrent) {
      // Something sits on top. The Popup's dismiss_blocked precedent:
      // retry rather than lose the deadline — the obstruction closes
      // itself (a ding Popup lives 30 s) and the next fire lands.
      Log.debug('cameras', 'idle_blocked', {
        'retry_s': kCamerasIdleWarning.inSeconds,
      });
      _idleBlockedRetry = Timer(kCamerasIdleWarning, _fireIdle);
      return;
    }
    Log.info('cameras', 'idle_return', {'reason': 'unanswered'});
    Navigator.of(context).pop();
  }

  /// One tile, built in one place — the shipped grid and the ordering
  /// prototype both take it from here. The key is what makes a reorder
  /// *move* a live tile rather than rebuild it, so streams survive a drag.
  Widget _tile(Device device) => CameraTile(
    key: ValueKey('tile-${device.id}'),
    device: device,
    director: _director,
    snapshots: widget.snapshots,
    stills: widget.stills,
    onZoom: () => _zoomIn(device),
  );

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Any touch anywhere is "still watching" — including the tap that
      // answers the prompt, which needs no special-casing because rearming
      // is the answer.
      onPointerDown: (_) => _rearmIdle(),
      behavior: HitTestBehavior.translucent,
      child: Scaffold(
        backgroundColor: PanelTheme.surface,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _zoomed?.name ?? 'Cameras',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: PanelTheme.ink,
                      ),
                    ),
                    const Spacer(),
                    // The way back to plan order, and it exists **only once
                    // there is something to undo** — no arrangement, no
                    // control, so a wall nobody has rearranged carries no
                    // extra chrome.
                    //
                    // Earned rather than decorative: a rest of half a second
                    // on a tile followed by a flick rearranges the grid
                    // instead of scrolling it (`CameraGrid._liftAfter` has
                    // the measurement). Dragging the tile back is the usual
                    // undo, and this is for the case where nobody remembers
                    // what the order was.
                    if (_zoomed == null && widget.order.value.isNotEmpty) ...[
                      _ResetOrderButton(onPressed: widget.order.reset),
                      const SizedBox(width: 10),
                    ],
                    // The same puck the Popups wear. It was a bare Material
                    // IconButton until 2026-08-15 — flat, inked, and the one
                    // control on the Panel that did not look like the rest of
                    // the Panel. `close_button.dart` says why one idiom
                    // matters on a screen with no Escape key.
                    // One puck, two jobs, and the order matters: zoomed in,
                    // it steps back to the grid rather than leaving the
                    // Cameras view entirely. Anything else makes the way out
                    // of a zoom "press the only X twice", where the first
                    // press throws away more than the person asked it to.
                    PanelCloseButton(
                      key: const ValueKey('cameras-close'),
                      onPressed: () {
                        if (_zoomed != null) {
                          _zoomOut();
                        } else {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  // The second clause is the whole discoverability budget
                  // for rearranging. A press-and-hold has no affordance to
                  // draw — that is the price of a grid with no arrange mode
                  // and no handles — so the line says it, once, where
                  // somebody looking at the grid will read it.
                  _zoomed == null
                      ? 'Tap a camera to fill the screen · hold to move it'
                      : 'Full size · close to go back to all cameras',
                  style: const TextStyle(
                    fontSize: 12,
                    color: PanelTheme.inkFaint,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: switch (_zoomed) {
                    final device? => ZoomedCamera(
                      key: ValueKey('zoom-${device.id}'),
                      device: device,
                      director: _director,
                    ),
                    null => CameraGrid(
                      arranged: _arranged,
                      tileBuilder: _tile,
                      onArrange: widget.order.arrange,
                    ),
                  },
                ),
                if (_idle.prompting.value) const StillWatching.banner(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Reset order" — the same raised puck idiom as [PanelCloseButton], drawn
/// from [PanelTheme] rather than reached for from Material, because a
/// [TextButton] here would be the one flat inked control on the wall (the
/// mistake `close_button.dart` records).
class _ResetOrderButton extends StatelessWidget {
  const _ResetOrderButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('cameras-reset-order'),
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: PanelTheme.surfaceRaised,
          borderRadius: BorderRadius.circular(12),
          boxShadow: PanelTheme.raised(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.restart_alt, size: 16, color: PanelTheme.inkFaint),
            SizedBox(width: 8),
            Text(
              'Reset order',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: PanelTheme.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One camera's tile: face, name bar, and its feed.
///
/// A renderer since phase-8: the tile states its want at mount
/// ([StreamDirector.attach]), renders whatever [FeedPhase] comes back, and
/// releases in `dispose()` — so "closing the view stops everything" is not a
/// bookkeeping promise, it is `dispose()` running per tile, the same hook
/// the Popup trusts. The open/listen/log-once/close dance this widget used
/// to hand-roll (one of three drifted copies) lives in the Director now.
/// What stays here is the still face: stills are not streams. Two sources,
/// one preference (phase-8 A7): the HA-held JPEG where a `snapshot:`
/// binding exists (the doorbell — `camera_proxy` costs no device session),
/// else go2rtc's own frame grab for probed cameras (the Wyze fleet, whose
/// substream keyframe is a picture HA never held).
class CameraTile extends StatefulWidget {
  const CameraTile({
    super.key,
    required this.device,
    required this.director,
    required this.snapshots,
    required this.stills,
    required this.onZoom,
  });

  final Device device;
  final StreamDirector director;
  final SnapshotConfig snapshots;
  final Go2rtcStillsConfig stills;

  /// Fills the screen with this camera at full size.
  ///
  /// **This is what a tap does now, and it used to toggle the stream on and
  /// off.** The toggle earned its place when every tile was 1080p and turning
  /// one off was the only way to get the bandwidth back; the substream took
  /// that job (a tile is 640×360, five of them is what the Wi-Fi carries),
  /// and what was left was a control whose main effect was a tile someone
  /// had accidentally switched off. The doorbell keeps its default-off
  /// behaviour through `KindSpec.autoLive` (policy data in the Director),
  /// not through the tap — so tapping it still opens a Ring session only
  /// because a person asked (#177014), and leaving the zoom still closes it.
  final VoidCallback onZoom;

  @override
  State<CameraTile> createState() => CameraTileState();
}

class CameraTileState extends State<CameraTile>
    with AutomaticKeepAliveClientMixin {
  late final CameraFeed _feed;

  /// The shared core of the not-live face (`camera_face.dart`): whether a
  /// picture was ever up on this tile, and whether the wait it is in is a
  /// restoration — "Reconnecting…" is worn only over one; a first connect
  /// that keeps failing stays "Connecting…". Listens to both of the feed's
  /// notifiers; this State listens to it.
  late final CameraFace _cameraFace;
  var _wasActive = false;

  Uint8List? _still;
  String? _stillStatus;
  Timer? _refresh;

  Device get _device => widget.device;

  /// An active tile may not be unmounted by the grid's lazy viewport: a
  /// feed dying because its tile scrolled past `cacheExtent` is a stream
  /// the Director (or a person) chose to run, silently killed with a log
  /// line blaming the view. Idle tiles stay lazy — remounting one costs a
  /// snapshot refetch and nothing else.
  ///
  /// Reads the [_wasActive] mirror rather than the feed itself: the mixin's
  /// own `initState` consults this getter before this State's body has run,
  /// which is before [_feed] exists (measured — a `late` read here took the
  /// whole grid down).
  @override
  bool get wantKeepAlive => _wasActive;

  @override
  void initState() {
    super.initState();
    _feed = widget.director.attach(_device, role: FeedRole.tile);
    // The face listens to both of the feed's notifiers (the count can climb
    // without a phase change) and reads the born phase — a tile handed a
    // lingered picture by the pool knows it was up even if the player drops
    // back to connecting before it fails.
    _cameraFace = CameraFace(_feed)..addListener(_onPhase);
    _wasActive = _feed.phase.value.isActive;
    // The mixin read [wantKeepAlive] before the feed existed; tell it the
    // real answer now that there is one.
    if (_wasActive) updateKeepAlive();
    _startStillLoop();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _cameraFace.dispose();
    // The view reads its closing census off the Director in `deactivate()`,
    // which runs before any child's dispose — not from a set this tile fed
    // — so releasing here costs the count nothing on any path (teardown,
    // zoom-in, or a lazy-viewport eviction).
    _feed.release();
    super.dispose();
  }

  void _onPhase() {
    if (!mounted) return;
    final active = _feed.phase.value.isActive;
    if (active != _wasActive) {
      _wasActive = active;
      updateKeepAlive();
    }
    setState(() {});
  }

  /// A tap zooms. The tile's own feed is not touched here: the view
  /// replaces the grid, which unmounts this tile, and [dispose] releases it
  /// — one teardown path rather than two that must agree.
  ///
  /// A tile with nothing to show still zooms, and deliberately: the zoomed
  /// body says *why* there is no picture, at a size somebody can read,
  /// which is more use than a tap that appears to do nothing.
  void _onTap() => widget.onZoom();

  /// The go2rtc stream a frame grab would bill, or null where the source
  /// does not apply. **The kind check is the doorbell's safety wall**
  /// (invariant: no go2rtc consumer on the Ring stream outside a
  /// person-opened view, #177014) — the doorbell is `DeviceKind.doorbell`,
  /// so it can never build a `frame.jpeg` URL, whatever its bindings say.
  ///
  /// The fall-through to [Device.streamName] is deliberate, the video
  /// seam's own rule restated: a substream is an offer, not a requirement —
  /// a camera offering only a main stream is grabbed on it rather than
  /// wearing the icon forever.
  String? get _grabStream => _device.kind == DeviceKind.camera
      ? (_device.substream ?? _device.streamName)
      : null;

  void _startStillLoop() {
    if (_device.snapshotEntityId == null &&
        widget.stills.urlFor(_grabStream) == null) {
      return;
    }
    _fetchStill();
    _refresh ??= Timer.periodic(kCamerasSnapshotRefresh, (_) => _fetchStill());
  }

  Future<void> _fetchStill() async {
    // The HA-held JPEG first — the doorbell's path, and the cheaper one
    // wherever a `snapshot:` binding exists (camera_proxy serves HA's own
    // cache; the fetch never wakes a device).
    final entity = _device.snapshotEntityId;
    if (entity != null) {
      final url = widget.snapshots.urlFor(entity);
      if (url == null) return;
      final result = await widget.snapshots.fetch(
        url,
        token: widget.snapshots.token,
      );
      _applyStill(result, 'entity', entity);
      return;
    }
    final stream = _grabStream;
    final url = widget.stills.urlFor(stream);
    // Whether the grab is worth its dial is the Director's verdict, read at
    // fetch time — one answer over the four facts it already holds (phase,
    // Camera Health, viewport, overlay), never re-derived here (2026-09-02).
    if (url == null || !_feed.stillGrabAllowed) return;
    // Tokenless on purpose: go2rtc is unauthenticated on this LAN (owner
    // decision, phase-4 §B0), and the fetcher sends no header for ''.
    final result = await widget.stills.fetch(url, token: '');
    _applyStill(result, 'stream', stream!);
  }

  /// [source] is the loggable name — an HA entity id or a go2rtc stream
  /// name, never a URL (`diagnostics/log.dart`: the name is the safe half).
  void _applyStill(SnapshotResult result, String key, String source) {
    // A live face needs no still under it, and swapping bytes behind a
    // playing video would repaint for nobody.
    if (!mounted || _feed.phase.value.isLive) return;
    // Logged on change only: a broken source would otherwise write the same
    // warning once a minute for as long as the view is open.
    if (result.status != _stillStatus) {
      if (result.bytes != null) {
        Log.debug('cameras', 'snapshot_ok', {key: source});
      } else {
        // `status` is an HTTP code or an exception's bare type name — never
        // exception text, which embeds the request URL (phase-7 §B5).
        Log.warn('cameras', 'snapshot_failed', {
          key: source,
          'status': result.status,
        });
      }
    }
    setState(() {
      _stillStatus = result.status;
      if (result.bytes != null) _still = result.bytes;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin's contract.
    // The viewport fact, pushed to the Director (phase-8 §C): an auto-live
    // tile starts when it becomes visible and stops 45 s after it scrolls
    // away — the grid scrolls on the wall (six tiles fit, the seventh is
    // below the fold), and airtime for a tile nobody can see is airtime
    // taken from one somebody can. Bounding-box only, and blind to routes
    // pushed on top — which is why a covering Popup is a separate signal
    // (`didPushNext` → `StreamDirector.overlaid`), never inferred here.
    // A kept-alive live tile is not laid out while scrolled away, so
    // visibleFraction == 0 is also the only "it left" signal such a tile
    // ever gets: its dispose() never runs off-screen.
    return VisibilityDetector(
      key: ValueKey('tile-visibility-${_device.id}'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        _feed.visible = info.visibleFraction > 0;
      },
      child: _tileBody(),
    );
  }

  Widget _tileBody() {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: PanelTheme.surfaceRaised,
              borderRadius: BorderRadius.circular(16),
              boxShadow: PanelTheme.raised(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _face()),
                _nameBar(),
              ],
            ),
          ),
        ),
        // The tap target is painted ON TOP of the face, and that is the only
        // reason a playing tile can be tapped at all.
        //
        // On web, `feed.view` is a platform view — a real `<video>` in the
        // DOM, composited above Flutter's canvas — and it takes the pointer
        // before any [GestureDetector] wrapped *around* it sees one.
        // Measured on the wall 2026-08-15, and the symptom named the cause
        // exactly: tiles showing `Connecting…` or `Live view failed` zoomed
        // on a tap, and tiles actually showing video did nothing. A control
        // that works only when it has nothing to show.
        //
        // `pointer-events: none` on the video and its host (see
        // `live_video_mse.dart`) stops the element grabbing the event, and
        // this overlay is what catches it: painted after the platform view,
        // so Flutter composites it above, and `opaque` so it answers the hit
        // test across the whole tile rather than only where it drew ink.
        Positioned.fill(
          child: GestureDetector(
            onTap: _onTap,
            behavior: HitTestBehavior.opaque,
          ),
        ),
      ],
    );
  }

  Widget _face() {
    switch (_feed.phase.value) {
      case FeedPhase.playing:
        return _feed.view;
      // Honest text, never a spinner — the same rule as the Popup, for
      // the same pumpAndSettle and same-lie reasons. A ladder re-dial over
      // a picture that WAS up says "Reconnecting…" instead (owner request
      // 2026-08-26 — this superseded "the ladder is a log fact, not a
      // wall fact"); a first connect that keeps failing stays
      // "Connecting…", because "re-" claims a restoration.
      case FeedPhase.connecting:
        return _FaceNotice(
          _cameraFace.reconnecting ? 'Reconnecting…' : 'Connecting…',
        );
      // The quiet tile variant of the zoom's counted face: the aged still
      // (where one exists) with the word in the corner — the §C design
      // ("retrying = aged still + quiet badge") finally spelled.
      case FeedPhase.retrying:
        return _stillFace(
          notice: _cameraFace.reconnecting ? 'Reconnecting…' : 'Connecting…',
        );
      // Only a non-camera rests here (#177014).
      case FeedPhase.failed:
        return const _FaceNotice('Live view failed');
      // Camera Health's verdict: the camera is off the air, so the honest
      // face is the aged still with the word, not a 25 s connect timeout.
      case FeedPhase.offline:
        return _stillFace(notice: 'Camera offline');
      case FeedPhase.unconfigured || FeedPhase.unsupported:
        return _stillFace();
      // The one phase where a tap can actually deliver — the badge rides
      // on it, which is what stopped "Tap for live" appearing over a tap
      // that logs tile_skipped.
      case FeedPhase.idle || FeedPhase.queued:
        return _stillFace(badge: true);
    }
  }

  /// The not-live face: the still where one exists, the icon where none
  /// does, and the honest not-wired text where there is nothing at all.
  Widget _stillFace({bool badge = false, String? notice}) {
    final still = _still;
    if (still != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // `gaplessPlayback` keeps the previous frame up through a refresh
          // decode, so the tile never blinks grey once a minute. The
          // errorBuilder is for the bytes the fetchers cannot vet: they
          // refuse the measured zero-byte 200, but a truncated JPEG (or a
          // proxy's HTML under a 200 on the web build) arrives non-empty
          // and undecodable — without this, the decode error re-reports
          // through FlutterError on every rebuild and the face renders
          // nothing at all.
          Image.memory(
            still,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => Center(
              child: Icon(
                deviceIcon(_device.kind),
                size: 40,
                color: PanelTheme.inkFaint,
              ),
            ),
          ),
          if (notice != null)
            Align(alignment: Alignment.bottomLeft, child: _CornerTag(notice)),
          if (badge)
            const Align(
              alignment: Alignment.bottomRight,
              child: _CornerTag('Tap for live'),
            ),
        ],
      );
    }
    if (_device.streamName == null && _device.snapshotEntityId == null) {
      // The honest not-wired body: the same "unavailable beats a black
      // rectangle" rule the Popup follows for a camera with no feed.
      return const _FaceNotice('Not wired up yet');
    }
    if (notice != null) return _FaceNotice(notice);
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: Icon(
            deviceIcon(_device.kind),
            size: 40,
            color: PanelTheme.inkFaint,
          ),
        ),
        if (badge)
          const Align(
            alignment: Alignment.bottomRight,
            child: _CornerTag('Tap for live'),
          ),
      ],
    );
  }

  Widget _nameBar() {
    // LIVE means frames are flowing or about to — the one rule, stated in
    // [FeedPhaseFacts.isLive]; a failed or unsupported feed wearing the
    // badge was measured and is a lie.
    final live = _feed.phase.value.isLive;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(deviceIcon(_device.kind), size: 16, color: PanelTheme.inkFaint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _device.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: PanelTheme.ink,
              ),
            ),
          ),
          if (live)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: PanelTheme.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                  color: PanelTheme.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One camera filling the Cameras view, at full size.
///
/// The counterpart to the tile's substream policy: a tile plays the small
/// stream because there are several of them and each is ~400 px, and this
/// asks the Director for [FeedRole.zoom] — [DirectorPolicy.zoomStream], the
/// full picture — because there is exactly one of it and it is the whole
/// screen. On this house that is 640×360 against 1920×1080.
///
/// **The grid is not running behind this.** [_CamerasViewState] replaces the
/// grid rather than pushing a route over it, so every tile is unmounted and
/// every tile feed released by the time this opens — which is the point,
/// because the bandwidth this stream wants is the bandwidth those five were
/// using. See `_CamerasViewState._zoomed`.
///
/// Deliberately has no snapshot loop, unlike [CameraTile]. A still face is
/// what a tile wears while it is *not* live, and this is only ever here
/// because somebody asked for live; a full-screen JPEG refreshing once a
/// minute would look like a broken video rather than a deliberate still.
class ZoomedCamera extends StatefulWidget {
  const ZoomedCamera({
    super.key,
    required this.device,
    required this.director,
  });

  final Device device;
  final StreamDirector director;

  @override
  State<ZoomedCamera> createState() => _ZoomedCameraState();
}

class _ZoomedCameraState extends State<ZoomedCamera> {
  late final CameraFeed _feed;

  /// The shared core of the not-live face (`camera_face.dart`): whether a
  /// picture was EVER up on this zoom, and whether the wait it is in is a
  /// restoration — "re-" claims one, and a stream that never showed a frame
  /// has nothing to restore. Listens to both of the feed's notifiers; this
  /// State listens to it.
  late final CameraFace _cameraFace;

  Device get _device => widget.device;

  @override
  void initState() {
    super.initState();
    // Person-origin by role: a zoom exists because somebody tapped, so the
    // Director dials now and no viewport or overlay rule touches it; a
    // mid-watch death rides the retry ladder (N11 — cameras reconnect,
    // the doorbell rests at failed, #177014). Any born failure is already
    // logged by the time this returns — the born-failed trap is the
    // Director's to close, once.
    _feed = widget.director.attach(_device, role: FeedRole.zoom);
    // The face listens to both of the feed's notifiers — the count can
    // climb with NO phase change (a re-dial failing synchronously is
    // retrying→retrying), and a counted face that listened to phase alone
    // would freeze at "try 2" — and reads the born phase, so a zoom handed
    // a lingered picture by the pool knows it was up.
    _cameraFace = CameraFace(_feed)..addListener(_onPhase);
  }

  @override
  void dispose() {
    _cameraFace.dispose();
    // The view reads its closing census off the Director in `deactivate()`,
    // before this runs (the tiles' rule too), so the release costs it
    // nothing.
    _feed.release();
    super.dispose();
  }

  void _onPhase() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: PanelTheme.surfaceRaised,
        borderRadius: BorderRadius.circular(16),
        boxShadow: PanelTheme.raised(8),
      ),
      child: Center(child: _body()),
    );
  }

  Widget _body() {
    switch (_feed.phase.value) {
      case FeedPhase.playing:
        return SizedBox.expand(child: _feed.view);
      case FeedPhase.connecting ||
          // A ladder re-dial passes through queued now (admission paces
          // timer-born dials), and idle is unreachable for a zoom — all
          // three arms count the same way so a policy change cannot
          // leave the screen blank or the count silent.
          FeedPhase.idle ||
          FeedPhase.queued:
        // Plain "Connecting…" is for a first dial only: once the ladder
        // is climbing, the face keeps counting — and says "Reconnecting"
        // only if a picture was ever up ("re-" claims a restoration; a
        // first connect that keeps failing is still just connecting,
        // counted out loud).
        return _cameraFace.counting
            ? _FaceNotice(
                '${_cameraFace.reconnecting ? 'Reconnecting…' : 'Connecting…'}'
                ' try ${_cameraFace.attempt}',
              )
            : const _FaceNotice('Connecting…');
      case FeedPhase.retrying:
        return _FaceNotice(
          '${_cameraFace.reconnecting ? 'Reconnecting…' : 'Connecting…'}'
          ' try ${_cameraFace.attempt}',
        );
      // Only a non-camera rests here — the doorbell, whose stream is never
      // re-dialled on a timer (#177014). A tap asks again.
      case FeedPhase.failed:
        return const _FaceNotice('Live view failed');
      case FeedPhase.offline:
        return const _FaceNotice('Camera offline');
      case FeedPhase.unconfigured:
        // Same honesty rule as the tile and the Popup: say which of the two
        // silences this is, rather than showing a black rectangle.
        return _FaceNotice(
          _device.streamName == null
              ? 'Not wired up yet'
              : 'Live view unavailable',
        );
      case FeedPhase.unsupported:
        return const _FaceNotice('Live view unavailable');
    }
  }
}

class _FaceNotice extends StatelessWidget {
  const _FaceNotice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: PanelTheme.inkFaint),
      ),
    );
  }
}

/// The quiet corner tag a still face wears — the Director's verdict worth a
/// word at the left ("Camera offline", "Reconnecting…"), "Tap for live" at
/// the right. One widget for both, per CLAUDE.md: it was two identical
/// `Container`s until 2026-09-02, and the same pill drawn twice drifts on
/// the first change to either. Form before colour — it is information, not
/// an alarm.
class _CornerTag extends StatelessWidget {
  const _CornerTag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: PanelTheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: PanelTheme.inkFaint,
        ),
      ),
    );
  }
}
