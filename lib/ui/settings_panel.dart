import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../engine/accounts.dart';
import '../engine/cli_locator.dart';
import '../engine/plan_parser.dart';
import '../engine/settings.dart';
import 'app_theme.dart';
import 'accounts_dialog.dart';
import 'agent_badge.dart';
import 'choice_dialog.dart';

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
    final catalog = catalogs[s.agent] ?? const AgentCatalog();
    final efforts = catalog.effortsFor(s.model);
    final selectedModel = catalog.find(s.model);
    final summaryRecall =
        'Dopo ${s.relaunchDelaySeconds} s · ${s.maxAttemptsPerBlock} tentativi · max ${s.runTimeoutMinutes} min';
    final summaryPlan = [
      planPath == null ? 'Nessun piano' : p.basename(planPath!),
      if (workDir != null) p.basename(workDir!),
      s.strategy.label,
    ].join(' · ');
    final summaryAgent = [
      s.agent.label,
      selectedModel?.label ?? (s.model.isEmpty ? 'modello predefinito' : s.model),
      if (s.effort.isNotEmpty) _effortName(s.effort).toLowerCase(),
      s.autonomy == Autonomy.full ? 'accesso completo' : 'protetta',
    ].join(' · ');
    final summaryAccount = version == null
        ? 'CLI non trovata'
        : account == null
        ? 'Controllo…'
        : account.loggedIn
        ? [account.email ?? 'Connesso', if (!s.profile.isDefault) s.profile.name].join(' · ')
        : 'Non connesso';
    final summaryQuota = [
      s.quotaBehavior == QuotaBehavior.wait ? 'Riprova ogni ${s.quotaWaitMinutes} min' : 'Si ferma',
      s.maxTotalTokens == 0 ? 'budget illimitato' : 'budget ${_compactTokens(s.maxTotalTokens)} token',
    ].join(' · ');
    final summaryEnd = [
      s.verifyCommand.trim().isEmpty ? 'Nessuna verifica' : 'Verifica: ${s.verifyCommand.trim()}',
      s.gitCommit ? 'commit git' : 'senza commit',
      if (s.skipBlocked) 'salta i bloccati',
    ].join(' · ');
    final rules = s.extraInstructions.trim().replaceAll(RegExp(r'\s+'), ' ');
    final summaryRules = rules.isEmpty ? 'Nessuna regola aggiuntiva' : rules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              if (locked) const _RunningBanner(),
              // Expand/collapse-all is hidden for now; the button is kept below.
              // Piano, Agente and Account cannot change while the loop runs.
              _Collapsible(
                title: 'Piano',
                summary: summaryPlan,
                warning: issues.contains('Piano'),
                locked: locked,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Group(
                      children: [
                        _PathCard(
                          caption: 'File del piano',
                          inGroup: true,
                          icon: Icons.description_outlined,
                          title: planPath == null ? 'Scegli il file del piano' : p.basename(planPath!),
                          subtitle: planPath == null ? '.md o .txt' : _shortPath(p.dirname(planPath!)),
                          tooltip: planPath,
                          highlighted: planPath == null,
                          onTap: onPickPlan,
                        ),
                        _PathCard(
                          caption: 'Cartella di lavoro',
                          inGroup: true,
                          icon: Icons.folder_outlined,
                          title: workDir == null ? 'Scegli la cartella' : p.basename(workDir!),
                          subtitle: workDir == null ? 'Dove l\'agente crea e modifica i file' : _shortPath(workDir!),
                          tooltip: workDir,
                          onTap: onPickWorkDir,
                        ),
                        _ChoiceCard<SplitStrategy>(
                          caption: 'Suddivisione in blocchi',
                          icon: Icons.view_agenda_outlined,
                          dialogTitle: 'Suddivisione in blocchi',
                          dialogSubtitle: 'Come dividere il piano: l\'agente svolge un blocco alla volta.',
                          value: s.strategy,
                          choices: [
                            for (final v in SplitStrategy.values)
                              Choice(
                                value: v,
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
                title: 'Agente',
                summary: summaryAgent,
                warning: issues.contains('Agente'),
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
                          caption: 'Modello',
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
                            caption: 'Ragionamento',
                            efforts: efforts,
                            value: s.effort,
                            defaultLevel: selectedModel?.defaultEffort,
                            onChanged: (v) {
                              s.effort = v;
                              onChanged();
                            },
                          ),
                        _ChoiceCard<Autonomy>(
                          caption: 'Permessi',
                          icon: s.autonomy == Autonomy.full ? Icons.lock_open_rounded : Icons.shield_outlined,
                          dialogTitle: 'Permessi dell\'agente',
                          dialogSubtitle: 'Quanta libertà ha ${s.agent.label} mentre lavora da solo.',
                          value: s.autonomy,
                          choices: [
                            Choice(
                              value: Autonomy.sandboxed,
                              label: 'Protetta',
                              short: s.agent == AgentKind.codex
                                  ? 'Sandbox sulla cartella del progetto'
                                  : 'Azioni rischiose bloccate',
                              description: s.agent == AgentKind.codex
                                  ? 'Sandbox sulla cartella del progetto: modifica file ed esegue comandi al suo interno.'
                                  : 'Le azioni sicure (modifiche, build, test) sono approvate in automatico, quelle rischiose bloccate.',
                            ),
                            const Choice(
                              value: Autonomy.full,
                              label: 'Accesso completo',
                              short: 'Nessuna sandbox né conferma',
                              description:
                                  'Nessuna sandbox e nessuna conferma: può eseguire qualsiasi comando. '
                                  'Adatto a progetti sotto git o con un backup.',
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
                title: 'Account',
                summary: summaryAccount,
                warning: issues.contains('Account'),
                locked: locked,
                child: _Group(
                  children: [
                    // One row: profile and account open the same panel.
                    _PathCard(
                      caption: 'Account e CLI',
                      inGroup: true,
                      icon: account?.loggedIn == true ? Icons.account_circle_outlined : Icons.no_accounts_outlined,
                      highlighted: version == null || account?.loggedIn == false,
                      title: version == null
                          ? (exe.isEmpty ? 'CLI non trovata' : 'CLI non avviabile')
                          : account == null
                          ? 'Controllo dell\'account…'
                          : account.loggedIn
                          ? (account.email ?? 'Connesso')
                          : 'Non connesso',
                      subtitle: [
                        s.agent.label,
                        if (!s.profile.isDefault) s.profile.name,
                        if (account?.loggedIn == true && planLabel(account!.plan).isNotEmpty)
                          'Piano ${planLabel(account.plan)}',
                        if (version == null || account?.loggedIn == false) 'clicca per configurare',
                      ].join(' · '),
                      onTap: onOpenAccounts,
                    ),
                  ],
                ),
              ),
              // Read again at every invocation: safe to change while running.
              _Collapsible(
                title: 'Richiamo',
                summary: summaryRecall,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Pair(
                      _NumberField(
                        'Richiamo dopo',
                        's',
                        s.relaunchDelaySeconds,
                        (v) => s.relaunchDelaySeconds = v,
                        onChanged,
                      ),
                      _NumberField(
                        'Tentativi per blocco',
                        '',
                        s.maxAttemptsPerBlock,
                        (v) => s.maxAttemptsPerBlock = v,
                        onChanged,
                        min: 1,
                      ),
                    ),
                    _Pair(
                      _NumberField(
                        'Silenzio max',
                        'min',
                        s.idleTimeoutMinutes,
                        (v) => s.idleTimeoutMinutes = v,
                        onChanged,
                        min: 1,
                      ),
                      _NumberField(
                        'Durata max',
                        'min',
                        s.runTimeoutMinutes,
                        (v) => s.runTimeoutMinutes = v,
                        onChanged,
                        min: 1,
                      ),
                    ),
                  ],
                ),
              ),
              _Collapsible(
                title: 'Quota e budget',
                summary: summaryQuota,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Field(
                      label: 'Quando la quota finisce',
                      child: _ChoiceCard<QuotaBehavior>(
                        icon: s.quotaBehavior == QuotaBehavior.wait
                            ? Icons.update_rounded
                            : Icons.pause_circle_outline_rounded,
                        dialogTitle: 'Quando la quota finisce',
                        dialogSubtitle: 'Cosa fare quando la CLI segnala il limite di utilizzo.',
                        value: s.quotaBehavior,
                        choices: [
                          Choice(
                            value: QuotaBehavior.wait,
                            label: QuotaBehavior.wait.label,
                            short: 'Riprova ogni ${s.quotaWaitMinutes} min',
                            description:
                                'Aspetta e riprova ogni ${s.quotaWaitMinutes} minuti, finché la quota non torna.',
                          ),
                          Choice(
                            value: QuotaBehavior.stop,
                            label: QuotaBehavior.stop.label,
                            short: 'Il loop va in pausa',
                            description: 'Mette il loop in pausa: lo riprendi tu quando vuoi.',
                          ),
                        ],
                        onChanged: (v) {
                          s.quotaBehavior = v;
                          onChanged();
                        },
                      ),
                    ),
                    _Pair(
                      _NumberField(
                        'Riprova ogni',
                        'min',
                        s.quotaWaitMinutes,
                        (v) => s.quotaWaitMinutes = v,
                        onChanged,
                        min: 1,
                        enabled: s.quotaBehavior == QuotaBehavior.wait,
                      ),
                      _NumberField('Budget token', 'token', s.maxTotalTokens, (v) => s.maxTotalTokens = v, onChanged),
                    ),
                  ],
                ),
              ),
              _Collapsible(
                title: 'Fine blocco',
                summary: summaryEnd,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Field(
                      label: 'Comando di verifica',
                      hint: 'Deve terminare con exit 0 perché il blocco sia completato.',
                      child: TextFormField(
                        key: ValueKey('field-verify-$projectDir'),
                        initialValue: s.verifyCommand,
                        style: const TextStyle(fontSize: 13, fontFamily: mono, fontFamilyFallback: monoFallback),
                        decoration: const InputDecoration(hintText: 'es. flutter test'),
                        onChanged: (v) {
                          s.verifyCommand = v;
                          onChanged();
                        },
                      ),
                    ),
                    _Group(
                      indent: 14,
                      children: [
                        _Toggle(
                          title: 'Commit git a ogni blocco',
                          subtitle: 'Se la cartella è un repository',
                          value: s.gitCommit,
                          onChanged: (v) {
                            s.gitCommit = v;
                            onChanged();
                          },
                        ),
                        _Toggle(
                          title: 'Salta i blocchi bloccati',
                          subtitle: 'Altrimenti il loop va in pausa',
                          value: s.skipBlocked,
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
                title: 'Istruzioni',
                summary: summaryRules,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Field(
                      label: 'Regole per ogni blocco',
                      hint: 'Aggiunte a ogni prompt, oltre al piano.',
                      child: TextFormField(
                        key: ValueKey('field-instructions-$projectDir'),
                        initialValue: s.extraInstructions,
                        minLines: 3,
                        maxLines: 8,
                        style: const TextStyle(fontSize: 13, height: 1.4),
                        decoration: const InputDecoration(hintText: 'Stack, stile, cosa non toccare…'),
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
        ),
        if (projectDir != null) _ProjectFooter(projectDir: projectDir!),
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
  'Richiamo dopo': 10,
  'Tentativi per blocco': 5,
  'Silenzio max': 5,
  'Durata max': 15,
  'Riprova ogni': 15,
  'Budget token': 500000,
};

/// What the less obvious fields do, shown from the "i" next to their name.
const _fieldInfo = <String, String>{
  'Richiamo dopo': 'Pausa tra la fine di un\'invocazione dell\'agente e la successiva.',
  'Tentativi per blocco':
      'Quante volte l\'agente viene richiamato sullo stesso blocco prima di segnarlo come bloccato.',
  'Silenzio max': 'Se l\'agente non scrive nulla per questo tempo, viene fermato e richiamato.',
  'Durata max': 'Tempo massimo di una singola invocazione: oltre, viene fermata e il blocco riprende.',
  'Riprova ogni': 'Ogni quanto riprovare quando la CLI segnala che la quota è esaurita.',
  'Budget token': 'Il loop si ferma dopo aver consumato in totale questi token. 0 = nessun limite.',
  'Comando di verifica':
      'Eseguito con cmd.exe nella cartella di lavoro quando l\'agente dichiara il blocco finito. '
      'Se fallisce, l\'output torna all\'agente.',
  'Regole per ogni blocco': 'Testo aggiunto a ogni prompt, utile per stack, stile e cose da non toccare.',
};

/// Related settings in one rounded card, as rows separated by hairlines.
class _Group extends StatelessWidget {
  const _Group({required this.children, this.indent = 0});
  final List<Widget> children;

  /// Where the separators start: past the icon for cards, flush for toggles.
  final double indent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: c.field,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, indent: indent, color: c.border),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Says, at the foot of the panel, that these settings travel with the
/// project folder.
class _ProjectFooter extends StatelessWidget {
  const _ProjectFooter({required this.projectDir});
  final String projectDir;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message:
          'Salvate in ${p.join(p.basename(projectDir), '.autoloop', 'settings.json')}.\n'
          'Restano uguali per tutti i progetti: percorsi delle CLI e set di account.',
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            Icon(Icons.bookmark_added_outlined, size: 17, color: c.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Impostazioni salvate nel progetto',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.text),
                  ),
                  Text(
                    'Le ritrovi ogni volta che riapri «${p.basename(projectDir)}»',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: c.muted),
                  ),
                ],
              ),
            ),
            Icon(Icons.info_outline_rounded, size: 14, color: c.muted),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _ExpandAll extends StatelessWidget {
  const _ExpandAll();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ValueListenableBuilder<Set<String>>(
      valueListenable: _Collapsible.open,
      builder: (context, open, _) {
        final allOpen = _Collapsible.all.every(open.contains);
        return Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _Collapsible.open.value = allOpen ? <String>{} : {..._Collapsible.all},
            style: TextButton.styleFrom(
              foregroundColor: c.muted,
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: uiFont,
                fontFamilyFallback: uiFallback,
              ),
            ),
            icon: Icon(allOpen ? Icons.unfold_less_rounded : Icons.unfold_more_rounded, size: 17),
            label: Text(allOpen ? 'Comprimi tutto' : 'Espandi tutto'),
          ),
        );
      },
    );
  }
}

