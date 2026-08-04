import 'package:flutter/foundation.dart';

/// Where a resolved setting came from. Worth carrying as data: once a
/// setting has two possible origins, "the Panel is pointed at the wrong
/// Hub" and "the Panel is pointed at the right Hub and the Hub is down"
/// look identical on the badge, and only this tells them apart.
enum ConfigSource {
  /// The process environment. Unavailable on web, where there is no such
  /// thing — see `runtime_env.dart`.
  environment,

  /// A `--dart-define` compiled into this build.
  build,

  /// Nothing supplied it; the built-in default stands.
  fallback,

  /// Nothing supplied it and the default is empty — i.e. there is no value
  /// at all. Distinguished from [fallback] so `HA_TOKEN=absent` cannot be
  /// misread as "a default token was used"; it matches the wording
  /// `bootPanel` already uses when it refuses an empty token.
  absent,
}

/// The Hub settings `main()` hands to `bootPanel`, plus where each one came
/// from.
///
/// The values are plain strings because `bootPanel` takes plain strings —
/// this type exists to resolve them, not to travel any further.
@immutable
class HubConfig {
  const HubConfig({
    required this.kind,
    required this.url,
    required this.token,
    required this.sources,
    required this.overridden,
  });

  /// `fake` | `ha`. Validated by `bootPanel`, not here: an unknown kind must
  /// fail in the one place that already names the choices.
  final String kind;

  final String url;

  final String token;

  /// Setting name (`HUB`, `HA_URL`, `HA_TOKEN`) to its origin. Rendered into
  /// the boot diagnostic — names and origins only, never the token itself
  /// (log.dart: **Never log a secret**). Unmodifiable: this is a value.
  final Map<String, ConfigSource> sources;

  /// Settings an environment variable took from a `--dart-define` that also
  /// supplied one. An ambient variable quietly beating the flag the operator
  /// typed is the one genuinely surprising thing about environment-first
  /// order, so it is reported rather than left to be discovered.
  final List<String> overridden;

  /// The `hub.config` log fields: `{HA_URL: environment, ...}`. Safe to log
  /// wholesale because it contains no values.
  Map<String, String> get logFields =>
      {for (final e in sources.entries) e.key: e.value.name};
}

/// Built-in defaults, used when neither the environment nor the build says
/// otherwise. `fake` keeps a bare `flutter run` hermetic.
const defaultHubKind = 'fake';
const defaultHaUrl = 'http://localhost:8123';

/// Resolves the Hub settings from the runtime [environment] and the build's
/// dart-defines, **runtime first**.
///
/// The order is the whole point. `HA_URL` used to be a compile-time const,
/// so moving the Hub — or letting an unreserved DHCP lease move it —
/// invalidated the Panel binary. Reading the environment first makes the
/// address an operational setting: on the appliance, systemd supplies it and
/// a rebuild is never involved.
///
/// Build defines remain the fallback so the documented dev loop
/// (`flutter run -d chrome --dart-define=HA_URL=...`) is unchanged, and so
/// the web build — which has no process environment — behaves exactly as it
/// did.
///
/// An environment variable that is present but **empty** counts as absent. A
/// blank `HA_TOKEN` exported by a shell should not silently defeat the token
/// compiled into a build; and `bootPanel`'s "token=absent" refusal stays the
/// one place an empty token is diagnosed.
///
/// Pure: reads nothing itself, so every precedence case is reachable from a
/// test. `main()` supplies the environment; [runtimeEnvironment] fetches it.
HubConfig resolveHubConfig({
  required Map<String, String> environment,
  String? buildKind,
  String? buildUrl,
  String? buildToken,
}) {
  final sources = <String, ConfigSource>{};
  final overridden = <String>[];

  String pick(String name, String? fromBuild, String fallback) {
    final fromEnv = environment[name];
    final hasBuild = fromBuild != null && fromBuild.isNotEmpty;
    if (fromEnv != null && fromEnv.isNotEmpty) {
      sources[name] = ConfigSource.environment;
      if (hasBuild && fromBuild != fromEnv) overridden.add(name);
      return fromEnv;
    }
    if (hasBuild) {
      sources[name] = ConfigSource.build;
      return fromBuild;
    }
    // "absent" and "fallback" are different answers to "why is it this
    // value": one means a default applied, the other that there is nothing.
    sources[name] =
        fallback.isEmpty ? ConfigSource.absent : ConfigSource.fallback;
    return fallback;
  }

  return HubConfig(
    kind: pick('HUB', buildKind, defaultHubKind),
    url: pick('HA_URL', buildUrl, defaultHaUrl),
    token: pick('HA_TOKEN', buildToken, ''),
    sources: Map.unmodifiable(sources),
    overridden: List.unmodifiable(overridden),
  );
}
