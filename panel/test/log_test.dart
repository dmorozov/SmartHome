import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';

void main() {
  late List<LogRecord> records;

  setUp(() {
    records = [];
    Log.sink = records.add;
    Log.level = LogLevel.debug;
  });

  tearDown(() {
    Log.sink = Log.printRecord;
    Log.level = LogLevel.warn;
  });

  test('renders one greppable line per event', () {
    Log.info('hub', 'connected', {'url': 'ws://localhost:8123', 'devices': 33});

    expect(records.single.toString(),
        '[panel] I hub.connected url=ws://localhost:8123 devices=33');
  });

  test('quotes only values that would break key=value', () {
    Log.warn('hub', 'state_unusable', {
      'plain': 'Idle',
      'spaced': 'Cycle · 32 min left',
      'equals': 'a=b',
      'quoted': 'say "hi"',
      'empty': '',
      'missing': null,
    });

    expect(
      records.single.toString(),
      r'[panel] W hub.state_unusable plain=Idle '
      r'spaced="Cycle · 32 min left" equals="a=b" '
      r'quoted="say \"hi\"" empty="" missing=null',
    );
  });

  test('level gates what is emitted', () {
    Log.level = LogLevel.warn;
    Log.debug('ui', 'floor');
    Log.info('ui', 'floor');
    Log.warn('ui', 'floor');
    Log.error('ui', 'floor');

    expect(records.map((r) => r.level),
        [LogLevel.warn, LogLevel.error]);
    expect(Log.isDebug, isFalse);
  });

  test('off silences everything', () {
    Log.level = LogLevel.off;
    Log.error('hub', 'auth_invalid');

    expect(records, isEmpty);
  });

  test('errors carry the exception and its stack', () {
    final stack = StackTrace.current;
    Log.error('house', 'invalid',
        fields: {'file': 'house.yaml'},
        error: const FormatException('duplicate room id'),
        stack: stack);

    final record = records.single;
    expect(record.stack, same(stack));
    expect(
      record.toString(),
      '[panel] E house.invalid file=house.yaml '
      'error="FormatException: duplicate room id"',
    );
  });

  // The level is the one setting an operator reaches for when the Panel is
  // already on the wall and misbehaving, so it resolves the way the Hub
  // settings do (config/hub_config.dart): environment, then the build's
  // define, then the per-mode default. `buildLevel` is passed explicitly so
  // these cases hold whether or not the suite itself was run with
  // `--dart-define=LOG=…`.
  group('level resolution', () {
    test('the environment beats a build define', () {
      expect(Log.applyLevel(const {'LOG': 'error'}, buildLevel: 'debug'),
          'environment');
      expect(Log.level, LogLevel.error);
    });

    test('a build define is used when the environment is silent', () {
      expect(Log.applyLevel(const {}, buildLevel: 'off'), 'build');
      expect(Log.level, LogLevel.off);
    });

    test('an empty environment value does not defeat the define', () {
      // A shell that exports LOG= must not blank out a deliberate define,
      // exactly as for HA_TOKEN.
      expect(Log.applyLevel(const {'LOG': ''}, buildLevel: 'warn'), 'build');
      expect(Log.level, LogLevel.warn);
    });

    test('the per-mode default stands when neither speaks', () {
      expect(Log.applyLevel(const {}, buildLevel: ''), 'default');
      // `flutter test` runs in debug mode; the release build starts at info.
      expect(Log.level, LogLevel.debug);
    });

    test('a typo is reported, never thrown', () {
      expect(
          Log.applyLevel(const {'LOG': 'verbose'}, buildLevel: ''), 'default');
      expect(Log.level, LogLevel.debug);
      expect(
        records.single.toString(),
        '[panel] W panel.bad_log_level value=verbose from=environment '
        'using=debug expected=debug|info|warn|error|off',
      );
    });
  });
}
