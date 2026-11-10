import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

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

  bool get isActive =>
      phase != LoopPhase.idle && phase != LoopPhase.paused && phase != LoopPhase.finished;
  bool get pauseRequested => _pauseRequested;

  BlockState blockState(PlanBlock b) => state!.of(b.id);

  int get doneCount => plan == null
      ? 0
      : plan!.blocks
          .where((b) => const [BlockStatus.done, BlockStatus.skipped].contains(blockState(b).status))
          .length;

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

  void setBlockStatus(PlanBlock b, BlockStatus status) {
    final s = blockState(b);
    s.status = status;
    if (status == BlockStatus.pending) {
      s.attempts = 0;
      s.feedback = '';
      s.note = '';
    }
    state!.save(workDir!);
    if (!isActive) {
      phase = doneCount == plan!.blocks.length ? LoopPhase.finished : LoopPhase.idle;
    }
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  void _log(LogKind kind, String text) {
    logs.add(LogEntry(kind, text));
    if (logs.length > _maxLogs) logs.removeRange(0, logs.length - _maxLogs);
    notifyListeners();
  }

  void _setPhase(LoopPhase p, [String? message]) {
    phase = p;
    if (message != null) statusMessage = message;
    notifyListeners();
  }

  // ------------------------------------------------------------ controls

  Future<void> start() async {
    if (isActive || plan == null || workDir == null) return;
    final exe = settings.executable;
    if (exe.isEmpty || !File(exe).existsSync()) {
      _log(LogKind.error, 'Eseguibile di ${settings.agent.label} non trovato. Impostalo nelle impostazioni.');
      return;
    }
    _stopRequested = false;
    _pauseRequested = false;
    _log(LogKind.info, 'Avvio del loop con ${settings.agent.label} su ${p.basename(planPath!)}.');
    try {
      await _loop();
    } catch (e, st) {
      _log(LogKind.error, 'Errore interno: $e');
      debugPrint('$st');
      _setPhase(LoopPhase.paused, 'Interrotto da un errore interno.');
    } finally {
      _process = null;
      currentBlock = null;
      waitUntil = null;
      runStartedAt = null;
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
        _log(LogKind.success, blocked == 0
            ? 'Tutti i blocchi sono completati.'
            : 'Nessun blocco da fare; $blocked bloccati richiedono attenzione.');
        _setPhase(blocked == 0 ? LoopPhase.finished : LoopPhase.paused,
            blocked == 0 ? 'Piano completato.' : 'Ci sono blocchi bloccati.');
        return;
      }

      if (settings.maxTotalTokens > 0 && state.totalTokens >= settings.maxTotalTokens) {
        _log(LogKind.warning, 'Budget di token raggiunto (${state.totalTokens}).');
        _setPhase(LoopPhase.paused, 'Budget di token esaurito.');
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
            return;
          }
          await _wait(Duration(minutes: settings.quotaWaitMinutes), LoopPhase.quotaWait,
              'Quota esaurita: nuovo tentativo tra ${settings.quotaWaitMinutes} min.');
        case _RunResult.auth:
          _setPhase(LoopPhase.paused, 'Problema di autenticazione: esegui il login nella CLI.');
          return;
        case _RunResult.blocked:
          if (!settings.skipBlocked) {
            _setPhase(LoopPhase.paused, 'Blocco ${next.index + 1} bloccato: serve il tuo intervento.');
            return;
          }
        case _RunResult.fatal:
          _setPhase(LoopPhase.paused, 'Impossibile avviare l\'agente.');
          return;
        case _RunResult.blockDone:
        case _RunResult.again:
          break;
      }

      if (_halt) break;
      if (plan.blocks.every((b) => state.of(b.id).status != BlockStatus.pending)) continue;
      await _wait(Duration(seconds: settings.relaunchDelaySeconds), LoopPhase.waiting,
          'Richiamo tra ${settings.relaunchDelaySeconds}s.');
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
    final logDir = Directory(p.join(LoopState.dirOf(dir), 'logs',
        '$stamp-b${block.index + 1}-a${bs.attempts}'))
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
      completedTitles: [
        for (final b in plan.blocks)
          if (state.of(b.id).status == BlockStatus.done) b.title,
      ],
    );
    File(p.join(logDir.path, 'prompt.md')).writeAsStringSync(prompt);
    final lastMessage = p.join(logDir.path, 'last-message.txt');
    final args = backend.buildArgs(workDir: dir, settings: settings, lastMessageFile: lastMessage);

    _log(LogKind.info,
        '▶ Blocco ${block.index + 1}/${plan.blocks.length} «${block.title}» — invocazione ${bs.attempts}');
    runStartedAt = DateTime.now();
    _setPhase(LoopPhase.running, 'Blocco ${block.index + 1}: ${block.title}');

    final stream = backend.newStream();
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
        rawLog: raw,
        onLine: (line, stderr) {
          for (final e in stream.handle(line, stderr: stderr)) {
            logs.add(e);
          }
          if (logs.length > _maxLogs) logs.removeRange(0, logs.length - _maxLogs);
          notifyListeners();
        },
      );
      _process = proc;
      if (_stopRequested) await proc.kill(KillReason.stopped);
      outcome = await done;
    } on ProcessException catch (e) {
      await raw.close();
      _log(LogKind.error, 'Avvio fallito: ${e.message}');
      bs.attempts--;
      state.runs--;
      state.save(dir);
      return _RunResult.fatal;
    } finally {
      _process = null;
    }
    await raw.close();
    runStartedAt = null;

    state.inputTokens += stream.inputTokens;
    state.outputTokens += stream.outputTokens;
    final finalText = backend.readFinalMessage(lastMessage) ?? stream.finalText;
    final (verdict, reason) = parseVerdict(finalText);
    final summary = _summary(finalText);
    if (stream.inputTokens + stream.outputTokens > 0) {
      _log(LogKind.system, 'Token: ${stream.inputTokens} in / ${stream.outputTokens} out');
    }

    if (outcome.killReason == KillReason.stopped) {
      bs.feedback = 'L\'invocazione precedente è stata interrotta dall\'utente. Riprendi dal lavoro su disco.';
      state.save(dir);
      return _RunResult.again;
    }

    if (stream.blocker == Blocker.usageLimit) {
      _log(LogKind.warning, 'Limite di utilizzo raggiunto: ${stream.errorMessage ?? ''}');
      state.save(dir);
      return _RunResult.quota;
    }
    if (stream.blocker == Blocker.authorization) {
      _log(LogKind.error, 'Autenticazione richiesta: ${stream.errorMessage ?? ''}');
      bs.attempts--;
      state.save(dir);
      return _RunResult.auth;
    }

    if (outcome.killReason != null) {
      final why = outcome.killReason == KillReason.idleTimeout
          ? 'nessun output per ${settings.idleTimeoutMinutes} minuti'
          : 'superato il limite di ${settings.runTimeoutMinutes} minuti';
      _log(LogKind.warning, 'Agente terminato dal supervisore: $why.');
      bs.feedback = 'L\'invocazione precedente è stata terminata dal supervisore ($why). '
          'Il lavoro parziale è su disco: controllalo e procedi a passi più brevi, '
          'aggiornando .autoloop/PROGRESS.md più spesso.';
      state.save(dir);
      return _RunResult.again;
    }

    switch (verdict) {
      case AgentVerdict.done:
        final verifyError = await _verify(block);
        if (verifyError != null) {
          bs.feedback = 'Hai dichiarato DONE ma la verifica `${settings.verifyCommand}` è fallita. '
              'Correggi il problema. Output (ultima parte):\n$verifyError';
          state.save(dir);
          return _RunResult.again;
        }
        await _commit(block);
        bs.status = BlockStatus.done;
        bs.note = summary;
        bs.feedback = '';
        state.save(dir);
        _log(LogKind.success, 'Blocco ${block.index + 1} completato.');
        return _RunResult.blockDone;
      case AgentVerdict.blocked:
        bs.status = BlockStatus.blocked;
        bs.note = reason.isEmpty ? summary : reason;
        state.save(dir);
        _log(LogKind.error, 'Blocco ${block.index + 1} bloccato: ${bs.note}');
        return _RunResult.blocked;
      case AgentVerdict.continueWork:
        bs.feedback = 'Nell\'invocazione precedente hai risposto CONTINUE. Tuo riepilogo:\n$summary';
        _log(LogKind.info, 'L\'agente chiede di continuare il blocco.');
      case AgentVerdict.missing:
        final err = stream.errorMessage;
        bs.feedback = err != null
            ? 'L\'invocazione precedente è terminata con un errore: $err'
            : 'L\'invocazione precedente è terminata senza la riga AUTOLOOP_STATUS '
                '(exit ${outcome.exitCode}). Ultimo messaggio:\n$summary';
        _log(LogKind.warning, 'L\'agente si è fermato senza esito (exit ${outcome.exitCode}): verrà richiamato.');
    }
    state.save(dir);
    return _RunResult.again;
  }

  String _summary(String text) {
    final cleaned = text.replaceAll(RegExp(r'AUTOLOOP_STATUS:[^\n]*', caseSensitive: false), '').trim();
    return cleaned.length > 4000 ? '…${cleaned.substring(cleaned.length - 4000)}' : cleaned;
  }

  /// Returns null when the block passes, otherwise the tail of the output.
  Future<String?> _verify(PlanBlock block) async {
    final cmd = settings.verifyCommand.trim();
    if (cmd.isEmpty) return null;
    _setPhase(LoopPhase.verifying, 'Verifica: $cmd');
    _log(LogKind.tool, 'Verifica: $cmd');
    final (code, output) = await runShell(cmd, workDir!);
    if (code == 0) {
      _log(LogKind.success, 'Verifica superata.');
      return null;
    }
    _log(LogKind.warning, 'Verifica fallita (exit $code).');
    return output.length > 8000 ? output.substring(output.length - 8000) : output;
  }

  Future<void> _commit(PlanBlock block) async {
    if (!settings.gitCommit) return;
    final dir = workDir!;
    try {
      final inside = await git(['rev-parse', '--is-inside-work-tree'], dir);
      if (inside.exitCode != 0 || inside.stdout.toString().trim() != 'true') return;
      await git(['add', '-A'], dir);
      final staged = await git(['diff', '--cached', '--quiet'], dir);
      if (staged.exitCode == 0) {
        _log(LogKind.system, 'Nessuna modifica da committare.');
        return;
      }
      final title = block.title.length > 60 ? '${block.title.substring(0, 60)}…' : block.title;
      final r = await git(['commit', '-m', 'autoloop: $title', '-m',
          'Blocco ${block.index + 1} del piano ${p.basename(planPath!)}.'], dir);
      if (r.exitCode == 0) {
        _log(LogKind.success, 'Commit creato: autoloop: $title');
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
