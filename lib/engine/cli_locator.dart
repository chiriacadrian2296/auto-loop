import 'dart:convert';
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

class ModelOption {
  const ModelOption({
    required this.id,
    required this.label,
    this.description = '',
    this.efforts = const [],
    this.defaultEffort,
  });

  /// Value passed to `--model`.
  final String id;
  final String label;
  final String description;

  /// Reasoning levels this model accepts (empty = use the catalog-wide list).
  final List<String> efforts;
  final String? defaultEffort;
}

class AgentCatalog {
  const AgentCatalog({this.models = const [], this.efforts = const [], this.source = ''});

  final List<ModelOption> models;

  /// Effort levels valid for every model, when the CLI only exposes a global list.
  final List<String> efforts;

  /// Where the list came from, shown in the UI.
  final String source;

  bool get isEmpty => models.isEmpty && efforts.isEmpty;

  ModelOption? find(String id) => models.where((m) => m.id == id).firstOrNull;

  /// Effort levels to offer for [modelId] ('' = the CLI's default model).
  List<String> effortsFor(String modelId) {
    final m = find(modelId);
    if (m != null && m.efforts.isNotEmpty) return m.efforts;
    if (efforts.isNotEmpty) return efforts;
    // Default model on Codex: offer the levels common to the whole catalog.
    final lists = models.map((m) => m.efforts).where((e) => e.isNotEmpty).toList();
    if (lists.isEmpty) return const [];
    return lists.first.where((e) => lists.every((l) => l.contains(e))).toList();
  }
}

/// Asks the CLI itself which models and effort levels it supports.
Future<AgentCatalog> discoverCatalog(AgentKind kind, String exe) async {
  if (exe.isEmpty || !File(exe).existsSync()) return const AgentCatalog();
  try {
    return kind == AgentKind.codex ? await _codexCatalog(exe) : await _claudeCatalog(exe);
  } catch (_) {
    return const AgentCatalog();
  }
}

Future<AgentCatalog> _codexCatalog(String exe) async {
  // `debug models` refreshes the catalog online; `--bundled` is the offline fallback.
  for (final args in const [
    ['debug', 'models'],
    ['debug', 'models', '--bundled'],
  ]) {
    try {
      final r = await Process.run(exe, args, stdoutEncoding: utf8)
          .timeout(const Duration(seconds: 30));
      if (r.exitCode != 0) continue;
      final catalog = parseCodexCatalog(r.stdout.toString());
      if (!catalog.isEmpty) return catalog;
    } catch (_) {}
  }
  return const AgentCatalog();
}

AgentCatalog parseCodexCatalog(String json) {
  final root = jsonDecode(json);
  final list = (root is Map ? root['models'] : root) as List? ?? const [];
  final models = <(int, ModelOption)>[];
  for (final m in list.whereType<Map>()) {
    if (m['visibility'] != null && m['visibility'] != 'list') continue;
    final slug = m['slug']?.toString();
    if (slug == null || slug.isEmpty) continue;
    final efforts = [
      for (final l in (m['supported_reasoning_levels'] as List? ?? const []).whereType<Map>())
        if (l['effort'] is String) l['effort'] as String,
    ];
    models.add((
      m['priority'] is int ? m['priority'] as int : 1 << 20,
      ModelOption(
        id: slug,
        label: m['display_name']?.toString() ?? slug,
        description: m['description']?.toString() ?? '',
        efforts: efforts,
        defaultEffort: m['default_reasoning_level']?.toString(),
      ),
    ));
  }
  models.sort((a, b) => a.$1.compareTo(b.$1));
  return AgentCatalog(models: [for (final m in models) m.$2], source: 'catalogo di Codex');
}

Future<AgentCatalog> _claudeCatalog(String exe) async {
  final r = await Process.run(exe, ['--help'], stdoutEncoding: utf8).timeout(const Duration(seconds: 20));
  return parseClaudeHelp(r.stdout.toString());
}

/// Claude Code has no model-listing command: its `--help` names the model
/// aliases (always the latest of each family) and the accepted effort levels.
AgentCatalog parseClaudeHelp(String help) {
  String section(String flag) {
    final start = help.indexOf(flag);
    if (start < 0) return '';
    final next = help.indexOf(RegExp(r'\n\s{2}-'), start + flag.length);
    return help.substring(start, next < 0 ? help.length : next).replaceAll(RegExp(r'\s+'), ' ');
  }

  final modelHelp = section('--model <model>');
  final aliases = <String>{
    for (final m in RegExp(r"'([a-z][a-z0-9.\-]*)'").allMatches(modelHelp)) m.group(1)!,
  };
  final effortMatch = RegExp(r'\(([a-z, ]+)\)').firstMatch(section('--effort <level>'));
  final efforts = effortMatch == null
      ? const <String>[]
      : effortMatch.group(1)!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  return AgentCatalog(
    models: [
      for (final a in aliases)
        ModelOption(
          id: a,
          label: a[0].toUpperCase() + a.substring(1),
          description: 'Ultima versione di $a',
        ),
    ],
    efforts: efforts,
    source: 'alias di Claude Code',
  );
}
