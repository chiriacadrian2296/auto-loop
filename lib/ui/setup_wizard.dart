import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../engine/accounts.dart';
import '../engine/cli_install.dart';
import '../engine/cli_locator.dart';
import '../engine/settings.dart';
import 'agent_badge.dart';
import 'app_theme.dart';
import 'logo.dart';

/// What the setup needs from the main window.
class SetupHooks {
  const SetupHooks({
    required this.settings,
    required this.onSettingsChanged,
    required this.pickPlan,
    required this.pickWorkDir,
    required this.planPath,
    required this.workDir,
    this.probe,
  });

  final LoopSettings settings;
  final VoidCallback onSettingsChanged;
  final Future<void> Function() pickPlan;
  final Future<void> Function() pickWorkDir;
  final String? Function() planPath;
  final String? Function() workDir;

  /// Screenshots only: what the CLI checks find, without running anything
  /// (path, version, account).
  final (String?, String?, AccountStatus?) Function(AgentKind kind)? probe;
}

/// The first launch: choose the agent, find or install its CLI, sign in,
/// pick a plan. Every step can be skipped and done later from the panel.
Future<void> showSetupWizard(BuildContext context, SetupHooks hooks, {int step = 0}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => _SetupWizard(hooks: hooks, initialStep: step),
  );
}

class _SetupWizard extends StatefulWidget {
  const _SetupWizard({required this.hooks, required this.initialStep});
  final SetupHooks hooks;
  final int initialStep;

  @override
  State<_SetupWizard> createState() => _SetupWizardState();
}

/// What is known about one agent's CLI on this computer.
class _Cli {
  bool searching = true;
  String? path;
  String? version;
  bool checkingAccount = false;
  AccountStatus? account;
}

class _SetupWizardState extends State<_SetupWizard> {
  static const _steps = ['Benvenuto', 'Agente', 'CLI', 'Accesso', 'Progetto'];

  late int _step = widget.initialStep;
  final _cli = {for (final k in AgentKind.values) k: _Cli()};
  bool _busy = false;

  LoopSettings get _s => widget.hooks.settings;
  _Cli get _current => _cli[_s.agent]!;

  @override
  void initState() {
    super.initState();
    for (final k in AgentKind.values) {
      _find(k);
    }
  }

  /// Looks for the CLI (the saved path first), then its version and account.
  Future<void> _find(AgentKind kind, {bool fresh = false}) async {
    final cli = _cli[kind]!;
    setState(() => cli.searching = true);
    if (widget.hooks.probe case final probe?) {
      final (path, version, account) = probe(kind);
      setState(() {
        cli
          ..path = path
          ..version = version
          ..account = account
          ..searching = false;
      });
      return;
    }
    var path = kind == AgentKind.codex ? _s.codexPath : _s.claudePath;
    if (fresh || path.isEmpty || await cliVersion(path) == null) path = await locateCli(kind) ?? '';
    final version = path.isEmpty ? null : await cliVersion(path);
    if (!mounted) return;
    if (version != null) {
      if (kind == AgentKind.codex) {
        _s.codexPath = path;
      } else {
        _s.claudePath = path;
      }
      widget.hooks.onSettingsChanged();
    }
    setState(() {
      cli
        ..path = version == null ? null : path
        ..version = version
        ..searching = false;
    });
    if (version != null) await _checkAccount(kind);
  }

  Future<void> _checkAccount(AgentKind kind) async {
    final cli = _cli[kind]!;
    final path = cli.path;
    if (path == null || widget.hooks.probe != null) return;
    setState(() => cli.checkingAccount = true);
    final status = await accountStatus(kind, path, _s.profileId);
    if (!mounted) return;
    setState(() {
      cli
        ..account = status
        ..checkingAccount = false;
    });
  }

