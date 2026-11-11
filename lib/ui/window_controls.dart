import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Hides the native Windows title bar: the app's own top bar takes its place.
void setupWindow() {
  if (!Platform.isWindows) return;
  try {
    final window = WindowManager.instance.getCurrent();
    if (window == null) return;
    window
      ..title = 'AutoLoop'
      ..titleBarStyle = TitleBarStyle.hidden
      ..minimumSize = const Size(1100, 680).toNative();
  } catch (_) {
    // Without the native layer (tests, other platforms) the system bar stays.
  }
}

Window? _current() {
  try {
    return WindowManager.instance.getCurrent();
  } catch (_) {
    return null;
  }
}

/// Lets the user drag the window by [child]; double-click maximizes/restores.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Platform.isWindows ? DragToMoveArea(child: child) : child;
}

/// Minimize / maximize / close, styled like Windows 11 caption buttons.
class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key});

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> {
  ListenerId? _listener;
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    _maximized = _current()?.isMaximized ?? false;
    try {
      _listener = WindowManager.instance.addListener((event) {
        if (event is WindowMaximizedEvent || event is WindowRestoredEvent) {
          final maximized = _current()?.isMaximized ?? false;
          if (mounted && maximized != _maximized) setState(() => _maximized = maximized);
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    final id = _listener;
    if (id != null) {
      try {
        WindowManager.instance.removeListener(id);
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WindowCaptionButton.minimize(brightness: brightness, onPressed: () => _current()?.minimize()),
        // Not wrapped in MaximizeButtonArea: declaring it as the system
        // maximize button (for the Windows 11 snap flyout) makes Windows
        // swallow the hover, so it would not highlight like its neighbours.
        // Snap layouts stay available with Win+Z and by dragging to an edge.
        _maximized
            ? WindowCaptionButton.unmaximize(brightness: brightness, onPressed: () => _current()?.unmaximize())
            : WindowCaptionButton.maximize(brightness: brightness, onPressed: () => _current()?.maximize()),
        WindowCaptionButton.close(brightness: brightness, onPressed: () => _current()?.close()),
      ],
    );
  }
}

/// Restores and focuses the main window (e.g. when a notification is clicked).
void bringWindowToFront() {
  try {
    final w = _current();
    if (w == null) return;
    if (w.isMinimized) w.restore();
    w.show();
    w.focus();
  } catch (_) {}
}
