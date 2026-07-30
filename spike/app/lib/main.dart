// Spike test app: a Flutter GTK bundle run under the cage Wayland kiosk
// compositor on the real touchscreen.
//
// Runbook: docs/research/flutter-cage-spike.md (Step 5 content, section 4
// pass/fail). Four pages behind a NavigationBar exercise the behaviors the
// research could not settle from sources:
//
//   Counter — stock counter: basic tap targeting            (pass item 3)
//   Touch   — multi-touch visualizer: distinct pointer ids,
//             PointerDeviceKind.touch (never mouse)         (pass item 4, U2)
//   Fling   — ListView drag-release inertia                 (pass item 5, U2)
//   Pinch   — InteractiveViewer zoom + raw onScale readout
//             that would expose GtkGestureZoom double
//             delivery of touch sequences                   (pass item 6, U1)
//
// The whole app sits inside MouseRegion(cursor: SystemMouseCursors.none) so
// no cursor sprite can appear even if the hardware exposes a spurious
// pointer-capable input node (pass item 8; runbook section 2, "Cursor").

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

void main() => runApp(const SpikeApp());

// ---------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.none,
      child: MaterialApp(
        title: 'spike_app',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
        ),
        home: const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _pageIndex = 0;

  // IndexedStack keeps page state (max pointer count, scroll offset, zoom)
  // alive across tab switches — "this session" means the whole app run.
  static const List<Widget> _pages = <Widget>[
    CounterPage(),
    TouchVizPage(),
    FlingPage(),
    PinchPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: <Widget>[
          IndexedStack(index: _pageIndex, children: _pages),
          const Positioned(top: 8, right: 8, child: DisplayInfoOverlay()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _pageIndex,
        onDestinationSelected: (int index) =>
            setState(() => _pageIndex = index),
        destinations: const <Widget>[
          NavigationDestination(
            icon: Icon(Icons.add_circle_outline),
            label: 'Counter',
          ),
          NavigationDestination(
            icon: Icon(Icons.touch_app_outlined),
            label: 'Touch',
          ),
          NavigationDestination(
            icon: Icon(Icons.swipe_vertical_outlined),
            label: 'Fling',
          ),
          NavigationDestination(
            icon: Icon(Icons.zoom_out_map),
            label: 'Pinch',
          ),
        ],
      ),
    );
  }
}

/// Persistent top-corner readout of the logical surface size and the device
/// pixel ratio — confirms the fullscreen runner patch produced a surface at
/// the panel's real resolution. IgnorePointer keeps it out of hit testing.
class DisplayInfoOverlay extends StatelessWidget {
  const DisplayInfoOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}'
          ' logical  dpr ${dpr.toStringAsFixed(2)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 1 — Counter (stock; pass item 3: tap targeting)
// ---------------------------------------------------------------------------

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int _counter = 0;

  void _incrementCounter() => setState(() => _counter++);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Counter — basic tap targeting')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.displayMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2 — Multi-touch visualizer (pass item 4: two fingers = two pointers,
// PointerDeviceKind.touch)
// ---------------------------------------------------------------------------

class TouchVizPage extends StatefulWidget {
  const TouchVizPage({super.key});

  @override
  State<TouchVizPage> createState() => _TouchVizPageState();
}

/// One active contact as last reported by the embedder.
class _ActivePointer {
  const _ActivePointer({required this.kind, required this.position});

  final PointerDeviceKind kind;
  final Offset position;
}

class _TouchVizPageState extends State<TouchVizPage> {
  final Map<int, _ActivePointer> _active = <int, _ActivePointer>{};
  int _maxSimultaneous = 0;

  void _log(String phase, PointerEvent event) {
    debugPrint('[touch] $phase pointer=${event.pointer} '
        'kind=${event.kind.name} pos=${event.localPosition}');
  }

  void _track(String phase, PointerEvent event) {
    _log(phase, event);
    setState(() {
      _active[event.pointer] =
          _ActivePointer(kind: event.kind, position: event.localPosition);
      if (_active.length > _maxSimultaneous) {
        _maxSimultaneous = _active.length;
      }
    });
  }

