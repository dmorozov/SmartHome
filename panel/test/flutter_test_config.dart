import 'dart:async';

import 'package:panel/diagnostics/log.dart';

/// Applies to every test under `test/` — flutter_test finds this file by
/// walking up from each test file.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The Panel is chatty by default in debug builds, which is right on a
  // wall panel and wrong in test output. Warnings and errors still come
  // through: a test that provokes `hub.missing_entities` should say so.
  // Tests that assert on records set their own level and sink.
  Log.level = LogLevel.warn;
  await testMain();
}
