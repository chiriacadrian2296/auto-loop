import 'dart:convert';
import 'dart:io';

import 'quota_reset.dart';
import 'settings.dart';

/// [task] opens a block in the log (what to do), [result] closes it when it
/// is completed (how it went, and the agent's summary).
enum LogKind { info, agent, tool, error, warning, success, system, task, result }

/// How an invocation ended, carried by its closing [LogKind.result] line.
enum RunOutcome { done, again, blocked, interrupted, failed }

class LogEntry {
  LogEntry(this.kind, this.text, {DateTime? at, this.outcome}) : at = at ?? DateTime.now();
  final LogKind kind;
  final String text;
  final DateTime at;
  final RunOutcome? outcome;

  Map<String, Object?> toJson() => {'k': kind.name, 't': text, 'at': at.toIso8601String(), 'o': ?outcome?.name};

  static LogEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = LogKind.values.where((k) => k.name == j['k']).firstOrNull;
    final text = j['t'], at = DateTime.tryParse('${j['at']}');
    if (kind == null || text is! String || at == null) return null;
    final outcome = RunOutcome.values.where((o) => o.name == j['o']).firstOrNull;
    return LogEntry(kind, text, at: at, outcome: outcome);
  }
}

/// Text that went through a Windows code page and back is shown as "puÃ²"
/// instead of "può": undo that when it is clearly what happened.
String fixMojibake(String text) {
  if (!text.contains('Ã') && !text.contains('Â')) return text;
  try {
    final fixed = utf8.decode(latin1.encode(text));
    return fixed.contains('\uFFFD') ? text : fixed;
  } catch (_) {
    return text;
  }
}

/// Problems that are not the agent's fault and must not be retried blindly.
enum Blocker { usageLimit, authorization, network }

/// Conservative classification of *error messages* (never of task text).
Blocker? classifyError(String text) {
  final v = text.toLowerCase();
  const usage = [
    'usage limit',
    'usage_limit',
    'rate limit',
    'rate_limit',
    'quota',
    'insufficient_quota',
    'too many requests',
    'limit reached',
    'credits exhausted',
    'hit your limit',
    'out of credits',
    'credit balance',
  ];
  const auth = [
    'not logged in',
    'please log in',
    'login required',
    'unauthorized',
    'authentication',
    'failed to authenticate',
    'auth login',
    'invalid api key',
    'oauth token',
    '/login',
    'codex login',
    'token expired',
    'session expired',
  ];
  if (usage.any(v.contains) || RegExp(r'\b429\b').hasMatch(v)) {
    return Blocker.usageLimit;
  }
  if (auth.any(v.contains) || RegExp(r'\b401\b').hasMatch(v)) {
    return Blocker.authorization;
  }
  // The connection, not the agent: wait for the network and try again.
  const network = [
    'enotfound',
    'econnrefused',
    'econnreset',
    'etimedout',
    'eai_again',
    'getaddrinfo',
    'network error',
    'network is unreachable',
    'fetch failed',
    'error sending request',
    'stream disconnected',
    'could not resolve host',
    'failed to connect',
    'unable to connect',
    'connection error',
    'connection refused',
    'api connection',
  ];
  if (network.any(v.contains)) return Blocker.network;
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

  /// When the usage quota renews, when the CLI said so.
  DateTime? get quotaResetAt;
  String? get errorMessage;

  /// The CLI reported a cleanly finished turn.
  bool get turnCompleted;

  /// Estimated cost in USD, when the CLI reports one.
  double? get costUsd;
}

abstract class AgentBackend {
  AgentKind get kind;

  List<String> buildArgs({required String workDir, required LoopSettings settings, required String lastMessageFile});

  /// [workDir] lets the log show paths inside it as relative ones.
  AgentStream newStream({String workDir = ''});

  /// Some CLIs write the final message to a file; prefer it when present.
  String? readFinalMessage(String lastMessageFile) {
    final f = File(lastMessageFile);
    if (!f.existsSync()) return null;
    final text = f.readAsStringSync().trim();
    return text.isEmpty ? null : text;
  }

