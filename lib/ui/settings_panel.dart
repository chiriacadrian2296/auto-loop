import 'dart:io';

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
        'Dopo ${s.relaunchDelaySeconds} s · ${s.maxAttemptsPerBlock} tentativi · '
        'silenzio ${s.idleTimeoutMinutes} min · max ${s.runTimeoutMinutes} min';
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
    return AbsorbPointer(
      absorbing: locked,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: locked ? 0.55 : 1,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          children: [
            const _Section('Piano', first: true),
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
                  action: planPath == null
                      ? null
                      : _TinyIcon(icon: Icons.refresh_rounded, tooltip: 'Ricarica dal disco', onPressed: onReloadPlan),
                ),
                _PathCard(
                  caption: 'Cartella di lavoro',
                  inGroup: true,
                  icon: Icons.folder_outlined,
                  title: workDir == null ? 'Scegli la cartella' : p.basename(workDir!),
                  subtitle: workDir == null ? 'Dove l\'agente crea e modifica i file' : _shortPath(workDir!),
                  tooltip: workDir,
                  onTap: onPickWorkDir,
                  action: workDir == null
                      ? null
                      : _TinyIcon(
                          icon: Icons.open_in_new_rounded,
                          tooltip: 'Apri in Esplora file',
                          onPressed: () => Process.run('explorer.exe', [workDir!]),
                        ),
                ),
                _ChoiceCard<SplitStrategy>(
                  caption: 'Suddivisione in blocchi',
                  icon: Icons.view_agenda_outlined,
                  dialogTitle: 'Suddivisione in blocchi',
                  dialogSubtitle: 'Come dividere il piano: l\'agente svolge un blocco alla volta.',
                  value: s.strategy,
                  choices: [
                    for (final v in SplitStrategy.values)
                      Choice(value: v, label: v.label, description: _strategyInfo[v]!.$2, short: _strategyInfo[v]!.$1),
                  ],
                  onChanged: (v) {
                    s.strategy = v;
                    onStrategyChanged();
                  },
                ),
              ],
            ),
            const _Section('Agente'),
            Row(
              children: [
                for (final k in AgentKind.values) ...[
                  if (k != AgentKind.values.first) const SizedBox(width: 10),
                  Expanded(
                    child: _AgentOption(
                      kind: k,
                      selected: s.agent == k,
                      version: versions[k],
                      onTap: () {
                        s.agent = k;
                        onChanged();
                      },
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            _Group(
              children: [
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
                      description: 'Nessuna sandbox e nessuna conferma: può eseguire qualsiasi comando.',
                    ),
                  ],
                  onChanged: (v) {
                    s.autonomy = v;
                    onChanged();
                  },
                ),
              ],
            ),
            if (s.autonomy == Autonomy.full)
              const _Note('Accesso completo: usalo solo su progetti sotto git o con un backup.', warning: true),
            const _Section('Account'),
            _Group(
              children: [
                _PathCard(
                  caption: 'Profilo',
                  inGroup: true,
                  icon: s.profile.isDefault ? Icons.computer_rounded : Icons.badge_outlined,
                  title: s.profile.name,
                  subtitle: s.profile.isDefault
                      ? 'Accessi già presenti sul computer'
                      : 'Accessi separati, solo per AutoLoop',
                  trailing: Icons.unfold_more_rounded,
                  onTap: onOpenAccounts,
                ),
                _PathCard(
                  caption: 'Account ${s.agent.label}',
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
                  subtitle: version == null
                      ? 'Indica dove si trova la CLI'
                      : account == null
                      ? ''
                      : account.loggedIn
                      ? [
                          if (planLabel(account.plan).isNotEmpty) 'Piano ${planLabel(account.plan)}',
                          if (account.method != null) 'via ${account.method}',
                        ].join(' · ')
                      : 'Clicca per accedere',
                  onTap: onOpenAccounts,
                ),
              ],
            ),
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
                      'Tentativi',
                      'per blocco',
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
                    _NumberField('Budget token', '0 = ∞', s.maxTotalTokens, (v) => s.maxTotalTokens = v, onChanged),
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
                      key: const ValueKey('field-verify'),
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
                      key: const ValueKey('field-instructions'),
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
    );
  }
}

/// Last two segments of a path, enough to recognise it at a glance.
String _shortPath(String path) {
  final parts = p.split(path);
  if (parts.length <= 3) return path;
  return '…${p.separator}${p.joinAll(parts.sublist(parts.length - 2))}';
}

