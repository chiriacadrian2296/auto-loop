// A realistic run against the real CLIs, covering what a user meets in
// practice: verification, git commits, a pause after a chosen block, a block
// that cannot be done (skipped, the loop goes on) and the resume.
// Uses some tokens, so it is skipped unless AUTOLOOP_REAL=1:
//   $env:AUTOLOOP_REAL = '1'; flutter test test/real_scenario_test.dart
// AUTOLOOP_SCENARIO_DIR keeps the working folder there (for the screenshots in
// screenshot_test.dart); AUTOLOOP_AGENT=codex|claude runs only one agent.
import 'dart:io';

import 'package:auto_loop/engine/cli_locator.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/loop_state.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const scenarioPlan = '''# Piano di collaudo

Piano piccolo per collaudare AutoLoop: ogni blocco chiede un file di testo.

## Saluto
Crea il file `hello.txt` contenente esattamente la parola `ciao`.

## Numeri
Crea il file `numeri.txt` con i numeri 1, 2 e 3, uno per riga.

## Segreto
Leggi il file `segreto.txt` e copialo in `copia.txt`. Il file non esiste e NON devi crearlo né inventarne il
contenuto: se manca, termina con `AUTOLOOP_STATUS: BLOCKED: segreto.txt mancante`.

## Firma
Aggiungi a `hello.txt` una seconda riga con la parola `fine`.
''';

Future<String> _git(String dir, List<String> args) async {
  final r = await Process.run('git', args, workingDirectory: dir);
  return '${r.stdout}';
}

void main() {
  final enabled = Platform.environment['AUTOLOOP_REAL'] == '1';
  final only = Platform.environment['AUTOLOOP_AGENT'];
  final keep = Platform.environment['AUTOLOOP_SCENARIO_DIR'];

  for (final kind in AgentKind.values) {
    final skip = !enabled
        ? 'set AUTOLOOP_REAL=1'
        : (only != null && only != kind.name ? 'AUTOLOOP_AGENT=$only' : null);
    test('real ${kind.name}: pause, verify, commit, blocked block, resume', () async {
      final exe = await locateCli(kind);
      expect(exe, isNotNull, reason: 'CLI not found');

      final Directory dir;
      if (keep != null) {
        dir = Directory(p.join(keep, kind.name));
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
      } else {
        dir = await Directory.systemTemp.createTemp('autoloop_scenario_');
      }
      await _git(dir.path, ['init', '-q']);
      await _git(dir.path, ['config', 'user.name', 'AutoLoop Test']);
      await _git(dir.path, ['config', 'user.email', 'test@example.invalid']);
      final plan = File(p.join(dir.path, 'piano-collaudo.md'))..writeAsStringSync(scenarioPlan);

      final engine = LoopEngine(
        LoopSettings(
          agent: kind,
          codexPath: kind == AgentKind.codex ? exe! : '',
          claudePath: kind == AgentKind.claude ? exe! : '',
          claudeModel: 'sonnet',
          codexEffort: 'low',
          claudeEffort: 'low',
          relaunchDelaySeconds: 0,
          maxAttemptsPerBlock: 2,
          quotaBehavior: QuotaBehavior.stop,
          // Must pass for every DONE: true from the first block on.
          verifyCommand: 'findstr /c:ciao hello.txt',
          gitCommit: true,
          skipBlocked: true,
        ),
      )..load(workDir: dir.path, planPath: plan.path);
      var printed = 0;
      engine.addListener(() {
        while (printed < engine.logs.length) {
          // ignore: avoid_print
          print('[${kind.name}] ${engine.logs[printed++].text}');
        }
      });
      final blocks = engine.plan!.blocks;
      expect(blocks.map((b) => b.title), ['Saluto', 'Numeri', 'Segreto', 'Firma']);
      engine.setPauseAfter(blocks[0], true);

      // 1. Stops after the first block, as asked.
      await engine.start();
      expect(engine.phase, LoopPhase.paused);
      expect(engine.statusMessage, contains('In pausa dopo il blocco 1'));
      expect(engine.blockState(blocks[0]).status, BlockStatus.done);
      expect(engine.blockState(blocks[1]).status, BlockStatus.pending);

      // 2. Resumes: the impossible block is skipped as blocked, the rest is done.
      await engine.start();
      expect(engine.blockState(blocks[1]).status, BlockStatus.done);
      expect(engine.blockState(blocks[2]).status, BlockStatus.blocked);
      expect(engine.blockState(blocks[3]).status, BlockStatus.done);
      // A blocked block is left: paused, not finished.
      expect(engine.phase, LoopPhase.paused);

      // The work itself.
      final hello = File(p.join(dir.path, 'hello.txt')).readAsStringSync();
      expect(hello, contains('ciao'));
      expect(hello, contains('fine'));
      expect(File(p.join(dir.path, 'numeri.txt')).readAsStringSync(), allOf(contains('1'), contains('3')));
      expect(File(p.join(dir.path, 'segreto.txt')).existsSync(), isFalse);

      // Verification ran and passed, one commit per completed block.
      expect(engine.logs.where((l) => l.text.startsWith('Verifica superata')), hasLength(greaterThanOrEqualTo(3)));
      final commits = (await _git(dir.path, ['log', '--format=%s'])).trim().split('\n');
      expect(commits.where((c) => c.startsWith('autoloop:')), hasLength(3));
      // AutoLoop's own folder stays out of git.
      expect(await _git(dir.path, ['ls-files', '.autoloop']), isEmpty);

      // Counters and the saved state.
      expect(engine.state!.totalTokens, greaterThan(0));
      expect(engine.blockState(blocks[2]).attempts, greaterThanOrEqualTo(1));
      expect(File(p.join(dir.path, '.autoloop', 'state.json')).existsSync(), isTrue);
    }, skip: skip, timeout: const Timeout(Duration(minutes: 20)));
  }
}