  static AgentBackend of(AgentKind kind) => kind == AgentKind.codex ? CodexBackend() : ClaudeBackend();
}

String _short(String s, [int max = 300]) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= max ? one : '${one.substring(0, max)}…';
}

/// [text] with the paths inside [workDir] made relative to it, as the user
/// thinks of them: `C:\\proj\\lib\\a.dart` → `lib\\a.dart`, the folder itself → `.`.
String relativePaths(String text, String workDir) {
  final parts = workDir.split(RegExp(r'[\\/]+')).where((x) => x.isNotEmpty).map(RegExp.escape).toList();
  if (parts.length < 2) return text;
  // Either separator, doubled too (as in escaped strings).
  final root = parts.join(r'[\\/]+');
  return text
      .replaceAll(RegExp('$root[\\\\/]+', caseSensitive: false), '')
      .replaceAll(RegExp('$root(?![\\w.-])', caseSensitive: false), '.');
}

/// A command as the agent meant it: without the shell that runs it
/// (`"…\\powershell.exe" -Command '…'`, `bash -lc '…'`, `cmd /c …`), without a
/// leading `cd` into the working folder, and with relative paths.
String tidyCommand(String command, String workDir) {
  var c = command.trim();
  final shell = RegExp(
    r'''^(?:"[^"]*?(?:powershell|pwsh|bash|cmd)(?:\.exe)?"|\S*?(?:powershell|pwsh|bash|cmd)(?:\.exe)?)'''
    r'''((?:\s+-\w+(?:\s+(?!-)[^'"\s]+)?)*?)\s+(?:-Command|-c|-lc|/c|/d\s+/s\s+/c)\s+([\s\S]+)$''',
    caseSensitive: false,
  ).firstMatch(c);
  if (shell != null) {
    final arg = shell.group(2)!.trim();
    c = _shellWord(arg) ?? arg;
  }
  c = relativePaths(c, workDir);
  return c.replaceFirst(RegExp(r'''^cd\s+(?:/d\s+)?["']?\.["']?\s*(?:&&|;)\s*'''), '');
}

/// The text of one shell word written with POSIX quoting, as Codex quotes
/// the script it passes to the shell: `'a '"'"'b'"'"''` → `a 'b'`. Null when
/// [s] is not exactly one word.
String? _shellWord(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == "'") {
      final end = s.indexOf("'", i + 1);
      if (end < 0) return null;
      out.write(s.substring(i + 1, end));
      i = end + 1;
    } else if (ch == '"') {
      i++;
      while (true) {
        if (i >= s.length) return null;
        final d = s[i];
        if (d == '"') break;
        if (d == r'\' && i + 1 < s.length && r'"\$`'.contains(s[i + 1])) {
          out.write(s[i + 1]);
          i += 2;
        } else {
          out.write(d);
          i++;
        }
      }
      i++;
    } else if (ch.trim().isEmpty) {
      return null;
    } else if (ch == r'\' && i + 1 < s.length) {
      out.write(s[i + 1]);
      i += 2;
    } else {
      out.write(ch);
      i++;
    }
  }
  return out.toString();
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
  List<String> buildArgs({required String workDir, required LoopSettings settings, required String lastMessageFile}) {
    final full = settings.autonomy == Autonomy.full;
    return [
      '-a',
      'never',
      'exec',
      '--json',
      '--color',
      'never',
      '--skip-git-repo-check',
      '--ephemeral',
      if (full) '--dangerously-bypass-approvals-and-sandbox' else ...['--sandbox', 'workspace-write'],
      '--cd',
      workDir,
      '--output-last-message',
      lastMessageFile,
      if (settings.model.trim().isNotEmpty) ...['--model', settings.model.trim()],
      if (settings.effort.trim().isNotEmpty) ...['-c', 'model_reasoning_effort="${settings.effort.trim()}"'],
      '-',
    ];
  }

  @override
  AgentStream newStream({String workDir = ''}) => _CodexStream(workDir);
}

