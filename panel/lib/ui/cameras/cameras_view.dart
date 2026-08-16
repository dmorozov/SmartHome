import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';
import '../close_button.dart';
import '../edge_tab.dart';
import '../hub_controller.dart';
import '../theme.dart';
import '../video/live_video.dart';
import '../video/snapshot.dart';

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

/// How often an off tile refreshes its still face. HA holds the JPEG (the
/// fetch never wakes a device — see `SnapshotConfig.urlFor`), so the only
/// budget here is LAN chatter.
const kCamerasSnapshotRefresh = Duration(seconds: 60);

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
/// from the Popup is the session discipline — every tile's stream dies with
/// the route, because tiles close their sessions in `dispose()`, which runs
/// however the route leaves.
Future<void> showCamerasView(
  BuildContext context, {
  required HubController controller,
  required VideoConfig video,
  required SnapshotConfig snapshots,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => CamerasView(
        controller: controller,
        video: video,
        snapshots: snapshots,
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

/// The full-screen grid of camera tiles. Every tile is a toggle; the
/// doorbell's is off at entry (`KindSpec.autoLive`, the safety half of the
/// vocabulary row); closing the view stops them all.
class CamerasView extends StatefulWidget {
  const CamerasView({
    super.key,
    required this.controller,
    required this.video,
    required this.snapshots,
  });

  final HubController controller;
  final VideoConfig video;
  final SnapshotConfig snapshots;

  @override
  State<CamerasView> createState() => _CamerasViewState();
}

class _CamerasViewState extends State<CamerasView> {
  late final List<Device> _devices;
  late final DateTime _openedAt;

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

  /// Live-tile census, kept by the tiles themselves via [_tileWent] so the
  /// closing line can say how many streams the teardown is about to release.
  final _live = <String>{};

  @override
  void initState() {
    super.initState();
    _openedAt = DateTime.now();
    _devices = [
      for (final floor in widget.controller.house.floors)
        for (final device in floor.devices)
          if (specOf(device.kind).video) device,
    ];
    Log.info('cameras', 'opened', {
      'tiles': _devices.length,
      'auto_live': _devices
          .where(
            (d) =>
                specOf(d.kind).autoLive &&
                widget.video.urlFor(d.streamName) != null,
          )
          .length,
    });
    _rearmIdle();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _idleWarn?.cancel();
    _idleFire?.cancel();
    // The tiles close their own sessions in their `dispose()`; this line is
    // the summary a log reader greps for, not the mechanism. The census is
    // still populated here because tile teardown deliberately skips it —
    // children unmount before their parent, so a draining census always
    // read 0 by the time this line was written (measured).
    Log.info('cameras', 'closed', {
      'open_s': DateTime.now().difference(_openedAt).inSeconds,
      'live': _live.length,
    });
    super.dispose();
  }

  void _tileWent({required String device, required bool live}) {
    live ? _live.add(device) : _live.remove(device);
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
                    const Text(
                      'Cameras',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: PanelTheme.ink,
                      ),
                    ),
                    const Spacer(),
                    // The same puck the Popups wear. It was a bare Material
                    // IconButton until 2026-08-15 — flat, inked, and the one
                    // control on the Panel that did not look like the rest of
                    // the Panel. `close_button.dart` says why one idiom
                    // matters on a screen with no Escape key.
                    PanelCloseButton(
                      key: const ValueKey('cameras-close'),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Tap a tile to start or stop its stream',
                  style: TextStyle(fontSize: 12, color: PanelTheme.inkFaint),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth > 900 ? 3 : 2;
                      return GridView.count(
                        crossAxisCount: columns,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 16 / 11,
                        children: [
                          for (final device in _devices)
                            CameraTile(
                              key: ValueKey('tile-${device.id}'),
                              device: device,
                              video: widget.video,
                              snapshots: widget.snapshots,
                              onWent: _tileWent,
                            ),
                        ],
                      );
                    },
                  ),
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

/// One camera's tile: face, name bar, and its own session lifecycle.
///
/// The session and the snapshot loop both live here so that "closing the
/// view stops everything" is not a bookkeeping promise — it is `dispose()`
/// running per tile, the same hook the Popup trusts.
class CameraTile extends StatefulWidget {
  const CameraTile({
    super.key,
    required this.device,
    required this.video,
    required this.snapshots,
    required this.onWent,
  });

  final Device device;
  final VideoConfig video;
  final SnapshotConfig snapshots;

  /// Tells the view a tile went live or dark, for the closing census.
  final void Function({required String device, required bool live}) onWent;

  @override
  State<CameraTile> createState() => CameraTileState();
}

class CameraTileState extends State<CameraTile>
    with AutomaticKeepAliveClientMixin {
  LiveVideoSession? _session;
  var _failureLogged = false;

  /// Whether this session earned a `tile_open` line and a census entry.
  /// An `unsupported` session dialled nothing, so logging the open/closed
  /// pair for it — or badging it LIVE — would be the lie
  /// `popup.stream_unsupported` exists to avoid.
  var _openLogged = false;

  Uint8List? _still;
  String? _stillStatus;
  Timer? _refresh;

  Device get _device => widget.device;

  /// A live tile may not be unmounted by the grid's lazy viewport: a
  /// session dying because its tile scrolled past `cacheExtent` is a
  /// stream the person chose to watch, silently killed with a log line
  /// blaming the view. Idle tiles stay lazy — remounting one costs a
  /// snapshot refetch and nothing else.
  @override
  bool get wantKeepAlive => _session != null;

  @override
  void initState() {
    super.initState();
    if (specOf(_device.kind).autoLive) {
      _open();
    }
    if (_session == null) _startStillLoop();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    // `census: false`: children unmount before their parent, so draining
    // the census here would zero the count before the view's own closing
    // line reads it (measured — it always logged live: 0).
    _closeSession('view_closed', census: false);
    super.dispose();
  }

  void _onTap() {
    if (_session != null) {
      setState(() => _closeSession('tap'));
      updateKeepAlive();
      _startStillLoop();
      return;
    }
    _refresh?.cancel();
    _refresh = null;
    setState(_open);
    updateKeepAlive();
    // An open that declined (no stream name, no go2rtc) must hand the tile
    // back to the still loop, or one tap freezes the snapshot forever —
    // stale-picture territory, the lie this repo's comments forbid.
    if (_session == null) _startStillLoop();
  }

  void _open() {
    final name = _device.streamName;
    final url = widget.video.urlFor(name);
    if (name == null || url == null) {
      // Mirrors `popup.stream_skipped`'s three reasons, at the same level:
      // nothing is wrong, the Panel simply has not been told.
      Log.debug('cameras', 'tile_skipped', {
        'device': _device.id,
        'reason': name == null ? 'no_stream_name' : 'go2rtc_unconfigured',
      });
      return;
    }
    final session = _session = widget.video.open(url, name: name);
    _failureLogged = false;
    if (session.phase.value == LiveVideoPhase.unsupported) {
      _openLogged = false;
      Log.info('cameras', 'tile_unsupported', {'name': name});
    } else {
      _openLogged = true;
      Log.info('cameras', 'tile_open', {'name': name});
      widget.onWent(device: _device.id, live: true);
    }
    session.phase.addListener(_onPhase);
    // Both real openers can answer a session that is *born* failed
    // (constructor throw → SettledLiveVideoSession), and a settled
    // session's notifier never fires a listener — the exact trap
    // device_popup.dart documents and closes. The face needs no setState
    // for it (every build reads phase.value), but the log line does.
    _logFailureOnce(session);
  }

  void _onPhase() {
    final session = _session;
    if (session == null) return;
    _logFailureOnce(session);
    if (mounted) setState(() {});
  }

  void _logFailureOnce(LiveVideoSession session) {
    if (session.phase.value != LiveVideoPhase.failed || _failureLogged) {
      return;
    }
    _failureLogged = true;
    // The failure text is go2rtc's own sentence, already through the
    // players' redaction rules — same contract as `popup.stream_failed`.
    Log.warn('cameras', 'tile_failed', {
      'name': _device.streamName,
      'reason': session.failure ?? 'unknown',
    });
  }

  void _closeSession(String reason, {bool census = true}) {
    final session = _session;
    if (session == null) return;
    session.phase.removeListener(_onPhase);
    session.close();
    _session = null;
    if (_openLogged) {
      Log.info('cameras', 'tile_closed', {
        'name': _device.streamName,
        'reason': reason,
      });
      if (census) widget.onWent(device: _device.id, live: false);
    }
    _openLogged = false;
  }

  void _startStillLoop() {
    if (_device.snapshotEntityId == null) return;
    _fetchStill();
    _refresh ??= Timer.periodic(kCamerasSnapshotRefresh, (_) => _fetchStill());
  }

  Future<void> _fetchStill() async {
    final entity = _device.snapshotEntityId;
    final url = widget.snapshots.urlFor(entity);
    if (entity == null || url == null) return;
    final result = await widget.snapshots.fetch(
      url,
      token: widget.snapshots.token,
    );
    if (!mounted || _session != null) return;
    // Logged on change only: a broken Hub would otherwise write the same
    // warning once a minute for as long as the view is open.
    if (result.status != _stillStatus) {
      if (result.bytes != null) {
        Log.debug('cameras', 'snapshot_ok', {'entity': entity});
      } else {
        // `status` is an HTTP code or an exception's bare type name — never
        // exception text, which embeds the request URL (phase-7 §B5).
        Log.warn('cameras', 'snapshot_failed', {
          'entity': entity,
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
    return GestureDetector(
      onTap: _onTap,
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
    );
  }

  Widget _face() {
    final session = _session;
    if (session != null) {
      return switch (session.phase.value) {
        LiveVideoPhase.playing => session.view,
        // Honest text, never a spinner — the same rule as the Popup, for
        // the same pumpAndSettle and same-lie reasons.
        LiveVideoPhase.connecting => const _FaceNotice('Connecting…'),
        LiveVideoPhase.failed => const _FaceNotice('Live view failed'),
        LiveVideoPhase.unconfigured || LiveVideoPhase.unsupported =>
          const _FaceNotice('Live view unavailable'),
      };
    }
    // The badge only where a tap can actually deliver: a wired stream on a
    // build that knows where go2rtc is. "Tap for live" over a tap that
    // logs tile_skipped is an instruction that does not work.
    final canGoLive = widget.video.urlFor(_device.streamName) != null;
    final still = _still;
    if (still != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          // `gaplessPlayback` keeps the previous frame up through a refresh
          // decode, so the tile never blinks grey once a minute.
          Image.memory(still, fit: BoxFit.cover, gaplessPlayback: true),
          if (canGoLive)
            const Align(alignment: Alignment.bottomRight, child: _TapForLive()),
        ],
      );
    }
    if (_device.streamName == null && _device.snapshotEntityId == null) {
      // The honest not-wired body: the same "unavailable beats a black
      // rectangle" rule the Popup follows for a camera with no feed.
      return const _FaceNotice('Not wired up yet');
    }
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
        if (canGoLive)
          const Align(alignment: Alignment.bottomRight, child: _TapForLive()),
      ],
    );
  }

  Widget _nameBar() {
    // LIVE means frames are flowing or about to — a failed or unsupported
    // session wearing the badge was measured and is a lie.
    final phase = _session?.phase.value;
    final live =
        phase == LiveVideoPhase.connecting || phase == LiveVideoPhase.playing;
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