class _RunningBanner extends StatelessWidget {
  const _RunningBanner();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: c.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Loop in esecuzione: piano, agente e account sono bloccati. '
              'Le altre impostazioni si possono cambiare e valgono dalla prossima invocazione.',
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
  const _Collapsible({
    required this.title,
    required this.summary,
    required this.child,
    this.warning = false,
    this.locked = false,
  });
  final String title, summary;
  final Widget child;

  /// Something in this section prevents the loop from starting.
  final bool warning;

  /// The running loop cannot pick up changes here: shown dimmed, not editable.
  final bool locked;

  static const all = ['Piano', 'Agente', 'Account', 'Richiamo', 'Quota e budget', 'Fine blocco', 'Istruzioni'];

  // Shared by every section (and the expand/collapse-all button); survives
  // the list recycling sections that scroll out of view. The main sections
  // start open, the advanced ones closed.
  static final open = ValueNotifier<Set<String>>({'Piano', 'Agente'});

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool get _isOpen => _Collapsible.open.value.contains(widget.title);

  void _toggle() {
    final next = {..._Collapsible.open.value};
    if (!next.remove(widget.title)) next.add(widget.title);
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
          padding: const EdgeInsets.only(top: 14),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: Divider(color: c.border)),
                        Padding(
                          padding: const EdgeInsets.only(left: 12, right: 6),
                          child: Text(
                            widget.title.toUpperCase(),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.6,
                              color: widget.warning ? c.danger : c.text,
                            ),
                          ),
                        ),
                        if (widget.warning)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(Icons.error_rounded, size: 15, color: c.danger),
                          ),
                        AnimatedRotation(
                          turns: open ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(Icons.expand_more_rounded, size: 18, color: c.muted),
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Divider(color: c.border)),
                      ],
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: open
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                              child: Text(
                                widget.summary,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, height: 1.4, color: c.muted),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: AbsorbPointer(
                    absorbing: widget.locked,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: widget.locked ? 0.5 : 1,
                      child: widget.child,
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
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

  static const _about = {
    AgentKind.codex: 'L\'agente di OpenAI, con il tuo account ChatGPT.',
    AgentKind.claude: 'L\'agente di Anthropic, con il tuo account Claude.',
  };

  @override
  Widget build(BuildContext context) {
    final version = _short(versions[value]);
    return _PathCard(
      caption: 'Agente',
      inGroup: true,
      icon: Icons.smart_toy_outlined,
      leading: AgentBadge(kind: value, size: 34),
      title: value.label,
      subtitle: version == null ? 'Non trovato su questo computer' : 'Versione $version',
      trailing: Icons.unfold_more_rounded,
      onTap: () async {
        final picked = await showChoiceDialog<AgentKind>(
          context: context,
          title: 'Agente',
          subtitle: 'Chi svolge il piano, un blocco alla volta.',
          selected: value,
          choices: [
            for (final k in AgentKind.values)
              Choice(
                value: k,
                label: k.label,
                tag: _short(versions[k]) == null ? 'non trovato' : 'v${_short(versions[k])}',
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
    this.tooltip,
    this.leading,
  });

  /// Replaces the icon tile (e.g. with the agent's logo).
  final Widget? leading;

  /// Full text shown on hover (e.g. the complete path).
  final String? tooltip;
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
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (caption != null)
                      Text(
                        caption!.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                          color: highlighted ? c.primary : c.muted,
                        ),
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
                    if (subtitle.isNotEmpty) const SizedBox(height: 1),
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
    return tooltip == null
        ? card
        : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 600), child: card);
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child, this.hint});
  final String label;
  final Widget child;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
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
              if (_fieldInfo[label] case final info?) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: info,
                  waitDuration: const Duration(milliseconds: 150),
                  child: Icon(Icons.info_outline_rounded, size: 14, color: c.muted),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          child,
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!, style: TextStyle(fontSize: 11.5, height: 1.35, color: c.muted)),
          ],
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

