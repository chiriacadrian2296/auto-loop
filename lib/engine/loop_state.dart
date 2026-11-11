import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agents.dart';

enum BlockStatus {
  pending('Da fare'),
  done('Completato'),
  blocked('Bloccato'),
  skipped('Saltato');

  const BlockStatus(this.label);
  final String label;
}

class BlockState {
  BlockState({
    this.status = BlockStatus.pending,
    this.attempts = 0,
    this.note = '',
    this.feedback = '',
    this.activeSeconds = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  BlockStatus status;
  int attempts;

  /// Human-facing note (summary when done, reason when blocked).
  String note;

  /// What the next invocation should know about the previous one.
  String feedback;

  /// Time the agent spent on this block and the tokens it used, summed over
  /// all invocations.
  int activeSeconds;
  int inputTokens;
  int outputTokens;

  int get totalTokens => inputTokens + outputTokens;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'attempts': attempts,
    'note': note,
    'feedback': feedback,
    'activeSeconds': activeSeconds,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
  };

  static BlockState fromJson(Map<String, Object?> j) => BlockState(
    status: BlockStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => BlockStatus.pending),
    attempts: j['attempts'] as int? ?? 0,
    note: j['note'] as String? ?? '',
    feedback: j['feedback'] as String? ?? '',
    activeSeconds: j['activeSeconds'] as int? ?? 0,
    inputTokens: j['inputTokens'] as int? ?? 0,
    outputTokens: j['outputTokens'] as int? ?? 0,
  );
}

/// Persistent progress, stored in `<project>/.autoloop/state.json` so that a
/// restart (or a crash) resumes exactly where the loop stopped.
class LoopState {
  LoopState({required this.planPath});

  String planPath;
  final Map<String, BlockState> blocks = {};
  int runs = 0;
  int inputTokens = 0;
  int outputTokens = 0;

  /// Seconds the loop has been running on this plan, across sessions.
  int activeSeconds = 0;

  /// Commits AutoLoop created for this plan.
  int commits = 0;

  int get totalTokens => inputTokens + outputTokens;

  BlockState of(String blockId) => blocks.putIfAbsent(blockId, BlockState.new);

  static String dirOf(String workDir) => p.join(workDir, '.autoloop');
  static String fileOf(String workDir) => p.join(dirOf(workDir), 'state.json');
  static String progressFileOf(String workDir) => p.join(dirOf(workDir), 'PROGRESS.md');

  static LoopState load(String workDir, String planPath) {
    final file = File(fileOf(workDir));
    final state = LoopState(planPath: planPath);
    if (!file.existsSync()) return state;
    try {
      final j = (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
      // Progress belongs to one plan file; another plan in the same folder
      // starts from scratch but keeps the token counters.
      final samePlan = p.equals(j['planPath'] as String? ?? '', planPath);
      state.runs = j['runs'] as int? ?? 0;
      state.inputTokens = j['inputTokens'] as int? ?? 0;
      state.outputTokens = j['outputTokens'] as int? ?? 0;
      state.activeSeconds = j['activeSeconds'] as int? ?? 0;
      state.commits = j['commits'] as int? ?? 0;
      if (samePlan) {
        final b = (j['blocks'] as Map?)?.cast<String, Object?>() ?? const {};
        for (final e in b.entries) {
          state.blocks[e.key] = BlockState.fromJson((e.value as Map).cast<String, Object?>());
        }
      }
    } catch (_) {
      // A corrupt file must not brick the app; keep a copy for inspection.
      try {
        file.copySync('${file.path}.corrupt');
      } catch (_) {}
    }
    return state;
  }

  void save(String workDir) {
    ensureDir(workDir);
    final file = File(fileOf(workDir));
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'planPath': planPath,
        'runs': runs,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'activeSeconds': activeSeconds,
        'commits': commits,
        'blocks': {for (final e in blocks.entries) e.key: e.value.toJson()},
      }),
    );
    tmp.renameSync(file.path);
  }

  /// Creates `.autoloop/` and keeps it out of git automatically.
  static void ensureDir(String workDir) {
    final dir = Directory(dirOf(workDir));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final ignore = File(p.join(dir.path, '.gitignore'));
    if (!ignore.existsSync()) ignore.writeAsStringSync('*\n');
  }
}

/// The activity log of one plan, one JSON line per entry, so it survives
/// restarts: `<project>/.autoloop/activity-<plan>.jsonl`.
class ActivityLog {
  ActivityLog(String workDir, String planPath)
    : file = File(p.join(LoopState.dirOf(workDir), 'activity-${p.basenameWithoutExtension(planPath)}.jsonl')),
      _workDir = workDir;

  final File file;
  final String _workDir;

  /// The most recent [max] entries.
  List<LogEntry> read({int max = 4000}) {
    if (!file.existsSync()) return [];
    try {
      final lines = file.readAsLinesSync();
      final tail = lines.length > max ? lines.sublist(lines.length - max) : lines;
      return [
        for (final l in tail)
          if (l.trim().isNotEmpty) ?_decode(l),
      ];
    } catch (_) {
      return [];
    }
  }

  static LogEntry? _decode(String line) {
    try {
      return LogEntry.fromJson(jsonDecode(line));
    } catch (_) {
      return null;
    }
  }

  void append(LogEntry e) {
    try {
      LoopState.ensureDir(_workDir);
      file.writeAsStringSync('${jsonEncode(e.toJson())}\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // The on-screen log still works if the folder is read-only.
    }
  }

  void clear() {
    try {
      if (file.existsSync()) file.writeAsStringSync('');
    } catch (_) {}
  }
}
