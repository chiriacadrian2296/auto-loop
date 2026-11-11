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
    return AbsorbPointer(
      absorbing: locked,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: locked ? 0.55 : 1,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          children: [
            const _Section('Piano', first: true),
            _Field(
              label: 'File del piano',
              child: _PathCard(
                icon: Icons.description_outlined,
                title: planPath == null ? 'Scegli il file del piano' : p.basename(planPath!),
                subtitle: planPath == null ? '.md o .txt' : p.dirname(planPath!),
                highlighted: planPath == null,
                onTap: onPickPlan,
                action: planPath == null
                    ? null
                    : _TinyIcon(icon: Icons.refresh_rounded, tooltip: 'Ricarica dal disco', onPressed: onReloadPlan),
              ),
            ),
            _Field(
              label: 'Cartella di lavoro',
              child: _PathCard(
                icon: Icons.folder_outlined,
                title: workDir == null ? 'Scegli la cartella' : p.basename(workDir!),
                subtitle: workDir ?? 'Dove l\'agente crea e modifica i file',
                onTap: onPickWorkDir,
              ),
            ),
            _Field(
              label: 'Suddivisione in blocchi',
              child: _ChoiceCard<SplitStrategy>(
                icon: Icons.view_agenda_outlined,
                dialogTitle: 'Suddivisione in blocchi',
                dialogSubtitle: 'Come dividere il piano: l\'agente svolge un blocco alla volta.',
                value: s.strategy,
                choices: [
                  for (final v in SplitStrategy.values)
                    Choice(value: v, label: v.label, description: _strategyInfo[v]!),
                ],
                onChanged: (v) {
                  s.strategy = v;
                  onStrategyChanged();
                },
              ),
            ),
            const _Section('Agente'),
            _Field(
              label: 'Agente',
              child: Row(
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
            ),
            _Field(
              label: 'Modello',
              child: _ModelPicker(
                catalog: catalog,
                value: s.model,
                onChanged: (v) {
                  s.model = v;
                  // Keep the effort only if the new model supports it.
                  if (s.effort.isNotEmpty && !catalog.effortsFor(v).contains(s.effort)) s.effort = '';
                  onChanged();
                },
              ),
            ),
            if (efforts.isNotEmpty)
              _Field(
                label: 'Ragionamento',
                child: _EffortPicker(
                  efforts: efforts,
                  value: s.effort,
                  defaultLevel: selectedModel?.defaultEffort,
                  onChanged: (v) {
                    s.effort = v;
                    onChanged();
                  },
                ),
              ),
            _Field(
              label: 'Permessi',
              hint: s.autonomy == Autonomy.full ? 'Usala solo su progetti sotto git o con un backup.' : null,
              hintIsWarning: true,
              child: _ChoiceCard<Autonomy>(
                icon: s.autonomy == Autonomy.full ? Icons.lock_open_rounded : Icons.shield_outlined,
                dialogTitle: 'Permessi dell\'agente',
                dialogSubtitle: 'Quanta libertà ha ${s.agent.label} mentre lavora da solo.',
                value: s.autonomy,
                choices: [
                  Choice(
                    value: Autonomy.sandboxed,
                    label: 'Protetta',
                    description: s.agent == AgentKind.codex
                        ? 'Sandbox sulla cartella del progetto: modifica file ed esegue comandi al suo interno.'
                        : 'Le azioni sicure (modifiche, build, test) sono approvate in automatico, quelle rischiose bloccate.',
                  ),
                  const Choice(
                    value: Autonomy.full,
                    label: 'Accesso completo',
                    description: 'Nessuna sandbox e nessuna conferma: può eseguire qualsiasi comando.',
                  ),
                ],
                onChanged: (v) {
                  s.autonomy = v;
                  onChanged();
                },
              ),
            ),
            const _Section('Account'),
            _Field(
              label: 'Profilo',
              child: _PathCard(
                icon: s.profile.isDefault ? Icons.computer_rounded : Icons.badge_outlined,
                title: s.profile.name,
                subtitle: s.profile.isDefault
                    ? 'Gli accessi già presenti su questo computer'
                    : 'Accessi separati, solo per AutoLoop',
                trailing: Icons.unfold_more_rounded,
                onTap: onOpenAccounts,
              ),
            ),
            _Field(
              label: 'Account ${s.agent.label}',
              child: _PathCard(
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
            ),
            const _Section('Richiamo'),
            _Pair(
              _NumberField('Richiamo dopo', 's', s.relaunchDelaySeconds, (v) => s.relaunchDelaySeconds = v, onChanged),
              _NumberField('Tentativi', 'per blocco', s.maxAttemptsPerBlock, (v) => s.maxAttemptsPerBlock = v, onChanged, min: 1),
            ),
            _Pair(
              _NumberField('Silenzio max', 'min', s.idleTimeoutMinutes, (v) => s.idleTimeoutMinutes = v, onChanged, min: 1),
              _NumberField('Durata max', 'min', s.runTimeoutMinutes, (v) => s.runTimeoutMinutes = v, onChanged, min: 1),
            ),
            const _Section('Quota e budget'),
            _Field(
              label: 'Quando la quota finisce',
              child: _ChoiceCard<QuotaBehavior>(
                icon: s.quotaBehavior == QuotaBehavior.wait ? Icons.update_rounded : Icons.pause_circle_outline_rounded,
                dialogTitle: 'Quando la quota finisce',
                dialogSubtitle: 'Cosa fare quando la CLI segnala il limite di utilizzo.',
                value: s.quotaBehavior,
                choices: [
                  Choice(
                    value: QuotaBehavior.wait,
                    label: QuotaBehavior.wait.label,
                    description: 'Aspetta e riprova ogni ${s.quotaWaitMinutes} minuti, finché la quota non torna.',
                  ),
                  Choice(
                    value: QuotaBehavior.stop,
                    label: QuotaBehavior.stop.label,
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
              _NumberField('Riprova ogni', 'min', s.quotaWaitMinutes, (v) => s.quotaWaitMinutes = v, onChanged,
                  min: 1, enabled: s.quotaBehavior == QuotaBehavior.wait),
              _NumberField('Budget token', '0 = ∞', s.maxTotalTokens, (v) => s.maxTotalTokens = v, onChanged),
            ),
            const _Section('Fine blocco'),
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
            _Field(
              label: 'Opzioni',
              child: Column(
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
            ),
            const _Section('Istruzioni'),
            _Field(
              label: 'Regole per ogni blocco',
              hint: 'Aggiunte a ogni prompt, oltre al piano.',
              child: TextFormField(
                key: const ValueKey('field-instructions'),
                initialValue: s.extraInstructions,
                minLines: 3,
                maxLines: 8,
                style: const TextStyle(fontSize: 13, height: 1.4),
                decoration: const InputDecoration(
                  hintText: 'Stack, stile, cosa non toccare…',
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
              Text(kind.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: selected ? c.primary : c.text,
                  )),
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
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool highlighted;
  final IconData trailing;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: highlighted ? c.primarySoft : c.field,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
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
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: highlighted ? c.primary : c.text)),
                    const SizedBox(height: 1),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: c.muted)),
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
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child, this.hint, this.hintIsWarning = false});
  final String label;
  final Widget child;
  final String? hint;
  final bool hintIsWarning;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text)),
          const SizedBox(height: 6),
          child,
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!, style: TextStyle(fontSize: 11.5, height: 1.35, color: hintIsWarning ? c.danger : c.muted)),
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
  });
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
      title: current?.label ?? '$value',
      subtitle: current?.description ?? '',
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

