import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/cameras/camera_order.dart';

/// The ordering rules behind the Cameras grid, and the store that keeps an
/// arrangement alive across a restart.
///
/// Pure and hermetic on purpose: everything here is a function over plain
/// data or a notifier with a stubbed writer, so the awkward cases — a camera
/// removed from the plan, a camera added since the last drag, a write that
/// throws — can be stated directly instead of dragged into existence.
void main() {
  Device camera(String id, {String? stream, String? snapshot}) => Device(
    id: id,
    name: id,
    kind: DeviceKind.camera,
    connectivity: Connectivity.local,
    position: Offset.zero,
    streamName: stream,
    snapshotEntityId: snapshot,
  );

  group('which cameras count as set up', () {
    test('a stream is enough, and so is a snapshot on its own', () {
      expect(cameraIsWired(camera('a', stream: 's')), isTrue);
      expect(cameraIsWired(camera('b', snapshot: 'camera.b')), isTrue);
      expect(cameraIsWired(camera('c')), isFalse);
    });

    test(
      'a camera whose daemon is dead is still SET UP — the plan decides '
      'this, not the health probe, or the grid would reshuffle itself '
      'every time a Wyze firmware sulked',
      () {
        // Nothing in this file can consult Camera Health even if it wanted
        // to; the test is here so that stays true on purpose.
        expect(cameraIsWired(camera('offline-right-now', stream: 's')), isTrue);
      },
    );
  });

  group('arranging', () {
    final plan = [
      camera('a', stream: 's'),
      camera('unwired'),
      camera('b', stream: 's'),
      camera('c', stream: 's'),
    ];

    test('with nothing saved, plan order stands and the unwired sink', () {
      final arranged = arrangeCameras(plan, const []);
      expect(arranged.wired.map((d) => d.id), ['a', 'b', 'c']);
      expect(arranged.unwired.map((d) => d.id), ['unwired']);
      expect(arranged.ids, ['a', 'b', 'c', 'unwired']);
    });

    test('a saved order wins inside the group', () {
      expect(arrangeCameras(plan, ['c', 'a', 'b']).ids, [
        'c',
        'a',
        'b',
        'unwired',
      ]);
    });

    test(
      'the unwired camera stays last however it was saved — the one part '
      'of the order a person cannot drag away',
      () {
        expect(arrangeCameras(plan, ['unwired', 'c', 'b', 'a']).ids, [
          'c',
          'b',
          'a',
          'unwired',
        ]);
      },
    );

    test('an id no longer in the plan evaporates, with no cleanup pass', () {
      expect(arrangeCameras(plan, ['gone', 'c', 'sold']).ids, [
        'c',
        'a',
        'b',
        'unwired',
      ]);
    });

    test(
      'a camera added to the plan since the last drag lands BEHIND the '
      'arranged ones, not in the middle of somebody arrangement',
      () {
        final grown = [...plan, camera('new', stream: 's')];
        expect(arrangeCameras(grown, ['c', 'a']).ids, [
          'c',
          'a',
          'b',
          'new',
          'unwired',
        ]);
      },
    );

    test('two never-arranged cameras keep plan order, deterministically', () {
      // Dart's sort is not stable, so this is a property of the comparator
      // and not of the input. Same answer every time or the grid shuffles
      // itself between builds.
      for (var i = 0; i < 20; i++) {
        expect(arrangeCameras(plan, const ['c']).ids, [
          'c',
          'a',
          'b',
          'unwired',
        ]);
      }
    });
  });

  group('moving one camera', () {
    final order = [
      camera('a', stream: 's'),
      camera('b', stream: 's'),
      camera('c', stream: 's'),
    ];
    List<String> ids(List<Device> devices) => [for (final d in devices) d.id];

    test('dropped onto a later slot, it takes that slot', () {
      expect(ids(moveCamera(order, 'a', 2)), ['b', 'c', 'a']);
    });

    test('dropped onto an earlier slot, it takes that slot', () {
      expect(ids(moveCamera(order, 'c', 0)), ['c', 'a', 'b']);
    });

    test('a one-place move is a real move in both directions', () {
      // The trap this pins: ReorderableListView's convention would make a
      // one-slot downward move a no-op. Nothing here is built on it.
      expect(ids(moveCamera(order, 'a', 1)), ['b', 'a', 'c']);
      expect(ids(moveCamera(order, 'b', 0)), ['b', 'a', 'c']);
    });

    test('an unknown id changes nothing, and returns the same list', () {
      expect(moveCamera(order, 'ghost', 0), same(order));
    });

    test('an out-of-range index clamps instead of throwing', () {
      expect(ids(moveCamera(order, 'a', 99)), ['b', 'c', 'a']);
      expect(ids(moveCamera(order, 'c', -4)), ['c', 'a', 'b']);
    });
  });

  group('the store', () {
    test('starts at whatever storage had', () {
      expect(CameraOrderStore(initial: const ['a', 'b']).value, ['a', 'b']);
      expect(CameraOrderStore().value, isEmpty);
    });

    test('arranging notifies and writes through', () async {
      final written = <List<String>>[];
      final store = CameraOrderStore(
        write: (order) async => written.add(order),
      );
      var notified = 0;
      store.addListener(() => notified++);

      store.arrange(['b', 'a']);
      expect(store.value, ['b', 'a']);
      expect(notified, 1);
      await Future<void>.delayed(Duration.zero);
      expect(written, [
        ['b', 'a'],
      ]);
    });

    test('the same order arranged twice still notifies', () {
      // ValueNotifier compares with `==`, and a list assigned back to itself
      // would be swallowed silently. `arrange` always stores a fresh list —
      // this is what keeps a listener from freezing on an identical value.
      final store = CameraOrderStore();
      var notified = 0;
      store.addListener(() => notified++);
      final same = ['a', 'b'];
      store.arrange(same);
      store.arrange(same);
      expect(notified, 2);
    });

    test('the stored value cannot be mutated behind the store back', () {
      final store = CameraOrderStore(initial: ['a']);
      expect(() => store.value.add('b'), throwsUnsupportedError);
    });

    test('reset forgets the arrangement rather than inverting it', () async {
      final written = <List<String>>[];
      final store = CameraOrderStore(
        initial: const ['b', 'a'],
        write: (order) async => written.add(order),
      );
      store.reset();
      expect(store.value, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(written, [<String>[]]);
    });

    test(
      'a write that throws is logged and swallowed — losing an arrangement '
      'is a disappointment next boot, not something to interrupt the wall',
      () async {
        final records = <LogRecord>[];
        Log.sink = records.add;
        addTearDown(() => Log.sink = Log.printRecord);

        final store = CameraOrderStore(
          write: (_) async => throw const _DiskIsBusy('/home/somebody/.cache'),
        );
        store.arrange(['a']);
        // The value the person dragged stands, whatever storage did.
        expect(store.value, ['a']);
        await Future<void>.delayed(Duration.zero);

        final warned = records.singleWhere(
          (r) => r.event == 'order_save_failed',
        );
        expect(warned.level, LogLevel.warn);
        // Type only: an exception's text can carry a path.
        expect(warned.fields?['error'], '_DiskIsBusy');
        expect(
          warned.fields!.values.join(),
          isNot(contains('/home/somebody')),
        );
      },
    );

    test('a store with no writer just remembers, and never throws', () async {
      final store = CameraOrderStore();
      store.arrange(['a']);
      await Future<void>.delayed(Duration.zero);
      expect(store.value, ['a']);
    });
  });
}

/// A storage failure whose message carries a path — which is the half the
/// log must not repeat.
class _DiskIsBusy implements Exception {
  const _DiskIsBusy(this.path);

  final String path;

  @override
  String toString() => 'could not write $path';
}
