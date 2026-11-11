import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'accounts.dart';
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
  sandboxed('Protetta (azioni sicure approvate in automatico)'),
  full('Accesso completo (nessuna conferma)');

  const Autonomy(this.label);
  final String label;
}

class LoopSettings {
  LoopSettings({
    this.agent = AgentKind.codex,
    this.codexPath = '',
    this.claudePath = '',
    this.codexModel = '',
    this.claudeModel = '',
    this.codexEffort = '',
    this.claudeEffort = '',
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
    this.profileId = AccountProfile.defaultId,
    List<AccountProfile>? profiles,
  }) : profiles = profiles ?? [];

  AgentKind agent;
  String codexPath;
  String claudePath;
  /// Model and reasoning effort are kept per agent: a Codex model name means
  /// nothing to Claude and vice versa. Empty = the CLI's own default.
  String codexModel, claudeModel, codexEffort, claudeEffort;
  Autonomy autonomy;

  String get model => agent == AgentKind.codex ? codexModel : claudeModel;
  set model(String v) => agent == AgentKind.codex ? codexModel = v : claudeModel = v;

  String get effort => agent == AgentKind.codex ? codexEffort : claudeEffort;
  set effort(String v) => agent == AgentKind.codex ? codexEffort = v : claudeEffort = v;

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

  /// Which set of CLI logins the agent runs with.
  String profileId;

  /// User-created profiles (the built-in system profile is implicit).
  final List<AccountProfile> profiles;

  List<AccountProfile> get allProfiles => [AccountProfile.builtIn, ...profiles];

  AccountProfile get profile =>
      allProfiles.firstWhere((x) => x.id == profileId, orElse: () => AccountProfile.builtIn);

  String get executable => agent == AgentKind.codex ? codexPath : claudePath;

  Map<String, Object?> toJson() => {
        'agent': agent.name,
        'codexPath': codexPath,
        'claudePath': claudePath,
        'codexModel': codexModel,
        'claudeModel': claudeModel,
        'codexEffort': codexEffort,
        'claudeEffort': claudeEffort,
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
        'profileId': profileId,
        'profiles': [for (final x in profiles) x.toJson()],
      };

  static LoopSettings fromJson(Map<String, Object?> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    int number(Object? v, int fallback, {int min = 0}) =>
        v is int && v >= min ? v : fallback;
    final d = LoopSettings();
    final agent = pick(AgentKind.values, j['agent'], d.agent);
    // Older versions had a single `model` shared by both agents.
    final legacyModel = j['model'] as String? ?? '';
    return LoopSettings(
      agent: agent,
      codexPath: j['codexPath'] as String? ?? '',
      claudePath: j['claudePath'] as String? ?? '',
      codexModel: j['codexModel'] as String? ?? (agent == AgentKind.codex ? legacyModel : ''),
      claudeModel: j['claudeModel'] as String? ?? (agent == AgentKind.claude ? legacyModel : ''),
      codexEffort: j['codexEffort'] as String? ?? '',
      claudeEffort: j['claudeEffort'] as String? ?? '',
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
      profileId: j['profileId'] as String? ?? AccountProfile.defaultId,
      profiles: [
        for (final x in (j['profiles'] as List? ?? const [])) ?AccountProfile.fromJson(x),
      ],
    );
  }

  String encode() => jsonEncode(toJson());

  // ---------------------------------------------------------- per project

  /// Settings that belong to the work, not to the computer: they are saved
  /// in each project's `.autoloop/settings.json`. CLI paths and the list of
  /// profiles stay global.
  static const projectKeys = {
    'agent', 'codexModel', 'claudeModel', 'codexEffort', 'claudeEffort', 'autonomy',
    'relaunchDelaySeconds', 'idleTimeoutMinutes', 'runTimeoutMinutes', 'maxAttemptsPerBlock',
    'quotaBehavior', 'quotaWaitMinutes', 'maxTotalTokens', 'verifyCommand', 'gitCommit',
    'strategy', 'extraInstructions', 'skipBlocked', 'profileId',
  };

  static String projectFile(String workDir) => p.join(workDir, '.autoloop', 'settings.json');

  Map<String, Object?> projectJson() {
    final all = toJson();
    return {for (final k in projectKeys) k: all[k]};
  }

  /// Overwrites the project-scoped fields with [j], keeping global ones.
  void applyProject(Map<String, Object?> j) {
    final o = fromJson({...toJson(), for (final e in j.entries) if (projectKeys.contains(e.key)) e.key: e.value});
    agent = o.agent;
    codexModel = o.codexModel;
    claudeModel = o.claudeModel;
    codexEffort = o.codexEffort;
    claudeEffort = o.claudeEffort;
    autonomy = o.autonomy;
    relaunchDelaySeconds = o.relaunchDelaySeconds;
    idleTimeoutMinutes = o.idleTimeoutMinutes;
    runTimeoutMinutes = o.runTimeoutMinutes;
    maxAttemptsPerBlock = o.maxAttemptsPerBlock;
    quotaBehavior = o.quotaBehavior;
    quotaWaitMinutes = o.quotaWaitMinutes;
    maxTotalTokens = o.maxTotalTokens;
    verifyCommand = o.verifyCommand;
    gitCommit = o.gitCommit;
    strategy = o.strategy;
    extraInstructions = o.extraInstructions;
    skipBlocked = o.skipBlocked;
    // A profile deleted since then falls back to the system one.
    profileId = allProfiles.any((x) => x.id == o.profileId) ? o.profileId : AccountProfile.defaultId;
  }

  /// Loads the project's saved settings, if any. Returns whether it found them.
  bool loadProject(String workDir) {
    final f = File(projectFile(workDir));
    if (!f.existsSync()) return false;
    try {
      applyProject((jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>());
      return true;
    } catch (_) {
      return false;
    }
  }

  void saveProject(String workDir) {
    try {
      final f = File(projectFile(workDir));
      if (!f.parent.existsSync()) {
        f.parent.createSync(recursive: true);
        // Same rule as the rest of .autoloop/: never committed.
        File(p.join(f.parent.path, '.gitignore')).writeAsStringSync('*\n');
      }
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(projectJson()));
    } catch (_) {
      // A read-only folder must not break the app; settings stay global.
    }
  }

  static LoopSettings decode(String? s) {
    if (s == null || s.isEmpty) return LoopSettings();
    try {
      return fromJson((jsonDecode(s) as Map).cast<String, Object?>());
    } catch (_) {
      return LoopSettings();
    }
  }
}
