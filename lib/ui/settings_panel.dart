import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../engine/accounts.dart';
import '../engine/cli_locator.dart';
import '../engine/plan_parser.dart';
import '../engine/settings.dart';
import 'app_theme.dart';
import 'section_title.dart';
import 'resizable_text_field.dart';
import 'accounts_dialog.dart';
import 'agent_badge.dart';
import 'choice_dialog.dart';
import '../l10n.dart';

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.locked,
    required this.workDir,
    required this.planPath,
    required this.versions,
    required this.catalogs,
    required this.accounts,
    required this.onOpenAccounts,
    this.issues = const {},
    this.requirements = const [],
    this.projectDir,
    required this.onPickPlan,
    required this.onPickWorkDir,
    required this.onReloadPlan,
    required this.onDetect,
    required this.onChanged,
    required this.onStrategyChanged,
  });

  final LoopSettings settings;
  final bool locked;
  final String? workDir, planPath;
  final Map<AgentKind, String?> versions;
  final Map<AgentKind, AgentCatalog> catalogs;
  final Map<AgentKind, AccountStatus?> accounts;
  final VoidCallback onOpenAccounts;

  /// Sections with a problem that blocks the start ('Piano', 'Agente', 'Account').
  final Set<String> issues;

  /// What a start needs, and whether it is there: shown as a bar on top.
  final List<(String, bool)> requirements;

  /// When the loop starts: Piano, Agente and Account cannot change, so they
  /// close (they can still be opened to read them).
  static void collapseLocked() {
    _Collapsible.open.value = {..._Collapsible.open.value}..removeAll(['plan', 'agent', 'account']);
  }

  /// "Espandi tutto" / "Comprimi tutto" for the panel's title bar.
  static Widget expandAllButton() => ValueListenableBuilder<Set<String>>(
    valueListenable: _Collapsible.open,
    builder: (context, open, _) {
      final allOpen = _Collapsible.all.every(open.contains);
      return ExpandAllButton(
        allOpen: allOpen,
        onPressed: () => _Collapsible.open.value = allOpen ? <String>{} : {..._Collapsible.all},
      );
    },
  );

  /// Work folder whose own settings file holds the settings below.
  final String? projectDir;
  final VoidCallback onPickPlan, onPickWorkDir, onDetect, onChanged, onStrategyChanged;
  final VoidCallback? onReloadPlan;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final exe = s.executable;
    final version = versions[s.agent];
    final account = accounts[s.agent];
    final catalog = catalogs[s.agent] ?? AgentCatalog();
    final efforts = catalog.effortsFor(s.model);
    final selectedModel = catalog.find(s.model);
    final summaryRecall = tr(
      'Dopo ${s.relaunchDelaySeconds} s · ${s.maxAttemptsPerBlock} tentativi · max ${s.runTimeoutMinutes} min',
      'After ${s.relaunchDelaySeconds} s · ${s.maxAttemptsPerBlock} attempts · max ${s.runTimeoutMinutes} min',
    );
    final summaryPlan = [
      planPath == null ? tr('Nessun piano', 'No plan') : p.basename(planPath!),
      if (workDir != null) p.basename(workDir!),
      s.strategy.label,
    ].join(' · ');
    final summaryAgent = [
      s.agent.label,
      selectedModel?.label ?? (s.model.isEmpty ? tr('modello predefinito', 'default model') : s.model),
      if (s.effort.isNotEmpty) _effortName(s.effort).toLowerCase(),
      s.autonomy == Autonomy.full ? tr('accesso completo', 'full access') : tr('protetta', 'protected'),
    ].join(' · ');
    final summaryAccount = version == null
        ? tr('CLI non trovata', 'CLI not found')
        : account == null
        ? tr('Controllo…', 'Checking…')
        : account.loggedIn
        ? [account.email ?? tr('Connesso', 'Signed in'), if (!s.profile.isDefault) s.profile.name].join(' · ')
        : tr('Non connesso', 'Not signed in');
    final summaryQuota = [
      s.quotaBehavior == QuotaBehavior.wait ? tr('Riprende da solo', 'Resumes by itself') : tr('Si ferma', 'Stops'),
      if (s.keepAwake) tr('PC acceso', 'PC awake'),
      s.maxTotalTokens == 0
          ? tr('budget illimitato', 'no token budget')
          : tr('budget ${_compactTokens(s.maxTotalTokens)} token', 'budget ${_compactTokens(s.maxTotalTokens)} tokens'),
    ].join(' · ');
    final summaryEnd = [
      s.verifyCommand.trim().isEmpty
          ? tr('Nessuna verifica', 'No check')
          : tr('Verifica: ${s.verifyCommand.trim()}', 'Check: ${s.verifyCommand.trim()}'),
      s.gitCommit ? tr('commit git', 'git commit') : tr('senza commit', 'no commit'),
      if (s.skipBlocked) tr('salta i bloccati', 'skips blocked ones'),
    ].join(' · ');
    final rules = s.extraInstructions.trim().replaceAll(RegExp(r'\s+'), ' ');
    final summaryRules = rules.isEmpty ? tr('Nessuna regola aggiuntiva', 'No extra rules') : rules;
    final ready = requirements.where((r) => r.$2).length;
    final missing = [
      for (final r in requirements)
        if (!r.$2) r.$1,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (requirements.isNotEmpty)
          ProgressSummary(
            title: missing.isEmpty
                ? tr('Pronto per partire', 'Ready to start')
                : tr('Prima di partire', 'Before starting'),
            ratio: ready / requirements.length,
            label: tr(
              '$ready di ${requirements.length} requisiti pronti',
              '$ready of ${requirements.length} requirements ready',
            ),
            color: missing.isEmpty ? context.colors.success : null,
          ),
        Expanded(
          child: Stack(
            children: [
              ListView(
                padding: EdgeInsets.fromLTRB(18, 10, 18, 24),
                children: [
                  // Expand/collapse-all is hidden for now; the button is kept below.
                  // Piano, Agente and Account cannot change while the loop runs.
                  _Collapsible(
                    id: 'plan',
                    title: tr('Piano', 'Plan'),
                    summary: summaryPlan,
                    warning: issues.contains(tr('Piano', 'Plan')),
                    locked: locked,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Group(
                          children: [
                            _PathCard(
                              caption: tr('File del piano', 'Plan file'),
                              inGroup: true,
                              icon: Icons.description_outlined,
                              title: planPath == null
                                  ? tr('Scegli il file del piano', 'Choose the plan file')
                                  : p.basename(planPath!),
                              subtitle: planPath == null
                                  ? tr('.md o .txt', '.md or .txt')
                                  : _shortPath(p.dirname(planPath!)),
                              highlighted: planPath == null,
                              onTap: onPickPlan,
                            ),
                            _PathCard(
                              caption: tr('Cartella di lavoro', 'Working folder'),
                              inGroup: true,
                              icon: Icons.folder_outlined,
                              title: workDir == null
                                  ? tr('Scegli la cartella', 'Choose the folder')
                                  : p.basename(workDir!),
                              subtitle: workDir == null
                                  ? tr(
                                      'Dove l\'agente crea e modifica i file',
                                      'Where the agent creates and edits files',
                                    )
                                  : _shortPath(workDir!),
                              onTap: onPickWorkDir,
                            ),
                            _ChoiceCard<SplitStrategy>(
                              caption: tr('Suddivisione in blocchi', 'Splitting into blocks'),
                              icon: Icons.view_agenda_outlined,
                              dialogTitle: tr('Suddivisione in blocchi', 'Splitting into blocks'),
                              dialogSubtitle: tr(
                                'Come dividere il piano: l\'agente svolge un blocco alla volta.',
                                'How to split the plan: the agent works on one block at a time.',
                              ),
                              value: s.strategy,
                              choices: [
                                for (final v in SplitStrategy.values)
                                  Choice(
                                    value: v,
                                    icon: _strategyIcon[v],
                                    dividerAfter: v == SplitStrategy.auto,
                                    label: v.label,
                                    description: _strategyInfo[v]!.$2,
                                    short: _strategyInfo[v]!.$1,
                                  ),
                              ],
                              onChanged: (v) {
                                s.strategy = v;
                                onStrategyChanged();
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _Collapsible(
                    id: 'agent',
                    title: tr('Agente', 'Agent'),
                    summary: summaryAgent,
                    warning: issues.contains(tr('Agente', 'Agent')),
                    locked: locked,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Group(
                          children: [
                            _AgentPicker(
                              value: s.agent,
                              versions: versions,
                              onChanged: (v) {
                                s.agent = v;
                                onChanged();
                              },
                            ),
                            _ModelPicker(
                              caption: tr('Modello', 'Model'),
                              catalog: catalog,
                              value: s.model,
                              onChanged: (v) {
                                s.model = v;
                                // Keep the effort only if the new model supports it.
                                if (s.effort.isNotEmpty && !catalog.effortsFor(v).contains(s.effort)) s.effort = '';
                                onChanged();
                              },
                            ),
                            if (efforts.isNotEmpty)
                              _EffortPicker(
                                caption: tr('Ragionamento', 'Reasoning'),
                                efforts: efforts,
                                value: s.effort,
                                defaultLevel: selectedModel?.defaultEffort,
                                onChanged: (v) {
                                  s.effort = v;
                                  onChanged();
                                },
                              ),
                            _ChoiceCard<Autonomy>(
                              caption: tr('Permessi', 'Permissions'),
                              icon: s.autonomy == Autonomy.full ? Icons.lock_open_rounded : Icons.shield_outlined,
                              dialogTitle: tr('Permessi dell\'agente', 'Agent permissions'),
                              dialogSubtitle: tr(
                                'Quanta libertà ha ${s.agent.label} mentre lavora da solo.',
                                'How much freedom ${s.agent.label} has while it works on its own.',
                              ),
                              value: s.autonomy,
                              choices: [
                                Choice(
                                  value: Autonomy.sandboxed,
                                  icon: Icons.shield_outlined,
                                  label: tr('Protetta', 'Protected'),
                                  short: s.agent == AgentKind.codex
                                      ? tr('Sandbox sulla cartella del progetto', 'Sandbox on the project folder')
                                      : tr('Azioni rischiose bloccate', 'Risky actions blocked'),
                                  description: s.agent == AgentKind.codex
                                      ? tr(
                                          'Sandbox sulla cartella del progetto: modifica file ed esegue comandi al suo interno.',
                                          'Sandbox on the project folder: it edits files and runs commands inside it.',
                                        )
                                      : tr(
                                          'Le azioni sicure (modifiche, build, test) sono approvate in automatico, quelle rischiose bloccate.',
                                          'Safe actions (edits, builds, tests) are approved automatically, risky ones are blocked.',
                                        ),
                                ),
                                Choice(
                                  value: Autonomy.full,
                                  icon: Icons.lock_open_rounded,
                                  label: tr('Accesso completo', 'Full access'),
                                  short: tr('Nessuna sandbox né conferma', 'No sandbox, no confirmation'),
                                  description: tr(
                                    'Nessuna sandbox e nessuna conferma: può eseguire qualsiasi comando. '
                                        'Adatto a progetti sotto git o con un backup.',
                                    'No sandbox and no confirmation: it can run any command. For projects under git or with a backup.',
                                  ),
                                ),
                              ],
                              onChanged: (v) {
                                s.autonomy = v;
                                onChanged();
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _Collapsible(
                    id: 'account',
                    title: 'Account',
                    summary: summaryAccount,
                    warning: issues.contains('Account'),
                    locked: locked,
                    child: _Group(
                      children: [
                        // One row: profile and account open the same panel.
                        _PathCard(
                          caption: tr('Account e CLI', 'Accounts and CLIs'),
                          inGroup: true,
                          icon: account?.loggedIn == true ? Icons.account_circle_outlined : Icons.no_accounts_outlined,
                          highlighted: version == null || account?.loggedIn == false,
                          title: version == null
                              ? (exe.isEmpty
                                    ? tr('CLI non trovata', 'CLI not found')
                                    : tr('CLI non avviabile', 'CLI does not start'))
                              : account == null
                              ? tr('Controllo dell\'account…', 'Checking the account…')
                              : account.loggedIn
                              ? (account.email ?? tr('Connesso', 'Signed in'))
                              : tr('Non connesso', 'Not signed in'),
                          subtitle: [
                            s.agent.label,
                            if (!s.profile.isDefault) s.profile.name,
                            if (account?.loggedIn == true && planLabel(account!.plan).isNotEmpty)
                              tr('Piano ${planLabel(account.plan)}', '${planLabel(account.plan)} plan'),
                            if (version == null || account?.loggedIn == false)
                              tr('clicca per configurare', 'click to set up'),
                          ].join(' · '),
                          onTap: onOpenAccounts,
                        ),
                      ],
                    ),
                  ),
                  // While the loop runs: what can and cannot change, right after
                  // the sections that are locked.
                  if (locked) Padding(padding: EdgeInsets.only(top: 14), child: _RunningBanner()),
                  // Read again at every invocation: safe to change while running.
                  _Collapsible(
                    id: 'relaunch',
                    title: tr('Richiamo', 'Relaunch'),
                    summary: summaryRecall,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Pair(
                          _NumberField(
                            tr('Richiamo dopo', 'Relaunch after'),
                            's',
                            s.relaunchDelaySeconds,
                            (v) => s.relaunchDelaySeconds = v,
                            onChanged,
                            id: 'relaunch-delay',
                          ),
                          _NumberField(
                            tr('Tentativi per blocco', 'Attempts per block'),
                            '',
                            s.maxAttemptsPerBlock,
                            (v) => s.maxAttemptsPerBlock = v,
                            onChanged,
                            id: 'attempts',
                            min: 1,
                          ),
                        ),
                        _Pair(
                          _NumberField(
                            tr('Silenzio max', 'Max silence'),
                            'min',
                            s.idleTimeoutMinutes,
                            (v) => s.idleTimeoutMinutes = v,
                            onChanged,
                            id: 'idle-timeout',
                            min: 1,
                          ),
                          _NumberField(
                            tr('Durata max', 'Max duration'),
                            'min',
                            s.runTimeoutMinutes,
                            (v) => s.runTimeoutMinutes = v,
                            onChanged,
                            id: 'run-timeout',
                            min: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Collapsible(
                    id: 'quota',
                    title: tr('Quota e budget', 'Quota and budget'),
                    summary: summaryQuota,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Field(
                          label: tr('Quando la quota finisce', 'When the quota runs out'),
                          child: _ChoiceCard<QuotaBehavior>(
                            icon: s.quotaBehavior == QuotaBehavior.wait
                                ? Icons.update_rounded
                                : Icons.pause_circle_outline_rounded,
                            dialogTitle: tr('Quando la quota finisce', 'When the quota runs out'),
                            dialogSubtitle: tr(
                              'Cosa fare quando la CLI segnala il limite di utilizzo.',
                              'What to do when the CLI reports the usage limit.',
                            ),
                            value: s.quotaBehavior,
                            choices: [
                              Choice(
                                value: QuotaBehavior.wait,
                                icon: Icons.update_rounded,
                                label: QuotaBehavior.wait.label,
                                short: tr('Quando la quota si rinnova', 'When the quota renews'),
                                description: tr(
                                  'Riparte all\'ora in cui la quota si rinnova, se la CLI la indica; altrimenti '
                                      'riprova ogni ${s.quotaWaitMinutes} minuti. Va avanti così finché il piano è finito.',
                                  'Starts again at the time the quota renews, when the CLI says it; otherwise it tries again every ${s.quotaWaitMinutes} minutes. It goes on like this until the plan is done.',
                                ),
                              ),
                              Choice(
                                value: QuotaBehavior.stop,
                                icon: Icons.pause_circle_outline_rounded,
                                label: QuotaBehavior.stop.label,
                                short: tr('Il loop va in pausa', 'The loop pauses'),
                                description: tr(
                                  'Mette il loop in pausa: lo riprendi tu quando vuoi.',
                                  'Pauses the loop: you resume it when you want.',
                                ),
                              ),
                            ],
                            onChanged: (v) {
                              s.quotaBehavior = v;
                              onChanged();
                            },
                          ),
                        ),
                        _Field(
                          label: tr('PC acceso', 'PC awake'),
                          child: _ChoiceCard<bool>(
                            icon: s.keepAwake ? Icons.coffee_outlined : Icons.bedtime_outlined,
                            dialogTitle: tr('Mentre il loop lavora', 'While the loop works'),
                            dialogSubtitle: tr(
                              'Se Windows può andare in sospensione mentre il loop lavora o aspetta.',
                              'Whether Windows may go to sleep while the loop works or waits.',
                            ),
                            value: s.keepAwake,
                            choices: [
                              Choice(
                                value: true,
                                icon: Icons.coffee_outlined,
                                label: tr('Tieni acceso il PC', 'Keep the PC awake'),
                                short: tr('Niente sospensione automatica', 'No automatic sleep'),
                                description: tr(
                                  'Finché il loop lavora o aspetta la quota, Windows non va in sospensione da solo. '
                                      'Chiudere il coperchio o sospendere a mano lo ferma comunque.',
                                  'While the loop works or waits for the quota, Windows does not go to sleep on its own. Closing the lid or putting it to sleep by hand still stops it.',
                                ),
                              ),
                              Choice(
                                value: false,
                                icon: Icons.bedtime_outlined,
                                label: tr('Lascia decidere a Windows', 'Let Windows decide'),
                                short: tr('Sospensione come sempre', 'Sleep as usual'),
                                description: tr(
                                  'Il PC va in sospensione secondo le impostazioni di Windows, e il loop si ferma con lui.',
                                  'The PC sleeps according to the Windows settings, and the loop stops with it.',
                                ),
                              ),
                            ],
                            onChanged: (v) {
                              s.keepAwake = v;
                              onChanged();
                            },
                          ),
                        ),
                        _Pair(
                          _NumberField(
                            tr('Riprova ogni', 'Retry every'),
                            'min',
                            s.quotaWaitMinutes,
                            (v) => s.quotaWaitMinutes = v,
                            onChanged,
                            id: 'quota-retry',
                            min: 1,
                            enabled: s.quotaBehavior == QuotaBehavior.wait,
                          ),
                          _NumberField(
                            tr('Budget token', 'Token budget'),
                            'token',
                            s.maxTotalTokens,
                            (v) => s.maxTotalTokens = v,
                            onChanged,
                            id: 'token-budget',
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Collapsible(
                    id: 'end-of-block',
                    title: tr('Fine blocco', 'End of block'),
                    summary: summaryEnd,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Field(
                          label: tr('Comando di verifica', 'Check command'),
                          child: ResizableTextField(
                            key: ValueKey('field-verify-$projectDir'),
                            initialValue: s.verifyCommand,
                            minHeight: 54,
                            style: TextStyle(fontSize: 13, fontFamily: mono, fontFamilyFallback: monoFallback),
                            decoration: InputDecoration(hintText: tr('es. flutter test', 'e.g. flutter test')),
                            onChanged: (v) {
                              s.verifyCommand = v;
                              onChanged();
                            },
                          ),
                        ),
                        // Two-way choices are cards with a popup, like all the others.
                        _Group(
                          children: [
                            _ChoiceCard<bool>(
                              caption: tr('Commit git', 'Git commit'),
                              icon: s.gitCommit ? Icons.commit_rounded : Icons.block_rounded,
                              dialogTitle: tr('Commit git', 'Git commit'),
                              dialogSubtitle: tr(
                                'Se registrare le modifiche di ogni blocco completato.',
                                'Whether to record the changes of every completed block.',
                              ),
                              value: s.gitCommit,
                              choices: [
                                Choice(
                                  value: true,
                                  icon: Icons.commit_rounded,
                                  label: tr('A ogni blocco', 'Every block'),
                                  short: tr('Un commit per ogni blocco completato', 'One commit per completed block'),
                                  description: tr(
                                    'Quando un blocco è completato, le sue modifiche vengono registrate con un commit '
                                        '(se la cartella di lavoro è un repository git).',
                                    'When a block is completed, its changes are recorded with a commit (if the working folder is a git repository).',
                                  ),
                                ),
                                Choice(
                                  value: false,
                                  icon: Icons.block_rounded,
                                  label: tr('Mai', 'Never'),
                                  short: tr('Le modifiche restano da registrare', 'Changes are left to record'),
                                  description: tr(
                                    'Nessun commit automatico: le modifiche le registri tu quando vuoi.',
                                    'No automatic commit: you record the changes when you want.',
                                  ),
                                ),
                              ],
                              onChanged: (v) {
                                s.gitCommit = v;
                                onChanged();
                              },
                            ),
                            _ChoiceCard<bool>(
                              caption: tr('Blocchi bloccati', 'Blocked blocks'),
                              icon: s.skipBlocked ? Icons.redo_rounded : Icons.pause_circle_outline_rounded,
                              dialogTitle: tr('Quando un blocco è bloccato', 'When a block is blocked'),
                              dialogSubtitle: tr(
                                'Cosa fare se l\'agente non riesce a proseguire su un blocco.',
                                'What to do if the agent cannot go on with a block.',
                              ),
                              value: s.skipBlocked,
                              choices: [
                                Choice(
                                  value: false,
                                  icon: Icons.pause_circle_outline_rounded,
                                  label: tr('Metti in pausa', 'Pause'),
                                  short: tr('Aspetta il tuo intervento', 'Waits for you'),
                                  description: tr(
                                    'Il loop si ferma su quel blocco e aspetta che tu lo risolva.',
                                    'The loop stops on that block and waits for you to sort it out.',
                                  ),
                                ),
                                Choice(
                                  value: true,
                                  icon: Icons.redo_rounded,
                                  label: tr('Passa al successivo', 'Move to the next'),
                                  short: tr('Continua con gli altri blocchi', 'Goes on with the other blocks'),
                                  description: tr(
                                    'Il blocco resta bloccato e il loop va avanti con quelli dopo.',
                                    'The block stays blocked and the loop goes on with the next ones.',
                                  ),
                                ),
                              ],
                              onChanged: (v) {
                                s.skipBlocked = v;
                                onChanged();
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _Collapsible(
                    id: 'instructions',
                    title: tr('Istruzioni', 'Instructions'),
                    summary: summaryRules,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Field(
                          label: tr('Regole per ogni blocco', 'Rules for every block'),
                          child: ResizableTextField(
                            key: ValueKey('field-instructions-$projectDir'),
                            initialValue: s.extraInstructions,
                            minHeight: 100,
                            style: TextStyle(fontSize: 13, height: 1.4),
                            decoration: InputDecoration(
                              hintText: tr('Stack, stile, cosa non toccare…', 'Stack, style, what not to touch…'),
                            ),
                            onChanged: (v) {
                              s.extraInstructions = v;
                              onChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              // While the loop runs, the notice floats in the middle, over
              // the dimmed sections; clicks go through to what can change.
            ],
          ),
        ),
      ],
    );
  }
}

/// Last two segments of a path, enough to recognise it at a glance.
String _shortPath(String path) {
  final parts = p.split(path);
  if (parts.length <= 3) return path;
  return '…${p.separator}${p.joinAll(parts.sublist(parts.length - 2))}';
}

/// How far one click on a number field's arrows moves, chosen from the values
/// people typically use for that field.
const _fieldStep = <String, int>{
  'relaunch-delay': 10,
  'attempts': 5,
  'idle-timeout': 5,
  'run-timeout': 15,
  'quota-retry': 15,
  'token-budget': 500000,
};

/// What the less obvious fields do, shown from the "i" next to their name.
Map<String, String> get _fieldInfo => {
  tr('Richiamo dopo', 'Relaunch after'): tr(
    'Pausa tra la fine di un\'invocazione dell\'agente e la successiva.',
    'Pause between the end of one agent invocation and the next.',
  ),
  tr('Tentativi per blocco', 'Attempts per block'): tr(
    'Quante volte l\'agente viene richiamato sullo stesso blocco prima di segnarlo come bloccato.',
    'How many times the agent is relaunched on the same block before it is marked blocked.',
  ),
  tr('Silenzio max', 'Max silence'): tr(
    'Se l\'agente non scrive nulla per questo tempo, viene fermato e richiamato.',
    'If the agent writes nothing for this long, it is stopped and relaunched.',
  ),
  tr('Durata max', 'Max duration'): tr(
    'Tempo massimo di una singola invocazione: oltre, viene fermata e il blocco riprende.',
    'Longest time for one invocation: beyond it, it is stopped and the block starts again.',
  ),
  tr('Riprova ogni', 'Retry every'): tr(
    'Quando la CLI non dice a che ora si rinnova la quota, ogni quanto riprovare.',
    'When the CLI does not say when the quota renews, how often to try again.',
  ),
  tr('PC acceso', 'PC awake'): tr(
    'Se il PC va in sospensione il loop si ferma con lui. Con "Tieni acceso il PC" Windows non si sospende da '
        'solo finché il loop lavora o aspetta.',
    'If the PC goes to sleep the loop stops with it. With "Keep the PC awake" Windows does not sleep on its own while the loop works or waits.',
  ),
  tr('Budget token', 'Token budget'): tr(
    'Il loop si ferma dopo aver consumato in totale questi token. 0 = nessun limite.',
    'The loop stops after using this many tokens in total. 0 = no limit.',
  ),
  tr('Comando di verifica', 'Check command'): tr(
    'Eseguito con cmd.exe nella cartella di lavoro quando l\'agente dichiara il blocco finito: deve '
        'terminare con exit 0 perché il blocco sia completato. Se fallisce, l\'output torna all\'agente.',
    'Run with cmd.exe in the working folder when the agent says the block is done: it must end with exit 0 for the block to be completed. If it fails, the output goes back to the agent.',
  ),
  tr('Regole per ogni blocco', 'Rules for every block'): tr(
    'Testo aggiunto a ogni prompt, oltre al piano: utile per stack, stile e cose da non toccare.',
    'Text added to every prompt, besides the plan: useful for stack, style and things not to touch.',
  ),
  tr('Commit git', 'Git commit'): tr(
    'A ogni blocco completato registra le modifiche con un commit. Solo se la cartella di lavoro è un '
        'repository git.',
    'Records the changes of every completed block with a commit. Only if the working folder is a git repository.',
  ),
  tr('Blocchi bloccati', 'Blocked blocks'): tr(
    'Quando un blocco resta bloccato passa al successivo. Altrimenti il loop va in pausa e aspetta te.',
    'When a block stays blocked, moves on to the next one. Otherwise the loop pauses and waits for you.',
  ),
  tr('File del piano', 'Plan file'): tr(
    'Il file di testo (.md o .txt) con il piano. Viene diviso in blocchi, che l\'agente svolge uno alla volta.',
    'The text file (.md or .txt) with the plan. It is split into blocks, which the agent works on one at a time.',
  ),
  tr('Agente', 'Agent'): tr(
    'La CLI che svolge il piano, un blocco alla volta: Codex o Claude.',
    'The CLI that carries out the plan, one block at a time: Codex or Claude.',
  ),
  tr('Modello', 'Model'): tr(
    'Il modello che l\'agente usa. "Predefinito della CLI" lascia quello configurato nella CLI stessa.',
    'The model the agent uses. "CLI default" keeps the one set in the CLI itself.',
  ),
  tr('Quando la quota finisce', 'When the quota runs out'): tr(
    'Cosa fare quando la CLI segnala che il limite di utilizzo è stato raggiunto. "Riprendi da solo" riparte '
        'all\'ora in cui la quota si rinnova: così il piano va avanti anche per giorni, finché il PC è acceso e c\'è rete.',
    'What to do when the CLI reports that the usage limit has been reached. "Resume by itself" starts again at the time the quota renews: so the plan goes on even for days, as long as the PC is on and online.',
  ),
  // Cards whose name alone does not say what they are for.
  tr('Cartella di lavoro', 'Working folder'): tr(
    'Dove l\'agente crea e modifica i file. Le impostazioni di questo pannello si salvano qui, '
        'in .autoloop/settings.json, e tornano quando riapri il progetto. Percorsi delle CLI e set di '
        'account restano invece uguali per tutti i progetti.',
    'Where the agent creates and edits files. The settings of this panel are saved here, in .autoloop/settings.json, and come back when you reopen the project. CLI paths and account sets stay the same for every project.',
  ),
  tr('Suddivisione in blocchi', 'Splitting into blocks'): tr(
    'Come il piano viene diviso in blocchi. L\'agente ne svolge uno alla volta, e ogni blocco ha il suo esito.',
    'How the plan is split into blocks. The agent works on one at a time, and every block has its own outcome.',
  ),
  tr('Ragionamento', 'Reasoning'): tr(
    'Quanto l\'agente ragiona prima di agire: più alto dà risultati migliori, ma usa più tempo e token.',
    'How much the agent thinks before acting: higher gives better results, but uses more time and tokens.',
  ),
  tr('Permessi', 'Permissions'): tr(
    'Cosa l\'agente può fare da solo, senza chiedere conferma, mentre lavora sul piano.',
    'What the agent can do on its own, without asking, while it works on the plan.',
  ),
  tr('Account e CLI', 'Accounts and CLIs'): tr(
    'Con quale account lavora la CLI dell\'agente. Si possono tenere più set di account, per esempio di persone diverse.',
    'Which account the agent\'s CLI works with. You can keep several account sets, for example for different people.',
  ),
};

/// The ⓘ next to a field's name, when the name needs explaining.
Widget? _infoIcon(String? label, AppColors c) {
  final info = label == null ? null : _fieldInfo[label];
  if (info == null) return null;
  return Tooltip(
    message: info,
    waitDuration: const Duration(milliseconds: 150),
    child: Icon(Icons.info_outline_rounded, size: 13, color: c.muted),
  );
}

/// Related settings in one rounded card, as rows separated by hairlines.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: c.field,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RunningBanner extends StatelessWidget {
  const _RunningBanner();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: c.primary),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              tr(
                'Loop in esecuzione: piano, agente e account sono bloccati. '
                    'Le altre impostazioni si possono cambiare e valgono dalla prossima invocazione.',
                'Loop running: plan, agent and account are locked. The other settings can change and apply from the next invocation.',
              ),
              style: TextStyle(fontSize: 12, height: 1.4, color: c.text),
            ),
          ),
        ],
      ),
    );
  }
}

String _compactTokens(int n) => n >= 1000000
    ? '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M'
    : n >= 1000
    ? '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k'
    : '$n';

/// A section that starts closed and shows a one-line summary of its
/// settings; clicking the title opens it.
class _Collapsible extends StatefulWidget {
  _Collapsible({
    required this.id,
    required this.title,
    required this.summary,
    required this.child,
    this.warning = false,
    this.locked = false,
  }) : super(key: ValueKey('settings-section-$id'));
  final String id, title, summary;
  final Widget child;

  /// Something in this section prevents the loop from starting.
  final bool warning;

  /// The running loop cannot pick up changes here: shown dimmed, not editable.
  final bool locked;

  static const all = ['plan', 'agent', 'account', 'relaunch', 'quota', 'end-of-block', 'instructions'];

  // Shared by every section (and the expand/collapse-all button); survives
  // the list recycling sections that scroll out of view. Every section
  // starts open.
  static final open = ValueNotifier<Set<String>>({...all});

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool get _isOpen => _Collapsible.open.value.contains(widget.id);

  void _toggle() {
    final next = {..._Collapsible.open.value};
    if (!next.remove(widget.id)) next.add(widget.id);
    _Collapsible.open.value = next;
  }

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    _Collapsible.open.addListener(_changed);
  }

  @override
  void dispose() {
    _Collapsible.open.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final open = _isOpen;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(top: widget.id == _Collapsible.all.first ? 0 : 14),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Same title as the groups of the progress panel and
                    // the blocks of the activity log.
                    Row(
                      children: [
                        SizedBox(
                          width: sectionGutter,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SectionChevron(open: open),
                          ),
                        ),
                        Flexible(
                          flex: 3,
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: widget.warning ? c.danger : c.text,
                            ),
                          ),
                        ),
                        if (widget.warning) ...[
                          const SizedBox(width: 10),
                          Icon(Icons.error_rounded, size: 15, color: c.danger),
                        ],
                        const SizedBox(width: 16),
                        // Closed, the choices made inside show on the right,
                        // like the numbers of the other panels: as much as
                        // fits in part of the row, all of it in the tooltip.
                        Expanded(
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 160),
                            opacity: open ? 0 : 1,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: 170),
                                child: Tooltip(
                                  message: widget.summary,
                                  child: Text(
                                    open ? '' : widget.summary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(fontSize: 12, color: c.muted),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: AbsorbPointer(
                    absorbing: widget.locked,
                    child: AnimatedOpacity(
                      duration: Duration(milliseconds: 200),
                      opacity: widget.locked ? 0.5 : 1,
                      child: widget.child,
                    ),
                  ),
                )
              : SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _AgentPicker extends StatelessWidget {
  const _AgentPicker({required this.value, required this.versions, required this.onChanged});
  final AgentKind value;
  final Map<AgentKind, String?> versions;
  final ValueChanged<AgentKind> onChanged;

  static String? _short(String? version) =>
      version == null ? null : RegExp(r'\d+\.\d+\.\d+').firstMatch(version)?.group(0) ?? version;

  static Map<AgentKind, String> get _about => {
    AgentKind.codex: tr(
      'L\'agente di OpenAI, con il tuo account ChatGPT.',
      'OpenAI\'s agent, with your ChatGPT account.',
    ),
    AgentKind.claude: tr(
      'L\'agente di Anthropic, con il tuo account Claude.',
      'Anthropic\'s agent, with your Claude account.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final version = _short(versions[value]);
    return _PathCard(
      caption: tr('Agente', 'Agent'),
      inGroup: true,
      icon: Icons.smart_toy_outlined,
      leading: AgentBadge(kind: value, size: 34),
      title: value.label,
      subtitle: version == null
          ? tr('Non trovato su questo computer', 'Not found on this computer')
          : tr('Versione $version', 'Version $version'),
      trailing: Icons.unfold_more_rounded,
      onTap: () async {
        final picked = await showChoiceDialog<AgentKind>(
          context: context,
          title: tr('Agente', 'Agent'),
          subtitle: tr('Chi svolge il piano, un blocco alla volta.', 'Who carries out the plan, one block at a time.'),
          selected: value,
          choices: [
            for (final k in AgentKind.values)
              Choice(
                value: k,
                label: k.label,
                tag: _short(versions[k]) == null ? tr('non trovato', 'not found') : 'v${_short(versions[k])}',
                description: _about[k]!,
                leading: AgentBadge(kind: k, size: 32, selected: k == value, background: context.colors.field),
              ),
          ],
        );
        if (picked != null && picked != value) onChanged(picked);
      },
    );
  }
}

class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
    this.trailing = Icons.chevron_right_rounded,
    this.caption,
    this.inGroup = false,
    this.leading,
  });

  /// Replaces the icon tile (e.g. with the agent's logo).
  final Widget? leading;

  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool highlighted;
  final IconData trailing;

  /// Small uppercase name of the field, shown above the value inside groups.
  final String? caption;

  /// Drawn as a row of a [_Group] instead of a standalone card.
  final bool inGroup;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final radius = BorderRadius.circular(inGroup ? 0 : 12);
    final card = Material(
      color: highlighted ? c.primarySoft : (inGroup ? Colors.transparent : c.field),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: inGroup ? 9 : 10),
          child: Row(
            children: [
              leading ??
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: highlighted ? c.primary : c.surface,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(icon, size: 18, color: highlighted ? Colors.white : c.primary),
                  ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (caption != null)
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              caption!.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.9,
                                color: highlighted ? c.primary : c.muted,
                              ),
                            ),
                          ),
                          if (_infoIcon(caption, c) case final info?) ...[SizedBox(width: 4), info],
                        ],
                      ),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                        color: highlighted ? c.primary : c.text,
                      ),
                    ),
                    if (subtitle.isNotEmpty) SizedBox(height: 1),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: c.muted),
                      ),
                  ],
                ),
              ),
              Icon(trailing, size: 18, color: c.muted),
            ],
          ),
        ),
      ),
    );
    return card;
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text),
                ),
              ),
              if (_infoIcon(label, c) case final info?) ...[SizedBox(width: 4), info],
            ],
          ),
          SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

