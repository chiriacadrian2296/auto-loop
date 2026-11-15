import 'dart:ffi';
import 'dart:io';

/// Keeps Windows from going to sleep on its own while the loop works or
/// waits. It does not stop a sleep the user asks for (lid closed, Start →
/// Sospendi): it only keeps the idle timer from putting the PC to sleep.
class KeepAwake {
  KeepAwake._();

  static const _continuous = 0x80000000;
  static const _systemRequired = 0x00000001;

  static int Function(int)? _set;
  static bool _on = false;

  static bool get isOn => _on;

  static void set(bool on) {
    if (on == _on || !Platform.isWindows) return;
    try {
      _set ??= DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Uint32 Function(Uint32), int Function(int)>('SetThreadExecutionState');
      _set!(on ? _continuous | _systemRequired : _continuous);
      _on = on;
    } catch (_) {
      // Not available: the loop works the same, the PC may sleep.
    }
  }
}
