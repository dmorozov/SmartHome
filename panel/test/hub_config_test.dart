import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/config/hub_config.dart';
import 'package:panel/config/runtime_env.dart';
import 'package:panel/diagnostics/log.dart';

/// The precedence rule, one case per row. This exists because the rule is
/// the whole feature: `HA_URL` was a compile-time const, so an address that
/// moved invalidated the binary. Every way a setting can arrive — and every
/// way one can be ignored — is asserted here rather than discovered on the
/// appliance.
void main() {
  group('precedence', () {
    test('the environment beats a build define', () {
      final config = resolveHubConfig(
        environment: {'HA_URL': 'http://192.168.68.81:8123'},
        buildUrl: 'http://compiled-in:8123',
      );

      expect(config.url, 'http://192.168.68.81:8123');
      expect(config.sources['HA_URL'], ConfigSource.environment);
    });

    test('a build define is used when the environment is silent', () {
      final config = resolveHubConfig(
        environment: const {},
        buildUrl: 'http://compiled-in:8123',
      );

      expect(config.url, 'http://compiled-in:8123');
      expect(config.sources['HA_URL'], ConfigSource.build);
    });

    test('the built-in default stands when neither speaks', () {
      final config = resolveHubConfig(environment: const {});

      expect(config.kind, defaultHubKind);
      expect(config.url, defaultHaUrl);
      expect(config.token, '');
      expect(config.sources, {
        'HUB': ConfigSource.fallback,
        'HA_URL': ConfigSource.fallback,
        // Not `fallback`: there is no default token, so saying one applied
        // would be a lie the operator has to disprove.
        'HA_TOKEN': ConfigSource.absent,
      });
    });

    test('every setting resolves independently', () {
      final config = resolveHubConfig(
        environment: {'HA_URL': 'http://from-env:8123'},
        buildKind: 'ha',
        // HA_TOKEN supplied by neither.
      );

      expect(config.kind, 'ha');
      expect(config.url, 'http://from-env:8123');
      expect(config.token, '');
      expect(config.sources, {
        'HUB': ConfigSource.build,
        'HA_URL': ConfigSource.environment,
        'HA_TOKEN': ConfigSource.absent,
      });
    });
  });

  group('an ambient override is reported', () {
    test('a setting the environment took from a define is named', () {
      final config = resolveHubConfig(
        environment: {'HA_URL': 'http://ambient:8123', 'HUB': 'ha'},
        buildUrl: 'http://i-typed-this:8123',
        buildKind: 'ha',
      );

      // HA_URL: both origins spoke and disagreed — surprising, so reported.
      // HUB: both spoke and agreed — nothing surprising happened.
      expect(config.overridden, ['HA_URL']);
    });

    test('nothing is reported when only one origin spoke', () {
      final config = resolveHubConfig(
        environment: {'HA_URL': 'http://ambient:8123'},
      );

      expect(config.overridden, isEmpty);
    });
  });

  group('the value is a value', () {
    test('sources and overridden cannot be edited after construction', () {
      final config = resolveHubConfig(environment: const {});

      expect(() => config.sources['HUB'] = ConfigSource.build,
          throwsUnsupportedError);
      expect(() => config.overridden.add('HUB'), throwsUnsupportedError);
    });
  });

  group('empty counts as absent', () {
    test('an empty environment variable does not defeat a build define', () {
      // A shell that exports HA_TOKEN= (unset-ish, or a `$(cat missing)`
      // that produced nothing) must not blank out the token a build was
      // deliberately compiled with.
      final config = resolveHubConfig(
        environment: {'HA_TOKEN': '', 'HA_URL': ''},
        buildToken: 'a-token',
        buildUrl: 'http://compiled-in:8123',
      );

      expect(config.token, 'a-token');
      expect(config.url, 'http://compiled-in:8123');
      expect(config.sources['HA_TOKEN'], ConfigSource.build);
      expect(config.sources['HA_URL'], ConfigSource.build);
    });

    test('an empty build define falls through to the default', () {
      final config = resolveHubConfig(environment: const {}, buildUrl: '');

      expect(config.url, defaultHaUrl);
      expect(config.sources['HA_URL'], ConfigSource.fallback);
    });
  });

  group('diagnostics', () {
    test('log fields carry origins, never values', () {
      const secret = 'super-secret-token-abc123';
      final config = resolveHubConfig(
        environment: {'HA_TOKEN': secret, 'HA_URL': 'http://from-env:8123'},
      );

      expect(config.logFields, {
        'HUB': 'fallback',
        'HA_URL': 'environment',
        'HA_TOKEN': 'environment',
      });
      // The whole rendered map, as a sink or journald would see it.
      expect(config.logFields.toString(), isNot(contains(secret)));
    });

    test('the emitted line is the one the READMEs promise', () {
      // panel/README.md, hub/dev/README.md and phase-1 all quote this line
      // as the way to tell a stale address from a dead Hub. Pinning it here
      // means those docs cannot quietly drift from what actually prints.
      final config = resolveHubConfig(
        environment: {'HA_URL': 'http://192.168.68.81:8123', 'HA_TOKEN': 'x'},
        buildKind: 'ha',
      );

      expect(
        LogRecord(LogLevel.info, 'hub', 'config', fields: config.logFields)
            .toString(),
        '[panel] I hub.config HUB=build HA_URL=environment '
            'HA_TOKEN=environment',
      );
    });
  });

  group('an unknown kind is not this function\'s business', () {
    test('it is passed through for bootPanel to refuse by name', () {
      // Validation lives in exactly one place — the one that already names
      // the choices ("unknown HUB \\"mqtt\\" (fake | ha)").
      final config = resolveHubConfig(environment: {'HUB': 'mqtt'});

      expect(config.kind, 'mqtt');
    });
  });

  group('runtimeEnvironment', () {
    test('is readable and never throws on this platform', () {
      // On the VM this is the real process environment; on web it is empty
      // by construction. Both are valid — the contract is only that asking
      // is safe, because main() asks unconditionally.
      expect(runtimeEnvironment(), isA<Map<String, String>>());
    });

    test('the platform split is asserted, not assumed', () {
      // Run this file with `--platform chrome` and the other branch is
      // checked: web must select runtime_env_none.dart, or a documented
      // `HA_URL=… flutter run -d chrome` would quietly do nothing.
      if (kIsWeb) {
        expect(environmentIsAvailable, isFalse);
        expect(runtimeEnvironment(), isEmpty);
      } else {
        expect(environmentIsAvailable, isTrue);
      }
    });
  });
}
