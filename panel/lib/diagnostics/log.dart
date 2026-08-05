import 'package:flutter/foundation.dart';

import 'url_redaction.dart';

/// Structured diagnostics: one event, one greppable line.
///
///     [panel] I hub.connected url=ws://localhost:8123 devices=33
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

  /// Emit nothing. Tests use it; `LOG=off` in the environment — or
  /// `--dart-define=LOG=off`, the only route on web — silences a Panel.
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

  /// Subsystem: `panel`, `house`, `hub`, `ui`, `popup`, `flutter`, `dart`.
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
    // The `error=` field is the one this class cannot reason about: `fields`
    // are chosen by a call site that knows what it is saying, while an
    // exception's text is composed by whatever threw it — Dart, a package, a
    // remote process — and two of the sites that reach here
    // (`flutter.error`, `dart.uncaught`) have no call site to guard at all.
    //
    // The measured case, and the reason this is here rather than at each
    // thrower: `HaHubClient.webSocketUrl` used `Uri.parse`, whose
    // FormatException reproduces the whole source string with a caret under
    // the offending character. A password containing `@` — the commonest
    // special character there is, and one RFC 3986 says to percent-encode and
    // nobody does — made `HA_URL` land in journald verbatim, at E level, on
    // every boot of a Panel that then restarts forever under systemd. Six
    // rounds of fixing this per-channel each missed a channel; the class is
    // "free-form text the Panel did not compose", and this is where all of it
    // converges.
    //
    // Defence in depth, NOT a replacement for the call-site rules: this runs
    // over a rendered string and cannot see structure, so a site that knows
    // its value is a URL should still say so through `urlForLog`. Rejected:
    // redacting `stack` too — a stack trace's `file:///…` frames are not
    // credentials, and cutting them to their host would destroy the one
    // artefact a crash leaves worth reading.
    if (error != null) out.write(' error=${_render(redactCredentials('$error'))}');
    return out.toString();
  }
}

abstract final class Log {
  /// The `LOG` compiled into this build; empty where the define was omitted.
  /// Still a const: web has no process environment, so on `-d chrome` a
  /// `--dart-define` stays the only route (see `config/runtime_env.dart`).
  static const _buildLevel = String.fromEnvironment('LOG');

  /// Everything at this level or above is emitted. A debug build is chatty
  /// (every state change, every tap); the kiosk's release build is not.
  ///
  /// This is the value before anything has said otherwise — the build's
  /// `--dart-define=LOG=…`, else the per-mode default. [applyLevel] is what
  /// gives the *environment* the last word, and `main()` calls it: a wall
  /// panel whose log level can only be raised by rebuilding it is a wall
  /// panel whose logs cannot be raised.
  static LogLevel level = _parseLevel(_buildLevel) ??
      (kReleaseMode ? LogLevel.info : LogLevel.debug);

  /// Resolves [level] from the runtime [environment], then the build's
  /// `--dart-define=LOG=…` ([buildLevel], defaulted from it), then the
  /// per-mode default — the **environment-first** order `resolveHubConfig`
  /// uses for `HUB`/`HA_URL`/`HA_TOKEN`, for the same reason: on the
  /// appliance the level is an operational setting, not a property of the
  /// binary. An empty value counts as absent there too, so a shell that
  /// exports `LOG=` cannot blank out a deliberate define.
  ///
  /// Returns the winning origin — `environment` | `build` | `default` — for
  /// the `panel.start` line. A level that did not take is otherwise
  /// invisible, most of all on web, where there is no process environment
  /// and `LOG=debug flutter run -d chrome` silently changes nothing.
  ///
  /// **Takes the environment; never reads it.** [Log] is reachable from
  /// every module, `bootPanel` included, and `bootPanel`'s contract is that
  /// it reads no files and no environment. A static initializer reading
  /// `Platform.environment` would break that contract transitively, at
  /// whichever arbitrary moment the first log line happened to be emitted.
  /// `main()` stays the only thing in the Panel that touches the
  /// environment; [buildLevel] exists so every precedence case is reachable
  /// from a test.
  ///
  /// A value neither origin can parse is reported, not thrown: a typo in a
  /// diagnostics flag must never be the reason a wall panel comes up to a
  /// black screen — precisely the situation this logging exists to explain.
  static String applyLevel(
    Map<String, String> environment, {
    String? buildLevel,
  }) {
    final fromBuild = buildLevel ?? _buildLevel;
    final fromEnv = environment['LOG'] ?? '';
    final chosen = fromEnv.isNotEmpty ? fromEnv : fromBuild;
    final origin = fromEnv.isNotEmpty
        ? 'environment'
        : (fromBuild.isNotEmpty ? 'build' : 'default');
    final parsed = _parseLevel(chosen);
    level = parsed ?? (kReleaseMode ? LogLevel.info : LogLevel.debug);
    if (parsed != null) return origin;
    if (chosen.isNotEmpty) {
      warn('panel', 'bad_log_level', {
        'value': chosen,
        'from': origin,
        'using': level.name,
        'expected': LogLevel.values.map((l) => l.name).join('|'),
      });
    }
    return 'default';
  }

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
