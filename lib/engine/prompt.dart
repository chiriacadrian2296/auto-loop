import 'plan_parser.dart';
import 'settings.dart';

const _maxPlanChars = 40000;
const _maxProgressChars = 16000;

String _tail(String s, int max) => s.length <= max ? s : '[…troncato…]\n${s.substring(s.length - max)}';

String _head(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}\n[…troncato…]';

/// The instructions sent to the agent on every invocation.
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
  final b = StringBuffer()
    ..writeln(
      'Sei un agente di sviluppo autonomo guidato da AutoLoop, un supervisore che ti '
      'richiama finché il piano non è completato. Nessun umano sta leggendo in tempo reale.',
    )
    ..writeln()
    ..writeln('## Situazione')
    ..writeln('- Piano: $planName')
    ..writeln('- Blocco corrente: ${block.index + 1} di $n — «${block.title}»')
    ..writeln('- Invocazione n. $attempt su questo blocco')
    ..writeln(
      '- Blocchi già completati: ${completedTitles.isEmpty ? 'nessuno' : completedTitles.map((t) => '«$t»').join(', ')}',
    )
    ..writeln()
    ..writeln('## Regole')
    ..writeln('1. Lavora SOLO sul blocco corrente. Non iniziare i blocchi successivi.')
    ..writeln(
      '2. Il file `.autoloop/PROGRESS.md` è la tua memoria tra un\'invocazione e l\'altra. '
      'Prima di terminare aggiornalo con: cosa hai fatto, decisioni prese, cosa resta da fare per '
      'questo blocco. Tienilo conciso; puoi riassumere le voci vecchie.',
    )
    ..writeln(
      '3. Le modifiche delle invocazioni precedenti sono già su disco: ispezionale e prosegui, '
      'non ricominciare da capo.',
    )
    ..writeln(
      '4. Non chiedere conferme o chiarimenti: nessuno risponderà. Se devi scegliere, scegli '
      'l\'opzione più ragionevole e annotala in PROGRESS.md.',
    )
    ..writeln(
      '5. ${settings.gitCommit ? 'Non fare commit, push, reset o checkout: i commit li crea il supervisore a fine blocco.' : 'Non fare push, reset o checkout distruttivi.'}',
    )
    ..writeln('6. Non modificare il file del piano né i file in `.autoloop/` diversi da PROGRESS.md.')
    ..writeln('7. Non avviare processi che restano in esecuzione (server, watcher) senza chiuderli.')
    ..writeln(
      '8. Prima di dichiarare il blocco completato, verifica davvero il risultato '
      '(compila, esegui i test o controlla l\'output) quando è possibile.',
    );
  if (verify.isNotEmpty) {
    b.writeln(
      '9. Dopo che dichiari DONE il supervisore esegue `$verify`. Se fallisce, riceverai '
      'l\'output e dovrai correggere.',
    );
  }
  if (settings.extraInstructions.trim().isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Istruzioni aggiuntive dell\'utente')
      ..writeln(settings.extraInstructions.trim());
  }
  b
    ..writeln()
    ..writeln('## Esito (obbligatorio)')
    ..writeln('L\'ultima riga della tua risposta finale deve essere esattamente una di queste:')
    ..writeln('AUTOLOOP_STATUS: DONE')
    ..writeln('AUTOLOOP_STATUS: CONTINUE')
    ..writeln('AUTOLOOP_STATUS: BLOCKED: <motivo>')
    ..writeln(
      'DONE = il blocco corrente è completo e verificato. CONTINUE = hai fatto progressi ma '
      'resta lavoro (verrai richiamato). BLOCKED = impossibile procedere senza un intervento '
      'umano (credenziali, decisioni di business, risorse mancanti). Usa BLOCKED solo come ultima risorsa.',
    )
    ..writeln()
    ..writeln('## Avanzamento del blocco')
    ..writeln(
      'All\'inizio dividi il compito del blocco in passi concreti. Ogni volta che ne completi '
      'uno, scrivi in un tuo messaggio una riga a sé così: AUTOLOOP_PROGRESS: <fatti>/<totale> '
      '(per esempio AUTOLOOP_PROGRESS: 2/5). Mantieni lo stesso totale tra un\'invocazione e '
      'l\'altra; cambialo solo se scopri che i passi sono davvero di più o di meno.',
    )
    ..writeln(
      steps == null
          ? 'Finora non hai segnalato passi per questo blocco.'
          : 'Finora hai segnalato: AUTOLOOP_PROGRESS: ${steps.$1}/${steps.$2}.',
    )
    ..writeln()
    ..writeln('## Piano completo (contesto)')
    ..writeln('<piano>')
    ..writeln(_head(plan.raw.trim(), _maxPlanChars))
    ..writeln('</piano>')
    ..writeln()
    ..writeln('## Blocco corrente: il tuo compito')
    ..writeln('<blocco>')
    ..writeln(block.body.trim())
    ..writeln('</blocco>')
    ..writeln()
    ..writeln('## Contenuto attuale di .autoloop/PROGRESS.md')
    ..writeln('<progress>')
    ..writeln(_tail(progress.trim(), _maxProgressChars))
    ..writeln('</progress>');
  if (feedback.trim().isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Esito dell\'invocazione precedente')
      ..writeln(_tail(feedback.trim(), 12000));
  }
  b
    ..writeln()
    ..writeln('Inizia ora. Ricorda l\'ultima riga AUTOLOOP_STATUS.');
  return b.toString();
}
