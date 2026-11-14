import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'accounts.dart';
import 'agents.dart';
import 'loop_state.dart';
import 'plan_parser.dart';
import 'process_runner.dart';
import 'prompt.dart';
import 'settings.dart';

enum LoopPhase {
  idle('Pronto'),
  running('Agente al lavoro'),
  verifying('Verifica in corso'),
  waiting('In attesa del richiamo'),
  quotaWait('Quota esaurita, in attesa'),
  stopping('Arresto…'),
  paused('In pausa'),
  finished('Piano completato');

  const LoopPhase(this.label);
  final String label;
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
    if (isActive) return 'Ferma il loop prima di cambiare piano.';
    final file = File(planPath);
    if (!file.existsSync()) return 'File del piano non trovato.';
    if (!Directory(workDir).existsSync()) return 'Cartella di progetto non trovata.';
    final String raw;
    try {
      raw = file.readAsStringSync();
    } catch (e) {
      return 'Impossibile leggere il piano: $e';
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
        s.note = 'Già spuntato nel piano.';
      }
    }
    final allDone = doneCount == plan!.blocks.length;
    phase = allDone ? LoopPhase.finished : LoopPhase.idle;
    statusMessage = '${plan!.blocks.length} blocchi (${plan!.strategy.label}), $doneCount completati.';
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
        'Modalità dimostrazione: l\'avvio è disattivato. Apri AutoLoop senza --demo per lavorare davvero.',
      );
      return;
    }
    final exe = settings.executable;
    if (exe.isEmpty || !File(exe).existsSync()) {
      _log(LogKind.error, 'Eseguibile di ${settings.agent.label} non trovato. Impostalo nelle impostazioni.');
      return;
    }
    _stopRequested = false;
    _pauseRequested = false;
    sessionStartedAt = DateTime.now();
    try {
      await _loop();
    } catch (e, st) {
      _log(LogKind.error, 'Errore interno: $e');
      debugPrint('$st');
      _setPhase(LoopPhase.paused, 'Interrotto da un errore interno.');
      _attention('Loop interrotto', 'Errore interno: $e');
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
    _log(LogKind.info, 'Pausa richiesta: il loop si fermerà al termine del passo corrente.');
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

  Future<void> _wait(Duration d, LoopPhase phase, String message) async {
    if (d <= Duration.zero || _halt) return;
    waitUntil = DateTime.now().add(d);
    _setPhase(phase, message);
    final c = _sleep = Completer<void>();
    final t = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    await c.future;
    t.cancel();
    _sleep = null;
    waitUntil = null;
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
              ? 'Tutti i blocchi sono completati.'
              : blocked == 1
              ? 'Nessun blocco da fare; 1 blocco bloccato richiede attenzione.'
              : 'Nessun blocco da fare; $blocked blocchi bloccati richiedono attenzione.',
        );
        _setPhase(
          blocked == 0 ? LoopPhase.finished : LoopPhase.paused,
          blocked == 0 ? 'Piano completato.' : 'Ci sono blocchi bloccati.',
        );
        _attention(
          blocked == 0 ? 'Piano completato' : 'Serve il tuo intervento',
          blocked == 0
              ? '${p.basename(planPath!)}: tutti i blocchi sono completati.'
              : '${p.basename(planPath!)}: $blocked blocchi sono bloccati.',
        );
        return;
      }

      if (settings.maxTotalTokens > 0 && state.totalTokens >= settings.maxTotalTokens) {
        _log(LogKind.warning, 'Budget di token raggiunto (${state.totalTokens}).');
        _setPhase(LoopPhase.paused, 'Budget di token esaurito.');
        _attention('Budget di token esaurito', 'Il loop si è fermato dopo ${state.totalTokens} token.');
        return;
      }

      final bs = state.of(next.id);
      if (bs.attempts >= settings.maxAttemptsPerBlock) {
        bs.status = BlockStatus.blocked;
        bs.note = 'Superato il limite di ${settings.maxAttemptsPerBlock} invocazioni.';
        state.save(dir);
        _log(LogKind.error, 'Blocco ${next.index + 1}: ${bs.note}');
        if (settings.skipBlocked) continue;
        _setPhase(LoopPhase.paused, 'Blocco ${next.index + 1} fermo: troppi tentativi.');
        _attention('Serve il tuo intervento', 'Blocco ${next.index + 1} «${next.title}»: troppi tentativi.');
        return;
      }

      currentBlock = next.index;
      final result = await _invoke(next, bs);
      if (_stopRequested) {
        _log(LogKind.warning, 'Agente interrotto manualmente. Il lavoro parziale resta su disco.');
        _setPhase(LoopPhase.paused, 'Fermato.');
        return;
      }

      switch (result) {
        case _RunResult.quota:
          bs.attempts--; // a quota stop is not the block's fault
          state.save(dir);
          if (settings.quotaBehavior == QuotaBehavior.stop) {
            _setPhase(LoopPhase.paused, 'Quota esaurita.');
            _attention('Quota esaurita', 'Il loop è in pausa: riprendilo quando la quota torna disponibile.');
            return;
          }
          _attention('Quota esaurita', 'Nuovo tentativo tra ${settings.quotaWaitMinutes} minuti.');
          await _wait(
            Duration(minutes: settings.quotaWaitMinutes),
            LoopPhase.quotaWait,
            'Quota esaurita: nuovo tentativo tra ${settings.quotaWaitMinutes} min.',
          );
        case _RunResult.auth:
          _setPhase(LoopPhase.paused, 'Problema di autenticazione: esegui il login nella CLI.');
          _attention('Accesso richiesto', '${settings.agent.label}: rifai l\'accesso da Account e CLI.');
          return;
        case _RunResult.blocked:
          if (!settings.skipBlocked) {
            _setPhase(LoopPhase.paused, 'Blocco ${next.index + 1} bloccato: serve il tuo intervento.');
            _attention('Serve il tuo intervento', 'Blocco ${next.index + 1} «${next.title}»: l\'agente si è bloccato.');
            return;
          }
        case _RunResult.fatal:
          _setPhase(LoopPhase.paused, 'Impossibile avviare l\'agente.');
          _attention('Loop interrotto', 'Impossibile avviare ${settings.agent.label}.');
          return;
        case _RunResult.blockDone:
          // A stop the user asked for: once, then the loop can be resumed.
          if (bs.pauseAfter) {
            bs.pauseAfter = false;
            state.save(dir);
            _log(LogKind.info, 'In pausa dopo il blocco ${next.index + 1}, come richiesto: controlla e riprendi.');
            _setPhase(LoopPhase.paused, 'In pausa dopo il blocco ${next.index + 1}: controlla e riprendi.');
            _attention('In pausa per un controllo', 'Blocco ${next.index + 1} «${next.title}» completato.');
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
        'Richiamo tra ${settings.relaunchDelaySeconds}s.',
      );
    }
    _setPhase(LoopPhase.paused, _stopRequested ? 'Fermato.' : 'In pausa.');
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
      progressFile.writeAsStringSync('# Progresso AutoLoop\n\nPiano: ${p.basename(planPath!)}\n');
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
      '▶ Blocco ${block.index + 1}/${plan.blocks.length} «${block.title}» — invocazione ${bs.attempts}',
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
    _setPhase(LoopPhase.running, 'Blocco ${block.index + 1}: ${block.title}');

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
      _result(RunOutcome.failed, 'Avvio fallito: ${e.message}');
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
      bs.feedback = 'L\'invocazione precedente è stata interrotta dall\'utente. Riprendi dal lavoro su disco.';
      _result(RunOutcome.interrupted, 'Fermata da te: alla ripresa continuerà dal lavoro su disco.');
      state.save(dir);
      return _RunResult.again;
    }

    if (stream.blocker == Blocker.usageLimit) {
      _result(RunOutcome.interrupted, 'Limite di utilizzo raggiunto: ${stream.errorMessage ?? ''}'.trim());
      state.save(dir);
      return _RunResult.quota;
    }
    if (stream.blocker == Blocker.authorization) {
      _result(RunOutcome.failed, 'Autenticazione richiesta: ${stream.errorMessage ?? ''}'.trim());
      bs.attempts--;
      state.save(dir);
      return _RunResult.auth;
    }

    if (outcome.killReason != null) {
      final why = outcome.killReason == KillReason.idleTimeout
          ? 'nessun output per ${settings.idleTimeoutMinutes} minuti'
          : 'superato il limite di ${settings.runTimeoutMinutes} minuti';
      _result(RunOutcome.interrupted, 'Terminata dal supervisore: $why.');
      bs.feedback =
          'L\'invocazione precedente è stata terminata dal supervisore ($why). '
          'Il lavoro parziale è su disco: controllalo e procedi a passi più brevi, '
          'aggiornando .autoloop/PROGRESS.md più spesso.';
      state.save(dir);
      return _RunResult.again;
    }

    switch (verdict) {
      case AgentVerdict.done:
        final verifyError = await _verify(block);
        if (verifyError != null) {
          bs.feedback =
              'Hai dichiarato DONE ma la verifica `${settings.verifyCommand}` è fallita. '
              'Correggi il problema. Output (ultima parte):\n$verifyError';
          _result(RunOutcome.again, 'La verifica non è passata: l\'agente la correggerà nella prossima invocazione.');
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
        _result(RunOutcome.done, what.isEmpty ? 'Blocco completato.' : what);
        return _RunResult.blockDone;
      case AgentVerdict.blocked:
        bs.status = BlockStatus.blocked;
        bs.note = reason.isEmpty ? summary : reason;
        state.save(dir);
        // Just the reason: the header already says it is blocked.
        _result(RunOutcome.blocked, bs.note.isEmpty ? 'L\'agente non riesce a proseguire.' : bs.note);
        return _RunResult.blocked;
      case AgentVerdict.continueWork:
        bs.feedback = 'Nell\'invocazione precedente hai risposto CONTINUE. Tuo riepilogo:\n$summary';
        _result(RunOutcome.again, 'Il blocco continua nella prossima invocazione.');
      case AgentVerdict.missing:
        final err = stream.errorMessage;
        bs.feedback = err != null
            ? 'L\'invocazione precedente è terminata con un errore: $err'
            : 'L\'invocazione precedente è terminata senza la riga AUTOLOOP_STATUS '
                  '(exit ${outcome.exitCode}). Ultimo messaggio:\n$summary';
        _result(
          err != null ? RunOutcome.failed : RunOutcome.interrupted,
          'Fermata senza esito (exit ${outcome.exitCode}): verrà richiamata.',
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
    _setPhase(LoopPhase.verifying, 'Verifica: $cmd');
    _log(LogKind.tool, 'Verifica: $cmd');
    final watch = Stopwatch()..start();
    final (code, output) = await runShell(cmd, workDir!);
    if (code == 0) {
      // The last line of the output usually says it all ("All tests passed!").
      final last = output.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).lastOrNull;
      final tail = last == null ? '' : ' · ${last.length > 120 ? '${last.substring(0, 120)}…' : last}';
      _log(LogKind.success, 'Verifica superata in ${_span(watch.elapsed.inSeconds)}$tail');
      return null;
    }
    _log(LogKind.warning, 'Verifica fallita (exit $code).');
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
          'Commit saltato: la cartella di lavoro è dentro un altro repository (${top.stdout.toString().trim()}).',
        );
        return;
      }
      await git(['add', '-A'], dir);
      final staged = await git(['diff', '--cached', '--quiet'], dir);
      if (staged.exitCode == 0) {
        _log(LogKind.system, 'Nessuna modifica da committare.');
        return;
      }
      final title = block.title.length > 60 ? '${block.title.substring(0, 60)}…' : block.title;
      final r = await git([
        'commit',
        '-m',
        'autoloop: $title',
        '-m',
        'Blocco ${block.index + 1} del piano ${p.basename(planPath!)}.',
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
            if (files > 0) files == 1 ? '1 file' : '$files file',
            if (out.length > 1) '+${n('insertion')} −${n('deletion')}',
          ].join(' · '),
        );
      } else {
        _log(LogKind.warning, 'Commit non riuscito: ${r.stderr.toString().trim()}');
      }
    } catch (e) {
      _log(LogKind.warning, 'Git non disponibile: $e');
    }
  }

  @override
  void dispose() {
    _process?.kill(KillReason.stopped);
    super.dispose();
  }
}

enum _RunResult { blockDone, again, blocked, quota, auth, fatal }
