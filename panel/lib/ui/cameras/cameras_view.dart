import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';
import '../close_button.dart';
import '../edge_tab.dart';
import '../hub_controller.dart';
import '../theme.dart';
import '../video/live_video.dart';
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
/// one keyframe dial (~3 s of camera stream), which is why the tile gates
/// that source (`_grabAllowed`) and the URL carries a cache window.
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

/// Which tile shell to draw — the second bisect of the frozen-video hunt,
/// set from `main()` by `VIDEO_TILE`.
///
/// The first bisect (`CAMERAS_GRID`) cleared the grid skeleton, and a
/// clean-room probe then cleared five simultaneous textures, the sliver
/// grid, the clip, the drag wrappers and the repaint patterns — while the
/// zoomed view (same process, same route, same player chain) plays. What
/// remains is what only [CameraTile] itself wraps around the picture:
///
/// * `full` (default) — the shipped tile.
/// * `novis` — no [VisibilityDetector]. Isolates the one layer-protocol
///   participant unique to the grid path: it registers a composition
///   callback on the tile's retained layer on every paint.
/// * `nokeepalive` — [CameraTileState.wantKeepAlive] is pinned false.
///   Isolates the sliver's KeepAlive bracket around live tiles.
/// * `nooverlay` — no tap-catcher painted over the face. Isolates the
///   opaque hit-test overlay above the texture (the web-platform-view fix).
/// * `bare` — a playing tile is [CameraFeed.view] and nothing else: no
///   VisibilityDetector, no card, no clip, no shadows, no name bar, no
///   overlay. Everything at once; if this still freezes, the tile is
///   exonerated wholesale and the hunt moves outside it.
/// * `early` — the view is mounted while the feed is still `connecting`,
///   under the notice, instead of appearing at `playing` — and it keeps
///   ONE tree position through the playing boundary, so its element (and
///   the Texture under it) is created exactly once, before frames flow.
///   Isolates mount timing: the shipped tile mounts each Texture only
///   after its stream has been decoding for a while, and every
///   configuration that plays (the probe grids) mounts its Textures
///   before the first frame; the zoom is the one counter-example, and it
///   is single-texture. The arm's first cut swapped tree shapes at
///   `playing` and silently remounted the Texture — frozen, and
///   correctly so, but it tested nothing.
/// * `raw` — `bare` and `early` at once: the tile is [CameraFeed.view] in
///   a [ColoredBox] from birth, no shell, no faces, view element created
///   once before frames. The probe-pool grid's exact shape fed through
///   the Director — the combination cell the single-variable arms above
///   cannot reach. **Played, 2026-08-27** — and against `bare` (same
///   strip, view mounted at playing, frozen) it convicted
///   mount-after-frames as one of two freezers.
/// * `rawvis` / `rawoverlay` / `rawcard` — `raw` plus exactly one shell
///   piece: the [VisibilityDetector], the opaque tap overlay, or the card
///   (clip + shadows + name bar). View-from-birth held constant; the arm
///   that freezes names the second freezer. **Run 2026-08-27: rawvis and
///   rawoverlay play, rawcard freezes** — the card carries it.
/// * `rawclip` / `rawshadow` / `rawbar` — the card split three ways on
///   `raw`: the bare antialiased clip (the probe cleared this shape), the
///   clip plus the dual blurred BoxShadows, the clip plus Column + name
///   bar. The arm that freezes names the card's guilty piece. **Run
///   2026-08-27: all three froze** — the clip itself is the second
///   freezer, over five textures (the zoom clips one and plays; the
///   probe cleared the clip one-switch-at-a-time in a Wrap, never
///   combined with its grid).
/// * `rawrrect` / `rawhard` — the clip's implementation split: the same
///   rounded rect via [ClipRRect] (a ClipRRectLayer) versus
///   `Container(clipBehavior: Clip.hardEdge)` (no antialias). The shipped
///   card clips via ClipPath; if either of these plays, that difference
///   is the fix.
///
/// Delete together with `CAMERAS_GRID`'s arms once the freeze is settled.
String cameraTileMode = 'full';

