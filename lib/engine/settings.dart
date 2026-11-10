import 'dart:convert';

import 'plan_parser.dart';

enum AgentKind {
  codex('Codex CLI'),
  claude('Claude Code');

  const AgentKind(this.label);
  final String label;
}

enum QuotaBehavior {
  stop('Fermati'),
  wait('Attendi e riprova');

  const QuotaBehavior(this.label);
  final String label;
}

/// How much freedom the agent gets. Mapped to each CLI's own flags.
enum Autonomy {
  sandboxed('Sandbox (solo cartella progetto)'),
  full('Accesso completo (nessuna conferma)');

  const Autonomy(this.label);
  final String label;
}

class LoopSettings {
  LoopSettings({
    this.agent = AgentKind.codex,
    this.codexPath = '',
    this.claudePath = '',
    this.model = '',
    this.autonomy = Autonomy.sandboxed,
    this.relaunchDelaySeconds = 30,
    this.idleTimeoutMinutes = 10,
    this.runTimeoutMinutes = 60,
    this.maxAttemptsPerBlock = 10,
    this.quotaBehavior = QuotaBehavior.wait,
    this.quotaWaitMinutes = 30,
    this.maxTotalTokens = 0,
    this.verifyCommand = '',
    this.gitCommit = true,
    this.strategy = SplitStrategy.auto,
    this.extraInstructions = '',
    this.skipBlocked = false,
  });

  AgentKind agent;
  String codexPath;
  String claudePath;
  String model;
  Autonomy autonomy;

  /// The "richiamo": pause between one invocation and the next.
  int relaunchDelaySeconds;

  /// Kill the agent if it produces no output for this long.
  int idleTimeoutMinutes;

  /// Hard cap on a single invocation.
  int runTimeoutMinutes;

  /// Invocations of one block before the loop gives up and pauses.
  int maxAttemptsPerBlock;

  QuotaBehavior quotaBehavior;
  int quotaWaitMinutes;

  /// 0 = no budget, keep going until the provider says the quota is over.
  int maxTotalTokens;

  /// Optional shell command (cmd.exe) that must pass before a block is done.
  String verifyCommand;
  bool gitCommit;
  SplitStrategy strategy;

  /// Free text appended to every prompt (style rules, stack, constraints).
  String extraInstructions;

  /// When the agent declares a block BLOCKED, move on instead of pausing.
  bool skipBlocked;

  String get executable => agent == AgentKind.codex ? codexPath : claudePath;

  Map<String, Object?> toJson() => {
        'agent': agent.name,
        'codexPath': codexPath,
        'claudePath': claudePath,
        'model': model,
        'autonomy': autonomy.name,
        'relaunchDelaySeconds': relaunchDelaySeconds,
        'idleTimeoutMinutes': idleTimeoutMinutes,
        'runTimeoutMinutes': runTimeoutMinutes,
        'maxAttemptsPerBlock': maxAttemptsPerBlock,
        'quotaBehavior': quotaBehavior.name,
        'quotaWaitMinutes': quotaWaitMinutes,
        'maxTotalTokens': maxTotalTokens,
        'verifyCommand': verifyCommand,
        'gitCommit': gitCommit,
        'strategy': strategy.name,
        'extraInstructions': extraInstructions,
        'skipBlocked': skipBlocked,
      };

  static LoopSettings fromJson(Map<String, Object?> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    int number(Object? v, int fallback, {int min = 0}) =>
        v is int && v >= min ? v : fallback;
    final d = LoopSettings();
    return LoopSettings(
      agent: pick(AgentKind.values, j['agent'], d.agent),
      codexPath: j['codexPath'] as String? ?? '',
      claudePath: j['claudePath'] as String? ?? '',
      model: j['model'] as String? ?? '',
      autonomy: pick(Autonomy.values, j['autonomy'], d.autonomy),
      relaunchDelaySeconds: number(j['relaunchDelaySeconds'], d.relaunchDelaySeconds),
      idleTimeoutMinutes: number(j['idleTimeoutMinutes'], d.idleTimeoutMinutes, min: 1),
      runTimeoutMinutes: number(j['runTimeoutMinutes'], d.runTimeoutMinutes, min: 1),
      maxAttemptsPerBlock: number(j['maxAttemptsPerBlock'], d.maxAttemptsPerBlock, min: 1),
      quotaBehavior: pick(QuotaBehavior.values, j['quotaBehavior'], d.quotaBehavior),
      quotaWaitMinutes: number(j['quotaWaitMinutes'], d.quotaWaitMinutes, min: 1),
      maxTotalTokens: number(j['maxTotalTokens'], d.maxTotalTokens),
      verifyCommand: j['verifyCommand'] as String? ?? '',
      gitCommit: j['gitCommit'] as bool? ?? d.gitCommit,
      strategy: pick(SplitStrategy.values, j['strategy'], d.strategy),
      extraInstructions: j['extraInstructions'] as String? ?? '',
      skipBlocked: j['skipBlocked'] as bool? ?? false,
    );
  }

  String encode() => jsonEncode(toJson());

  static LoopSettings decode(String? s) {
    if (s == null || s.isEmpty) return LoopSettings();
    try {
      return fromJson((jsonDecode(s) as Map).cast<String, Object?>());
    } catch (_) {
      return LoopSettings();
    }
  }
}
