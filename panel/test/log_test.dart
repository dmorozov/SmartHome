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
}