/// The pieces `VIDEO_TILE=rawmix` composes — set from `main()` by
/// `VIDEO_MIX` (comma-separated: `shadow`, `radius`, `notch`, `bar`,
/// `clip`). The build-order and nesting live at the `rawmix` arm.
Set<String> cameraTileMix = const {};

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
/// [director] is the process-wide Stream Director when `main()` composed
/// one; null makes the view build its own over [video], which is what keeps
/// every hermetic fixture working unchanged — the fixture's [VideoConfig]
/// flows into an owned Director with the shipped default policy.
Future<void> showCamerasView(
  BuildContext context, {
  required HubController controller,
  required VideoConfig video,
  required SnapshotConfig snapshots,
  required Go2rtcStillsConfig stills,
  required CameraOrderStore order,
  StreamDirector? director,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => CamerasView(
        controller: controller,
        video: video,
        snapshots: snapshots,
        stills: stills,
        order: order,
        director: director,
      ),
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
    ),
  );
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
    required this.video,
    required this.snapshots,
    required this.stills,
    required this.order,
    this.director,
  });

  final HubController controller;
  final VideoConfig video;
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

  final StreamDirector? director;

  @override
  State<CamerasView> createState() => _CamerasViewState();
}

class _CamerasViewState extends State<CamerasView> with RouteAware {
  late final List<Device> _devices;
  late final DateTime _openedAt;

  /// The Director the tiles attach to — `main()`'s process-wide one on the
  /// wall, or this view's own over [CamerasView.video] in a hermetic rig.
  /// Owned only in the second case: disposing the wall's Director would
  /// cancel the Popup path's census with it.
  late final StreamDirector _director;
  late final bool _ownsDirector;

  /// This view's own route, captured so the idle return can refuse to pop
  /// blind — the same discipline `device_popup.dart` keeps for its
  /// deadline. Measured before the fix: an unconditional `pop()` at fire
  /// time took a doorbell Popup that had opened on top, and — raced
  /// against a non-tap pop of the view itself — took the Dollhouse home
  /// route, leaving an empty Navigator on the wall.
  ModalRoute<void>? _route;

  Timer? _idleWarn;
  Timer? _idleFire;
  var _prompting = false;

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

  /// Live-tile census, kept by the tiles themselves via [_tileWent] so the
  /// closing line can say how many streams the teardown is about to release.
  final _live = <String>{};