/// A tappable card showing the current choice; opens a popup to change it.
class _ChoiceCard<T> extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.dialogTitle,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.dialogSubtitle,
    this.caption,
  });
  final String? caption;
  final IconData icon;
  final String dialogTitle;
  final String? dialogSubtitle;
  final T value;
  final List<Choice<T>> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = choices.where((c) => c.value == value).firstOrNull;
    return _PathCard(
      icon: icon,
      caption: caption,
      inGroup: caption != null,
      title: current?.label ?? '$value',
      subtitle: current?.cardText ?? '',
      trailing: Icons.unfold_more_rounded,
      onTap: () async {
        final picked = await showChoiceDialog<T>(
          context: context,
          title: dialogTitle,
          subtitle: dialogSubtitle,
          choices: choices,
          selected: value,
        );
        if (picked != null && picked != value) onChanged(picked);
      },
    );
  }
}

final _strategyIcon = {
  SplitStrategy.auto: Icons.auto_awesome_outlined,
  SplitStrategy.headings: Icons.title_rounded,
  SplitStrategy.numbered: Icons.format_list_numbered_rounded,
  SplitStrategy.checkboxes: Icons.checklist_rounded,
  SplitStrategy.bullets: Icons.format_list_bulleted_rounded,
  SplitStrategy.whole: Icons.article_outlined,
};

