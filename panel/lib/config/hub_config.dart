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

/// The Panel's runtime addresses, plus where each one came from.
///
/// Not "the Hub settings" any more, and the rename is the point: three of
/// these travel on to `bootPanel`, while [go2rtcUrl] goes to the widget tree
/// instead (`main.dart`). What they have in common is the thing this type
/// exists for — every one of them is an address of a daemon on the Hub box,
/// and for every one of them "pointed at the wrong place" and "the right
/// place is down" look identical until [sources] says which.
///
/// The values are plain strings because their consumers take plain strings —
/// this type exists to resolve them, not to travel any further.
@immutable
class HubConfig {
  const HubConfig({
    required this.kind,
    required this.url,
    required this.token,
    required this.go2rtcUrl,
    required this.sources,
    required this.overridden,
  });

  /// `fake` | `ha`. Validated by `bootPanel`, not here: an unknown kind must
  /// fail in the one place that already names the choices.
  final String kind;

  final String url;

  final String token;

  /// Base address of the go2rtc daemon the Popup plays camera streams from,
  /// e.g. `http://192.168.68.81:1984`. Empty where nobody named one — see
  /// [ConfigSource.absent] and [defaultHaUrl]'s neighbour comment for why
  /// there is no built-in default here.
  final String go2rtcUrl;

  /// Setting name (`HUB`, `HA_URL`, `HA_TOKEN`, `GO2RTC_URL`) to its origin.
  /// Rendered into the boot diagnostic — names and origins only, never the
  /// token itself (log.dart: **Never log a secret**). Unmodifiable: this is
  /// a value.
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
///
/// There is deliberately no `defaultGo2rtcUrl`. [defaultHaUrl] is earned
/// because [defaultHubKind] gates it — on a bare `flutter run` the Hub is
/// fake and that address is never dialled. Video has no such gate: a camera
/// is a camera under every Hub, so a `http://localhost:1984` default would
/// open a socket to nothing on every hermetic run, and — unlike `HA_URL`,
/// which has a badge — a wrong go2rtc address is invisible until somebody
/// taps a camera pin. `GO2RTC_URL=absent` on the boot line says "nobody has
/// told me where go2rtc is"; `=fallback` could not.
const defaultHubKind = 'fake';
const defaultHaUrl = 'http://localhost:8123';

/// Resolves the Panel's runtime addresses from the runtime [environment] and
/// the build's dart-defines, **runtime first**.
///
/// The order is the whole point. `HA_URL` used to be a compile-time const,
/// so moving the Hub — or letting an unreserved DHCP lease move it —
/// invalidated the Panel binary. Reading the environment first makes the
/// address an operational setting: on the appliance, systemd supplies it and
/// a rebuild is never involved.
///
/// Build defines remain the fallback so the documented dev loop
/// (`flutter run -d web-server --dart-define=HA_URL=...`) is unchanged, and
/// so the web build — which has no process environment — behaves exactly as
/// it did.
///
/// An environment variable that is present but **empty** counts as absent. A
/// blank `HA_TOKEN` exported by a shell should not silently defeat the token
/// compiled into a build; and `bootPanel`'s "token=absent" refusal stays the
/// one place an empty token is diagnosed.
///
/// `GO2RTC_URL` resolves here rather than in a reader of its own, unlike
/// `LOG`. `LOG` earned its own path because it is not an address and putting
/// it on the `hub.config` line would blunt that line's one job. `GO2RTC_URL`
/// is the same species of fact as `HA_URL` — the address of a daemon on the
/// Hub box, whose staleness is indistinguishable from its being down — which
/// is precisely what `hub.config` exists to disambiguate.
///
/// Pure: reads nothing itself, so every precedence case is reachable from a
/// test. `main()` supplies the environment; [runtimeEnvironment] fetches it.
HubConfig resolveHubConfig({
  required Map<String, String> environment,
  String? buildKind,
  String? buildUrl,
  String? buildToken,
  String? buildGo2rtcUrl,
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

  // Argument order is load-bearing, not cosmetic: `sources` is a
  // LinkedHashMap filled in `pick()` call order and Dart evaluates named
  // arguments in source order, so this list is what decides that the boot
  // line reads `… HA_TOKEN=… GO2RTC_URL=…` and not the other way round.
  // A test pins that line verbatim because three READMEs quote it.
  return HubConfig(
    kind: pick('HUB', buildKind, defaultHubKind),
    url: pick('HA_URL', buildUrl, defaultHaUrl),
    token: pick('HA_TOKEN', buildToken, ''),
    go2rtcUrl: pick('GO2RTC_URL', buildGo2rtcUrl, ''),
    sources: Map.unmodifiable(sources),
    overridden: List.unmodifiable(overridden),
  );
}
