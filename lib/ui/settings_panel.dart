import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../engine/cli_locator.dart';
import '../engine/plan_parser.dart';
import '../engine/settings.dart';
import 'app_theme.dart';

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.locked,
    required this.workDir,
    required this.planPath,
    required this.versions,
    required this.catalogs,
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
  final VoidCallback onPickPlan, onPickWorkDir, onDetect, onChanged, onStrategyChanged;
  final VoidCallback? onReloadPlan;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final c = context.colors;
    final exe = s.executable;
    final version = versions[s.agent];
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
            SectionLabel('Piano',
                trailing: _TinyIcon(icon: Icons.refresh_rounded, tooltip: 'Ricarica dal disco', onPressed: onReloadPlan)),
            const SizedBox(height: 10),
            _PathCard(
              icon: Icons.description_outlined,
              title: planPath == null ? 'Scegli il file del piano' : p.basename(planPath!),
              subtitle: planPath == null ? '.md o .txt' : p.dirname(planPath!),
              highlighted: planPath == null,
              onTap: onPickPlan,
            ),
            const SizedBox(height: 8),
            _PathCard(
              icon: Icons.folder_outlined,
              title: workDir == null ? 'Cartella di lavoro' : p.basename(workDir!),
              subtitle: workDir ?? 'Dove l\'agente crea e modifica i file',
              onTap: onPickWorkDir,
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'Suddivisione in blocchi',
              child: _Dropdown<SplitStrategy>(
                value: s.strategy,
                values: SplitStrategy.values,
                label: (v) => v.label,
                onChanged: (v) {
                  s.strategy = v;
                  onStrategyChanged();
                },
              ),
            ),
            const _Gap(),
            const SectionLabel('Agente'),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<AgentKind>(
                showSelectedIcon: false,
                segments: [
                  for (final k in AgentKind.values) ButtonSegment(value: k, label: Text(k.label)),
                ],
                selected: {s.agent},
                onSelectionChanged: (v) {
                  s.agent = v.first;
                  onChanged();
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(version != null ? Icons.check_circle_rounded : Icons.error_rounded,
                    size: 15, color: version != null ? c.success : c.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    version ?? (exe.isEmpty ? 'CLI non trovata' : 'Versione non rilevata'),
                    style: TextStyle(fontSize: 12.5, color: version != null ? c.muted : c.danger),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _TinyIcon(icon: Icons.manage_search_rounded, tooltip: 'Rileva automaticamente', onPressed: onDetect),
              ],
            ),
            const SizedBox(height: 6),
            _Field(
              label: 'Eseguibile',
              child: TextFormField(
                key: ValueKey('${s.agent}-$exe'),
                initialValue: exe,
                style: const TextStyle(fontSize: 12, fontFamily: mono, fontFamilyFallback: monoFallback),
                onChanged: (v) {
                  if (s.agent == AgentKind.codex) {
                    s.codexPath = v.trim();
                  } else {
                    s.claudePath = v.trim();
                  }
                  onChanged();
                },
              ),
            ),
            _Field(
              label: 'Modello',
              hint: selectedModel?.description.isNotEmpty == true
                  ? selectedModel!.description
                  : catalog.isEmpty
                      ? 'Elenco non disponibile: premi la lente per rilevarlo.'
                      : '${catalog.models.length} modelli dal ${catalog.source}.',
              child: _ModelPicker(
                key: ValueKey('model-${s.agent}-${s.model}-${catalog.models.length}'),
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
                  defaultLabel: selectedModel?.defaultEffort,
                  onChanged: (v) {
                    s.effort = v;
                    onChanged();
                  },
                ),
              ),
            _Field(
              label: 'Permessi',
              hint: s.autonomy == Autonomy.full
                  ? 'Nessuna sandbox né conferma. Solo su progetti sotto git o con backup.'
                  : s.agent == AgentKind.codex
                      ? 'Sandbox sulla cartella del progetto: modifica file ed esegue comandi al suo interno.'
                      : 'Le azioni sicure (modifiche, build, test) sono approvate in automatico, quelle rischiose bloccate.',
              hintIsWarning: s.autonomy == Autonomy.full,
              child: _Dropdown<Autonomy>(
                value: s.autonomy,
                values: Autonomy.values,
                label: (v) => v == Autonomy.full ? 'Accesso completo' : 'Protetta',
                onChanged: (v) {
                  s.autonomy = v;
                  onChanged();
                },
              ),
            ),
            const _Gap(),
            const SectionLabel('Richiamo'),
            const SizedBox(height: 10),
            _Pair(
              _NumberField('Richiamo dopo', 's', s.relaunchDelaySeconds, (v) => s.relaunchDelaySeconds = v, onChanged),
              _NumberField('Tentativi', 'per blocco', s.maxAttemptsPerBlock, (v) => s.maxAttemptsPerBlock = v, onChanged, min: 1),
            ),
            _Pair(
              _NumberField('Silenzio max', 'min', s.idleTimeoutMinutes, (v) => s.idleTimeoutMinutes = v, onChanged, min: 1),
              _NumberField('Durata max', 'min', s.runTimeoutMinutes, (v) => s.runTimeoutMinutes = v, onChanged, min: 1),
            ),
            const _Gap(),
            const SectionLabel('Quota e budget'),
            const SizedBox(height: 10),
            _Field(
              label: 'Quando la quota finisce',
              child: _Dropdown<QuotaBehavior>(
                value: s.quotaBehavior,
                values: QuotaBehavior.values,
                label: (v) => v.label,
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
            const _Gap(),
            const SectionLabel('Fine blocco'),
            const SizedBox(height: 10),
            _Field(
              label: 'Comando di verifica',
              hint: 'Deve terminare con exit 0 perché il blocco sia completato.',
              child: TextFormField(
                initialValue: s.verifyCommand,
                style: const TextStyle(fontSize: 13, fontFamily: mono, fontFamilyFallback: monoFallback),
                decoration: const InputDecoration(hintText: 'es. flutter test'),
                onChanged: (v) {
                  s.verifyCommand = v;
                  onChanged();
                },
              ),
            ),
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
            const _Gap(),
            const SectionLabel('Istruzioni aggiuntive'),
            const SizedBox(height: 10),
            TextFormField(
              initialValue: s.extraInstructions,
              minLines: 3,
              maxLines: 8,
              style: const TextStyle(fontSize: 13, height: 1.4),
              decoration: const InputDecoration(
                hintText: 'Regole valide per ogni blocco: stack, stile, cosa non toccare…',
              ),
              onChanged: (v) {
                s.extraInstructions = v;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Gap extends StatelessWidget {
  const _Gap();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Divider(),
      );
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
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool highlighted;

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
              Icon(Icons.chevron_right_rounded, size: 18, color: c.muted),
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

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.value, required this.values, required this.label, required this.onChanged});
  final T value;
  final List<T> values;
  final String Function(T) label;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        borderRadius: BorderRadius.circular(12),
        icon: const Icon(Icons.expand_more_rounded, size: 20),
        style: TextStyle(fontSize: 13.5, color: context.colors.text, fontFamily: uiFont, fontFamilyFallback: uiFallback),
        items: [for (final v in values) DropdownMenuItem(value: v, child: Text(label(v)))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
}

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
  const _ModelPicker({super.key, required this.catalog, required this.value, required this.onChanged});
  final AgentCatalog catalog;
  final String value;
  final ValueChanged<String> onChanged;

  static const _custom = '\u0000custom';

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
    final c = context.colors;
    final known = catalog.find(value) != null;
    final items = <String, (String, String)>{
      '': ('Predefinito della CLI', ''),
      for (final m in catalog.models) m.id: (m.label, m.label.toLowerCase() == m.id ? '' : m.id),
      if (value.isNotEmpty && !known) value: (value, 'personalizzato'),
      _custom: ('Altro modello…', ''),
    };
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      borderRadius: BorderRadius.circular(12),
      icon: const Icon(Icons.expand_more_rounded, size: 20),
      menuMaxHeight: 420,
      style: TextStyle(fontSize: 13.5, color: c.text, fontFamily: uiFont, fontFamilyFallback: uiFallback),
      selectedItemBuilder: (context) => [
        for (final e in items.entries)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(e.value.$1, overflow: TextOverflow.ellipsis),
          ),
      ],
      items: [
        for (final e in items.entries)
          DropdownMenuItem(
            value: e.key,
            child: Row(
              children: [
                Flexible(
                  child: Text(e.value.$1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: e.key == _custom ? c.primary : c.text,
                        fontWeight: e.key == _custom ? FontWeight.w600 : null,
                      )),
                ),
                if (e.value.$2.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(e.value.$2,
                      style: TextStyle(
                          fontSize: 11.5, color: c.muted, fontFamily: mono, fontFamilyFallback: monoFallback)),
                ],
              ],
            ),
          ),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (v == _custom) {
          _askCustom(context);
        } else {
          onChanged(v);
        }
      },
    );
  }
}

class _EffortPicker extends StatelessWidget {
  const _EffortPicker({required this.efforts, required this.value, required this.onChanged, this.defaultLabel});
  final List<String> efforts;
  final String value;
  final String? defaultLabel;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget pill(String id, String label) {
      final selected = value == id;
      return Material(
        color: selected ? c.primary : c.field,
        borderRadius: BorderRadius.circular(99),
        child: InkWell(
          borderRadius: BorderRadius.circular(99),
          onTap: () => onChanged(id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            child: Text(label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : c.muted,
                )),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        pill('', defaultLabel == null ? 'Predefinito' : 'Predefinito ($defaultLabel)'),
        for (final e in efforts) pill(e, e),
      ],
    );
  }
}