const _strategyInfo = <SplitStrategy, String>{
  SplitStrategy.auto: 'Sceglie da solo la struttura del file: titoli, elenchi o checkbox.',
  SplitStrategy.headings: 'Un blocco per ogni titolo Markdown (## Titolo).',
  SplitStrategy.numbered: 'Un blocco per ogni voce di un elenco numerato (1. 2. 3.).',
  SplitStrategy.checkboxes: 'Un blocco per ogni casella (- [ ]); quelle spuntate sono già fatte.',
  SplitStrategy.bullets: 'Un blocco per ogni voce di un elenco puntato (- voce).',
  SplitStrategy.whole: 'Tutto il piano come un unico blocco: l\'agente decide come procedere.',
};

class _Pair extends StatelessWidget {
  const _Pair(this.a, this.b);
  final Widget a, b;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)],
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
      borderRadius: BorderRadius.circular(10),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text)),
                  Text(subtitle, style: TextStyle(fontSize: 11.5, color: c.muted)),
                ],
              ),
            ),
            Transform.scale(scale: 0.8, child: Switch(value: value, onChanged: onChanged)),
          ],
        ),
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.catalog, required this.value, required this.onChanged});
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
        if (value.isNotEmpty && catalog.find(value) == null)
          Choice(value: value, label: value, tag: 'personalizzato'),
        const Choice(value: _custom, label: 'Altro modello…', description: 'Scrivi il nome completo di un modello.', accent: true),
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
  const _EffortPicker({required this.efforts, required this.value, required this.onChanged, this.defaultLevel});
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
        for (final e in efforts)
          Choice(value: e, label: _effortName(e), tag: e, description: _effortInfo[e]?.$2 ?? ''),
      ],
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final title = value.isEmpty
        ? (defaultLevel == null ? 'Predefinito' : 'Predefinito · ${_effortName(defaultLevel!).toLowerCase()}')
        : _effortName(value);
    final subtitle = value.isEmpty
        ? '${efforts.length} livelli disponibili'
        : (_effortInfo[value]?.$2 ?? value);
    return _PathCard(
      icon: Icons.psychology_outlined,
      title: title,
      subtitle: subtitle,
      trailing: Icons.unfold_more_rounded,
      onTap: () => _pick(context),
    );
  }
}