/// What the less obvious fields do, shown from the "i" next to their name.
const _fieldInfo = <String, String>{
  'Richiamo dopo': 'Pausa tra la fine di un\'invocazione dell\'agente e la successiva.',
  'Tentativi': 'Quante volte l\'agente viene richiamato sullo stesso blocco prima di segnarlo come bloccato.',
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
  const _Group({required this.children, this.indent = 54});
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

class _Note extends StatelessWidget {
  const _Note(this.text, {this.warning = false});
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      child: Text(text, style: TextStyle(fontSize: 11.5, height: 1.35, color: warning ? c.danger : c.muted)),
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
  const _Collapsible({required this.title, required this.summary, required this.child});
  final String title, summary;
  final Widget child;

  // Survives the list recycling sections that scroll out of view.
  static final _open = <String>{};

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool get _isOpen => _Collapsible._open.contains(widget.title);

  void _toggle() => setState(() {
    if (!_Collapsible._open.remove(widget.title)) _Collapsible._open.add(widget.title);
  });

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
                              color: c.text,
                            ),
                          ),
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
                                maxLines: 2,
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
              ? Padding(padding: const EdgeInsets.only(top: 8), child: widget.child)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// Centered section title between two hairlines.
class _Section extends StatelessWidget {
  const _Section(this.title, {this.first = false});
  final String title;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(top: first ? 2 : 22, bottom: 14),
      child: Row(
        children: [
          Expanded(child: Divider(color: c.border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 1.6, color: c.text),
            ),
          ),
          Expanded(child: Divider(color: c.border)),
        ],
      ),
    );
  }
}

class _AgentOption extends StatelessWidget {
  const _AgentOption({required this.kind, required this.selected, required this.version, required this.onTap});
  final AgentKind kind;
  final bool selected;
  final String? version;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final short = version == null ? null : RegExp(r'\d+\.\d+\.\d+').firstMatch(version!)?.group(0) ?? version;
    return Material(
      color: selected ? c.primarySoft : c.field,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? c.primary : Colors.transparent, width: 1.4),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            children: [
              AgentBadge(kind: kind, size: 34),
              const SizedBox(height: 8),
              Text(
                kind.label,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: selected ? c.primary : c.text),
              ),
              const SizedBox(height: 1),
              Text(
                short == null ? 'Non trovata' : 'v$short',
                style: TextStyle(fontSize: 11, color: short == null ? c.danger : c.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TinyIcon extends StatelessWidget {
  const _TinyIcon({required this.icon, required this.tooltip, this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    visualDensity: VisualDensity.compact,
    iconSize: 18,
    constraints: const BoxConstraints.tightFor(width: 30, height: 30),
    padding: EdgeInsets.zero,
    icon: Icon(icon),
  );
}

class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
    this.trailing = Icons.chevron_right_rounded,
    this.action,
    this.caption,
    this.inGroup = false,
    this.tooltip,
  });

  /// Full text shown on hover (e.g. the complete path).
  final String? tooltip;
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool highlighted;
  final IconData trailing;
  final Widget? action;

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
              ?action,
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

class _NumberField extends StatelessWidget {
  const _NumberField(this.label, this.unit, this.value, this.set, this.onChanged, {this.min = 0, this.enabled = true});
  final String label, unit;
  final int value;
  final void Function(int) set;
  final VoidCallback onChanged;
  final int min;
  final bool enabled;

  @override
  Widget build(BuildContext context) => _Field(
    label: label,
    child: TextFormField(
      // Stable identity: fields appearing above (e.g. reasoning level)
      // must not hand this field another field's text.
      key: ValueKey('number-$label'),
      initialValue: '$value',
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(fontSize: 13.5, fontFeatures: [FontFeature.tabularFigures()]),
      decoration: InputDecoration(
        suffixText: unit,
        suffixStyle: TextStyle(color: context.colors.muted, fontSize: 12),
      ),
      onChanged: (v) {
        final n = int.tryParse(v);
        if (n != null && n >= min) {
          set(n);
          onChanged();
        }
      },
    ),
  );
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

  static const _custom = '\u0000custom';

  Future<void> _pick(BuildContext context) async {
    final picked = await showChoiceDialog<String>(
      context: context,
      title: 'Modello',
      subtitle: catalog.isEmpty
          ? 'Elenco non rilevato: puoi usare il predefinito o scrivere un nome.'
          : '${catalog.models.length} modelli dal ${catalog.source}',
      selected: value,
      choices: [
        const Choice(value: '', label: 'Predefinito della CLI', description: 'Il modello configurato nella CLI.'),
        for (final m in catalog.models)
          Choice(
            value: m.id,
            label: m.label,
            tag: m.label.toLowerCase() == m.id ? '' : m.id,
            description: m.description,
          ),
        if (value.isNotEmpty && catalog.find(value) == null) Choice(value: value, label: value, tag: 'personalizzato'),
        const Choice(
          value: _custom,
          label: 'Altro modello…',
          description: 'Scrivi il nome completo di un modello.',
          accent: true,
        ),
      ],
    );
    if (picked == null || !context.mounted) return;
    if (picked == _custom) {
      await _askCustom(context);
    } else {
      onChanged(picked);
    }
  }

  Future<void> _askCustom(BuildContext context) async {
    final controller = TextEditingController(text: value);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modello personalizzato'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Nome completo del modello'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Usa')),
        ],
      ),
    );
    if (result != null) onChanged(result.trim());
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