const _strategyInfo = <SplitStrategy, (String, String)>{
  SplitStrategy.auto: (
    'Riconosce la struttura del file',
    'Sceglie da solo la struttura del file: titoli, elenchi o checkbox.',
  ),
  SplitStrategy.headings: ('Un blocco per titolo', 'Un blocco per ogni titolo Markdown (## Titolo).'),
  SplitStrategy.numbered: ('Un blocco per voce numerata', 'Un blocco per ogni voce di un elenco numerato (1. 2. 3.).'),
  SplitStrategy.checkboxes: (
    'Un blocco per casella',
    'Un blocco per ogni casella (- [ ]); quelle spuntate sono già fatte.',
  ),
  SplitStrategy.bullets: ('Un blocco per voce', 'Un blocco per ogni voce di un elenco puntato (- voce).'),
  SplitStrategy.whole: ('Tutto in un blocco', 'Tutto il piano come un unico blocco: l\'agente decide come procedere.'),
};

class _Pair extends StatelessWidget {
  const _Pair(this.a, this.b);
  final Widget a, b;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: a),
      const SizedBox(width: 10),
      Expanded(child: b),
    ],
  );
}

class _NumberField extends StatefulWidget {
  // Stable identity by label: fields appearing above (e.g. reasoning level)
  // must not hand this field another field's state.
  _NumberField(this.label, this.unit, this.value, this.set, this.onChanged, {this.min = 0, this.enabled = true})
    : super(key: ValueKey('number-$label'));
  final String label, unit;
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
  String? _error;

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    // Follow external changes (e.g. per-project settings) unless mid-edit.
    if (_error == null && int.tryParse(_controller.text) != widget.value) {
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
        _error = 'Inserisci un numero';
      } else if (n < widget.min) {
        _error = 'Minimo ${widget.min}';
      } else {
        _error = null;
        widget.set(n);
        widget.onChanged();
      }
    });
  }

  int get _increment => _fieldStep[widget.label] ?? 1;

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
        waitDuration: const Duration(milliseconds: 400),
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
        style: const TextStyle(fontSize: 13.5, fontFeatures: [FontFeature.tabularFigures()]),
        decoration: InputDecoration(
          errorText: _error,
          errorStyle: TextStyle(fontSize: 11, color: c.danger),
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.unit.isNotEmpty) ...[
                  Text(widget.unit, style: TextStyle(color: c.muted, fontSize: 12)),
                  const SizedBox(width: 4),
                ],
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [arrow(Icons.keyboard_arrow_up_rounded, 1), arrow(Icons.keyboard_arrow_down_rounded, -1)],
                ),
              ],
            ),
          ),
          suffixIconConstraints: const BoxConstraints(minHeight: 36),
        ),
        onChanged: _apply,
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.title, required this.subtitle, required this.value, required this.onChanged});
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text),
                  ),
                  Text(subtitle, style: TextStyle(fontSize: 11.5, color: c.muted)),
                ],
              ),
            ),
            Transform.scale(
              scale: 0.8,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ],
        ),
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
      title: 'Modello',
      subtitle: catalog.isEmpty
          ? 'Elenco non rilevato: resta disponibile il modello predefinito.'
          : '${catalog.models.length} modelli dal ${catalog.source}',
      selected: value,
      choices: [
        const Choice(
          value: '',
          label: 'Predefinito della CLI',
          description: 'Il modello configurato nella CLI.',
          dividerAfter: true,
        ),
        for (final m in catalog.models)
          Choice(
            value: m.id,
            label: m.label,
            tag: m.label.toLowerCase() == m.id ? '' : m.id,
            description: m.description,
          ),
        // A model set earlier by hand stays selectable until changed.
        if (value.isNotEmpty && catalog.find(value) == null) Choice(value: value, label: value, tag: 'personalizzato'),
      ],
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final m = catalog.find(value);
    final title = value.isEmpty ? 'Predefinito della CLI' : (m?.label ?? value);
    final subtitle = value.isEmpty
        ? (catalog.isEmpty ? 'Clicca per scegliere' : '${catalog.models.length} modelli disponibili')
        : (m?.description.isNotEmpty == true ? m!.description : (m == null ? 'Modello personalizzato' : value));
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
const _effortInfo = <String, (String, String)>{
  'minimal': ('Minimo', 'Quasi nessun ragionamento: il più veloce.'),
  'low': ('Basso', 'Risposte rapide, ragionamento leggero.'),
  'medium': ('Medio', 'Equilibrio tra velocità e profondità.'),
  'high': ('Alto', 'Più ragionamento per problemi complessi.'),
  'xhigh': ('Molto alto', 'Ragionamento esteso, più lento.'),
  'max': ('Massimo', 'Il ragionamento più approfondito.'),
  'ultra': ('Ultra', 'Il livello più alto disponibile: lento e costoso.'),
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
      title: 'Livello di ragionamento',
      subtitle: 'Più ragionamento: risultati migliori, ma più tempo e token.',
      selected: value,
      choices: [
        Choice(
          value: '',
          label: 'Predefinito',
          dividerAfter: true,
          tag: defaultLevel ?? '',
          description: defaultLevel == null
              ? 'Il livello configurato nella CLI.'
              : 'Il livello consigliato per questo modello: ${_effortName(defaultLevel!).toLowerCase()}.',
        ),
        for (final e in efforts) Choice(value: e, label: _effortName(e), tag: e, description: _effortInfo[e]?.$2 ?? ''),
      ],
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final title = value.isEmpty
        ? (defaultLevel == null ? 'Predefinito' : 'Predefinito · ${_effortName(defaultLevel!).toLowerCase()}')
        : _effortName(value);
    final subtitle = value.isEmpty ? '${efforts.length} livelli disponibili' : (_effortInfo[value]?.$2 ?? value);
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
