import 'dart:io';

import 'package:local_notifier/local_notifier.dart';

import 'window_controls.dart';

/// Windows toast notifications for events that need the user while the app
/// is in the background (plan finished, quota over, loop stopped).
class Notifier {
  Notifier._();

  static bool _ready = false;
  static final _lastShown = <String, DateTime>{};

  /// Registers the app with Windows. Toasts need a Start menu shortcut, which
  /// the plugin creates once ("AutoLoop").
  static Future<void> setup() async {
    if (!Platform.isWindows) return;
    try {
      await localNotifier.setup(appName: 'AutoLoop', shortcutPolicy: ShortcutPolicy.requireCreate);
      _ready = true;
    } catch (_) {
      // No notifications is better than a crash.
    }
  }

  /// Shows [title]/[body]. The same title is not repeated within two hours,
  /// so a quota that keeps running out does not notify every retry.
  static void show(String title, String body) {
    if (!_ready) return;
    final now = DateTime.now();
    final last = _lastShown[title];
    if (last != null && now.difference(last) < const Duration(hours: 2)) return;
    _lastShown[title] = now;
    try {
      final n = LocalNotification(title: title, body: body);
      n.onClick = bringWindowToFront;
      n.show();
    } catch (_) {}
  }
}
