import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/log.dart';
import '../ui/cameras/camera_order.dart';

/// Where the Cameras arrangement lives between runs.
///
/// **Per screen, not per house**, and that is the decision rather than an
/// accident of the plugin: the wall and the web second screen keep their own
/// order, because a screen in another room may well want a different camera
/// first. The alternative that was weighed and dropped was an HA helper
/// entity — one order shared by every screen, at the cost of the arrangement
/// failing exactly when the Hub is unreachable, which is the moment the
/// Panel is supposed to keep working alone (ADR-0007).
///
/// [SharedPreferencesAsync] rather than `SharedPreferences.getInstance()`:
/// the plugin's own docs call the instance API legacy and slated for
/// deprecation, and the cache it exists to provide buys nothing here —
/// [CameraOrderStore] already holds the value in memory, reads it once at
/// boot, and never reads it again.
///
/// On the appliance this lands in the XDG data dir the Linux implementation
/// picks; on the web build it is `localStorage`, which is why a browser
/// profile wipe forgets the arrangement and nothing else does.

/// The one key. Prefixed because [SharedPreferencesAsync] shares a namespace
/// with anything else the Panel ever stores.
const _key = 'panel.cameras.order';

/// Reads the saved arrangement and returns a store that writes changes back.
///
/// **Never throws**, and the Panel would still come up if it did not need to
/// be told that twice: a wall that refuses to start because a preferences
/// file is corrupt is a worse failure than a wall that starts in plan order.
/// A failed read is logged and treated as "no arrangement yet"; the first
/// drag then overwrites whatever was unreadable.
Future<CameraOrderStore> loadCameraOrder() async {
  final prefs = SharedPreferencesAsync();
  var initial = const <String>[];
  try {
    initial = await prefs.getStringList(_key) ?? const <String>[];
  } catch (error) {
    // Type only — a storage error's message can carry a path (log.dart).
    Log.warn('cameras', 'order_load_failed', {
      'error': error.runtimeType.toString(),
    });
  }
  Log.info('cameras', 'order_loaded', {'saved': initial.length});
  return CameraOrderStore(
    initial: initial,
    write: (order) => prefs.setStringList(_key, order),
  );
}
