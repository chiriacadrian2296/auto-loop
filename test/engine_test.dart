import 'dart:io';

import 'package:auto_loop/engine/agents.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/loop_state.dart';
import 'package:auto_loop/engine/plan_parser.dart';
import 'package:auto_loop/engine/process_runner.dart';
import 'package:auto_loop/engine/quota_reset.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('plan parser', () {
    test('splits on the shallowest repeated heading, title goes to preamble', () {
      final plan = parsePlan('''
# Mio progetto
Obiettivo generale.

## Fase 1: setup
- crea progetto

```md
## non è un titolo
```

## Fase 2: feature
### dettaglio
testo
''');
      expect(plan.strategy, SplitStrategy.headings);
      expect(plan.preamble, contains('Obiettivo generale'));
      expect(plan.blocks.map((b) => b.title), ['Fase 1: setup', 'Fase 2: feature']);
      expect(plan.blocks[0].body, contains('## non è un titolo'));
      expect(plan.blocks[1].body, contains('### dettaglio'));
    });

    test('numbered list, checkboxes with pre-checked items, whole fallback', () {
      final numbered = parsePlan('Intro\n1. Primo\n  dettaglio\n2. Secondo\n');
      expect(numbered.strategy, SplitStrategy.numbered);
      expect(numbered.blocks[0].body, contains('dettaglio'));

      final boxes = parsePlan('- [x] fatto\n- [ ] da fare\n');
      expect(boxes.strategy, SplitStrategy.checkboxes);
      expect(boxes.blocks.map((b) => b.preChecked), [true, false]);

      final whole = parsePlan('Fai una app che saluta.\nCon un bottone.');
      expect(whole.strategy, SplitStrategy.whole);
      expect(whole.blocks.single.title, 'Fai una app che saluta.');
    });

    test('forced strategy and stable ids', () {
      const text = '## A\nx\n## B\ny\n';
      expect(parsePlan(text, strategy: SplitStrategy.whole).blocks, hasLength(1));
      expect(parsePlan(text).blocks[0].id, parsePlan('$text\n## C\nz').blocks[0].id);
    });
  });

  test('verdict parsing takes the last marker', () {
    expect(parseVerdict('AUTOLOOP_STATUS: CONTINUE\n...\nAUTOLOOP_STATUS: DONE').$1, AgentVerdict.done);
    final (v, reason) = parseVerdict('ok\nautoloop_status: blocked: manca la API key');
    expect(v, AgentVerdict.blocked);
    expect(reason, 'manca la API key');
    expect(parseVerdict('finito').$1, AgentVerdict.missing);
  });

  group('stream parsers', () {
    test('codex JSONL', () {
      final s = CodexBackend().newStream();
      s.handle('{"type":"thread.started","thread_id":"x"}', stderr: false);
      final logs = s.handle(
        '{"type":"item.completed","item":{"id":"1","type":"agent_message","text":"fatto\\nAUTOLOOP_STATUS: DONE"}}',
        stderr: false,
      );
      s.handle(
        '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5}}',
        stderr: false,
      );
      expect(logs.single.kind, LogKind.agent);
      expect(s.finalText, contains('DONE'));
      expect((s.inputTokens, s.outputTokens, s.turnCompleted), (50, 5, true));

      final q = CodexBackend().newStream();
      q.handle(
        '{"type":"turn.failed","error":{"message":"You\'ve hit your usage limit. Try again later."}}',
        stderr: false,
      );
      expect(q.blocker, Blocker.usageLimit);
    });

    test('claude stream-json', () {
      final s = ClaudeBackend().newStream();
      s.handle(
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}',
        stderr: false,
      );
      s.handle(
        '{"type":"result","subtype":"success","is_error":false,"result":"ok\\nAUTOLOOP_STATUS: CONTINUE",'
        '"usage":{"input_tokens":3,"cache_read_input_tokens":7,"output_tokens":2}}',
        stderr: false,
      );
      expect(parseVerdict(s.finalText).$1, AgentVerdict.continueWork);
      expect((s.inputTokens, s.outputTokens), (10, 2));

      final q = ClaudeBackend().newStream();
      q.handle(
        '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1"}',
        stderr: false,
      );
      expect(q.blocker, Blocker.usageLimit);

      final a = ClaudeBackend().newStream();
      const msg = 'Failed to authenticate: this login reached its time limit. Run `claude auth login`';
      final logs = a.handle(
        '{"type":"assistant","message":{"content":[{"type":"text","text":"$msg"}]}}',
        stderr: false,
      );
      expect(a.handle('{"type":"result","subtype":"success","is_error":true,"result":"$msg"}', stderr: false), isEmpty);
      expect(logs.single.kind, LogKind.error);
      expect(a.blocker, Blocker.authorization);
    });

    test('stderr echoes are not shown, mojibake is repaired', () {
      final s = CodexBackend().newStream();
      expect(s.handle('        // This is the theme of your application.', stderr: true), isEmpty);
      expect(fixMojibake('il prossimo blocco puÃ² implementare'), 'il prossimo blocco può implementare');
      expect(fixMojibake('già pronto'), 'già pronto');
    });

    test('task text mentioning quota is not an error', () {
      final s = CodexBackend().newStream();
      s.handle(
        '{"type":"item.completed","item":{"type":"agent_message","text":"Implemento la quota utente"}}',
        stderr: false,
      );
      expect(s.blocker, isNull);
    });
  });

  test('idle watchdog kills a silent process tree quickly', () async {
    final sw = Stopwatch()..start();
    final (_, done) = await ManagedProcess.start(
      executable: 'cmd.exe',
      args: ['/d', '/c', 'ping -n 60 127.0.0.1 >nul'],
      workingDirectory: Directory.systemTemp.path,
      timeout: const Duration(minutes: 5),
      idleTimeout: const Duration(seconds: 2),
      onLine: (_, _) {},
    );
    final outcome = await done;
    expect(outcome.killReason, KillReason.idleTimeout);
    expect(sw.elapsed, lessThan(const Duration(seconds: 15)));
  });

  group('loop with fake agent', () {
    late Directory dir;
    final fake = p.join(Directory.current.path, 'test', 'fake_agent', 'fake_claude.cmd');

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('autoloop_test_');
      Future<void> g(List<String> a) => Process.run('git', a, workingDirectory: dir.path);
      await g(['init', '-q']);
      await g(['config', 'user.email', 'test@example.com']);
      await g(['config', 'user.name', 'Test']);
      File(p.join(dir.path, 'README.md')).writeAsStringSync('x');
      await g(['add', '-A']);
      await g(['commit', '-q', '-m', 'init']);
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    LoopSettings settings({QuotaBehavior quota = QuotaBehavior.wait}) => LoopSettings(
      agent: AgentKind.claude,
      claudePath: fake,
      relaunchDelaySeconds: 0,
      quotaBehavior: quota,
      verifyCommand: 'if exist out1.txt (exit 0) else (exit 1)',
    );

    test('continues, completes every block, verifies and commits', () async {
      final plan = File(p.join(dir.path, 'plan.md'))..writeAsStringSync('## Uno\nfai uno\n## Due\nfai due\n');
      final engine = LoopEngine(settings());
      final alerts = <String>[];
      engine.onAttention = (title, _) => alerts.add(title);
      expect(engine.load(workDir: dir.path, planPath: plan.path), isNull);
      await engine.start();
      expect(alerts, ['Piano completato']);
      expect(engine.sessionStartedAt, isNull);

      expect(engine.phase, LoopPhase.finished, reason: engine.logs.map((l) => l.text).join('\n'));
      expect(engine.state!.runs, 4);
      expect(engine.state!.totalTokens, 440);
      for (final b in engine.plan!.blocks) {
        expect(engine.blockState(b).totalTokens, 220); // two invocations of 110 tokens
        // Steps reported with AUTOLOOP_PROGRESS; a completed block is complete.
        expect((engine.blockState(b).stepsDone, engine.blockState(b).stepsTotal), (3, 3));
      }
      expect(engine.state!.commits, 2);
      // Every invocation closes with one result line that says how it ended.
      final results = engine.logs.where((e) => e.kind == LogKind.result).toList();
      expect(results, hasLength(4));
      expect(results.map((e) => e.outcome).toSet(), {RunOutcome.again, RunOutcome.done});
      // Progress lines are read, not shown.
      expect(engine.logs.map((e) => e.text), everyElement(isNot(contains('AUTOLOOP_PROGRESS'))));
      // The readable export used by "Apri i log".
      final text = engine.exportActivity()!.readAsStringSync();
      expect(text, allOf(contains('── Blocco 1/2'), contains('AGENTE'), contains('OK')));
      expect(File(p.join(dir.path, 'out2.txt')).existsSync(), isTrue);
      final log = await Process.run('git', ['log', '--oneline'], workingDirectory: dir.path);
      expect(log.stdout.toString(), allOf(contains('autoloop: Uno'), contains('autoloop: Due')));
      // .autoloop/ stays out of git
      final tracked = await Process.run('git', ['ls-files'], workingDirectory: dir.path);
      expect(tracked.stdout.toString(), isNot(contains('.autoloop')));

      // Progress is persisted: a new engine sees everything done.
      final again = LoopEngine(settings())..load(workDir: dir.path, planPath: plan.path);
      expect(again.phase, LoopPhase.finished);
      // ...and so is the activity log, which survives a restart.
      expect(again.logs.map((e) => e.text), engine.logs.map((e) => e.text));
      again.clearLogs();
      expect((LoopEngine(settings())..load(workDir: dir.path, planPath: plan.path)).logs, isEmpty);
    });

    test('stops after a chosen block, then goes on when resumed', () async {
      final plan = File(p.join(dir.path, 'plan.md'))..writeAsStringSync('## Uno\nfai uno\n## Due\nfai due\n');
      final alerts = <String>[];
      final engine = LoopEngine(settings())
        ..onAttention = ((title, _) => alerts.add(title))
        ..load(workDir: dir.path, planPath: plan.path);
      engine.setPauseAfter(engine.plan!.blocks[0], true);
      await engine.start();
      expect(engine.phase, LoopPhase.paused);
      expect(alerts, ['In pausa per un controllo']);
      expect(engine.blockState(engine.plan!.blocks[0]).status, BlockStatus.done);
      expect(engine.blockState(engine.plan!.blocks[1]).attempts, 0);
      // The stop is used up: resuming runs the rest of the plan.
      expect(engine.blockState(engine.plan!.blocks[0]).pauseAfter, isFalse);
      await engine.start();
      expect(engine.phase, LoopPhase.finished);
    });

    test('a work folder inside another repository gets no commits', () async {
      final sub = Directory(p.join(dir.path, 'progetto'))..createSync();
      final plan = File(p.join(sub.path, 'plan.md'))..writeAsStringSync('## Uno\nfai uno\n');
      final before = (await Process.run('git', ['rev-list', '--count', 'HEAD'], workingDirectory: dir.path)).stdout;
      final engine = LoopEngine(LoopSettings(agent: AgentKind.claude, claudePath: fake, relaunchDelaySeconds: 0))
        ..load(workDir: sub.path, planPath: plan.path);
      await engine.start();
      expect(engine.phase, LoopPhase.finished);
      final after = (await Process.run('git', ['rev-list', '--count', 'HEAD'], workingDirectory: dir.path)).stdout;
      expect(after, before);
      expect(engine.logs.map((e) => e.text), contains(startsWith('Commit saltato')));
    });

    test('resumes by itself when the quota renews, at the time the CLI said', () async {
      LoopEngine.quotaMargin = Duration.zero;
      addTearDown(() => LoopEngine.quotaMargin = const Duration(minutes: 1));
      final plan = File(p.join(dir.path, 'plan.md'))..writeAsStringSync('## Uno QUOTA SOON\nfai uno\n## Due\nx\n');
      final engine = LoopEngine(settings())..load(workDir: dir.path, planPath: plan.path);
      final phases = <LoopPhase>{};
      DateTime? until;
      engine.addListener(() {
        phases.add(engine.phase);
        if (engine.phase == LoopPhase.quotaWait) until ??= engine.waitUntil;
      });
      final started = DateTime.now();
      await engine.start();
      expect(engine.phase, LoopPhase.finished, reason: engine.logs.map((l) => l.text).join('\n'));
      expect(phases, contains(LoopPhase.quotaWait));
      // Waited for the renewal (about two seconds), not the 30-minute interval.
      expect(until!.difference(started), lessThan(const Duration(seconds: 10)));
      expect(engine.logs.map((l) => l.text), contains(startsWith('La quota si rinnova alle')));
      expect(engine.blockState(engine.plan!.blocks[0]).attempts, 2);
    });

    test('waits for the network without consuming an attempt', () async {
      final plan = File(p.join(dir.path, 'plan.md'))..writeAsStringSync('## Uno OFFLINE\nfai uno\n');
      final engine = LoopEngine(settings())..load(workDir: dir.path, planPath: plan.path);
      await engine.start();
      expect(engine.phase, LoopPhase.finished, reason: engine.logs.map((l) => l.text).join('\n'));
      expect(engine.logs.map((l) => l.text), contains(startsWith('Connessione assente')));
      expect(engine.blockState(engine.plan!.blocks[0]).attempts, 2);
    });

    test('quota stop pauses without consuming an attempt, then resumes', () async {
      final plan = File(p.join(dir.path, 'plan.md'))..writeAsStringSync('## Uno QUOTA\nfai uno\n## Due\nx\n');
      final alerts = <String>[];
      final engine = LoopEngine(settings(quota: QuotaBehavior.stop))
        ..onAttention = ((title, _) => alerts.add(title))
        ..load(workDir: dir.path, planPath: plan.path);
      await engine.start();
      expect(alerts, ['Quota esaurita']);
      expect(engine.phase, LoopPhase.paused);
      expect(engine.statusMessage, contains('Quota'));
      expect(engine.blockState(engine.plan!.blocks[0]).attempts, 0);

      await engine.start();
      expect(engine.phase, LoopPhase.finished);
      expect(LoopState.load(dir.path, plan.path).runs, 5);
    });
  });

  test('commands and paths in the log are short', () {
    const dir = r'C:\Users\me\AppData\Local\Temp\scenario\codex';
    expect(
      tidyCommand(
        r'''"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Command 'Get-Content -LiteralPath hello.txt' ''',
        dir,
      ),
      'Get-Content -LiteralPath hello.txt',
    );
    expect(tidyCommand(r'''"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -Command 'ls' ''', dir), 'ls');
    expect(tidyCommand("bash -lc 'flutter test'", dir), 'flutter test');
    expect(tidyCommand('cmd.exe /d /s /c "git status"', dir), 'git status');
    expect(tidyCommand('cd "C:/Users/me/AppData/Local/Temp/scenario/codex" && cat hello.txt', dir), 'cat hello.txt');
    expect(tidyCommand('git status', dir), 'git status');
    // Codex's POSIX quoting of the script.
    expect(
      tidyCommand(r'''powershell.exe -Command 'Join-Path (Get-Location) '"'"'hello.txt'"'"'' ''', dir),
      "Join-Path (Get-Location) 'hello.txt'",
    );
    expect(
      tidyCommand(r'''powershell.exe -Command "[IO.File]::WriteAllText('a.txt', \"1"'`n2", $x)' ''', dir),
      r'''[IO.File]::WriteAllText('a.txt', "1`n2", $x)''',
    );
    expect(relativePaths(r'C:\Users\me\AppData\Local\Temp\scenario\codex\lib\a.dart', dir), r'lib\a.dart');
    expect(relativePaths('c:/users/me/appdata/local/temp/scenario/codex/hello.txt', dir), 'hello.txt');
    expect(relativePaths(r'C:\Users\me\AppData\Local\Temp\scenario\codex', dir), '.');
    // A sibling folder with a longer name stays as it is.
    expect(
      relativePaths(r'C:\Users\me\AppData\Local\Temp\scenario\codex2\x', dir),
      r'C:\Users\me\AppData\Local\Temp\scenario\codex2\x',
    );

    final s = ClaudeBackend().newStream(workDir: dir);
    final out = s.handle(
      r'{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"C:\\Users\\me\\AppData\\Local\\Temp\\scenario\\codex\\hello.txt"}}]}}',
      stderr: false,
    );
    expect(out.single.text, 'Read: hello.txt');
  });

  test('reads when the quota renews from the CLI messages', () {
    final now = DateTime(2026, 11, 15, 10, 30);
    expect(
      parseQuotaReset('Claude AI usage limit reached|1794683400', now: now),
      DateTime.fromMillisecondsSinceEpoch(1794683400 * 1000),
    );
    expect(parseQuotaReset("You've hit your limit · resets 3pm (Europe/Rome)", now: now), DateTime(2026, 11, 15, 15));
    expect(parseQuotaReset('5-hour limit reached ∙ resets 9:15am', now: now), DateTime(2026, 11, 16, 9, 15));
    expect(parseQuotaReset('Usage limit. Try again at 15:05.', now: now), DateTime(2026, 11, 15, 15, 5));
    expect(
      parseQuotaReset(
        "You've hit your usage limit. Upgrade to Pro or try again in 1 day 3 hours 12 minutes.",
        now: now,
      ),
      now.add(const Duration(days: 1, hours: 3, minutes: 12)),
    );
    expect(parseQuotaReset('try again in 45 min', now: now), now.add(const Duration(minutes: 45)));
    expect(
      parseQuotaReset('Usage limit reached, try again at Nov 17th, 2026 4:05 PM.', now: now),
      DateTime(2026, 11, 17, 16, 5),
    );
    expect(parseQuotaReset('Usage limit reached.', now: now), isNull);
    expect(parseQuotaReset('rate limit: 429', now: now), isNull);
  });

  test('Claude rate-limit events say when the rejected window renews', () {
    final s = ClaudeBackend().newStream();
    s.handle(
      '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1794683400,'
      '"unifiedWindows":{"five_hour":{"status":"allowed","resetsAt":1794683400}}}}',
      stderr: false,
    );
    expect(s.quotaResetAt, isNull);
    s.handle(
      '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794683400,'
      '"unifiedWindows":{"five_hour":{"status":"rejected","resetsAt":1794683400},'
      '"seven_day":{"status":"allowed","resetsAt":1794740400}}}}',
      stderr: false,
    );
    expect(s.quotaResetAt, DateTime.fromMillisecondsSinceEpoch(1794683400 * 1000));
  });

  test('network failures are told apart from the agent and from the quota', () {
    expect(classifyError('API Error: fetch failed (getaddrinfo ENOTFOUND api.anthropic.com)'), Blocker.network);
    expect(classifyError('stream disconnected before completion: error sending request'), Blocker.network);
    expect(classifyError('Claude AI usage limit reached|1794683400'), Blocker.usageLimit);
    expect(classifyError('Implemento la gestione degli errori di rete'), isNull);
  });
}
