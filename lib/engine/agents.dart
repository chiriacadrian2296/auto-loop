import 'dart:convert';
import 'dart:io';

import 'settings.dart';

enum LogKind { info, agent, tool, error, warning, success, system }

class LogEntry {
  LogEntry(this.kind, this.text, {DateTime? at}) : at = at ?? DateTime.now();
  final LogKind kind;
  final String text;
  final DateTime at;
}

/// Problems that are not the agent's fault and must not be retried blindly.
enum Blocker { usageLimit, authorization }

/// Conservative classification of *error messages* (never of task text).
Blocker? classifyError(String text) {
  final v = text.toLowerCase();
  const usage = [
    'usage limit', 'usage_limit', 'rate limit', 'rate_limit', 'quota',
    'insufficient_quota', 'too many requests', 'limit reached',
    'credits exhausted', 'hit your limit', 'out of credits', 'credit balance',
  ];
  const auth = [
    'not logged in', 'please log in', 'login required', 'unauthorized',
    'authentication', 'failed to authenticate', 'auth login', 'invalid api key',
    'oauth token', '/login', 'codex login', 'token expired', 'session expired',
  ];
  if (usage.any(v.contains) || RegExp(r'\b429\b').hasMatch(v)) {
    return Blocker.usageLimit;
  }
  if (auth.any(v.contains) || RegExp(r'\b401\b').hasMatch(v)) {
    return Blocker.authorization;
  }
  return null;
}

/// Per-invocation parser of a CLI's machine-readable output stream.
abstract class AgentStream {
  /// Turns one output line into zero or more log entries, updating state.
  List<LogEntry> handle(String line, {required bool stderr});

  /// Last assistant message (where the AUTOLOOP_STATUS line is expected).
  String get finalText;
  int get inputTokens;
  int get outputTokens;
  Blocker? get blocker;
  String? get errorMessage;

  /// The CLI reported a cleanly finished turn.
  bool get turnCompleted;
}

abstract class AgentBackend {
  AgentKind get kind;

  List<String> buildArgs({
    required String workDir,
    required LoopSettings settings,
    required String lastMessageFile,
  });

  AgentStream newStream();

  /// Some CLIs write the final message to a file; prefer it when present.
  String? readFinalMessage(String lastMessageFile) {
    final f = File(lastMessageFile);
    if (!f.existsSync()) return null;
    final text = f.readAsStringSync().trim();
    return text.isEmpty ? null : text;
  }

  static AgentBackend of(AgentKind kind) =>
      kind == AgentKind.codex ? CodexBackend() : ClaudeBackend();
}

String _short(String s, [int max = 300]) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= max ? one : '${one.substring(0, max)}…';
}

