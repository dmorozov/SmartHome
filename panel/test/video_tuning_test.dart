import 'package:flutter_test/flutter_test.dart';
import 'package:panel/config/video_tuning.dart';

/// How the RTSP transport is tuned, one case per rule.
///
/// These four settings had no test at all until 2026-09-04. They were parsed
/// by ~50 lines inside `main()`, which no test binary runs, and stored in
/// process-wide globals — so the only way to find out what
/// `VIDEO_DECODERS=auto` did was to read the parser, and the only way to find
/// out what a typo did was to ship it. Every rule the parser has is asserted
/// here, including the ones whose answer is "quietly keep the default", which
/// is a decision rather than an absence and is argued for on
/// [resolveRtspTuning].
void main() {
  group('precedence — the environment beats the build, like every Hub '
      'setting', () {
    test('the environment wins', () {
      final tuning = resolveRtspTuning(
        environment: {'VIDEO_DECODERS': 'CUDA,FFmpeg'},
        buildDecoders: 'VAAPI',
      );

      expect(tuning.decoders, ['CUDA', 'FFmpeg']);
    });

    test('a build define is used when the environment is silent', () {
      final tuning = resolveRtspTuning(
        environment: const {},
        buildDecoders: 'VAAPI',
      );

      expect(tuning.decoders, ['VAAPI']);
    });

    test('an empty environment variable counts as absent, so a blank value '
        'exported by a shell cannot defeat the build', () {
      final tuning = resolveRtspTuning(
        environment: {'VIDEO_DECODERS': '', 'VIDEO_LOW_LATENCY': ''},
        buildDecoders: 'VAAPI',
        buildLowLatency: '1',
      );

      expect(tuning.decoders, ['VAAPI']);
      expect(tuning.lowLatency, 1);
    });

    test('with neither, the shipped defaults stand — and they are the ones '
        'the wall runs on', () {
      final tuning = resolveRtspTuning(environment: const {});

      expect(tuning.decoders, ['FFmpeg'], reason: 'software decode');
      expect(tuning.lowLatency, 0, reason: '1 drops the first key frame');
      expect(tuning.framePulse, isFalse, reason: 'off since 2026-09-04');
      expect(tuning.debug, isFalse);
      expect(tuning, isA<RtspTuning>());
      expect(const RtspTuning().decoders, tuning.decoders,
          reason: 'the const default and the resolved default are one value, '
              'so a session constructed without a tuning behaves as the wall '
              'does');
    });
  });

  group('decoders', () {
    test('`auto` is null, not an empty list — fvp reads an empty list as '
        '"use no decoder at all", which is a black wall', () {
      expect(
          resolveRtspTuning(environment: {'VIDEO_DECODERS': 'auto'}).decoders,
          isNull);
      expect(
          resolveRtspTuning(environment: {'VIDEO_DECODERS': ' AUTO '}).decoders,
          isNull,
          reason: 'an operator typing it by hand should not have to match '
              'case or trim');
    });

    test('a list is split and trimmed, so the fallback order an operator '
        'types with spaces is the order fvp is given', () {
      expect(
          resolveRtspTuning(environment: {'VIDEO_DECODERS': 'CUDA, VAAPI ,FFmpeg'})
              .decoders,
          ['CUDA', 'VAAPI', 'FFmpeg']);
    });

    test('a list that names nothing is the same instruction as `auto`', () {
      // `VIDEO_DECODERS=,` and friends. Handing fvp the empty list this
      // parses to would tell it to use no decoder at all — the one answer
      // that is certainly not what somebody typing a comma meant.
      expect(resolveRtspTuning(environment: {'VIDEO_DECODERS': ','}).decoders,
          isNull);
      expect(resolveRtspTuning(environment: {'VIDEO_DECODERS': ' , '}).decoders,
          isNull);
    });
  });

  group('lowLatency', () {
    test('a number is taken as given — the knob exists to reproduce the '
        'macroblock fault, so 1 has to be reachable', () {
      expect(
          resolveRtspTuning(environment: {'VIDEO_LOW_LATENCY': '1'}).lowLatency,
          1);
    });

    test('anything unparseable falls back to 0, which is the only safe '
        'value anyway', () {
      expect(
          resolveRtspTuning(environment: {'VIDEO_LOW_LATENCY': 'yes'})
              .lowLatency,
          0);
    });
  });

  group('the frame pulse', () {
    test('off unless somebody asks for it — the fault it worked around was '
        "Impeller's and is pinned away (ADR-0012)", () {
      expect(resolveRtspTuning(environment: const {}).framePulse, isFalse);
    });

    test('VIDEO_REPAINT_PULSE=on is the rescue path, and it needs no '
        'rebuild — one Environment= line and a restart', () {
      expect(
          resolveRtspTuning(environment: {'VIDEO_REPAINT_PULSE': 'on'})
              .framePulse,
          isTrue);
      expect(
          resolveRtspTuning(environment: {'VIDEO_REPAINT_PULSE': ' ON '})
              .framePulse,
          isTrue);
    });

    test('a word that is neither leaves the shipped behaviour rather than '
        'guessing', () {
      // The failure this avoids is silent either way, so it goes to the
      // setting the wall is known to run on: a typo that turned the pulse ON
      // would quietly cost a per-vsync repaint nobody asked for.
      expect(
          resolveRtspTuning(environment: {'VIDEO_REPAINT_PULSE': 'yes'})
              .framePulse,
          isFalse);
    });
  });

  group('debug', () {
    test('VIDEO_DEBUG=on, and nothing else, turns the instrumentation on', () {
      expect(resolveRtspTuning(environment: {'VIDEO_DEBUG': 'on'}).debug,
          isTrue);
      expect(resolveRtspTuning(environment: {'VIDEO_DEBUG': '1'}).debug,
          isFalse,
          reason: 'a line per second per stream is not something to enable by '
              'accident');
      expect(resolveRtspTuning(environment: const {}).debug, isFalse);
    });
  });

  group('the boot line', () {
    test('reports the values that were used, so a wall with a wrong picture '
        'can be diagnosed from the journal alone', () {
      expect(
          resolveRtspTuning(environment: const {}).logFields,
          {'decoders': 'FFmpeg', 'low_latency': 0, 'repaint_pulse': 'off'});
    });

    test('`auto` is named rather than left blank — "fvp chose" and "nobody '
        'said" are different answers', () {
      expect(
          resolveRtspTuning(environment: {'VIDEO_DECODERS': 'auto'})
              .logFields['decoders'],
          'fvp_default');
    });

    test('a list is joined, and the order is the fallback order', () {
      expect(
          resolveRtspTuning(environment: {
            'VIDEO_DECODERS': 'CUDA,FFmpeg',
            'VIDEO_LOW_LATENCY': '1',
            'VIDEO_REPAINT_PULSE': 'on',
          }).logFields,
          {
            'decoders': 'CUDA,FFmpeg',
            'low_latency': 1,
            'repaint_pulse': 'on',
          });
    });
  });
}
