import 'dart:io';

import 'package:path/path.dart' as p;

import 'engine/agents.dart';
import 'engine/loop_state.dart';
import 'engine/plan_parser.dart';

/// Sample data for `AutoLoop.exe --demo`: a plan that has already been
/// worked on, so every panel has something to show without running an agent
/// or touching the user's own plans and preferences.
class DemoData {
  DemoData._(this.workDir, this.planPath, this.logs);

  final String workDir;
  final String planPath;
  final List<LogEntry> logs;

  static const _plan = '''# Sito personale

Un sito statico di una pagina con presentazione, progetti e contatti.

## Struttura del progetto
Crea index.html, style.css e la cartella img/. Nessun framework.

## Sezione presentazione
Titolo, sottotitolo e una breve biografia con foto.

## Sezione progetti
Griglia di card con titolo, descrizione e link per ogni progetto.

## Modulo contatti
Modulo con nome, email e messaggio, inviato tramite un servizio esterno.

## Tema scuro
Variante scura dei colori che segue le impostazioni del sistema.

## Rifinitura e README
Controlli di accessibilità, meta tag e un README con le istruzioni.
''';

  static Future<DemoData> create() async {
    final dir = Directory(p.join(Directory.systemTemp.path, 'autoloop-demo'));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final planFile = File(p.join(dir.path, 'sito-personale.md'))..writeAsStringSync(_plan);

    final plan = parsePlan(_plan);
    final state = LoopState(planPath: planFile.path)
      ..runs = 9
      ..inputTokens = 1184000
      ..outputTokens = 23600
      ..activeSeconds = 2 * 3600 + 14 * 60;
    void set(int i, BlockStatus status, int attempts, int minutes, int tokens, [String note = '']) =>
        state.of(plan.blocks[i].id)
          ..status = status
          ..attempts = attempts
          ..note = note
          ..activeSeconds = minutes * 60
          ..inputTokens = tokens * 98 ~/ 100
          ..outputTokens = tokens * 2 ~/ 100;
    set(
      0,
      BlockStatus.done,
      1,
      6,
      104000,
      'Creati index.html, style.css e img/. La pagina si apre correttamente nel browser.',
    );
    set(1, BlockStatus.done, 2, 19, 236000, 'Sezione presentazione completa, con foto segnaposto e testo responsive.');
    set(2, BlockStatus.done, 3, 41, 362000, 'Griglia di 6 card che passa a una colonna sotto i 640 px.');
    set(
      3,
      BlockStatus.blocked,
      2,
      52,
      298000,
      'Serve la chiave del servizio di invio email: non posso crearla da solo.',
    );
    set(4, BlockStatus.pending, 1, 16, 207600);
    state.save(dir.path);

    final t = DateTime.now().subtract(const Duration(minutes: 12));
    DateTime at(int seconds) => t.add(Duration(seconds: seconds));
    final logs = [
      LogEntry(LogKind.info, 'Avvio del loop con Claude (account: Questo computer) su sito-personale.md.', at: at(0)),
      LogEntry(LogKind.info, '▶ Blocco 3/6 «Sezione progetti» — invocazione 3', at: at(4)),
      LogEntry(LogKind.system, 'Sessione Claude avviata (claude-sonnet-5-5)', at: at(5)),
      LogEntry(LogKind.tool, 'Read: .autoloop/PROGRESS.md', at: at(9)),
      LogEntry(LogKind.tool, 'Edit: style.css', at: at(41)),
      LogEntry(
        LogKind.agent,
        'Le card ora passano a una colonna sotto i 640 px; ho aggiunto i link mancanti.',
        at: at(66),
      ),
      LogEntry(LogKind.tool, 'Verifica: npx html-validate index.html', at: at(70)),
      LogEntry(LogKind.success, 'Verifica superata in 8 s · 0 errori in 3 file', at: at(78)),
      LogEntry(LogKind.success, 'Commit 4f2a9c1 · 3 file · +142 −18', at: at(79)),
      LogEntry(
        LogKind.result,
        'Completato in 3 invocazioni · 41 min · 362k token\n\n'
        'Sezione progetti con sei card responsive, link ai repository e immagini ottimizzate.',
        at: at(79),
      ),
      LogEntry(LogKind.info, '▶ Blocco 4/6 «Modulo contatti» — invocazione 1', at: at(110)),
      LogEntry(
        LogKind.task,
        'Aggiungi un modulo contatti con nome, email e messaggio, validazione lato client '
        'e invio tramite il servizio email.',
        at: at(111),
      ),
      LogEntry(LogKind.tool, 'Write: contatti.js', at: at(160)),
      LogEntry(LogKind.warning, 'Agente terminato dal supervisore: nessun output per 10 minuti.', at: at(760)),
      LogEntry(LogKind.info, '▶ Blocco 4/6 «Modulo contatti» — invocazione 2', at: at(790)),
      LogEntry(
        LogKind.agent,
        'Il modulo è pronto, ma per inviare le email serve una chiave del servizio esterno.',
        at: at(830),
      ),
      LogEntry(LogKind.error, 'Serve la chiave del servizio di invio email: non posso crearla da solo.', at: at(831)),
    ];
    final activity = ActivityLog(dir.path, planFile.path);
    logs.forEach(activity.append);
    return DemoData._(dir.path, planFile.path, logs);
  }
}