  @override
  void initState() {
    super.initState();
    _openedAt = DateTime.now();
    _ownsDirector = widget.director == null;
    _director = widget.director ?? StreamDirector(video: widget.video);
    // Plan order, captured once. What the grid actually draws is this run
    // through [arrangeCameras] with the person's saved arrangement — see
    // [_arranged], which is recomputed rather than stored so that a plan
    // change and a drag cannot disagree about which list is current.
    _devices = [
      for (final floor in widget.controller.house.floors)
        for (final device in floor.devices)
          if (specOf(device.kind).video) device,
    ];
    widget.order.addListener(_onOrderChanged);
    Log.info('cameras', 'opened', {
      'tiles': _devices.length,
      'auto_live': _devices
          .where(
            (d) =>
                _director.policy.autoLive(d) &&
                widget.video.urlFor(_director.policy.tileStream(d)) != null,
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

  @override
  void dispose() {
    widget.order.removeListener(_onOrderChanged);
    camerasRouteObserver.unsubscribe(this);
    _idleWarn?.cancel();
    _idleFire?.cancel();
    // The tiles release their own feeds in their `dispose()`; this line is
    // the summary a log reader greps for, not the mechanism. The census is
    // still populated here because tile teardown deliberately skips it —
    // children unmount before their parent, so a draining census always
    // read 0 by the time this line was written (measured).
    Log.info('cameras', 'closed', {
      'open_s': DateTime.now().difference(_openedAt).inSeconds,
      'live': _live.length,
    });
    // A view-owned Director dies with the view — its gate and retry timers
    // with it, which is what lets a widget test end clean. The wall's
    // Director is `main()`'s and outlives every route.
    if (_ownsDirector) {
      _director.dispose();
    } else {
      // Leaving the route is also leaving the overlay state behind: the
      // wall's Director must not stay paused because the thing that was
      // covered is gone.
      _director.overlaid = false;
    }
    super.dispose();
  }

  void _tileWent({required String device, required bool live}) {
    live ? _live.add(device) : _live.remove(device);
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
    // The tiles this unmounts deliberately skip their own drain (the
    // children-unmount-first rule below), which is right at view teardown
    // and wrong here: a census carried through a zoom would count a grid
    // that is not running, and a close-from-zoom would log its ghost. The
    // zoom feed reports itself in through the same [_tileWent].
    _live.clear();
    setState(() => _zoomed = device);
  }

  void _zoomOut() {
    final device = _zoomed;
    if (device == null) return;
    Log.info('cameras', 'zoom_out', {'device': device.id});
    // The zoom's own census entry leaves with it — the remounting tiles
    // re-report through their initState, born active off the pool's kept
    // sessions.
    _live.remove(device.id);
    setState(() => _zoomed = null);
  }

  void _rearmIdle() {
    _idleWarn?.cancel();
    _idleFire?.cancel();
    if (_prompting) setState(() => _prompting = false);
    _idleWarn = Timer(kCamerasIdleReturn - kCamerasIdleWarning, () {
      if (!mounted) return;
      setState(() => _prompting = true);
      _idleFire = Timer(kCamerasIdleWarning, _fireIdle);
    });
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
      _idleFire = Timer(kCamerasIdleWarning, _fireIdle);
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
    onWent: _tileWent,
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
                      onWent: _tileWent,
                    ),
                    // `legacy` is the grid this replaced, kept reachable for
                    // the frozen-video bisect (`camerasGridMode`): plan
                    // order, one GridView, no slivers, no rule, no drag.
                    // `probe` is the clean-room probe app transplanted whole
                    // — raw sessions, no tiles, no Director; its class doc
                    // says what the fork decides.
                    null => switch (camerasGridMode) {
                      'probe' => CamerasProbeGrid(
                        devices: _devices,
                        video: widget.video,
                      ),
                      // Same bare grid, but dialling through the wall's own
                      // `VideoConfig.open` — the keep-alive pool — instead
                      // of raw `openRtspVideo`. With `probe` playing, this
                      // splits the plumbing: frozen here means the pool,
                      // playing here squeezes the Director and the tile's
                      // mount timing (`VIDEO_TILE=early`).
                      'probepool' => CamerasProbeGrid(
                        devices: _devices,
                        video: widget.video,
                        opener: widget.video.open,
                      ),
                      'legacy' => LayoutBuilder(
                        builder: (context, constraints) => GridView.count(
                          crossAxisCount: constraints.maxWidth > 900 ? 3 : 2,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 16 / 11,
                          children: [
                            for (final device in _devices) _tile(device),
                          ],
                        ),
                      ),
                      _ => CameraGrid(
                        arranged: _arranged,
                        tileBuilder: _tile,
                        onArrange: widget.order.arrange,
                      ),
                    },
                  },
                ),
                if (_prompting) _StillWatching(),
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

/// The pre-return prompt. Any touch dismisses it — the surrounding
/// [Listener] rearms on pointer-down, so the banner itself needs no button.
class _StillWatching extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: PanelTheme.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        boxShadow: PanelTheme.raised(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.timer_outlined, size: 18, color: PanelTheme.inkFaint),
          SizedBox(width: 10),
          Text(
            'Still watching? Tap anywhere to stay',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: PanelTheme.ink,
            ),
          ),
        ],
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
    required this.onWent,
    required this.onZoom,
  });

  final Device device;
  final StreamDirector director;
  final SnapshotConfig snapshots;
  final Go2rtcStillsConfig stills;

  /// Tells the view a tile's feed went active or dark, for the closing
  /// census.
  final void Function({required String device, required bool live}) onWent;

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
  var _wasActive = false;

  /// Whether a picture was ever up on this tile — "Reconnecting…" is worn
  /// only over a restoration; a first connect that keeps failing stays
  /// "Connecting…" (the zoom's rule, quietly).
  var _sawPlaying = false;

  /// The viewport fact, mirrored for the grab gate — the feed's own
  /// `visible` is a setter (push-only, by the seam's design), and the gate
  /// needs to read it.
  var _tileVisible = true;

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
  bool get wantKeepAlive =>
      cameraTileMode == 'nokeepalive' ? false : _wasActive;

  @override
  void initState() {
    super.initState();
    _feed = widget.director.attach(_device, role: FeedRole.tile);
    _feed.phase.addListener(_onPhase);
    // Both notifiers: the retry count can climb without a phase change
    // (retrying→retrying on a synchronous re-dial failure), and a counted
    // face that listens to phase alone freezes.
    _feed.retryAttempt.addListener(_onPhase);
    _wasActive = _feed.phase.value.isActive;
    if (_wasActive) {
      widget.onWent(device: _device.id, live: true);
      // The mixin read [wantKeepAlive] before the feed existed; tell it the
      // real answer now that there is one.
      updateKeepAlive();
    }
    _startStillLoop();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _feed.phase.removeListener(_onPhase);
    _feed.retryAttempt.removeListener(_onPhase);
    // The census is deliberately not drained here: children unmount before
    // their parent, so a census drained in tile dispose always read 0 by
    // the time the view's closing line was written (measured).
    _feed.release();
    super.dispose();
  }

  void _onPhase() {
    if (!mounted) return;
    if (_feed.phase.value == FeedPhase.playing) _sawPlaying = true;
    final active = _feed.phase.value.isActive;
    if (active != _wasActive) {
      _wasActive = active;
      widget.onWent(device: _device.id, live: active);
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

  /// Whether a go2rtc frame grab is worth its dial right now. Four gates,
  /// each with its own reason, because a cache-miss grab IS a camera dial:
  ///
  /// 1. **Phase**: only idle/unconfigured/unsupported — the faces that can
  ///    *show* a still. While live the video is on screen and a grab buys
  ///    nothing; while failed/retrying the retry ladder owns the camera's
  ///    dial budget (each failed open costs the camera two connections,
  ///    measured); while queued a live dial is milliseconds away — and at
  ///    view-open every tile past the first is queued, so grabbing there
  ///    would fire the N-simultaneous-dials burst the admission gate
  ///    exists to prevent; while offline, see gate 2, of which that phase
  ///    is a subset.
  /// 2. **Camera Health, read live** — never inferred from phase: a feed
  ///    parked at idle (or settled at unconfigured/unsupported) does not
  ///    transition when the probe flips, so the phase arm alone would knock
  ///    a dead daemon once a minute forever. Only `unreachable` gates;
  ///    unknown is absence of evidence (the health module's rule). Recovery
  ///    needs no listener: the next tick reads the flipped verdict.
  /// 3. **Viewport**: airtime for a tile nobody can see is airtime taken
  ///    from one somebody can — the still loop honours the same doctrine
  ///    the Director's viewport stop enforces for streams. Born `true`
  ///    like the feed's own flag (R4's bounded first-report window).
  /// 4. **Overlay**: under a covering Popup the grid is invisible by
  ///    route, which the VisibilityDetector cannot see (#29/#295) — the
  ///    same `didPushNext` fact that pauses the streams pauses the grabs.
  ///
  /// The HA-held source has none of these gates: HA serves its cached
  /// JPEG, no device ever hears about it.
  bool get _grabAllowed {
    final phaseOk = switch (_feed.phase.value) {
      FeedPhase.idle || FeedPhase.unconfigured || FeedPhase.unsupported => true,
      FeedPhase.queued ||
      FeedPhase.connecting ||
      FeedPhase.playing ||
      FeedPhase.failed ||
      FeedPhase.retrying ||
      FeedPhase.offline => false,
    };
    return phaseOk &&
        _feed.reachability != Reachability.unreachable &&
        _tileVisible &&
        !widget.director.overlaid;
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
    if (url == null || !_grabAllowed) return;
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
    //
    // Bisect arms ([cameraTileMode]): without the detector the feed's
    // `visible` simply keeps its born-true default — the viewport stop and
    // the grab gate go blind, which is acceptable for the experiment's
    // lifetime and for nothing else.
    if (cameraTileMode.startsWith('raw') || cameraTileMode == 'fixcorners') {
      // The combination cells the single-variable arms above cannot reach.
      // `raw` (bare + early at once — probepool's exact shape through the
      // Director) PLAYED on 2026-08-27. The bare-vs-raw split that seemed
      // to convict mount-after-frames did not survive repeats: the 2×2
      // factorial {shell, mount order} at three rig runs per cell
      // (2026-08-28, stalled-stream cells discounted by their burned-in
      // clocks) reads bare 3/3 and raw 3/3 healthy against early and full
      // 0/6 every run — mount order changes nothing, the shell decides.
      // The `raw*` arms hold view-from-birth constant and add back ONE
      // shell piece each, to name the freezer inside the shell.
      Widget view = ColoredBox(
        color: const Color(0xFF11151F),
        child: _feed.view,
      );
      // `rawcard` froze (2026-08-27) with `rawvis`/`rawoverlay` playing —
      // the second freezer is in the card. But the card is three things,
      // and the standalone probe cleared the bare antialiased clip, so
      // these split it: `rawclip` (clip+radius+colour only — the probe's
      // cleared shape), `rawshadow` (clip + the dual blurred BoxShadows),
      // `rawbar` (clip + Column + name bar).
      // The FIX CANDIDATE: the shipped card's whole look with no clip
      // anywhere above the texture. The rounded raised surface paints
      // BEHIND the video; the video stays square; quarter-circle notches
      // in the page colour paint OVER its top corners to fake the
      // rounding. If this plays, it is what the wall ships.
      if (cameraTileMode == 'fixcorners') {
        view = DecoratedBox(
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
            boxShadow: PanelTheme.raised(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    view,
                    const Positioned(
                      top: 0,
                      left: 0,
                      child: _CornerNotch(Alignment.topLeft),
                    ),
                    const Positioned(
                      top: 0,
                      right: 0,
                      child: _CornerNotch(Alignment.topRight),
                    ),
                  ],
                ),
              ),
              _nameBar(),
            ],
          ),
        );
      }
      // 2026-08-27's "fixcorners froze" measured the FULL design: the
      // raw-family gate above read `startsWith('raw')` only, so this
      // branch never ran (caught 2026-08-28 — the doorbell wore the full
      // design's still face in the rig's own grab). Re-measured with the
      // gate fixed: every pair and triple of pieces plays, the four-piece
      // card plays most runs — and one run in three the wall stopped
      // WHOLE, five textures at one instant with synchronized burned-in
      // clocks. The sever is a wall-wide probabilistic event whose odds
      // grow with paint load, not a guilty widget. One factor per arm,
      // rig-validated: square shadow only; rounded background paint only;
      // corner notches only; Column+name bar only.
      if (cameraTileMode == 'rawshadow2') {
        view = DecoratedBox(
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            boxShadow: PanelTheme.raised(8),
          ),
          child: view,
        );
      }
      if (cameraTileMode == 'rawradius') {
        view = DecoratedBox(
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
          ),
          child: view,
        );
      }
      if (cameraTileMode == 'rawnotch') {
        view = Stack(
          fit: StackFit.expand,
          children: [
            view,
            const Positioned(
              top: 0,
              left: 0,
              child: _CornerNotch(Alignment.topLeft),
            ),
            const Positioned(
              top: 0,
              right: 0,
              child: _CornerNotch(Alignment.topRight),
            ),
          ],
        );
      }
      if (cameraTileMode == 'rawbar2') {
        view = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Expanded(child: view), _nameBar()],
        );
      }
      // The composable cell — `VIDEO_TILE=rawmix` + `VIDEO_MIX=a,b,...`
      // picks any subset of the card's pieces, because the rig found the
      // freeze is a THRESHOLD, not a widget: every single factor plays,
      // all four together freeze (2026-08-27). Pieces: `shadow`, `radius`,
      // `notch`, `bar`, `clip` — nested exactly as `fixcorners` nests
      // them, so a subset differs from it only by what it omits.
      if (cameraTileMode == 'rawmix') {
        final mix = cameraTileMix;
        if (mix.contains('notch')) {
          view = Stack(
            fit: StackFit.expand,
            children: [
              view,
              const Positioned(
                top: 0,
                left: 0,
                child: _CornerNotch(Alignment.topLeft),
              ),
              const Positioned(
                top: 0,
                right: 0,
                child: _CornerNotch(Alignment.topRight),
              ),
            ],
          );
        }
        if (mix.contains('bar')) {
          view = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Expanded(child: view), _nameBar()],
          );
        }
        final radius = mix.contains('radius');
        final shadow = mix.contains('shadow');
        if (radius || shadow || mix.contains('clip')) {
          view = Container(
            clipBehavior:
                mix.contains('clip') ? Clip.antiAlias : Clip.none,
            decoration: BoxDecoration(
              color: PanelTheme.surfaceRaised,
              borderRadius: radius || mix.contains('clip')
                  ? BorderRadius.circular(16)
                  : null,
              boxShadow: shadow ? PanelTheme.raised(8) : null,
            ),
            child: view,
          );
        }
      }
      // Mechanism probe: the same freezing clip, with a RepaintBoundary
      // between it and the texture — does an extra layer boundary change
      // the pass structure the clip forces?
      if (cameraTileMode == 'rawclip2') {
        view = Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
          ),
          child: RepaintBoundary(child: view),
        );
      }
      // All three card splits froze (2026-08-27): the common piece is the
      // rounded clip itself, not the shadows or the bar. These two probe
      // the clip's IMPLEMENTATION: `Container(clipBehavior:)` over a
      // rounded decoration clips via ClipPath, while [ClipRRect] emits a
      // ClipRRectLayer — different layer types, identical pixels. If one
      // plays where the other freezes, that difference is the fix.
      if (cameraTileMode == 'rawrrect') {
        view = ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: view,
        );
      }
      if (cameraTileMode == 'rawhard') {
        view = Container(
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
          ),
          child: view,
        );
      }
      const cardArms = {'rawcard', 'rawclip', 'rawshadow', 'rawbar'};
      if (cardArms.contains(cameraTileMode)) {
        final shadows =
            cameraTileMode == 'rawcard' || cameraTileMode == 'rawshadow';
        final bar = cameraTileMode == 'rawcard' || cameraTileMode == 'rawbar';
        view = Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
            boxShadow: shadows ? PanelTheme.raised(8) : null,
          ),
          child: bar
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [Expanded(child: view), _nameBar()],
                )
              : view,
        );
      }
      if (cameraTileMode == 'rawoverlay') {
        view = Stack(
          children: [
            Positioned.fill(child: view),
            Positioned.fill(
              child: GestureDetector(
                onTap: _onTap,
                behavior: HitTestBehavior.opaque,
              ),
            ),
          ],
        );
      }
      if (cameraTileMode == 'rawvis') {
        view = VisibilityDetector(
          key: ValueKey('tile-visibility-${_device.id}'),
          onVisibilityChanged: (info) {
            if (!mounted) return;
            _tileVisible = info.visibleFraction > 0;
            _feed.visible = _tileVisible;
          },
          child: view,
        );
      }
      return view;
    }
    if (cameraTileMode == 'bare' && _feed.phase.value == FeedPhase.playing) {
      return _feed.view;
    }
    if (cameraTileMode == 'bare' || cameraTileMode == 'novis') {
      return _tileBody();
    }
    return VisibilityDetector(
      key: ValueKey('tile-visibility-${_device.id}'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        _tileVisible = info.visibleFraction > 0;
        _feed.visible = _tileVisible;
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
        if (cameraTileMode != 'nooverlay')
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
        // Bisect arm `early`: the SAME Stack shape as the connecting case
        // below, so the view's element survives the connecting→playing
        // boundary. The first cut of this arm returned the bare view here,
        // and that remounted the Texture at exactly the moment the stream
        // came up — the arm reproduced the suspect instead of removing it.
        if (cameraTileMode == 'early') {
          return Stack(fit: StackFit.expand, children: [_feed.view]);
        }
        return _feed.view;
      // Honest text, never a spinner — the same rule as the Popup, for
      // the same pumpAndSettle and same-lie reasons. A ladder re-dial over
      // a picture that WAS up says "Reconnecting…" instead (owner request
      // 2026-08-26 — this superseded "the ladder is a log fact, not a
      // wall fact"); a first connect that keeps failing stays
      // "Connecting…", because "re-" claims a restoration.
      case FeedPhase.connecting:
        final notice = _sawPlaying && _feed.retryAttempt.value > 0
            ? 'Reconnecting…'
            : 'Connecting…';
        // Bisect arm `early` ([cameraTileMode]): the view is mounted the
        // moment a session exists, under the notice, instead of waiting
        // for `playing`. The shipped wall mounts each Texture only after
        // its stream has been decoding for a while — the probe grids,
        // which play, mount theirs before the first frame — and this arm
        // is the difference worn by the real tile.
        if (cameraTileMode == 'early') {
          return Stack(
            fit: StackFit.expand,
            children: [
              _feed.view,
              Align(
                alignment: Alignment.bottomLeft,
                child: _FaceTag(notice),
              ),
            ],
          );
        }
        return _FaceNotice(notice);
      // The quiet tile variant of the zoom's counted face: the aged still
      // (where one exists) with the word in the corner — the §C design
      // ("retrying = aged still + quiet badge") finally spelled.
      case FeedPhase.retrying:
        return _stillFace(
          notice: _sawPlaying ? 'Reconnecting…' : 'Connecting…',
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
            Align(alignment: Alignment.bottomLeft, child: _FaceTag(notice)),
          if (badge)
            const Align(alignment: Alignment.bottomRight, child: _TapForLive()),
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
          const Align(alignment: Alignment.bottomRight, child: _TapForLive()),
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
    required this.onWent,
  });

  final Device device;
  final StreamDirector director;

  /// The same census wire the tiles report on: the zoom is the one feed
  /// running while the grid is not, and a closing line that omitted it
  /// would count a ghost grid instead.
  final void Function({required String device, required bool live}) onWent;

  @override
  State<ZoomedCamera> createState() => _ZoomedCameraState();
}