  Future<void> _install() async {
    final installer = CliInstaller.of(_s.agent);
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        title: Text('Installare ${installer.product}?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Si apre una finestra che esegue l\'installazione da ${installer.source}. '
                'Puoi seguirla e chiuderla quando ha finito.',
                style: TextStyle(color: c.text, height: 1.45),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(10)),
                child: SelectableText(
                  installer.command,
                  style: const TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 13),
                ),
              ),
              if (installer.note.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(installer.note, style: TextStyle(color: c.muted, fontSize: 13)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Installa')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await installer.run();
    if (!mounted) return;
    setState(() => _busy = false);
    await _find(_s.agent, fresh: true);
  }

  Future<void> _browseCli() async {
    final name = _s.agent == AgentKind.codex ? 'codex' : 'claude';
    final file = await FilePicker.pickFile(
      dialogTitle: 'Dov\'è $name.exe?',
      type: FileType.custom,
      allowedExtensions: const ['exe', 'cmd'],
    );
    final path = file?.path;
    if (path == null) return;
    if (_s.agent == AgentKind.codex) {
      _s.codexPath = path;
    } else {
      _s.claudePath = path;
    }
    widget.hooks.onSettingsChanged();
    await _find(_s.agent);
  }

  Future<void> _signIn() async {
    final path = _current.path;
    if (path == null) return;
    setState(() => _busy = true);
    await startLogin(_s.agent, path, _s.profileId);
    if (!mounted) return;
    setState(() => _busy = false);
    await _checkAccount(_s.agent);
  }

  void _finish() => Navigator.of(context).pop();

  // ------------------------------------------------------------ the frame

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final last = _step == _steps.length - 1;
    return Dialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: c.border),
      ),
      // One size for every step: the buttons stay where they are.
      child: SizedBox(
        width: 620,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 0),
              child: _StepRail(steps: _steps, current: _step),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 26, 28, 12),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: KeyedSubtree(key: ValueKey(_step), child: _body(context)),
                ),
              ),
            ),
            Divider(height: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              child: Row(
                children: [
                  if (!last)
                    TextButton(
                      onPressed: _busy ? null : _finish,
                      style: TextButton.styleFrom(foregroundColor: c.muted),
                      child: Text(_step == 0 ? 'Salta, faccio da solo' : 'Finisco dopo'),
                    ),
                  const Spacer(),
                  if (_step > 0) ...[
                    OutlinedButton(
                      onPressed: _busy ? null : () => setState(() => _step--),
                      style: OutlinedButton.styleFrom(
                        shape: const StadiumBorder(),
                        side: BorderSide(color: c.border),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      ),
                      child: const Text('Indietro'),
                    ),
                    const SizedBox(width: 10),
                  ],
                  FilledButton(
                    onPressed: _busy ? null : (last ? _finish : () => setState(() => _step++)),
                    child: Text(switch (_step) {
                      0 => 'Inizia',
                      _ when last => 'Fine',
                      _ => 'Avanti',
                    }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) => switch (_step) {
    0 => _welcome(context),
    1 => _agent(context),
    2 => _cliStep(context),
    3 => _login(context),
    _ => _project(context),
  };

  // ------------------------------------------------------------ the steps

  Widget _welcome(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LogoMark(size: 52, color: c.primary),
        const SizedBox(height: 18),
        _Title('Benvenuto in AutoLoop', 'Bastano pochi passi per preparare tutto.'),
        const SizedBox(height: 22),
        const _Point(
          Icons.description_outlined,
          'Scrivi il piano',
          'Un file Markdown o di testo: AutoLoop lo divide in blocchi da solo.',
        ),
        const _Point(
          Icons.bolt_rounded,
          'L\'agente lo porta a termine',
          'Codex o Claude lavorano un blocco alla volta, e vengono richiamati quando si fermano.',
        ),
        const _Point(
          Icons.verified_outlined,
          'Tu controlli il risultato',
          'Verifica e commit a ogni blocco, e la pausa quando vuoi controllare.',
        ),
      ],
    );
  }

  Widget _agent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Title('Quale agente usi?', 'Serve la sua CLI su questo computer. Puoi cambiarlo quando vuoi.'),
        const SizedBox(height: 20),
        for (final k in AgentKind.values) ...[
          _AgentCard(
            kind: k,
            selected: _s.agent == k,
            title: k == AgentKind.codex ? 'Codex' : 'Claude',
            subtitle: k == AgentKind.codex ? 'Codex CLI, di OpenAI' : 'Claude Code, di Anthropic',
            status: _statusText(_cli[k]!),
            ready: _cli[k]!.version != null,
            onTap: () {
              setState(() => _s.agent = k);
              widget.hooks.onSettingsChanged();
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  String _statusText(_Cli cli) {
    if (cli.searching) return 'Cerco la CLI…';
    if (cli.version == null) return 'Non installata';
    final who = cli.account?.loggedIn == true ? ' · ${cli.account?.email ?? 'connesso'}' : '';
    return 'Installata$who';
  }

  Widget _cliStep(BuildContext context) {
    final c = context.colors;
    final cli = _current;
    final installer = CliInstaller.of(_s.agent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Title(installer.product, 'AutoLoop la avvia a ogni invocazione, come faresti tu dal terminale.'),
        const SizedBox(height: 20),
        if (cli.searching || _busy)
          _StatusBox(
            icon: const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            title: _busy ? 'Installazione in corso…' : 'Cerco ${installer.product}…',
            body: _busy ? 'Segui la finestra che si è aperta, e chiudila quando ha finito.' : '',
          )
        else if (cli.version != null)
          _StatusBox(
            icon: Icon(Icons.check_circle_rounded, color: c.success, size: 22),
            title: 'Trovata: versione ${cli.version}',
            body: cli.path ?? '',
            monospace: true,
          )
        else ...[
          _StatusBox(
            icon: Icon(Icons.info_outline_rounded, color: c.warning, size: 22),
            title: 'Non trovo ${installer.product} su questo computer',
            body: 'Posso installarla io con il suo installer ufficiale, dopo averti mostrato cosa esegue.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _install,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text('Installa ${installer.product}'),
              ),
              _Ghost(Icons.refresh_rounded, 'Cerca di nuovo', () => _find(_s.agent, fresh: true)),
              _Ghost(Icons.folder_open_outlined, 'Indica il file…', _browseCli),
            ],
          ),
        ],
      ],
    );
  }

  Widget _login(BuildContext context) {
    final c = context.colors;
    final cli = _current;
    final name = CliInstaller.of(_s.agent).product;
    final account = cli.account;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Title('Accesso a $name', 'L\'agente lavora con il tuo account e la sua quota.'),
        const SizedBox(height: 20),
        if (cli.version == null)
          _StatusBox(
            icon: Icon(Icons.info_outline_rounded, color: c.warning, size: 22),
            title: 'Prima serve la CLI',
            body: 'Torna indietro per installarla o indicarla.',
          )
        else if (cli.checkingAccount || _busy)
          _StatusBox(
            icon: const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            title: _busy ? 'Accesso in corso…' : 'Controllo l\'accesso…',
            body: _busy ? 'Completa la procedura nella finestra e nel browser che si sono aperti.' : '',
          )
        else if (account?.loggedIn == true)
          _StatusBox(
            icon: Icon(Icons.check_circle_rounded, color: c.success, size: 22),
            title: account?.email ?? 'Accesso fatto',
            body: [if (account?.plan != null) 'Piano ${account!.plan}', 'Account: ${_s.profile.name}'].join(' · '),
          )
        else ...[
          _StatusBox(
            icon: Icon(Icons.login_rounded, color: c.primary, size: 22),
            title: 'Non hai ancora fatto l\'accesso',
            body:
                'L\'accesso si fa con la procedura ufficiale di $name: si apre una finestra e poi il browser. '
                'AutoLoop non vede né conserva la tua password.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _signIn,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('Accedi'),
              ),
              _Ghost(Icons.refresh_rounded, 'Controlla di nuovo', () => _checkAccount(_s.agent)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _project(BuildContext context) {
    final plan = widget.hooks.planPath();
    final dir = widget.hooks.workDir();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Title('Il primo piano', 'Scegli il file con il piano e la cartella in cui l\'agente lavora.'),
        const SizedBox(height: 20),
        _PickRow(
          icon: Icons.description_outlined,
          label: 'Piano',
          value: plan == null ? 'Nessun piano' : p.basename(plan),
          hint: 'Un file .md o .txt. I titoli, gli elenchi numerati o le caselle diventano i blocchi.',
          button: plan == null ? 'Scegli il piano' : 'Cambia',
          onTap: () async {
            await widget.hooks.pickPlan();
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 10),
        _PickRow(
          icon: Icons.folder_outlined,
          label: 'Cartella di lavoro',
          value: dir == null ? 'Quella del piano' : p.basename(dir),
          hint: 'Dove l\'agente crea e modifica i file. Meglio se è un repository git.',
          button: 'Cambia',
          onTap: () async {
            await widget.hooks.pickWorkDir();
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 14),
        Text(
          'Il resto (verifica, commit, quota) ha già valori pensati per partire: li trovi nel pannello di controllo.',
          style: TextStyle(color: context.colors.muted, fontSize: 13),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------ pieces

class _StepRail extends StatelessWidget {
  const _StepRail({required this.steps, required this.current});
  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        for (final (i, s) in steps.indexed) ...[
          if (i > 0) Expanded(child: Container(height: 2, color: i <= current ? c.primary : c.border)),
          Tooltip(
            message: s,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < current ? c.primary : (i == current ? c.primarySoft : c.field),
                border: Border.all(color: i <= current ? c.primary : c.border, width: 1.5),
              ),
              child: i < current
                  ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
                  : Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: i == current ? c.primary : c.muted,
                      ),
                    ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.title, this.subtitle);
  final String title, subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: c.text),
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: TextStyle(fontSize: 14.5, color: c.muted, height: 1.4)),
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point(this.icon, this.title, this.body);
  final IconData icon;
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 19, color: c.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: c.text),
                ),
                const SizedBox(height: 2),
                Text(body, style: TextStyle(fontSize: 13.5, color: c.muted, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({
    required this.kind,
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.ready,
    required this.onTap,
  });
  final AgentKind kind;
  final bool selected, ready;
  final String title, subtitle, status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.primarySoft : c.field,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? c.primary : c.border, width: selected ? 1.5 : 1),
      ),
      child: InkWell(
        customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              AgentBadge(kind: kind, size: 42, selected: selected),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 13, color: c.muted)),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    ready ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    size: 16,
                    color: ready ? c.success : c.muted,
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 190),
                    child: Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: ready ? c.text : c.muted),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({required this.icon, required this.title, required this.body, this.monospace = false});
  final Widget icon;
  final String title, body;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.field,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text),
                ),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: TextStyle(
                      fontSize: monospace ? 12.5 : 13.5,
                      color: c.muted,
                      height: 1.4,
                      fontFamily: monospace ? mono : null,
                      fontFamilyFallback: monospace ? monoFallback : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.hint,
    required this.button,
    required this.onTap,
  });
  final IconData icon;
  final String label, value, hint, button;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.field,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 19, color: c.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: c.muted),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: c.text),
                ),
                const SizedBox(height: 2),
                Text(hint, style: TextStyle(fontSize: 12.5, color: c.muted)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _Ghost(null, button, onTap),
        ],
      ),
    );
  }
}

class _Ghost extends StatelessWidget {
  const _Ghost(this.icon, this.label, this.onTap);
  final IconData? icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = OutlinedButton.styleFrom(
      shape: const StadiumBorder(),
      side: BorderSide(color: c.border),
      foregroundColor: c.text,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
    return icon == null
        ? OutlinedButton(onPressed: onTap, style: style, child: Text(label))
        : OutlinedButton.icon(onPressed: onTap, style: style, icon: Icon(icon, size: 18), label: Text(label));
  }
}