Map<SplitStrategy, (String, String)> get _strategyInfo => {
  SplitStrategy.auto: (
    tr('Riconosce la struttura del file', 'Detects the file\'s structure'),
    tr(
      'Sceglie da solo la struttura del file: titoli, elenchi o checkbox.',
      'Picks the file\'s structure by itself: headings, lists or checkboxes.',
    ),
  ),
  SplitStrategy.headings: (
    tr('Un blocco per titolo', 'One block per heading'),
    tr('Un blocco per ogni titolo Markdown (## Titolo).', 'One block for every Markdown heading (## Heading).'),
  ),
  SplitStrategy.numbered: (
    tr('Un blocco per voce numerata', 'One block per numbered item'),
    tr(
      'Un blocco per ogni voce di un elenco numerato (1. 2. 3.).',
      'One block for every item of a numbered list (1. 2. 3.).',
    ),
  ),
  SplitStrategy.checkboxes: (
    tr('Un blocco per casella', 'One block per checkbox'),
    tr(
      'Un blocco per ogni casella (- [ ]); quelle spuntate sono già fatte.',
      'One block for every checkbox (- [ ]); ticked ones are already done.',
    ),
  ),
  SplitStrategy.bullets: (
    tr('Un blocco per voce', 'One block per item'),
    tr(
      'Un blocco per ogni voce di un elenco puntato (- voce).',
      'One block for every item of a bulleted list (- item).',
    ),
  ),
  SplitStrategy.whole: (
    tr('Tutto in un blocco', 'All in one block'),
    tr(
      'Tutto il piano come un unico blocco: l\'agente decide come procedere.',
      'The whole plan as a single block: the agent decides how to proceed.',
    ),
  ),
};

