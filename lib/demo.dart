import 'dart:io';

import 'package:path/path.dart' as p;

import 'engine/agents.dart';
import 'engine/loop_state.dart';
import 'engine/plan_parser.dart';
import 'l10n.dart';

/// Sample data for `AutoLoop.exe --demo`: a plan that has already been
/// worked on, so every panel has something to show without running an agent
/// or touching the user's own plans and preferences.
class DemoData {
  DemoData._(this.workDir, this.planPath, this.logs);

  final String workDir;
  final String planPath;
  final List<LogEntry> logs;

  static String get _plan => isEnglish ? _planEn : _planIt;

  static const _planIt = '''# Sito personale

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

  static const _planEn = '''# Personal website

A one-page static site with an introduction, projects and contacts.

## Project structure
Create index.html, style.css and the img/ folder. No framework.

## Introduction section
Title, subtitle and a short bio with a photo.

## Projects section
A grid of cards with a title, description and link for every project.

## Contact form
A form with name, email and message, sent through an external service.

## Dark theme
A dark variant of the colours that follows the system settings.

## Polish and README
Accessibility checks, meta tags and a README with the instructions.
''';

  /// [folder] lets tests that run side by side use folders of their own.
  static Future<DemoData> create({String folder = 'autoloop-demo'}) async {
    final dir = Directory(p.join(Directory.systemTemp.path, folder));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final planFile = File(p.join(dir.path, tr('sito-personale.md', 'personal-site.md')))..writeAsStringSync(_plan);

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
      tr(
        'Creati index.html, style.css e img/. La pagina si apre correttamente nel browser.',
        'Created index.html, style.css and img/. The page opens correctly in the browser.',
      ),
    );
    set(
      1,
      BlockStatus.done,
      2,
      19,
      236000,
      tr(
        'Sezione presentazione completa, con foto segnaposto e testo responsive.',
        'Introduction section complete, with a placeholder photo and responsive text.',
      ),
    );
    set(
      2,
      BlockStatus.done,
      3,
      41,
      362000,
      tr(
        'Griglia di 6 card che passa a una colonna sotto i 640 px.',
        'A grid of 6 cards that becomes one column below 640 px.',
      ),
    );
    set(
      3,
      BlockStatus.blocked,
      2,
      52,
      298000,
      tr(
        'Serve la chiave del servizio di invio email: non posso crearla da solo.',
        'It needs the key of the email service: I cannot create it myself.',
      ),
    );
    set(4, BlockStatus.pending, 1, 16, 207600);
    // Steps the agent reported for the blocked block: four of five done.
    state.of(plan.blocks[3].id)
      ..stepsDone = 4
      ..stepsTotal = 5;
    // A stop asked for after block 5, to check the work before going on.
    state.of(plan.blocks[4].id).pauseAfter = true;
    state.save(dir.path);

    final t = DateTime.now().subtract(const Duration(minutes: 12));
    DateTime at(int seconds) => t.add(Duration(seconds: seconds));
    final logs = [
      LogEntry(
        LogKind.info,
        tr(
          'Avvio del loop con Claude (account: Questo computer) su sito-personale.md.',
          'Starting the loop with Claude (account: This computer) on personal-site.md.',
        ),
        at: at(0),
      ),
      LogEntry(
        LogKind.info,
        tr('▶ Blocco 3/6 «Sezione progetti» — invocazione 3', '▶ Block 3/6 «Projects section» — invocation 3'),
        at: at(4),
      ),
      LogEntry(
        LogKind.system,
        tr('Sessione Claude avviata (claude-sonnet-5-5)', 'Claude session started (claude-sonnet-5-5)'),
        at: at(5),
      ),
      LogEntry(LogKind.tool, 'Read: .autoloop/PROGRESS.md', at: at(9)),
      LogEntry(LogKind.tool, 'Edit: style.css', at: at(41)),
      LogEntry(
        LogKind.agent,
        tr(
          'Le card ora passano a una colonna sotto i 640 px; ho aggiunto i link mancanti.',
          'The cards now become one column below 640 px; I added the missing links.',
        ),
        at: at(66),
      ),
      LogEntry(LogKind.system, 'Token: 118400 in / 6200 out · \$0.412', at: at(69)),
      LogEntry(
        LogKind.tool,
        tr('Verifica: npx html-validate index.html', 'Check: npx html-validate index.html'),
        at: at(70),
      ),
      LogEntry(
        LogKind.success,
        tr('Verifica superata in 8 s · 0 errori in 3 file', 'Check passed in 8 s · 0 errors in 3 files'),
        at: at(78),
      ),
      LogEntry(
        LogKind.success,
        tr('Commit 4f2a9c1 · 3 file · +142 −18', 'Commit 4f2a9c1 · 3 files · +142 −18'),
        at: at(79),
      ),
      LogEntry(
        LogKind.result,
        tr(
          'Sezione progetti con sei card responsive, link ai repository e immagini ottimizzate; '
              'sotto i 640 px le card passano a una colonna.',
          'Projects section with six responsive cards, links to the repositories and optimized images; '
              'below 640 px the cards become one column.',
        ),
        at: at(79),
        outcome: RunOutcome.done,
      ),
      LogEntry(
        LogKind.info,
        tr('▶ Blocco 4/6 «Modulo contatti» — invocazione 1', '▶ Block 4/6 «Contact form» — invocation 1'),
        at: at(110),
      ),
      LogEntry(
        LogKind.task,
        tr(
          'Aggiungi un modulo contatti con nome, email e messaggio, validazione lato client '
              'e invio tramite il servizio email.',
          'Add a contact form with name, email and message, client-side validation '
              'and sending through the email service.',
        ),
        at: at(111),
      ),
      LogEntry(LogKind.tool, tr('Write: contatti.js', 'Write: contact.js'), at: at(160)),
      LogEntry(LogKind.system, 'Token: 64100 in / 2900 out · \$0.205', at: at(759)),
      LogEntry(
        LogKind.result,
        tr(
          'Terminata dal supervisore: nessun output per 10 minuti.',
          'Stopped by the supervisor: no output for 10 minutes.',
        ),
        at: at(760),
        outcome: RunOutcome.interrupted,
      ),
      LogEntry(
        LogKind.info,
        tr('▶ Blocco 4/6 «Modulo contatti» — invocazione 2', '▶ Block 4/6 «Contact form» — invocation 2'),
        at: at(790),
      ),
      LogEntry(
        LogKind.agent,
        tr(
          'Il modulo è pronto, ma per inviare le email serve una chiave del servizio esterno.',
          'The form is ready, but sending the emails needs a key for the external service.',
        ),
        at: at(830),
      ),
      LogEntry(LogKind.system, 'Token: 21800 in / 1400 out · \$0.081', at: at(830)),
      LogEntry(
        LogKind.result,
        tr(
          'Serve la chiave del servizio di invio email: non posso crearla da solo.',
          'It needs the key of the email service: I cannot create it myself.',
        ),
        at: at(831),
        outcome: RunOutcome.blocked,
      ),
    ];
    final activity = ActivityLog(dir.path, planFile.path);
    logs.forEach(activity.append);
    return DemoData._(dir.path, planFile.path, logs);
  }
}
