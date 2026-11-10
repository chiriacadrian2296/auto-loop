import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../engine/plan_parser.dart';
import '../engine/settings.dart';

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.locked,
    required this.workDir,
    required this.planPath,
    required this.versions,
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
  final VoidCallback onPickPlan, onPickWorkDir, onDetect, onChanged, onStrategyChanged;
  final VoidCallback? onReloadPlan;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final exe = s.executable;
    final version = versions[s.agent];
    return AbsorbPointer(
      absorbing: locked,
      child: Opacity(
        opacity: locked ? 0.6 : 1,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            const _Section('Piano'),
            _PathTile(
              icon: Icons.description_outlined,
              label: 'File del piano',
              value: planPath,
              onTap: onPickPlan,
              trailing: IconButton(
                tooltip: 'Ricarica il piano dal disco',
                onPressed: onReloadPlan,
                icon: const Icon(Icons.refresh),
              ),
            ),
            _PathTile(
              icon: Icons.folder_outlined,
              label: 'Cartella di lavoro',
              value: workDir,
              onTap: onPickWorkDir,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<SplitStrategy>(
              initialValue: s.strategy,
              decoration: const InputDecoration(labelText: 'Suddivisione in blocchi'),
              items: [
                for (final v in SplitStrategy.values) DropdownMenuItem(value: v, child: Text(v.label)),
              ],
              onChanged: (v) {
                s.strategy = v!;
                onStrategyChanged();
              },
            ),
            const _Section('Agente'),
            SegmentedButton<AgentKind>(
              segments: [
                for (final k in AgentKind.values) ButtonSegment(value: k, label: Text(k.label)),
              ],
              selected: {s.agent},
              onSelectionChanged: (v) {
                s.agent = v.first;
                onChanged();
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey('${s.agent}-$exe'),
              initialValue: exe,
              decoration: InputDecoration(
                labelText: 'Eseguibile ${s.agent.label}',
                helperText: version ?? (exe.isEmpty ? 'Non trovato' : 'Versione non rilevata'),
                helperStyle: TextStyle(color: version == null ? Theme.of(context).colorScheme.error : null),
                suffixIcon: IconButton(
                  tooltip: 'Rileva automaticamente',
                  onPressed: onDetect,
                  icon: const Icon(Icons.search),
                ),
              ),
              style: const TextStyle(fontSize: 12),
              onChanged: (v) {
                if (s.agent == AgentKind.codex) {
                  s.codexPath = v.trim();
                } else {
                  s.claudePath = v.trim();
                }
                onChanged();
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              initialValue: s.model,
              decoration: const InputDecoration(
                labelText: 'Modello (opzionale)',
                hintText: 'predefinito della CLI',
              ),
              onChanged: (v) {
                s.model = v;
                onChanged();
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<Autonomy>(
              initialValue: s.autonomy,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Permessi dell\'agente'),
              items: [
                for (final v in Autonomy.values) DropdownMenuItem(value: v, child: Text(v.label)),
              ],
              onChanged: (v) {
                s.autonomy = v!;
                onChanged();
              },
            ),
            if (s.autonomy == Autonomy.full)
              const _Hint(
                'L\'agente può eseguire qualsiasi comando senza chiedere. Usalo solo su progetti '
                'con backup o sotto git.',
                warning: true,
              )
            else
              _Hint(s.agent == AgentKind.codex
                  ? 'Codex lavora in una sandbox limitata alla cartella del progetto: può modificare '
                      'file ed eseguire comandi (test, build) al suo interno.'
                  : 'Claude modifica file ed esegue comandi (test, build); un classificatore approva '
                      'in automatico le azioni sicure e blocca quelle rischiose.'),
            const _Section('Richiamo'),
            _NumberRow(children: [
              _NumberField('Richiamo dopo (s)', s.relaunchDelaySeconds, (v) => s.relaunchDelaySeconds = v, onChanged),
              _NumberField('Tentativi per blocco', s.maxAttemptsPerBlock, (v) => s.maxAttemptsPerBlock = v, onChanged, min: 1),
            ]),
            _NumberRow(children: [
              _NumberField('Silenzio max (min)', s.idleTimeoutMinutes, (v) => s.idleTimeoutMinutes = v, onChanged, min: 1),
              _NumberField('Durata max (min)', s.runTimeoutMinutes, (v) => s.runTimeoutMinutes = v, onChanged, min: 1),
            ]),
            const _Hint('Se l\'agente resta muto oltre il limite o supera la durata massima viene '
                'terminato e richiamato sullo stesso blocco.'),
            const _Section('Quota e budget'),
            DropdownButtonFormField<QuotaBehavior>(
              initialValue: s.quotaBehavior,
              decoration: const InputDecoration(labelText: 'Quando la quota finisce'),
              items: [
                for (final v in QuotaBehavior.values) DropdownMenuItem(value: v, child: Text(v.label)),
              ],
              onChanged: (v) {
                s.quotaBehavior = v!;
                onChanged();
              },
            ),
            _NumberRow(children: [
              _NumberField('Riprova ogni (min)', s.quotaWaitMinutes, (v) => s.quotaWaitMinutes = v, onChanged,
                  min: 1, enabled: s.quotaBehavior == QuotaBehavior.wait),
              _NumberField('Budget token (0 = ∞)', s.maxTotalTokens, (v) => s.maxTotalTokens = v, onChanged),
            ]),
            const _Section('Fine blocco'),
            TextFormField(
              initialValue: s.verifyCommand,
              decoration: const InputDecoration(
                labelText: 'Comando di verifica (opzionale)',
                hintText: 'es. flutter test',
                helperText: 'Deve terminare con exit 0 perché il blocco sia completato.',
              ),
              onChanged: (v) {
                s.verifyCommand = v;
                onChanged();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Commit git a ogni blocco'),
              subtitle: const Text('Solo se la cartella è un repository'),
              value: s.gitCommit,
              onChanged: (v) {
                s.gitCommit = v;
                onChanged();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Salta i blocchi bloccati'),
              subtitle: const Text('Altrimenti il loop si mette in pausa'),
              value: s.skipBlocked,
              onChanged: (v) {
                s.skipBlocked = v;
                onChanged();
              },
            ),
            const _Section('Istruzioni aggiuntive'),
            TextFormField(
              initialValue: s.extraInstructions,
              minLines: 3,
              maxLines: 8,
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

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                )),
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.warning = false});
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: warning ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.outline,
                )),
      );
}

class _PathTile extends StatelessWidget {
  const _PathTile({required this.icon, required this.label, required this.value, required this.onTap, this.trailing});
  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(value == null ? label : p.basename(value!), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(value ?? 'Clicca per scegliere', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: trailing,
        onTap: onTap,
      );
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(child: children[i]),
            ],
          ],
        ),
      );
}

class _NumberField extends StatelessWidget {
  const _NumberField(this.label, this.value, this.set, this.onChanged, {this.min = 0, this.enabled = true});
  final String label;
  final int value;
  final void Function(int) set;
  final VoidCallback onChanged;
  final int min;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: '$value',
        enabled: enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n >= min) {
            set(n);
            onChanged();
          }
        },
      );
}