class _Pair extends StatelessWidget {
  const _Pair(this.a, this.b);
  final Widget a, b;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: a),
      SizedBox(width: 10),
      Expanded(child: b),
    ],
  );
}

class _NumberField extends StatefulWidget {
  // Stable identity across languages: fields appearing above (e.g. reasoning level)
  // must not hand this field another field's state.
  _NumberField(
    this.label,
    this.unit,
    this.value,
    this.set,
    this.onChanged, {
    required this.id,
    this.min = 0,
    this.enabled = true,
  }) : super(key: ValueKey('number-$id'));
  final String id, label, unit;
  final int value;
  final void Function(int) set;
  final VoidCallback onChanged;
  final int min;
  final bool enabled;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _controller = TextEditingController(text: '${widget.value}');
  bool _invalid = false;

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    // Follow external changes (e.g. per-project settings) unless mid-edit.
    if (!_invalid && int.tryParse(_controller.text) != widget.value) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply(String text) {
    final n = int.tryParse(text);
    setState(() {
      if (n == null) {
        _invalid = true;
      } else if (n < widget.min) {
        _invalid = true;
      } else {
        _invalid = false;
        widget.set(n);
        widget.onChanged();
      }
    });
  }

  int get _increment => _fieldStep[widget.id] ?? 1;

