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
  const WindowButtons({super.key, this.leading = const []});

  /// Extra caption-style buttons shown before minimize (e.g. the theme).
  final List<Widget> leading;

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
        ...widget.leading,
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

/// Cycles the theme system → light → dark, styled like the window buttons.
class ThemeCaptionButton extends StatefulWidget {
  const ThemeCaptionButton({super.key, required this.mode, required this.onChanged});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  State<ThemeCaptionButton> createState() => _ThemeCaptionButtonState();
}

/// Same size, colours and hover as window_manager's caption buttons (which
/// can only draw their own glyphs), with a Material icon instead.
class _ThemeCaptionButtonState extends State<ThemeCaptionButton> {
  bool _hover = false, _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? Colors.white : Colors.black;
    final bg = _pressed
        ? base.withValues(alpha: dark ? 0.0419 : 0.0241)
        : _hover
        ? base.withValues(alpha: dark ? 0.0605 : 0.0373)
        : Colors.transparent;
    final fg = dark
        ? Colors.white.withValues(alpha: _pressed ? 0.786 : 1)
        : Colors.black.withValues(alpha: _pressed ? 0.6063 : 0.8956);
    final (IconData icon, String now, ThemeMode next, String then) = switch (widget.mode) {
      ThemeMode.system => (Icons.brightness_auto_outlined, 'segue il sistema', ThemeMode.light, 'chiaro'),
      ThemeMode.light => (Icons.light_mode_outlined, 'chiaro', ThemeMode.dark, 'scuro'),
      ThemeMode.dark => (Icons.dark_mode_outlined, 'scuro', ThemeMode.system, 'come il sistema'),
    };
    return Tooltip(
      message: 'Tema: $now · clic per $then',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: () => widget.onChanged(next),
          child: Container(
            width: 46,
            height: 32,
            color: bg,
            alignment: Alignment.center,
            child: Icon(icon, size: 15, color: fg),
          ),
        ),
      ),
    );
  }
}