  void _release(String phase, PointerEvent event) {
    _log(phase, event);
    setState(() => _active.remove(event.pointer));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-touch visualizer')),
      body: Column(
        children: <Widget>[
          _VizHeader(active: _active, maxSimultaneous: _maxSimultaneous),
          const Divider(height: 1),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (PointerDownEvent e) => _track('down', e),
              onPointerMove: (PointerMoveEvent e) => _track('move', e),
              onPointerUp: (PointerUpEvent e) => _release('up', e),
              onPointerCancel: (PointerCancelEvent e) => _release('cancel', e),
              child: CustomPaint(
                painter: _PointerDotsPainter(_active),
                child: _active.isEmpty
                    ? const Center(
                        child: Text(
                          'Touch here — try two or more fingers at once',
                          style: TextStyle(fontSize: 18),
                        ),
                      )
                    : const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VizHeader extends StatelessWidget {
  const _VizHeader({required this.active, required this.maxSimultaneous});

  final Map<int, _ActivePointer> active;
  final int maxSimultaneous;

  @override
  Widget build(BuildContext context) {
    final String detail = active.isEmpty
        ? 'Pass bar: every finger must report kind "touch" — never "mouse".'
        : active.entries
            .map((MapEntry<int, _ActivePointer> e) =>
                'id ${e.key}: ${e.value.kind.name}')
            .join('    ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Active pointers: ${active.length}      '
            'Max simultaneous this session: $maxSimultaneous',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _PointerDotsPainter extends CustomPainter {
  _PointerDotsPainter(this.pointers);

  final Map<int, _ActivePointer> pointers;

  static const double _radius = 44;

  @override
  void paint(Canvas canvas, Size size) {
    for (final MapEntry<int, _ActivePointer> entry in pointers.entries) {
      final Color color =
          Colors.primaries[entry.key % Colors.primaries.length];
      final Offset pos = entry.value.position;

      canvas.drawCircle(
        pos,
        _radius,
        Paint()..color = color.withValues(alpha: 0.35),
      );
      canvas.drawCircle(
        pos,
        _radius,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );

      // Crosshair at the exact reported position.
      final Paint cross = Paint()
        ..color = color
        ..strokeWidth = 1.5;
      canvas.drawLine(
          pos - const Offset(12, 0), pos + const Offset(12, 0), cross);
      canvas.drawLine(
          pos - const Offset(0, 12), pos + const Offset(0, 12), cross);

      final TextPainter label = TextPainter(
        text: TextSpan(
          text: 'id ${entry.key} - ${entry.value.kind.name}\n'
              '(${pos.dx.toStringAsFixed(0)}, ${pos.dy.toStringAsFixed(0)})',
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, pos + const Offset(_radius + 8, -_radius / 2));
    }
  }

  // Positions mutate inside the same map instance on every event; always
  // repaint while this page is live.
  @override
  bool shouldRepaint(_PointerDotsPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Page 3 — Fling (pass item 5: inertia after drag-release)
// ---------------------------------------------------------------------------

class FlingPage extends StatelessWidget {
  const FlingPage({super.key});

  static const int _itemCount = 200;
  static const double _itemHeight = 90;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fling — drag fast, release, expect inertia'),
      ),
      body: ListView.builder(
        itemCount: _itemCount,
        itemExtent: _itemHeight,
        itemBuilder: (BuildContext context, int index) {
          return ColoredBox(
            color: index.isEven
                ? theme.colorScheme.surfaceContainerLow
                : theme.colorScheme.surfaceContainerHigh,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 24),
                SizedBox(
                  width: 110,
                  child: Text(
                    '$index',
                    style: theme.textTheme.displaySmall,
                  ),
                ),
                Text(
                  'of ${_itemCount - 1}',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 4 — Pinch (pass item 6: smooth scale, no GtkGestureZoom double
// delivery — U1)
// ---------------------------------------------------------------------------

enum _PinchMode { viewer, raw }

class PinchPage extends StatefulWidget {
  const PinchPage({super.key});

  @override
  State<PinchPage> createState() => _PinchPageState();
}

class _PinchPageState extends State<PinchPage> {
  _PinchMode _mode = _PinchMode.viewer;

  // InteractiveViewer mode.
  final TransformationController _transformation = TransformationController();
  double _viewerScale = 1.0;

  // Raw GestureDetector mode.
  String _rawPhase = 'idle';
  double _rawScale = 1.0;
  Offset _rawFocalPoint = Offset.zero;
  int _rawPointerCount = 0;

  @override
  void initState() {
    super.initState();
    _transformation.addListener(_onTransformationChanged);
  }

  @override
  void dispose() {
    _transformation
      ..removeListener(_onTransformationChanged)
      ..dispose();
    super.dispose();
  }

  void _onTransformationChanged() {
    final double scale = _transformation.value.getMaxScaleOnAxis();
    if (scale != _viewerScale) {
      setState(() => _viewerScale = scale);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pinch / zoom')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<_PinchMode>(
              segments: const <ButtonSegment<_PinchMode>>[
                ButtonSegment<_PinchMode>(
                  value: _PinchMode.viewer,
                  icon: Icon(Icons.grid_on),
                  label: Text('InteractiveViewer'),
                ),
                ButtonSegment<_PinchMode>(
                  value: _PinchMode.raw,
                  icon: Icon(Icons.radar),
                  label: Text('Raw onScale'),
                ),
              ],
              selected: <_PinchMode>{_mode},
              onSelectionChanged: (Set<_PinchMode> selection) =>
                  setState(() => _mode = selection.first),
            ),
          ),
          Expanded(
            child: _mode == _PinchMode.viewer
                ? _buildViewerMode(context)
                : _buildRawMode(context),
          ),
        ],
      ),
    );
  }

  Widget _buildViewerMode(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        _ReadoutBar(
          text: 'scale ${_viewerScale.toStringAsFixed(3)}'
              '   (minScale 0.5, maxScale 8)',
          trailing: TextButton(
            onPressed: () => _transformation.value = Matrix4.identity(),
            child: const Text('Reset'),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: InteractiveViewer(
              transformationController: _transformation,
              minScale: 0.5,
              maxScale: 8,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              child: GridPaper(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
                interval: 100,
                divisions: 2,
                subdivisions: 4,
                child: const SizedBox(
                  width: 1600,
                  height: 1600,
                  child: Center(
                    child: Text(
                      '100 px grid — pinch to zoom, drag to pan',
                      style: TextStyle(fontSize: 20),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRawMode(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (ScaleStartDetails details) {
        debugPrint('[pinch-raw] start focal=${details.localFocalPoint} '
            'pointers=${details.pointerCount}');
        setState(() {
          _rawPhase = 'start';
          _rawScale = 1.0;
          _rawFocalPoint = details.localFocalPoint;
          _rawPointerCount = details.pointerCount;
        });
      },
      onScaleUpdate: (ScaleUpdateDetails details) {
        setState(() {
          _rawPhase = 'update';
          _rawScale = details.scale;
          _rawFocalPoint = details.localFocalPoint;
          _rawPointerCount = details.pointerCount;
        });
      },
      onScaleEnd: (ScaleEndDetails details) {
        debugPrint('[pinch-raw] end lastScale=$_rawScale '
            'pointers=${details.pointerCount}');
        setState(() {
          _rawPhase = 'end';
          _rawPointerCount = details.pointerCount;
        });
      },
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Pinch anywhere on this page',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            Text(
              'phase         $_rawPhase\n'
              'scale         ${_rawScale.toStringAsFixed(3)}\n'
              'focalPoint    (${_rawFocalPoint.dx.toStringAsFixed(1)}, '
              '${_rawFocalPoint.dy.toStringAsFixed(1)})\n'
              'pointerCount  $_rawPointerCount',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 22,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Pass bar: scale tracks the fingers smoothly with no jumps. '
                'A sudden doubled step would mean GtkGestureZoom is also '
                'claiming the touch sequence (runbook U1).',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadoutBar extends StatelessWidget {
  const _ReadoutBar({required this.text, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
