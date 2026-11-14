// Runs a tiny plan against the real CLIs. Uses a few tokens, so it is skipped
// unless AUTOLOOP_REAL=1:  AUTOLOOP_REAL=1 flutter test test/real_cli_test.dart
import 'dart:io';

import 'package:auto_loop/engine/cli_locator.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final enabled = Platform.environment['AUTOLOOP_REAL'] == '1';

  for (final kind in AgentKind.values) {
    test(
      'real ${kind.name}: one-block plan completes',
      () async {
        final exe = await locateCli(kind);
        expect(exe, isNotNull, reason: 'CLI not found');
        final dir = await Directory.systemTemp.createTemp('autoloop_real_');
        final plan = File(p.join(dir.path, 'plan.md'))
          ..writeAsStringSync(
            '## Saluto\nCrea il file `hello.txt` contenente esattamente la parola `ciao`.\n'
            '## Firma\nAggiungi a `hello.txt` una seconda riga con la parola `fine`.\n'
            '## Comando\nEsegui `git --version` e salva il suo output nel file `version.txt`.\n',
          );
        final engine = LoopEngine(
          LoopSettings(
            agent: kind,
            codexPath: kind == AgentKind.codex ? exe! : '',
            claudePath: kind == AgentKind.claude ? exe! : '',
            // Exercises the model/effort flags too.
            claudeModel: 'sonnet',
            codexEffort: 'low',
            claudeEffort: 'low',
            relaunchDelaySeconds: 0,
            maxAttemptsPerBlock: 3,
            quotaBehavior: QuotaBehavior.stop,
          ),
        )..load(workDir: dir.path, planPath: plan.path);
        var printed = 0;
        engine.addListener(() {
          while (printed < engine.logs.length) {
            // ignore: avoid_print
            print('[${kind.name}] ${engine.logs[printed++].text}');
          }
        });
        await engine.start();
        expect(engine.phase, LoopPhase.finished);
        final content = File(p.join(dir.path, 'hello.txt')).readAsStringSync();
        expect(content, contains('ciao'));
        expect(content, contains('fine'));
        // Proves the agent can run commands in the protected mode.
        expect(File(p.join(dir.path, 'version.txt')).readAsStringSync(), contains('git version'));
        expect(engine.state!.totalTokens, greaterThan(0));
      },
      skip: enabled ? false : 'set AUTOLOOP_REAL=1',
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
