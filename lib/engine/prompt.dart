import '../l10n.dart';
import 'plan_parser.dart';
import 'settings.dart';

const _maxPlanChars = 40000;
const _maxProgressChars = 16000;

String _tail(String s, int max) =>
    s.length <= max ? s : '${tr('[…troncato…]', '[…truncated…]')}\n${s.substring(s.length - max)}';

String _head(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}\n${tr('[…troncato…]', '[…truncated…]')}';

/// The instructions sent to the agent on every invocation, in the language
/// of the app: the agent answers in the language it is spoken to, so its
/// messages in the activity follow the app (the plan itself can be in any
/// language).
///
/// Each invocation is a fresh session: continuity comes from the files on
/// disk and from `.autoloop/PROGRESS.md`, which the agent itself maintains.
String buildPrompt({
  required ParsedPlan plan,
  required PlanBlock block,
  required int attempt,
  required LoopSettings settings,
  required String planName,
  required String progress,
  required String feedback,
  required List<String> completedTitles,
  (int, int)? steps,
}) {
  final n = plan.blocks.length;
  final verify = settings.verifyCommand.trim();
  final done = completedTitles.isEmpty ? tr('nessuno', 'none') : completedTitles.map((t) => '«$t»').join(', ');
  final b = StringBuffer()
    ..writeln(
      tr(
        'Sei un agente di sviluppo autonomo guidato da AutoLoop, un supervisore che ti '
            'richiama finché il piano non è completato. Nessun umano sta leggendo in tempo reale.',
        'You are an autonomous development agent driven by AutoLoop, a supervisor that '
            'relaunches you until the plan is complete. No human is reading in real time.',
      ),
    )
    ..writeln()
    ..writeln(tr('## Situazione', '## Situation'))
    ..writeln(tr('- Piano: $planName', '- Plan: $planName'))
    ..writeln(
      tr(
        '- Blocco corrente: ${block.index + 1} di $n — «${block.title}»',
        '- Current block: ${block.index + 1} of $n — «${block.title}»',
      ),
    )
    ..writeln(tr('- Invocazione n. $attempt su questo blocco', '- Invocation no. $attempt on this block'))
    ..writeln(tr('- Blocchi già completati: $done', '- Blocks already completed: $done'))
    ..writeln()
    ..writeln(tr('## Regole', '## Rules'))
    ..writeln(
      tr(
        '1. Lavora SOLO sul blocco corrente. Non iniziare i blocchi successivi.',
        '1. Work ONLY on the current block. Do not start the next blocks.',
      ),
    )
    ..writeln(
      tr(
        '2. Il file `.autoloop/PROGRESS.md` è la tua memoria tra un\'invocazione e l\'altra. '
            'Prima di terminare aggiornalo con: cosa hai fatto, decisioni prese, cosa resta da fare per '
            'questo blocco. Tienilo conciso; puoi riassumere le voci vecchie.',
        '2. The file `.autoloop/PROGRESS.md` is your memory from one invocation to the next. '
            'Before finishing, update it with: what you did, decisions taken, what is left to do for '
            'this block. Keep it short; you can summarize old entries.',
      ),
    )
    ..writeln(
      tr(
        '3. Le modifiche delle invocazioni precedenti sono già su disco: ispezionale e prosegui, '
            'non ricominciare da capo.',
        '3. The changes of previous invocations are already on disk: inspect them and go on, '
            'do not start over.',
      ),
    )
    ..writeln(
      tr(
        '4. Non chiedere conferme o chiarimenti: nessuno risponderà. Se devi scegliere, scegli '
            'l\'opzione più ragionevole e annotala in PROGRESS.md.',
        '4. Do not ask for confirmation or clarification: nobody will answer. If you must choose, choose '
            'the most reasonable option and note it in PROGRESS.md.',
      ),
    )
    ..writeln(
      settings.gitCommit
          ? tr(
              '5. Non fare commit, push, reset o checkout: i commit li crea il supervisore a fine blocco.',
              '5. Do not commit, push, reset or checkout: the supervisor makes the commits at the end of the block.',
            )
          : tr('5. Non fare push, reset o checkout distruttivi.', '5. Do not push, reset or do destructive checkouts.'),
    )
    ..writeln(
      tr(
        '6. Non modificare il file del piano né i file in `.autoloop/` diversi da PROGRESS.md.',
        '6. Do not edit the plan file or the files in `.autoloop/` other than PROGRESS.md.',
      ),
    )
    ..writeln(
      tr(
        '7. Non avviare processi che restano in esecuzione (server, watcher) senza chiuderli.',
        '7. Do not start processes that keep running (servers, watchers) without closing them.',
      ),
    )
    ..writeln(
      tr(
        '8. Prima di dichiarare il blocco completato, verifica davvero il risultato '
            '(compila, esegui i test o controlla l\'output) quando è possibile.',
        '8. Before declaring the block complete, really check the result '
            '(build, run the tests or look at the output) when you can.',
      ),
    )
    ..writeln(
      tr(
        '9. Scrivi i tuoi messaggi e PROGRESS.md in italiano, anche se il piano è in un\'altra lingua.',
        '9. Write your messages and PROGRESS.md in English, even if the plan is in another language.',
      ),
    );
  if (verify.isNotEmpty) {
    b.writeln(
      tr(
        '10. Dopo che dichiari DONE il supervisore esegue `$verify`. Se fallisce, riceverai '
            'l\'output e dovrai correggere.',
        '10. After you declare DONE the supervisor runs `$verify`. If it fails, you will get '
            'the output and must fix it.',
      ),
    );
  }
  if (settings.extraInstructions.trim().isNotEmpty) {
    b
      ..writeln()
      ..writeln(tr('## Istruzioni aggiuntive dell\'utente', '## Additional instructions from the user'))
      ..writeln(settings.extraInstructions.trim());
  }
  b
    ..writeln()
    ..writeln(tr('## Esito (obbligatorio)', '## Outcome (required)'))
    ..writeln(
      tr(
        'L\'ultima riga della tua risposta finale deve essere esattamente una di queste:',
        'The last line of your final answer must be exactly one of these:',
      ),
    )
    ..writeln('AUTOLOOP_STATUS: DONE')
    ..writeln('AUTOLOOP_STATUS: CONTINUE')
    ..writeln(tr('AUTOLOOP_STATUS: BLOCKED: <motivo>', 'AUTOLOOP_STATUS: BLOCKED: <reason>'))
    ..writeln(
      tr(
        'DONE = il blocco corrente è completo e verificato. CONTINUE = hai fatto progressi ma '
            'resta lavoro (verrai richiamato). BLOCKED = impossibile procedere senza un intervento '
            'umano (credenziali, decisioni di business, risorse mancanti). Usa BLOCKED solo come ultima risorsa.',
        'DONE = the current block is complete and checked. CONTINUE = you made progress but '
            'work is left (you will be relaunched). BLOCKED = impossible to go on without a human '
            '(credentials, business decisions, missing resources). Use BLOCKED only as a last resort.',
      ),
    )
    ..writeln()
    ..writeln(tr('## Avanzamento del blocco', '## Block progress'))
    ..writeln(
      tr(
        'All\'inizio dividi il compito del blocco in passi concreti. Ogni volta che ne completi '
            'uno, scrivi in un tuo messaggio una riga a sé così: AUTOLOOP_PROGRESS: <fatti>/<totale> '
            '(per esempio AUTOLOOP_PROGRESS: 2/5). Mantieni lo stesso totale tra un\'invocazione e '
            'l\'altra; cambialo solo se scopri che i passi sono davvero di più o di meno.',
        'At the start, split the block\'s task into concrete steps. Every time you complete '
            'one, write a line of its own in one of your messages, like this: AUTOLOOP_PROGRESS: <done>/<total> '
            '(for example AUTOLOOP_PROGRESS: 2/5). Keep the same total from one invocation to the '
            'next; change it only if you find out the steps really are more or fewer.',
      ),
    )
    ..writeln(
      steps == null
          ? tr(
              'Finora non hai segnalato passi per questo blocco.',
              'So far you have not reported steps for this block.',
            )
          : tr(
              'Finora hai segnalato: AUTOLOOP_PROGRESS: ${steps.$1}/${steps.$2}.',
              'So far you reported: AUTOLOOP_PROGRESS: ${steps.$1}/${steps.$2}.',
            ),
    )
    ..writeln()
    ..writeln(tr('## Piano completo (contesto)', '## Full plan (context)'))
    ..writeln(tr('<piano>', '<plan>'))
    ..writeln(_head(plan.raw.trim(), _maxPlanChars))
    ..writeln(tr('</piano>', '</plan>'))
    ..writeln()
    ..writeln(tr('## Blocco corrente: il tuo compito', '## Current block: your task'))
    ..writeln(tr('<blocco>', '<block>'))
    ..writeln(block.body.trim())
    ..writeln(tr('</blocco>', '</block>'))
    ..writeln()
    ..writeln(tr('## Contenuto attuale di .autoloop/PROGRESS.md', '## Current content of .autoloop/PROGRESS.md'))
    ..writeln('<progress>')
    ..writeln(_tail(progress.trim(), _maxProgressChars))
    ..writeln('</progress>');
  if (feedback.trim().isNotEmpty) {
    b
      ..writeln()
      ..writeln(tr('## Esito dell\'invocazione precedente', '## Outcome of the previous invocation'))
      ..writeln(_tail(feedback.trim(), 12000));
  }
  b
    ..writeln()
    ..writeln(
      tr('Inizia ora. Ricorda l\'ultima riga AUTOLOOP_STATUS.', 'Start now. Remember the last AUTOLOOP_STATUS line.'),
    );
  return b.toString();
}
