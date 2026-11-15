import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'accounts.dart';
import 'agents.dart';
import 'keep_awake.dart';
import 'loop_state.dart';
import 'plan_parser.dart';
import 'process_runner.dart';
import 'prompt.dart';
import 'settings.dart';
import '../l10n.dart';

enum LoopPhase {
  idle('Pronto', 'Ready'),
  running('Agente al lavoro', 'Agent at work'),
  verifying('Verifica in corso', 'Checking'),
  waiting('In attesa del richiamo', 'Waiting to relaunch'),
  quotaWait('Quota esaurita, in attesa', 'Quota used up, waiting'),
  offline('In attesa della rete', 'Waiting for the network'),
  stopping('Arresto…', 'Stopping…'),
  paused('In pausa', 'Paused'),
  finished('Piano completato', 'Plan completed');

  const LoopPhase(this._it, this._en);
  final String _it, _en;

  /// The label in the language in use.
  String get label => tr(_it, _en);
}

/// Outcome the agent declares on the last line of its final message.
enum AgentVerdict { done, continueWork, blocked, missing }

(AgentVerdict, String) parseVerdict(String text) {
  final matches = RegExp(
    r'AUTOLOOP_STATUS:\s*(DONE|CONTINUE|BLOCKED)\b[ \t]*:?[ \t]*([^\n]*)',
    caseSensitive: false,
  ).allMatches(text).toList();
  if (matches.isEmpty) return (AgentVerdict.missing, '');
  final m = matches.last;
  final reason = m.group(2)!.trim();
  return switch (m.group(1)!.toUpperCase()) {
    'DONE' => (AgentVerdict.done, reason),
    'CONTINUE' => (AgentVerdict.continueWork, reason),
    _ => (AgentVerdict.blocked, reason),
  };
}

/// Drives one plan inside one project folder until it is done, the user stops
/// it, or the agent's quota/budget runs out.
class LoopEngine extends ChangeNotifier {
  LoopEngine(this.settings);

  LoopSettings settings;

  String? workDir;
  String? planPath;
  ParsedPlan? plan;
  LoopState? state;

  LoopPhase phase = LoopPhase.idle;
  String statusMessage = '';
  int? currentBlock;
  DateTime? waitUntil;

  /// When the usage quota renews, as the CLI said at the last limit.
  DateTime? quotaResetAt;

  /// How long after the renewal the loop resumes, to be sure it happened.
  @visibleForTesting
  static Duration quotaMargin = const Duration(minutes: 1);