class _ZoomedCameraState extends State<ZoomedCamera> {
  late final CameraFeed _feed;
  var _wasActive = false;

  /// Whether a picture was EVER up on this zoom — what separates the
  /// honest "Reconnecting…" from a first connect that keeps failing:
  /// "re-" claims a restoration, and a stream that never showed a frame
  /// has nothing to restore.
  var _sawPlaying = false;

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
    _feed.phase.addListener(_onPhase);
    // The count can climb with NO phase change (a re-dial failing
    // synchronously is retrying→retrying) — the counted face listens to
    // both or it freezes at "try 2".
    _feed.retryAttempt.addListener(_onPhase);
    _wasActive = _feed.phase.value.isActive;
    if (_wasActive) widget.onWent(device: _device.id, live: true);
  }

  @override
  void dispose() {
    _feed.phase.removeListener(_onPhase);
    _feed.retryAttempt.removeListener(_onPhase);
    // No census drain here, the tiles' rule: the view drains this feed's
    // entry itself at zoom-out, and at view teardown the populated census
    // is exactly what the closing line reads.
    _feed.release();
    super.dispose();
  }

  void _onPhase() {
    if (!mounted) return;
    if (_feed.phase.value == FeedPhase.playing) _sawPlaying = true;
    final active = _feed.phase.value.isActive;
    if (active != _wasActive) {
      _wasActive = active;
      widget.onWent(device: _device.id, live: active);
    }
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
        return _feed.retryAttempt.value > 0
            ? _FaceNotice(
                '${_sawPlaying ? 'Reconnecting…' : 'Connecting…'}'
                ' try ${_feed.retryAttempt.value + 1}',
              )
            : const _FaceNotice('Connecting…');
      case FeedPhase.retrying:
        return _FaceNotice(
          '${_sawPlaying ? 'Reconnecting…' : 'Connecting…'}'
          ' try ${_feed.retryAttempt.value + 1}',
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

/// A 16×16 page-coloured square with a quarter-circle bitten out — painted
/// OVER a square video corner to fake the card's rounded corner without a
/// clip layer anywhere above the texture (the `fixcorners` arm; the clip
/// is the wall's second freezer, convicted 2026-08-27). A Picture layer
/// composites above the Texture like any other paint; only CLIPPING the
/// texture severs its updates.
class _CornerNotch extends StatelessWidget {
  const _CornerNotch(this.corner);

  final Alignment corner;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(16, 16),
        painter: _CornerNotchPainter(corner),
      );
}

class _CornerNotchPainter extends CustomPainter {
  const _CornerNotchPainter(this.corner);

  final Alignment corner;

  @override
  void paint(Canvas canvas, Size size) {
    // The circle sits at the notch's INNER corner — the point of the tile
    // the rounding curves toward — so the area outside it, inside this
    // square, is exactly the sliver the card's rounded corner would have
    // clipped away. Even-odd leaves the circle's inside unpainted.
    final center = Offset(
      corner.x < 0 ? size.width : 0,
      corner.y < 0 ? size.height : 0,
    );
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: center, radius: size.width));
    canvas.drawPath(path, Paint()..color = PanelTheme.surface);
  }

  @override
  bool shouldRepaint(_CornerNotchPainter oldDelegate) =>
      oldDelegate.corner != corner;
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

/// The quiet corner tag a still face wears when the Director has a verdict
/// worth a word — "Camera offline" today. Form before colour: the same
/// pill as [_TapForLive], because it is information, not an alarm.
class _FaceTag extends StatelessWidget {
  const _FaceTag(this.text);

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

class _TapForLive extends StatelessWidget {
  const _TapForLive();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: PanelTheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        'Tap for live',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: PanelTheme.inkFaint,
        ),
      ),
    );
  }
}