class _CodexStream implements AgentStream {
  _CodexStream(this.workDir);
  final String workDir;
  String _final = '';

  @override
  double? get costUsd => null;
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
  DateTime? get quotaResetAt => _error == null ? null : parseQuotaReset(_error!);
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
      // Everything else on stderr is the echo of what commands read (file
      // contents, PROGRESS.md...): it stays in the raw log, not on screen.
      final lower = line.toLowerCase();
      if (stderr && (lower.contains('error') || lower.contains('limit'))) {
        _fail(line);
        return [LogEntry(LogKind.error, _short(fixMojibake(line), 600))];
      }
      return const [];
    }
    final type = e['type'] as String? ?? '';
    switch (type) {
      case 'thread.started':
        return const [];
      case 'turn.completed':
        _completed = true;
        final u = (e['usage'] as Map?)?.cast<String, Object?>() ?? const {};
        _in += _int(u['input_tokens']);
        _out += _int(u['output_tokens']);
        return const [];
      case 'turn.failed':
      case 'error':
        final err = e['error'];
        final msg = err is Map ? (err['message']?.toString() ?? jsonEncode(err)) : (e['message']?.toString() ?? line);
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
        return [LogEntry(LogKind.agent, fixMojibake(text.trim()))];
      case 'command_execution':
        final cmd = _short(tidyCommand(item['command']?.toString() ?? '', workDir), 200);
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
            .map((c) => '${c['kind'] ?? ''} ${relativePaths('${c['path'] ?? ''}', workDir)}'.trim())
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
  List<String> buildArgs({required String workDir, required LoopSettings settings, required String lastMessageFile}) {
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
  AgentStream newStream({String workDir = ''}) => _ClaudeStream(workDir);
}

class _ClaudeStream implements AgentStream {
  _ClaudeStream(this.workDir);
  final String workDir;
  String _final = '';
  double? _cost;

  @override
  double? get costUsd => _cost;
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
  DateTime? _resetAt;
  @override
  DateTime? get quotaResetAt => _resetAt ?? (_error == null ? null : parseQuotaReset(_error!));
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
          return [LogEntry(LogKind.error, _short(fixMojibake(line), 600))];
        }
        return const [];
      }
      return const [];
    }
    switch (e['type']) {
      case 'system':
        return const [];
      case 'rate_limit_event':
        // Says when each usage window renews; the rejected one is the limit.
        final info = (e['rate_limit_info'] as Map?)?.cast<String, Object?>() ?? const {};
        DateTime? when(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000) : null;
        final windows = (info['unifiedWindows'] as Map?)?.values.whereType<Map>() ?? const <Map>[];
        final rejected = [
          for (final w in windows)
            if (w['status'] != null && w['status'] != 'allowed') ?when(w['resetsAt']),
          if (info['status'] != null && info['status'] != 'allowed') ?when(info['resetsAt']),
        ];
        if (rejected.isNotEmpty) _resetAt = rejected.reduce((a, b) => a.isAfter(b) ? a : b);
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
              out.add(LogEntry(b != null && t.length < 400 ? LogKind.error : LogKind.agent, fixMojibake(t.trim())));
            }
          } else if (c['type'] == 'tool_use') {
            out.add(LogEntry(LogKind.tool, '${c['name']}: ${_toolSummary(c['input'])}'));
          }
        }
        return out;
      case 'result':
        final u = (e['usage'] as Map?)?.cast<String, Object?>() ?? const {};
        _in += _int(u['input_tokens']) + _int(u['cache_creation_input_tokens']) + _int(u['cache_read_input_tokens']);
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
        if (cost is num) _cost = cost.toDouble();
        return const [];
    }
    return const [];
  }

  String _toolSummary(Object? input) {
    if (input is! Map) return '';
    for (final key in ['command', 'file_path', 'path', 'pattern', 'url', 'description']) {
      final v = input[key];
      if (v is String && v.isNotEmpty) return _short(tidyCommand(v, workDir), 200);
    }
    return _short(jsonEncode(input), 160);
  }
}