Map<String, Object?>? _json(String line) {
  final t = line.trim();
  if (!t.startsWith('{')) return null;
  try {
    final v = jsonDecode(t);
    return v is Map ? v.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}

int _int(Object? v) => v is int ? v : 0;

// ---------------------------------------------------------------- Codex CLI

class CodexBackend extends AgentBackend {
  @override
  AgentKind get kind => AgentKind.codex;

  @override
  List<String> buildArgs({
    required String workDir,
    required LoopSettings settings,
    required String lastMessageFile,
  }) {
    final full = settings.autonomy == Autonomy.full;
    return [
      '-a', 'never',
      'exec',
      '--json',
      '--color', 'never',
      '--skip-git-repo-check',
      '--ephemeral',
      if (full)
        '--dangerously-bypass-approvals-and-sandbox'
      else ...[
        '--sandbox', 'workspace-write',
      ],
      '--cd', workDir,
      '--output-last-message', lastMessageFile,
      if (settings.model.trim().isNotEmpty) ...['--model', settings.model.trim()],
      if (settings.effort.trim().isNotEmpty) ...['-c', 'model_reasoning_effort="${settings.effort.trim()}"'],
      '-',
    ];
  }

  @override
  AgentStream newStream() => _CodexStream();
}

class _CodexStream implements AgentStream {
  String _final = '';
  int _in = 0, _out = 0;
  Blocker? _blocker;
  String? _error;
  bool _completed = false;

  @override
  String get finalText => _final;
  @override
  int get inputTokens => _in;
  @override
  int get outputTokens => _out;
  @override
  Blocker? get blocker => _blocker;
  @override
  String? get errorMessage => _error;
  @override
  bool get turnCompleted => _completed;

  void _fail(String message) {
    _error = message;
    _blocker ??= classifyError(message);
  }

  @override
  List<LogEntry> handle(String line, {required bool stderr}) {
    if (line.trim().isEmpty) return const [];
    final e = _json(line);
    if (e == null) {
      // Startup errors (auth, sandbox) may be printed before any JSON event.
      final lower = line.toLowerCase();
      if (stderr && (lower.contains('error') || lower.contains('limit'))) {
        _fail(line);
        return [LogEntry(LogKind.error, _short(line, 600))];
      }
      return stderr ? [LogEntry(LogKind.system, _short(line))] : const [];
    }
    final type = e['type'] as String? ?? '';
    switch (type) {
      case 'thread.started':
        return [LogEntry(LogKind.system, 'Sessione Codex avviata')];
      case 'turn.completed':
        _completed = true;
        final u = (e['usage'] as Map?)?.cast<String, Object?>() ?? const {};
        _in += _int(u['input_tokens']);
        _out += _int(u['output_tokens']);
        return const [];
      case 'turn.failed':
      case 'error':
        final err = e['error'];
        final msg = err is Map
            ? (err['message']?.toString() ?? jsonEncode(err))
            : (e['message']?.toString() ?? line);
        _fail(msg);
        return [LogEntry(LogKind.error, _short(msg, 600))];
      case 'item.started':
      case 'item.completed':
        final item = (e['item'] as Map?)?.cast<String, Object?>();
        if (item == null) return const [];
        return _item(item, completed: type == 'item.completed');
    }
    return const [];
  }

  List<LogEntry> _item(Map<String, Object?> item, {required bool completed}) {
    final kind = item['type'] ?? item['item_type'];
    switch (kind) {
      case 'agent_message':
      case 'assistant_message':
        if (!completed) return const [];
        final text = item['text']?.toString() ?? '';
        if (text.trim().isNotEmpty) _final = text;
        return [LogEntry(LogKind.agent, text.trim())];
      case 'command_execution':
        final cmd = _short(item['command']?.toString() ?? '', 200);
        if (!completed) return [LogEntry(LogKind.tool, '\$ $cmd')];
        final code = item['exit_code'];
        if (code is int && code != 0) {
          return [LogEntry(LogKind.warning, '\$ $cmd → exit $code')];
        }
        return const [];
      case 'file_change':
        if (!completed) return const [];
        final changes = (item['changes'] as List?) ?? const [];
        final paths = changes
            .whereType<Map>()
            .map((c) => '${c['kind'] ?? ''} ${c['path'] ?? ''}'.trim())
            .join(', ');
        return [LogEntry(LogKind.tool, '✎ ${_short(paths, 300)}')];
      case 'error':
        final msg = item['message']?.toString() ?? '';
        return [LogEntry(LogKind.warning, _short(msg, 400))];
      case 'todo_list':
        return const [];
    }
    return const [];
  }
}

// -------------------------------------------------------------- Claude Code

class ClaudeBackend extends AgentBackend {
  @override
  AgentKind get kind => AgentKind.claude;

  @override
  List<String> buildArgs({
    required String workDir,
    required LoopSettings settings,
    required String lastMessageFile,
  }) {
    return [
      '-p',
      '--output-format', 'stream-json',
      '--verbose',
      '--permission-mode',
      // `auto`: a classifier approves safe actions (edits, builds, tests) and
      // blocks risky ones, the closest match to Codex's workspace sandbox.
      settings.autonomy == Autonomy.full ? 'bypassPermissions' : 'auto',
      if (settings.model.trim().isNotEmpty) ...['--model', settings.model.trim()],
      if (settings.effort.trim().isNotEmpty) ...['--effort', settings.effort.trim()],
    ];
  }

  @override
  String? readFinalMessage(String lastMessageFile) => null;

  @override
  AgentStream newStream() => _ClaudeStream();
}

class _ClaudeStream implements AgentStream {
  String _final = '';
  String _lastLogged = '';
  int _in = 0, _out = 0;
  Blocker? _blocker;
  String? _error;
  bool _completed = false;

  @override
  String get finalText => _final;
  @override
  int get inputTokens => _in;
  @override
  int get outputTokens => _out;
  @override
  Blocker? get blocker => _blocker;
  @override
  String? get errorMessage => _error;
  @override
  bool get turnCompleted => _completed;

  @override
  List<LogEntry> handle(String line, {required bool stderr}) {
    if (line.trim().isEmpty) return const [];
    final e = _json(line);
    if (e == null) {
      if (stderr) {
        final b = classifyError(line);
        if (b != null) {
          _blocker ??= b;
          _error = line;
          return [LogEntry(LogKind.error, _short(line, 600))];
        }
        return [LogEntry(LogKind.system, _short(line))];
      }
      return const [];
    }
    switch (e['type']) {
      case 'system':
        if (e['subtype'] == 'init') {
          return [LogEntry(LogKind.system, 'Sessione Claude avviata (${e['model'] ?? 'modello predefinito'})')];
        }
        return const [];
      case 'assistant':
        final msg = (e['message'] as Map?)?.cast<String, Object?>() ?? const {};
        final out = <LogEntry>[];
        for (final c in (msg['content'] as List? ?? const []).whereType<Map>()) {
          if (c['type'] == 'text') {
            final t = c['text']?.toString() ?? '';
            if (t.trim().isNotEmpty) {
              _final = t;
              _lastLogged = t;
              final b = classifyError(t);
              // Auth/quota failures arrive as a synthetic assistant message.
              out.add(LogEntry(b != null && t.length < 400 ? LogKind.error : LogKind.agent, t.trim()));
            }
          } else if (c['type'] == 'tool_use') {
            out.add(LogEntry(LogKind.tool, '${c['name']}: ${_toolSummary(c['input'])}'));
          }
        }
        return out;
      case 'result':
        final u = (e['usage'] as Map?)?.cast<String, Object?>() ?? const {};
        _in += _int(u['input_tokens']) +
            _int(u['cache_creation_input_tokens']) +
            _int(u['cache_read_input_tokens']);
        _out += _int(u['output_tokens']);
        final result = e['result']?.toString() ?? '';
        final isError = e['is_error'] == true || e['subtype'] != 'success';
        if (isError) {
          final repeated = result.isNotEmpty && result == _lastLogged;
          _error = result.isEmpty ? '${e['subtype']}' : result;
          _blocker ??= classifyError(_error!);
          return repeated ? const [] : [LogEntry(LogKind.error, _short(_error!, 600))];
        }
        _completed = true;
        if (result.trim().isNotEmpty) _final = result;
        final cost = e['total_cost_usd'];
        return [
          if (cost is num) LogEntry(LogKind.system, 'Costo stimato: \$${cost.toStringAsFixed(3)}'),
        ];
    }
    return const [];
  }

  String _toolSummary(Object? input) {
    if (input is! Map) return '';
    for (final key in ['command', 'file_path', 'path', 'pattern', 'url', 'description']) {
      final v = input[key];
      if (v is String && v.isNotEmpty) return _short(v, 200);
    }
    return _short(jsonEncode(input), 160);
  }
}