  /// Moves to the next multiple of the field's step (7 → 10 or 5 for a step
  /// of 5), never below the minimum.
  void _step(int direction) {
    final step = _increment;
    final current = int.tryParse(_controller.text) ?? widget.value;
    var next = direction > 0 ? (current ~/ step + 1) * step : ((current - 1) ~/ step) * step;
    if (next < widget.min) next = widget.min;
    _controller.text = '$next';
    _apply('$next');
  }

  String get _stepLabel {
    final step = _increment;
    final amount = step >= 1000000
        ? '${step ~/ 1000000}M'
        : step >= 1000
        ? '${step ~/ 1000}k'
        : '$step';
    return widget.unit.isEmpty ? amount : '$amount ${widget.unit}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Secondary to the text field itself, so kept out of the semantics tree
    // (their tooltips also trip Flutter's checks when built off-screen).
    Widget arrow(IconData icon, int direction) => ExcludeSemantics(
      child: Tooltip(
        message: '${direction > 0 ? '+' : '−'}$_stepLabel',
        waitDuration: Duration(milliseconds: 400),
        child: InkWell(
          onTap: widget.enabled ? () => _step(direction) : null,
          borderRadius: BorderRadius.circular(4),
          child: Icon(icon, size: 16, color: widget.enabled ? c.muted : c.muted.withValues(alpha: 0.4)),
        ),
      ),
    );
    return _Field(
      label: widget.label,
      child: TextField(
        controller: _controller,
        enabled: widget.enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: TextStyle(fontSize: 13.5, fontFeatures: [FontFeature.tabularFigures()]),
        decoration: InputDecoration(
          errorText: !_invalid
              ? null
              : int.tryParse(_controller.text) == null
              ? tr('Inserisci un numero', 'Enter a number')
              : tr('Minimo ${widget.min}', 'Minimum ${widget.min}'),
          errorStyle: TextStyle(fontSize: 11, color: c.danger),
          suffixIcon: Padding(
            padding: EdgeInsets.only(right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.unit.isNotEmpty) ...[
                  Text(widget.unit, style: TextStyle(color: c.muted, fontSize: 12)),
                  SizedBox(width: 4),
                ],
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [arrow(Icons.keyboard_arrow_up_rounded, 1), arrow(Icons.keyboard_arrow_down_rounded, -1)],
                ),
              ],
            ),
          ),
          suffixIconConstraints: BoxConstraints(minHeight: 36),
        ),
        onChanged: _apply,
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.catalog, required this.value, required this.onChanged, this.caption});
  final String? caption;
  final AgentCatalog catalog;
  final String value;
  final ValueChanged<String> onChanged;

  Future<void> _pick(BuildContext context) async {
    final picked = await showChoiceDialog<String>(
      context: context,
      title: tr('Modello', 'Model'),
      subtitle: catalog.isEmpty
          ? tr(
              'Elenco non rilevato: resta disponibile il modello predefinito.',
              'List not found: the default model is still available.',
            )
          : '${catalog.models.length} modelli dal ${catalog.source}',
      selected: value,
      choices: [
        Choice(
          value: '',
          icon: Icons.tune_rounded,
          label: tr('Predefinito della CLI', 'CLI default'),
          description: tr('Il modello configurato nella CLI.', 'The model set in the CLI.'),
          dividerAfter: true,
        ),
        for (final m in catalog.models)
          Choice(
            value: m.id,
            icon: Icons.auto_awesome_outlined,
            label: m.label,
            tag: m.label.toLowerCase() == m.id ? '' : m.id,
            description: m.description,
          ),
        // A model set earlier by hand stays selectable until changed.
        if (value.isNotEmpty && catalog.find(value) == null)
          Choice(value: value, icon: Icons.edit_outlined, label: value, tag: 'personalizzato'),
      ],
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final m = catalog.find(value);
    final title = value.isEmpty ? tr('Predefinito della CLI', 'CLI default') : (m?.label ?? value);
    final subtitle = value.isEmpty
        ? (catalog.isEmpty
              ? tr('Clicca per scegliere', 'Click to choose')
              : '${catalog.models.length} modelli disponibili')
        : (m?.description.isNotEmpty == true
              ? m!.description
              : (m == null ? tr('Modello personalizzato', 'Custom model') : value));
    return _PathCard(
      caption: caption,
      inGroup: caption != null,
      icon: Icons.auto_awesome_outlined,
      title: title,
      subtitle: subtitle,
      trailing: Icons.unfold_more_rounded,
      onTap: () => _pick(context),
    );
  }
}

