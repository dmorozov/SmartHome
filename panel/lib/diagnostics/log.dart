import 'package:flutter/foundation.dart';

/// Structured diagnostics: one event, one greppable line.
///
///     [panel] I hub.connected url=ws://localhost:8123/api/websocket devices=33
///     [panel] W hub.missing_entities ids=sensor.oven,climate.ecobee
///     [panel] E hub.auth_invalid reason="Invalid access token"
///
/// The Panel lives on a wall with no keyboard and nobody watching a
/// console, so this is the only channel through which it can explain
/// itself after the fact. The same lines reach every place the Panel runs:
/// `flutter run`, the browser console (filterable on the `[panel]` prefix
/// by tooling that reads console messages), and journald on the appliance.
///
/// The format is deliberately `area.event key=value` rather than prose:
/// `journalctl | grep '\[panel\] E'` is the intended reading experience.
///
/// **Never log a secret.** The Hub token in particular: these lines outlive
/// the process, and Home Assistant's own websocket debug logging already
/// makes that mistake (see hub/dev/README.md). Log `token=set` instead.
enum LogLevel {
  debug('D'),
  info('I'),
  warn('W'),
  error('E'),

  /// Emit nothing. Tests use it; `--dart-define=LOG=off` silences a build.
  off('-');

  const LogLevel(this.mark);

  /// Single character in the emitted line — keeps `grep ' E '` short.
  final String mark;
}

/// One emitted event. Tests assert against these rather than parsing text.
@immutable
class LogRecord {
  const LogRecord(
    this.level,
    this.area,
    this.event, {
    this.fields,
    this.error,
    this.stack,
  });

  /// Subsystem: `panel`, `house`, `hub`, `ui`, `flutter`, `dart`.
  final String area;

  /// What happened, snake_case, stable enough to grep for over months.
  final String event;

  final LogLevel level;
  final Map<String, Object?>? fields;
  final Object? error;
  final StackTrace? stack;

  /// No timestamp on purpose: every consumer (journald, the browser
  /// console, `flutter run`) stamps its own, and a second one only makes
  /// the line harder to read.
  @override
  String toString() {
    final out = StringBuffer('[panel] ${level.mark} $area.$event');
    fields?.forEach((key, value) => out.write(' $key=${_render(value)}'));
    if (error != null) out.write(' error=${_render(error)}');
    return out.toString();
  }
}

abstract final class Log {
  static const _configured = String.fromEnvironment('LOG');

  /// Everything at this level or above is emitted. A debug build is chatty
  /// (every state change, every tap); the kiosk's release build is not.
  /// Override either way with `--dart-define=LOG=debug|info|warn|error|off`.
  static LogLevel level =
      _parseLevel(_configured) ?? (kReleaseMode ? LogLevel.info : LogLevel.debug);

  /// Guard for call sites that would build a map per frame or per Hub
  /// message: `if (Log.isDebug) Log.debug(...)`.
  static bool get isDebug => LogLevel.debug.index >= level.index;

  /// Where records go. Tests swap this for a list and restore
  /// [printRecord] afterwards.
  static void Function(LogRecord record) sink = printRecord;

  /// The default [sink]: [debugPrint], which reaches stdout on every
  /// platform the Panel runs on.
  static void printRecord(LogRecord record) {
    debugPrint(record.toString());
    final stack = record.stack;
    if (stack != null) debugPrint(stack.toString().trimRight());
  }

  static void debug(String area, String event,
          [Map<String, Object?>? fields]) =>
      _log(LogLevel.debug, area, event, fields);

  static void info(String area, String event, [Map<String, Object?>? fields]) =>
      _log(LogLevel.info, area, event, fields);

  static void warn(String area, String event, [Map<String, Object?>? fields]) =>
      _log(LogLevel.warn, area, event, fields);

  static void error(
    String area,
    String event, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stack,
  }) =>
      _log(LogLevel.error, area, event, fields, error: error, stack: stack);

  /// Routes framework and uncaught-zone errors through the same channel, so
  /// a crash on the wall panel leaves a `[panel] E` line behind instead of
  /// only a red screen nobody is standing in front of.
  ///
  /// Call once, from `main`. Widget tests must not: they install their own
  /// error handling, and this would report every deliberately-thrown error
  /// twice.
  static void installErrorHandlers() {
    if (_configured.isNotEmpty && _parseLevel(_configured) == null) {
      // Reported, not thrown. A typo in a diagnostics flag must never be the
      // reason a wall panel comes up to a black screen — which is precisely
      // the situation this logging exists to explain.
      warn('panel', 'bad_log_level', {
        'value': _configured,
        'using': level.name,
        'expected': LogLevel.values.map((l) => l.name).join('|'),
      });
    }
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      Log.error(
        'flutter',
        'error',
        fields: {
          'library': details.library,
          'context': details.context?.toDescription(),
        },
        error: details.exception,
        stack: details.stack,
      );
      // Keep the framework's own (much richer) debug-mode dump.
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      Log.error('dart', 'uncaught', error: error, stack: stack);
      // Not handled — let the platform do whatever it would have done.
      return false;
    };
  }

  static void _log(
    LogLevel at,
    String area,
    String event,
    Map<String, Object?>? fields, {
    Object? error,
    StackTrace? stack,
  }) {
    if (at.index < level.index) return;
    sink(LogRecord(at, area, event,
        fields: fields, error: error, stack: stack));
  }

  static LogLevel? _parseLevel(String name) {
    for (final level in LogLevel.values) {
      if (level.name == name) return level;
    }
    return null;
  }
}

/// Values are rendered bare unless they would break the `key=value` shape.
String _render(Object? value) {
  final text = '$value';
  if (text.isEmpty) return '""';
  if (!_needsQuoting.hasMatch(text)) return text;
  return '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
}

final _needsQuoting = RegExp(r'[\s"=]');
