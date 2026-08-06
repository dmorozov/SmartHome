/// The process environment, or an empty map where there is no such thing.
///
/// Conditional export rather than a bare `dart:io` import: the Panel still
/// builds for web (`flutter run -d web-server` is the documented dev loop),
/// and importing `dart:io` anywhere reachable from `main()` breaks that
/// build.
/// On web there is no process environment, so the Panel there is configured
/// by `--dart-define` exactly as it was before.
library;

export 'runtime_env_none.dart' if (dart.library.io) 'runtime_env_io.dart';