/// Plain-language meaning of each reasoning level, shared by both CLIs.
Map<String, (String, String)> get _effortInfo => {
  'minimal': (
    tr('Minimo', 'Minimal'),
    tr('Quasi nessun ragionamento: il più veloce.', 'Almost no reasoning: the fastest.'),
  ),
  'low': (tr('Basso', 'Low'), tr('Risposte rapide, ragionamento leggero.', 'Quick answers, light reasoning.')),
  'medium': (tr('Medio', 'Medium'), tr('Equilibrio tra velocità e profondità.', 'Balance between speed and depth.')),
  'high': (tr('Alto', 'High'), tr('Più ragionamento per problemi complessi.', 'More reasoning for complex problems.')),
  'xhigh': (tr('Molto alto', 'Very high'), tr('Ragionamento esteso, più lento.', 'Extended reasoning, slower.')),
  'max': (tr('Massimo', 'Maximum'), tr('Il ragionamento più approfondito.', 'The deepest reasoning.')),
  'ultra': (
    'Ultra',
    tr('Il livello più alto disponibile: lento e costoso.', 'The highest level available: slow and expensive.'),
  ),
};

String _effortName(String id) => _effortInfo[id]?.$1 ?? id;

class _EffortPicker extends StatelessWidget {
  const _EffortPicker({
    required this.efforts,
    required this.value,
    required this.onChanged,
    this.defaultLevel,
    this.caption,
  });
  final String? caption;
  final List<String> efforts;
  final String value;
  final String? defaultLevel;
  final ValueChanged<String> onChanged;

