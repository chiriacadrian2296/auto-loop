import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings.dart';

/// Finds the agent CLIs even when they are not on PATH (desktop apps and the
/// VS Code extension ship their own copies in versioned folders).
Future<String?> locateCli(AgentKind kind) async {
  final name = kind == AgentKind.codex ? 'codex' : 'claude';
  final env = Platform.environment;
  final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
  final local = env['LOCALAPPDATA'] ?? '';
  final roaming = env['APPDATA'] ?? '';

  // 1. PATH
  if (Platform.isWindows) {
    try {
      final r = await Process.run('where.exe', [name]);
      if (r.exitCode == 0) {
        final hits = r.stdout.toString().split(RegExp(r'\r?\n')).map((s) => s.trim()).where((s) => s.isNotEmpty);
        final exe = hits.where((h) => h.toLowerCase().endsWith('.exe')).firstOrNull;
        final any = exe ?? hits.where((h) => RegExp(r'\.(cmd|bat)$', caseSensitive: false).hasMatch(h)).firstOrNull;
        if (any != null) return any;
      }
    } catch (_) {}
  }

  // 2. Well-known install locations
  final fixed = kind == AgentKind.codex
      ? [p.join(roaming, 'npm', 'codex.cmd'), p.join(home, '.local', 'bin', 'codex.exe')]
      : [
          p.join(home, '.local', 'bin', 'claude.exe'),
          p.join(roaming, 'npm', 'claude.cmd'),
          p.join(home, '.claude', 'local', 'claude.exe'),
        ];
  for (final f in fixed) {
    if (File(f).existsSync()) return f;
  }

  // 3. Versioned folders: pick the most recently modified binary.
  final pattern = kind == AgentKind.codex
      ? (p.join(local, 'OpenAI', 'Codex', 'bin'), 'codex.exe', 1)
      : (p.join(home, '.vscode', 'extensions'), 'claude.exe', 0);
  final root = Directory(pattern.$1);
  if (!root.existsSync()) return null;
  final candidates = <File>[];
  for (final sub in root.listSync().whereType<Directory>()) {
    if (kind == AgentKind.claude && !p.basename(sub.path).startsWith('anthropic.claude-code-')) continue;
    final f = kind == AgentKind.codex
        ? File(p.join(sub.path, pattern.$2))
        : File(p.join(sub.path, 'resources', 'native-binary', pattern.$2));
    if (f.existsSync()) candidates.add(f);
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return candidates.first.path;
}

Future<String?> cliVersion(String exe) async {
  if (exe.isEmpty || !File(exe).existsSync()) return null;
  try {
    final r = await Process.run(exe, ['--version'], runInShell: exe.toLowerCase().endsWith('.cmd'))
        .timeout(const Duration(seconds: 20));
    final out = r.stdout.toString().trim();
    return r.exitCode == 0 && out.isNotEmpty ? out.split('\n').first : null;
  } catch (_) {
    return null;
  }
}