  /// "alle 15:01", or "domani alle 9:01", or "il 17/11 alle 9:01".
  static String _when(DateTime t) {
    final now = DateTime.now();
    final hm = '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    final days = DateTime(t.year, t.month, t.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    return switch (days) {
      0 => tr('alle $hm', 'at $hm'),
      1 => tr('domani alle $hm', 'tomorrow at $hm'),
      _ => tr('il ${t.day}/${t.month} alle $hm', 'on ${t.day}/${t.month} at $hm'),
    };
  }

  DateTime? runStartedAt;
  String? currentLogDir;

  final List<LogEntry> logs = [];
  static const _maxLogs = 4000;

  ManagedProcess? _process;
  Completer<void>? _sleep;
  bool _stopRequested = false;
  bool _pauseRequested = false;

  bool get isActive => phase != LoopPhase.idle && phase != LoopPhase.paused && phase != LoopPhase.finished;
  bool get pauseRequested => _pauseRequested;

  BlockState blockState(PlanBlock b) => state!.of(b.id);

  int get doneCount => plan == null
      ? 0
      : plan!.blocks.where((b) => const [BlockStatus.done, BlockStatus.skipped].contains(blockState(b).status)).length;

  // ------------------------------------------------------------ setup

  /// Loads (or reloads) a plan for a project folder, restoring saved progress.
  String? load({required String workDir, required String planPath}) {
    if (isActive) return tr('Ferma il loop prima di cambiare piano.', 'Stop the loop before changing plan.');
    final file = File(planPath);
    if (!file.existsSync()) return tr('File del piano non trovato.', 'Plan file not found.');
    if (!Directory(workDir).existsSync()) return tr('Cartella di progetto non trovata.', 'Project folder not found.');
    final String raw;
    try {
      raw = file.readAsStringSync();
    } catch (e) {
      return tr('Impossibile leggere il piano: $e', 'Cannot read the plan: $e');
    }
    this.workDir = workDir;
    this.planPath = planPath;
    plan = parsePlan(raw, strategy: settings.strategy);
    state = LoopState.load(workDir, planPath);
    // The log on screen is the plan's saved history.
    _activity = ActivityLog(workDir, planPath);
    logs
      ..clear()
      ..addAll(_activity!.read(max: _maxLogs));
    for (final b in plan!.blocks) {
      final s = state!.of(b.id);
      if (b.preChecked && s.status == BlockStatus.pending && s.attempts == 0) {
        s.status = BlockStatus.done;
        s.note = tr('Già spuntato nel piano.', 'Already ticked in the plan.');
      }
    }
    final allDone = doneCount == plan!.blocks.length;
    phase = allDone ? LoopPhase.finished : LoopPhase.idle;
    statusMessage = tr(
      '${plan!.blocks.length} blocchi (${plan!.strategy.label}), $doneCount completati.',
      '${plan!.blocks.length} blocks (${plan!.strategy.label}), $doneCount completed.',
    );
    notifyListeners();
    return null;
  }

  /// Asks the loop to stop once [b] is completed (or not any more). It can be
  /// changed at any time, also while the loop runs.
  void setPauseAfter(PlanBlock b, bool pause) {
    final s = blockState(b);
    s.pauseAfter = pause;
    state!.save(workDir!);
    notifyListeners();
  }

  void setBlockStatus(PlanBlock b, BlockStatus status) {
    final s = blockState(b);
    s.status = status;
    if (status == BlockStatus.pending) {
      s.attempts = 0;
      s.feedback = '';
      s.note = '';
      s.stepsDone = 0;
      s.stepsTotal = 0;
    }
    state!.save(workDir!);
    if (!isActive) {
      phase = doneCount == plan!.blocks.length ? LoopPhase.finished : LoopPhase.idle;
    }
    notifyListeners();
  }

  /// Adds an informational line to the activity log (for UI-side events).
  void note(String text) => _log(LogKind.info, text);

  /// The activity log as a plain-text file, for reading in an editor.
  File? exportActivity() => _activity?.exportText(logs, title: p.basename(planPath ?? ''));

  void clearLogs() {
    logs.clear();
    _activity?.clear();
    notifyListeners();
  }

  /// When the running agent last printed anything (null when not running).
  DateTime? lastOutputAt;

  ActivityLog? _activity;

  void _addLog(LogEntry e) {
    _activity?.append(e);
    logs.add(e);
    if (logs.length > _maxLogs) logs.removeRange(0, logs.length - _maxLogs);
  }

  void _log(LogKind kind, String text) {
    _addLog(LogEntry(kind, text));
    notifyListeners();
  }

  /// The line that closes every invocation: how it ended, in a few words.
  void _result(RunOutcome outcome, String text) {
    _addLog(LogEntry(LogKind.result, text, outcome: outcome));
    notifyListeners();
  }

  /// Called when something needs the user: the plan is done, the quota ran
  /// out, or the loop stopped on a problem (not when the user paused it).
  void Function(String title, String body)? onAttention;

  void _attention(String title, String body) => onAttention?.call(title, body);

  /// When the current session started; null while not running.
  DateTime? sessionStartedAt;

  /// Time spent running this plan, including the current session.
  Duration get totalTime {
    final saved = Duration(seconds: state?.activeSeconds ?? 0);
    final s = sessionStartedAt;
    return s == null ? saved : saved + DateTime.now().difference(s);
  }

  void _setPhase(LoopPhase p, [String? message]) {
    phase = p;
    if (message != null) statusMessage = message;
    // While the loop works or waits, the PC does not go to sleep on its own.
    if (!demo) KeepAwake.set(isActive && settings.keepAwake);
    notifyListeners();
  }

  // ------------------------------------------------------------ controls

  /// Sample-data mode (`--demo`): everything works except running an agent.
  bool demo = false;

  /// Block states as they were before [demoShow] marked every block done.
  Map<String, BlockStatus>? _demoSaved;

  /// Demo only: the window as it looks in [phase], on [block], without
  /// running anything. [allDone] shows the plan completed (and is undone by
  /// the next call without it).
  void demoShow(
    LoopPhase phase, {
    int? block,
    String message = '',
    bool pauseRequested = false,
    bool allDone = false,
    Duration quiet = Duration.zero,
  }) {
    if (!demo || plan == null || state == null) return;
    final st = state!;
    if (allDone) {
      _demoSaved ??= {for (final b in plan!.blocks) b.id: st.of(b.id).status};
      for (final b in plan!.blocks) {
        st.of(b.id).status = BlockStatus.done;
      }
    } else if (_demoSaved case final saved?) {
      for (final b in plan!.blocks) {
        st.of(b.id).status = saved[b.id] ?? st.of(b.id).status;
      }
      _demoSaved = null;
    }
    this.phase = phase;
    currentBlock = block;
    statusMessage = message;
    _pauseRequested = pauseRequested;
    final working = phase == LoopPhase.running || phase == LoopPhase.verifying || phase == LoopPhase.stopping;
    final now = DateTime.now();
    runStartedAt = working ? now.subtract(const Duration(minutes: 3, seconds: 12)) : null;
    lastOutputAt = working ? now.subtract(quiet) : null;
    sessionStartedAt = isActive ? now.subtract(const Duration(minutes: 18)) : null;
    notifyListeners();
  }

  Future<void> start() async {
    if (isActive || plan == null || workDir == null) return;
    if (demo) {
      _log(
        LogKind.warning,
        tr(
          'Modalità dimostrazione: l\'avvio è disattivato. Apri AutoLoop senza --demo per lavorare davvero.',
          'Demo mode: starting is turned off. Open AutoLoop without --demo to work for real.',
        ),
      );
      return;
    }
    final exe = settings.executable;
    if (exe.isEmpty || !File(exe).existsSync()) {
      _log(
        LogKind.error,
        tr(
          'Eseguibile di ${settings.agent.label} non trovato. Impostalo nelle impostazioni.',
          '${settings.agent.label} executable not found. Set it in the settings.',
        ),
      );
      return;
    }
    _stopRequested = false;
    _pauseRequested = false;
    sessionStartedAt = DateTime.now();
    try {
      await _loop();
    } catch (e, st) {
      _log(LogKind.error, tr('Errore interno: $e', 'Internal error: $e'));
      debugPrint('$st');
      _setPhase(LoopPhase.paused, tr('Interrotto da un errore interno.', 'Stopped by an internal error.'));
      _attention(tr('Loop interrotto', 'Loop stopped'), tr('Errore interno: $e', 'Internal error: $e'));
    } finally {
      _process = null;
      currentBlock = null;
      waitUntil = null;
      runStartedAt = null;
      final began = sessionStartedAt;
      if (began != null && state != null) {
        state!.activeSeconds += DateTime.now().difference(began).inSeconds;
      }
      sessionStartedAt = null;
      state?.save(workDir!);
      if (phase != LoopPhase.finished && phase != LoopPhase.paused) {
        _setPhase(LoopPhase.paused);
      }
      notifyListeners();
    }
  }

  /// Finish the current invocation, then stop.
  void requestPause() {
    if (!isActive) return;
    _pauseRequested = true;
    _wake();
    _log(
      LogKind.info,
      tr(
        'Pausa richiesta: il loop si fermerà al termine del passo corrente.',
        'Pause requested: the loop will stop at the end of the current step.',
      ),
    );
  }

  /// Kill the agent now. Its partial work stays on disk and is picked up on
  /// the next start.
  Future<void> stopNow() async {
    if (!isActive) return;
    _stopRequested = true;
    _setPhase(LoopPhase.stopping);
    _wake();
    await _process?.kill(KillReason.stopped);
  }

  void _wake() {
    final s = _sleep;
    if (s != null && !s.isCompleted) s.complete();
  }

  bool get _halt => _stopRequested || _pauseRequested;

  Future<void> _wait(Duration d, LoopPhase phase, String message) => _waitUntil(DateTime.now().add(d), phase, message);

  /// Waits until the clock reads [until]. Checked every few seconds too, so
  /// a wait of hours still ends on time after the PC wakes from sleep.
  Future<void> _waitUntil(DateTime until, LoopPhase phase, String message) async {
    if (!until.isAfter(DateTime.now()) || _halt) return;
    waitUntil = until;
    _setPhase(phase, message);
    final c = _sleep = Completer<void>();
    void check() {
      if (!c.isCompleted && !DateTime.now().isBefore(until)) c.complete();
    }

    final t = Timer(until.difference(DateTime.now()), check);
    final tick = Timer.periodic(const Duration(seconds: 15), (_) => check());
    await c.future;
    t.cancel();
    tick.cancel();
    _sleep = null;
    waitUntil = null;
  }

  /// Waits until a host of the agent's provider answers again.
  Future<void> _waitForNetwork() async {
    final host = settings.agent == AgentKind.codex ? 'api.openai.com' : 'api.anthropic.com';
    while (!_halt) {
      try {
        final found = await InternetAddress.lookup(host).timeout(const Duration(seconds: 10));
        if (found.isNotEmpty) return;
      } catch (_) {}
      await _wait(
        const Duration(seconds: 30),
        LoopPhase.offline,
        tr('Rete assente: riprendo appena torna.', 'No network: resuming as soon as it is back.'),
      );
    }
  }

  // ------------------------------------------------------------ the loop

  Future<void> _loop() async {
    final plan = this.plan!;
    final state = this.state!;
    final dir = workDir!;

    while (!_halt) {
      final next = plan.blocks.where((b) => state.of(b.id).status == BlockStatus.pending).firstOrNull;
      if (next == null) {
        final blocked = plan.blocks.where((b) => state.of(b.id).status == BlockStatus.blocked).length;
        _log(
          LogKind.success,
          blocked == 0
              ? tr('Tutti i blocchi sono completati.', 'All blocks are completed.')
              : blocked == 1
              ? tr(
                  'Nessun blocco da fare; 1 blocco bloccato richiede attenzione.',
                  'No blocks left to do; 1 blocked block needs attention.',
                )
              : tr(
                  'Nessun blocco da fare; $blocked blocchi bloccati richiedono attenzione.',
                  'No blocks left to do; $blocked blocked blocks need attention.',
                ),
        );
        _setPhase(
          blocked == 0 ? LoopPhase.finished : LoopPhase.paused,
          blocked == 0
              ? tr('Piano completato.', 'Plan completed.')
              : tr('Ci sono blocchi bloccati.', 'Some blocks are blocked.'),
        );
        _attention(
          blocked == 0 ? tr('Piano completato', 'Plan completed') : tr('Serve il tuo intervento', 'You are needed'),
          blocked == 0
              ? tr(
                  '${p.basename(planPath!)}: tutti i blocchi sono completati.',
                  '${p.basename(planPath!)}: all blocks are completed.',
                )
              : tr(
                  '${p.basename(planPath!)}: $blocked blocchi sono bloccati.',
                  '${p.basename(planPath!)}: $blocked blocks are blocked.',
                ),
        );
        return;
      }

      if (settings.maxTotalTokens > 0 && state.totalTokens >= settings.maxTotalTokens) {
        _log(
          LogKind.warning,
          tr('Budget di token raggiunto (${state.totalTokens}).', 'Token budget reached (${state.totalTokens}).'),
        );
        _setPhase(LoopPhase.paused, tr('Budget di token esaurito.', 'Token budget used up.'));
        _attention(
          tr('Budget di token esaurito', 'Token budget used up'),
          tr(
            'Il loop si è fermato dopo ${state.totalTokens} token.',
            'The loop stopped after ${state.totalTokens} tokens.',
          ),
        );
        return;
      }

      final bs = state.of(next.id);
      if (bs.attempts >= settings.maxAttemptsPerBlock) {
        bs.status = BlockStatus.blocked;
        bs.note = tr(
          'Superato il limite di ${settings.maxAttemptsPerBlock} invocazioni.',
          'Went over the limit of ${settings.maxAttemptsPerBlock} invocations.',
        );
        state.save(dir);
        _log(LogKind.error, tr('Blocco ${next.index + 1}: ${bs.note}', 'Block ${next.index + 1}: ${bs.note}'));
        if (settings.skipBlocked) continue;
        _setPhase(
          LoopPhase.paused,
          tr('Blocco ${next.index + 1} fermo: troppi tentativi.', 'Block ${next.index + 1} stuck: too many attempts.'),
        );
        _attention(
          tr('Serve il tuo intervento', 'You are needed'),
          tr(
            'Blocco ${next.index + 1} «${next.title}»: troppi tentativi.',
            'Block ${next.index + 1} «${next.title}»: too many attempts.',
          ),
        );
        return;
      }

      currentBlock = next.index;
      final result = await _invoke(next, bs);
      if (_stopRequested) {
        _log(
          LogKind.warning,
          tr(
            'Agente interrotto manualmente. Il lavoro parziale resta su disco.',
            'Agent stopped by hand. The partial work stays on disk.',
          ),
        );
        _setPhase(LoopPhase.paused, tr('Fermato.', 'Stopped.'));
        return;
      }

      switch (result) {
        case _RunResult.quota:
          bs.attempts--; // a quota stop is not the block's fault
          state.save(dir);
          if (settings.quotaBehavior == QuotaBehavior.stop) {
            _setPhase(LoopPhase.paused, tr('Quota esaurita.', 'Quota used up.'));
            _attention(
              tr('Quota esaurita', 'Quota used up'),
              tr(
                'Il loop è in pausa: riprendilo quando la quota torna disponibile.',
                'The loop is paused: resume it when the quota is available again.',
              ),
            );
            return;
          }
          // At the time the quota renews, when the CLI says it; a minute
          // later, to be sure. Otherwise, at regular intervals.
          final reset = quotaResetAt;
          final now = DateTime.now();
          if (reset != null && reset.isAfter(now) && reset.difference(now) < const Duration(days: 8)) {
            final at = reset.add(quotaMargin);
            final when = _when(at);
            _log(
              LogKind.info,
              tr(
                'La quota si rinnova $when: il loop riprenderà da solo.',
                'The quota renews $when: the loop will resume by itself.',
              ),
            );
            _attention(
              tr('Quota esaurita', 'Quota used up'),
              tr('Il loop riprenderà da solo $when.', 'The loop will resume by itself $when.'),
            );
            await _waitUntil(
              at,
              LoopPhase.quotaWait,
              tr('Quota esaurita: riprendo $when.', 'Quota used up: resuming $when.'),
            );
          } else {
            _attention(
              tr('Quota esaurita', 'Quota used up'),
              tr(
                'Nuovo tentativo tra ${settings.quotaWaitMinutes} minuti.',
                'Trying again in ${settings.quotaWaitMinutes} minutes.',
              ),
            );
            await _wait(
              Duration(minutes: settings.quotaWaitMinutes),
              LoopPhase.quotaWait,
              tr(
                'Quota esaurita: nuovo tentativo tra ${settings.quotaWaitMinutes} min.',
                'Quota used up: trying again in ${settings.quotaWaitMinutes} min.',
              ),
            );
          }
        case _RunResult.network:
          _log(
            LogKind.warning,
            tr(
              'Connessione assente: il loop riprende appena torna la rete.',
              'No connection: the loop resumes as soon as the network is back.',
            ),
          );
          await _waitForNetwork();
        case _RunResult.auth:
          _setPhase(
            LoopPhase.paused,
            tr('Problema di autenticazione: esegui il login nella CLI.', 'Sign-in problem: sign in again in the CLI.'),
          );
          _attention(
            tr('Accesso richiesto', 'Sign-in needed'),
            tr(
              '${settings.agent.label}: rifai l\'accesso da Account e CLI.',
              '${settings.agent.label}: sign in again from Accounts and CLIs.',
            ),
          );
          return;
        case _RunResult.blocked:
          if (!settings.skipBlocked) {
            _setPhase(
              LoopPhase.paused,
              tr(
                'Blocco ${next.index + 1} bloccato: serve il tuo intervento.',
                'Block ${next.index + 1} blocked: you are needed.',
              ),
            );
            _attention(
              tr('Serve il tuo intervento', 'You are needed'),
              tr(
                'Blocco ${next.index + 1} «${next.title}»: l\'agente si è bloccato.',
                'Block ${next.index + 1} «${next.title}»: the agent got stuck.',
              ),
            );
            return;
          }
        case _RunResult.fatal:
          _setPhase(LoopPhase.paused, tr('Impossibile avviare l\'agente.', 'Cannot start the agent.'));
          _attention(
            tr('Loop interrotto', 'Loop stopped'),
            tr('Impossibile avviare ${settings.agent.label}.', 'Cannot start ${settings.agent.label}.'),
          );
          return;
        case _RunResult.blockDone:
          // A stop the user asked for: once, then the loop can be resumed.
          if (bs.pauseAfter) {
            bs.pauseAfter = false;
            state.save(dir);
            _log(
              LogKind.info,
              tr(
                'In pausa dopo il blocco ${next.index + 1}, come richiesto: controlla e riprendi.',
                'Paused after block ${next.index + 1}, as asked: review and resume.',
              ),
            );
            _setPhase(
              LoopPhase.paused,
              tr(
                'In pausa dopo il blocco ${next.index + 1}: controlla e riprendi.',
                'Paused after block ${next.index + 1}: review and resume.',
              ),
            );
            _attention(
              tr('In pausa per un controllo', 'Paused for a review'),
              tr(
                'Blocco ${next.index + 1} «${next.title}» completato.',
                'Block ${next.index + 1} «${next.title}» completed.',
              ),
            );
            return;
          }
        case _RunResult.again:
          break;
      }

      if (_halt) break;
      if (plan.blocks.every((b) => state.of(b.id).status != BlockStatus.pending)) continue;
      await _wait(
        Duration(seconds: settings.relaunchDelaySeconds),
        LoopPhase.waiting,
        tr('Richiamo tra ${settings.relaunchDelaySeconds}s.', 'Relaunch in ${settings.relaunchDelaySeconds}s.'),
      );
    }
    _setPhase(LoopPhase.paused, _stopRequested ? tr('Fermato.', 'Stopped.') : tr('In pausa.', 'Paused.'));
  }

  Future<_RunResult> _invoke(PlanBlock block, BlockState bs) async {
    final plan = this.plan!;
    final state = this.state!;
    final dir = workDir!;
    final backend = AgentBackend.of(settings.agent);

    bs.attempts++;
    state.runs++;
    state.save(dir);

    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);
    final logDir = Directory(p.join(LoopState.dirOf(dir), 'logs', '$stamp-b${block.index + 1}-a${bs.attempts}'))
      ..createSync(recursive: true);
    currentLogDir = logDir.path;
    final progressFile = File(LoopState.progressFileOf(dir));
    if (!progressFile.existsSync()) {
      progressFile.writeAsStringSync(
        tr(
          '# Progresso AutoLoop\n\nPiano: ${p.basename(planPath!)}\n',
          '# AutoLoop progress\n\nPlan: ${p.basename(planPath!)}\n',
        ),
      );
    }

    final prompt = buildPrompt(
      plan: plan,
      block: block,
      attempt: bs.attempts,
      settings: settings,
      planName: p.basename(planPath!),
      progress: progressFile.readAsStringSync(),
      feedback: bs.feedback,
      steps: bs.stepsTotal > 0 ? (bs.stepsDone, bs.stepsTotal) : null,
      completedTitles: [
        for (final b in plan.blocks)
          if (state.of(b.id).status == BlockStatus.done) b.title,
      ],
    );
    File(p.join(logDir.path, 'prompt.md')).writeAsStringSync(prompt);
    final lastMessage = p.join(logDir.path, 'last-message.txt');
    final args = backend.buildArgs(workDir: dir, settings: settings, lastMessageFile: lastMessage);

    _log(
      LogKind.info,
      tr(
        '▶ Blocco ${block.index + 1}/${plan.blocks.length} «${block.title}» — invocazione ${bs.attempts}',
        '▶ Block ${block.index + 1}/${plan.blocks.length} «${block.title}» — invocation ${bs.attempts}',
      ),
    );
    if (bs.attempts == 1) {
      // The block's own heading repeats the title shown in the header.
      final lines = block.body.trim().split('\n');
      final body = (lines.first.contains(block.title) ? lines.skip(1) : lines).join('\n').trim();
      final task = body.isEmpty ? block.title : body;
      _log(LogKind.task, task.length > 3000 ? '${task.substring(0, 3000)}…' : task);
    }
    runStartedAt = DateTime.now();
    lastOutputAt = runStartedAt;
    _setPhase(
      LoopPhase.running,
      tr('Blocco ${block.index + 1}: ${block.title}', 'Block ${block.index + 1}: ${block.title}'),
    );

    final stream = backend.newStream(workDir: dir);
    final raw = File(p.join(logDir.path, 'output.jsonl')).openWrite();
    ProcessOutcome outcome;
    try {
      final (proc, done) = await ManagedProcess.start(
        executable: settings.executable,
        args: args,
        workingDirectory: dir,
        stdin: prompt,
        timeout: Duration(minutes: settings.runTimeoutMinutes),
        idleTimeout: Duration(minutes: settings.idleTimeoutMinutes),
        environment: profileEnvironment(settings.profileId, settings.agent),
        rawLog: raw,
        onLine: (line, stderr) {
          lastOutputAt = DateTime.now();
          for (final e in stream.handle(line, stderr: stderr)) {
            final shown = _takeProgress(e, bs);
            if (shown != null) _addLog(shown);
          }
          notifyListeners();
        },
      );
      _process = proc;
      if (_stopRequested) await proc.kill(KillReason.stopped);
      outcome = await done;
    } on ProcessException catch (e) {
      await raw.close();
      _result(RunOutcome.failed, tr('Avvio fallito: ${e.message}', 'Start failed: ${e.message}'));
      bs.attempts--;
      state.runs--;
      state.save(dir);
      return _RunResult.fatal;
    } finally {
      _process = null;
    }
    await raw.close();
    final began = runStartedAt;
    runStartedAt = null;
    lastOutputAt = null;

    state.inputTokens += stream.inputTokens;
    state.outputTokens += stream.outputTokens;
    bs.inputTokens += stream.inputTokens;
    bs.outputTokens += stream.outputTokens;
    if (began != null) bs.activeSeconds += DateTime.now().difference(began).inSeconds;
    final finalText = backend.readFinalMessage(lastMessage) ?? stream.finalText;
    final (verdict, reason) = parseVerdict(finalText);
    final summary = _summary(finalText);
    if (stream.inputTokens + stream.outputTokens > 0) {
      // Not shown as a line: the activity panel puts it in the invocation's header.
      final cost = stream.costUsd;
      _log(
        LogKind.system,
        'Token: ${stream.inputTokens} in / ${stream.outputTokens} out'
        '${cost == null ? '' : ' · \$${cost.toStringAsFixed(3)}'}',
      );
    }

    if (outcome.killReason == KillReason.stopped) {
      bs.feedback = tr(
        'L\'invocazione precedente è stata interrotta dall\'utente. Riprendi dal lavoro su disco.',
        'The previous invocation was interrupted by the user. Pick up from the work on disk.',
      );
      _result(
        RunOutcome.interrupted,
        tr(
          'Fermata da te: alla ripresa continuerà dal lavoro su disco.',
          'Stopped by you: when resumed it goes on from the work on disk.',
        ),
      );
      state.save(dir);
      return _RunResult.again;
    }

    if (stream.blocker == Blocker.usageLimit) {
      _result(
        RunOutcome.interrupted,
        tr(
          'Limite di utilizzo raggiunto: ${stream.errorMessage ?? ''}',
          'Usage limit reached: ${stream.errorMessage ?? ''}',
        ).trim(),
      );
      quotaResetAt = stream.quotaResetAt;
      state.save(dir);
      return _RunResult.quota;
    }
    if (stream.blocker == Blocker.network) {
      _result(
        RunOutcome.interrupted,
        tr(
          'Connessione non riuscita: ${stream.errorMessage ?? ''}',
          'Connection failed: ${stream.errorMessage ?? ''}',
        ).trim(),
      );
      bs.attempts--; // not the block's fault
      state.save(dir);
      return _RunResult.network;
    }
    if (stream.blocker == Blocker.authorization) {
      _result(
        RunOutcome.failed,
        tr(
          'Autenticazione richiesta: ${stream.errorMessage ?? ''}',
          'Sign-in needed: ${stream.errorMessage ?? ''}',
        ).trim(),
      );
      bs.attempts--;
      state.save(dir);
      return _RunResult.auth;
    }

    if (outcome.killReason != null) {
      final why = outcome.killReason == KillReason.idleTimeout
          ? tr(
              'nessun output per ${settings.idleTimeoutMinutes} minuti',
              'no output for ${settings.idleTimeoutMinutes} minutes',
            )
          : tr(
              'superato il limite di ${settings.runTimeoutMinutes} minuti',
              'went over the limit of ${settings.runTimeoutMinutes} minutes',
            );
      _result(RunOutcome.interrupted, tr('Terminata dal supervisore: $why.', 'Stopped by the supervisor: $why.'));
      bs.feedback = tr(
        'L\'invocazione precedente è stata terminata dal supervisore ($why). '
            'Il lavoro parziale è su disco: controllalo e procedi a passi più brevi, '
            'aggiornando .autoloop/PROGRESS.md più spesso.',
        'The previous invocation was stopped by the supervisor ($why). The partial work is on disk: check it and go on in shorter steps, updating .autoloop/PROGRESS.md more often.',
      );
      state.save(dir);
      return _RunResult.again;
    }

    switch (verdict) {
      case AgentVerdict.done:
        final verifyError = await _verify(block);
        if (verifyError != null) {
          bs.feedback = tr(
            'Hai dichiarato DONE ma la verifica `${settings.verifyCommand}` è fallita. '
                'Correggi il problema. Output (ultima parte):\n$verifyError',
            'You declared DONE but the check `${settings.verifyCommand}` failed. Fix the problem. Output (last part):\n$verifyError',
          );
          _result(
            RunOutcome.again,
            tr(
              'La verifica non è passata: l\'agente la correggerà nella prossima invocazione.',
              'The check did not pass: the agent will fix it in the next invocation.',
            ),
          );
          state.save(dir);
          return _RunResult.again;
        }
        await _commit(block);
        bs.status = BlockStatus.done;
        if (bs.stepsTotal > 0) bs.stepsDone = bs.stepsTotal;
        bs.note = summary;
        bs.feedback = '';
        state.save(dir);
        // Says what was done, like the task says what to do.
        final what = _whatWasDone(summary);
        _result(RunOutcome.done, what.isEmpty ? tr('Blocco completato.', 'Block completed.') : what);
        return _RunResult.blockDone;
      case AgentVerdict.blocked:
        bs.status = BlockStatus.blocked;
        bs.note = reason.isEmpty ? summary : reason;
        state.save(dir);
        // Just the reason: the header already says it is blocked.
        _result(
          RunOutcome.blocked,
          bs.note.isEmpty ? tr('L\'agente non riesce a proseguire.', 'The agent cannot go on.') : bs.note,
        );
        return _RunResult.blocked;
      case AgentVerdict.continueWork:
        bs.feedback = tr(
          'Nell\'invocazione precedente hai risposto CONTINUE. Tuo riepilogo:\n$summary',
          'In the previous invocation you answered CONTINUE. Your summary:\n$summary',
        );
        _result(
          RunOutcome.again,
          tr('Il blocco continua nella prossima invocazione.', 'The block goes on in the next invocation.'),
        );
      case AgentVerdict.missing:
        final err = stream.errorMessage;
        bs.feedback = err != null
            ? tr(
                'L\'invocazione precedente è terminata con un errore: $err',
                'The previous invocation ended with an error: $err',
              )
            : tr(
                'L\'invocazione precedente è terminata senza la riga AUTOLOOP_STATUS '
                    '(exit ${outcome.exitCode}). Ultimo messaggio:\n$summary',
                'The previous invocation ended without the AUTOLOOP_STATUS line (exit ${outcome.exitCode}). Last message:\n$summary',
              );
        _result(
          err != null ? RunOutcome.failed : RunOutcome.interrupted,
          tr(
            'Fermata senza esito (exit ${outcome.exitCode}): verrà richiamata.',
            'Stopped without an outcome (exit ${outcome.exitCode}): it will be relaunched.',
          ),
        );
    }
    state.save(dir);
    return _RunResult.again;
  }

  static String _span(int seconds) {
    if (seconds < 60) return '$seconds s';
    final m = seconds ~/ 60;
    return m < 60 ? '$m min' : '${m ~/ 60} h ${m % 60} min';
  }

  static final _progressLine = RegExp(
    r'^[ \t>*_`-]*AUTOLOOP_PROGRESS:\s*(\d+)\s*/\s*(\d+)[ \t*_`.]*$',
    multiLine: true,
    caseSensitive: false,
  );

  /// Reads the agent's AUTOLOOP_PROGRESS lines into the block's steps and
  /// removes them from what is shown; null when nothing else is left.
  LogEntry? _takeProgress(LogEntry e, BlockState bs) {
    if (e.kind != LogKind.agent || !e.text.toUpperCase().contains('AUTOLOOP_PROGRESS')) return e;
    for (final m in _progressLine.allMatches(e.text)) {
      final done = int.parse(m.group(1)!), total = int.parse(m.group(2)!);
      if (total > 0 && total < 1000) {
        bs.stepsTotal = total;
        bs.stepsDone = done.clamp(0, total);
      }
    }
    state?.save(workDir!);
    final rest = e.text.replaceAll(_progressLine, '').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return rest.isEmpty ? null : LogEntry(e.kind, rest, at: e.at);
  }

  /// The agent's own account of the block, short: its first paragraph
  /// (or list) that is not just a heading.
  static String _whatWasDone(String summary) {
    final paragraphs = summary
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty && !RegExp(r'^#+\s').hasMatch(p) && !p.startsWith('```'));
    final first = paragraphs.firstOrNull ?? '';
    return first.length > 600 ? '${first.substring(0, 600)}…' : first;
  }

  String _summary(String text) {
    final cleaned = text
        .replaceAll(RegExp(r'AUTOLOOP_STATUS:[^\n]*', caseSensitive: false), '')
        .replaceAll(_progressLine, '')
        .trim();
    return cleaned.length > 4000 ? '…${cleaned.substring(cleaned.length - 4000)}' : cleaned;
  }

  /// Returns null when the block passes, otherwise the tail of the output.
  Future<String?> _verify(PlanBlock block) async {
    final cmd = settings.verifyCommand.trim();
    if (cmd.isEmpty) return null;
    _setPhase(LoopPhase.verifying, tr('Verifica: $cmd', 'Check: $cmd'));
    _log(LogKind.tool, tr('Verifica: $cmd', 'Check: $cmd'));
    final watch = Stopwatch()..start();
    final (code, output) = await runShell(cmd, workDir!);
    if (code == 0) {
      // The last line of the output usually says it all ("All tests passed!").
      final last = output.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).lastOrNull;
      final tail = last == null ? '' : ' · ${last.length > 120 ? '${last.substring(0, 120)}…' : last}';
      _log(
        LogKind.success,
        tr(
          'Verifica superata in ${_span(watch.elapsed.inSeconds)}$tail',
          'Check passed in ${_span(watch.elapsed.inSeconds)}$tail',
        ),
      );
      return null;
    }
    _log(LogKind.warning, tr('Verifica fallita (exit $code).', 'Check failed (exit $code).'));
    return output.length > 8000 ? output.substring(output.length - 8000) : output;
  }

  Future<void> _commit(PlanBlock block) async {
    if (!settings.gitCommit) return;
    final dir = workDir!;
    try {
      final top = await git(['rev-parse', '--show-toplevel'], dir);
      if (top.exitCode != 0) return; // not a repository: nothing to commit
      // Only commit in the folder's own repository: a work folder inside
      // another project (e.g. a subfolder of AutoLoop itself) must not
      // write commits into that project.
      if (!p.equals(p.normalize(top.stdout.toString().trim()), p.normalize(dir))) {
        _log(
          LogKind.warning,
          tr(
            'Commit saltato: la cartella di lavoro è dentro un altro repository (${top.stdout.toString().trim()}).',
            'Commit skipped: the working folder is inside another repository (${top.stdout.toString().trim()}).',
          ),
        );
        return;
      }
      await git(['add', '-A'], dir);
      final staged = await git(['diff', '--cached', '--quiet'], dir);
      if (staged.exitCode == 0) {
        _log(LogKind.system, tr('Nessuna modifica da committare.', 'Nothing to commit.'));
        return;
      }
      final title = block.title.length > 60 ? '${block.title.substring(0, 60)}…' : block.title;
      final r = await git([
        'commit',
        '-m',
        'autoloop: $title',
        '-m',
        tr(
          'Blocco ${block.index + 1} del piano ${p.basename(planPath!)}.',
          'Block ${block.index + 1} of the plan ${p.basename(planPath!)}.',
        ),
      ], dir);
      if (r.exitCode == 0) {
        state!.commits++;
        final stat = await git(['show', '--shortstat', '--format=%h', 'HEAD'], dir);
        final out = stat.stdout.toString().trim().split('\n');
        int n(String what) => int.tryParse(RegExp('(\\d+) $what').firstMatch(out.last)?.group(1) ?? '') ?? 0;
        final files = n('file');
        _log(
          LogKind.success,
          [
            'Commit ${out.first.trim()}',
            if (files > 0) files == 1 ? '1 file' : tr('$files file', '$files files'),
            if (out.length > 1) '+${n('insertion')} −${n('deletion')}',
          ].join(' · '),
        );
      } else {
        _log(
          LogKind.warning,
          tr('Commit non riuscito: ${r.stderr.toString().trim()}', 'Commit failed: ${r.stderr.toString().trim()}'),
        );
      }
    } catch (e) {
      _log(LogKind.warning, tr('Git non disponibile: $e', 'Git not available: $e'));
    }
  }

  @override
  void dispose() {
    _process?.kill(KillReason.stopped);
    super.dispose();
  }
}

enum _RunResult { blockDone, again, blocked, quota, network, auth, fatal }