  Future<void> _pick(BuildContext context) async {
    final picked = await showChoiceDialog<String>(
      context: context,
      title: tr('Livello di ragionamento', 'Reasoning level'),
      subtitle: tr(
        'Più ragionamento: risultati migliori, ma più tempo e token.',
        'More reasoning: better results, but more time and tokens.',
      ),
      selected: value,
      choices: [
        Choice(
          value: '',
          icon: Icons.tune_rounded,
          label: tr('Predefinito', 'Default'),
          dividerAfter: true,
          tag: defaultLevel ?? '',
          description: defaultLevel == null
              ? tr('Il livello configurato nella CLI.', 'The level set in the CLI.')
              : tr(
                  'Il livello consigliato per questo modello: ${_effortName(defaultLevel!).toLowerCase()}.',
                  'The level advised for this model: ${_effortName(defaultLevel!).toLowerCase()}.',
                ),
        ),
        // Levels go from least to most reasoning: numbered in that order.
        for (final (i, e) in efforts.indexed)
          Choice(value: e, iconText: '${i + 1}', label: _effortName(e), tag: e, description: _effortInfo[e]?.$2 ?? ''),
      ],
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final title = value.isEmpty
        ? (defaultLevel == null
              ? tr('Predefinito', 'Default')
              : tr(
                  'Predefinito · ${_effortName(defaultLevel!).toLowerCase()}',
                  'Default · ${_effortName(defaultLevel!).toLowerCase()}',
                ))
        : _effortName(value);
    final subtitle = value.isEmpty
        ? tr('${efforts.length} livelli disponibili', '${efforts.length} levels available')
        : (_effortInfo[value]?.$2 ?? value);
    return _PathCard(
      caption: caption,
      inGroup: caption != null,
      icon: Icons.psychology_outlined,
      title: title,
      subtitle: subtitle,
      trailing: Icons.unfold_more_rounded,
      onTap: () => _pick(context),
    );
  }
}
