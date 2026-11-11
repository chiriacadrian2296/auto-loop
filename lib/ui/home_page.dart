import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/accounts.dart';
import '../engine/cli_locator.dart';
import '../engine/loop_engine.dart';
import '../engine/loop_state.dart';
import '../engine/settings.dart';
import 'accounts_dialog.dart';
import 'app_theme.dart';
import 'choice_dialog.dart';
import 'blocks_panel.dart';
import 'log_panel.dart';
import 'logo.dart';
import 'notifications.dart';
import 'settings_panel.dart';
import 'window_controls.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.engine, required this.prefs, required this.themeMode});

  final LoopEngine engine;
  final SharedPreferences prefs;
  final ValueNotifier<ThemeMode> themeMode;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LoopEngine get engine => widget.engine;
  String? _workDir;
  String? _planPath;
  String? _loadError;
  final _versions = <AgentKind, String?>{};
  final _catalogs = <AgentKind, AgentCatalog>{};
  final _accounts = <AgentKind, AccountStatus?>{};
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _workDir = widget.prefs.getString('workDir');
    _planPath = widget.prefs.getString('planPath');
    engine.addListener(_onEngine);
    engine.onAttention = Notifier.show;
    HardwareKeyboard.instance.addHandler(_onKey);
    // Re-render once a second for countdowns and elapsed time.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (engine.isActive && mounted) setState(() {});
    });
    if (_workDir != null && _planPath != null) _reload();
    _detectClis();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    engine.removeListener(_onEngine);
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  Future<void> _detectClis({bool force = false}) async {
    final s = engine.settings;
    for (final kind in AgentKind.values) {
      var path = kind == AgentKind.codex ? s.codexPath : s.claudePath;
      if (force || path.isEmpty || !File(path).existsSync()) {
        path = await locateCli(kind) ?? path;
        if (kind == AgentKind.codex) {
          s.codexPath = path;
        } else {
          s.claudePath = path;
        }
      }
      _versions[kind] = await cliVersion(path);
      _accounts[kind] = await accountStatus(kind, path, s.profileId);
      _catalogs[kind] = await discoverCatalog(kind, path, profileId: s.profileId);
      if (mounted) setState(() {});
    }
    _saveSettings();
  }

  Future<void> _openAccounts() async {
    final profile = engine.settings.profileId;
    await showAccountsDialog(context, settings: engine.settings, locked: engine.isActive, onChanged: _saveSettings);
    if (!mounted) return;
    if (profile != engine.settings.profileId) _accounts.clear();
    setState(() {});
    await _detectClis();
  }

  void _saveSettings() {
    widget.prefs.setString('settings', engine.settings.encode());
    // The work-related part is also remembered by the project itself.
    if (_projectDir != null) engine.settings.saveProject(_projectDir!);
    if (mounted) setState(() {});
  }

  /// Folder whose `.autoloop/settings.json` the current settings came from.
  String? _projectDir;

  /// Switches to the settings saved in [dir], if it has any.
  void _enterProject(String dir) {
    if (dir == _projectDir || engine.isActive) return;
    final profile = engine.settings.profileId;
    engine.settings.loadProject(dir);
    _projectDir = dir;
    widget.prefs.setString('settings', engine.settings.encode());
    if (profile != engine.settings.profileId) {
      _accounts.clear();
      _detectClis();
    }
  }

  void _reload() {
    if (_workDir != null) _enterProject(_workDir!);
    if (_workDir == null || _planPath == null) return;
    _loadError = engine.load(workDir: _workDir!, planPath: _planPath!);
    if (_loadError == null) _remember(_planPath!, _workDir!);
    setState(() {});
  }

  static const _planExtensions = ['md', 'markdown', 'txt'];
  static const _browse = '\u0000browse';

  /// Recently opened plans, each with the work folder it was used with.
  List<(String, String)> get _recent {
    try {
      final list = jsonDecode(widget.prefs.getString('recentPlans') ?? '[]') as List;
      return [
        for (final e in list.whereType<Map>())
          if (e['plan'] is String && e['dir'] is String) (e['plan'] as String, e['dir'] as String),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _remember(String plan, String dir) {
    final list = [(plan, dir), ..._recent.where((r) => !p.equals(r.$1, plan))].take(8);
    widget.prefs.setString(
      'recentPlans',
      jsonEncode([
        for (final r in list) {'plan': r.$1, 'dir': r.$2},
      ]),
    );
  }

  Future<void> _openPlan(String plan, {String? dir}) async {
    if (engine.isActive) {
      _toast('Ferma il loop prima di cambiare piano.');
      return;
    }
    _planPath = plan;
    _workDir = dir ?? _workDir ?? p.dirname(plan);
    await widget.prefs.setString('planPath', plan);
    await widget.prefs.setString('workDir', _workDir!);
    _remember(plan, _workDir!);
    _reload();
  }

  Future<void> _browsePlan() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Scegli il piano',
      type: FileType.custom,
      allowedExtensions: _planExtensions,
      initialDirectory: _planPath == null ? _workDir : p.dirname(_planPath!),
    );
    final path = file?.path;
    if (path != null) await _openPlan(path);
  }

  /// Recent plans first; the file browser is one click away.
  Future<void> _pickPlan() async {
    final recent = _recent.where((r) => File(r.$1).existsSync()).toList();
    if (recent.isEmpty) return _browsePlan();
    String short(String path) {
      final parts = p.split(path);
      return parts.length <= 3 ? path : '…${p.separator}${p.joinAll(parts.sublist(parts.length - 2))}';
    }

    final picked = await showChoiceDialog<String>(
      context: context,
      title: 'Piano',
      subtitle: 'Riapri un piano recente o scegline uno nuovo.',
      selected: '${recent.indexWhere((r) => _planPath != null && p.equals(r.$1, _planPath!))}',
      choices: [
        for (final (i, r) in recent.indexed)
          Choice(value: '$i', label: p.basename(r.$1), description: 'Cartella di lavoro: ${short(r.$2)}'),
        const Choice(
          value: _browse,
          label: 'Sfoglia…',
          description: 'Scegli un file .md o .txt dal computer.',
          accent: true,
        ),
      ],
    );
    if (picked == null) return;
    if (picked == _browse) return _browsePlan();
    final r = recent[int.parse(picked)];
    await _openPlan(r.$1, dir: Directory(r.$2).existsSync() ? r.$2 : null);
  }

  void _toast(String text) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  bool _dragging = false;

  Future<void> _onDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    for (final item in details.files) {
      final path = item.path;
      if (Directory(path).existsSync()) {
        if (engine.isActive) return _toast('Ferma il loop prima di cambiare cartella.');
        _workDir = path;
        await widget.prefs.setString('workDir', path);
        _reload();
        return _toast('Cartella di lavoro: ${p.basename(path)}');
      }
      final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      if (_planExtensions.contains(ext)) return _openPlan(path);
    }
    _toast('Trascina un file .md o .txt, oppure una cartella.');
  }

  Future<void> _pickWorkDir() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Cartella in cui l\'agente lavora',
      initialDirectory: _workDir,
    );
    if (dir == null) return;
    _workDir = dir;
    await widget.prefs.setString('workDir', dir);
    _reload();
  }

  void _openLogs() {
    LoopState.ensureDir(_workDir!);
    Process.run('explorer.exe', [LoopState.dirOf(_workDir!)]);
  }

  bool _confirming = false;

  /// "Ferma ora" kills the agent mid-work, so it asks first.
  Future<void> _confirmStop() async {
    if (_confirming || !engine.isActive) return;
    _confirming = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fermare l\'agente adesso?'),
        content: const Text(
          'L\'invocazione in corso viene interrotta. Il lavoro fatto finora resta su disco '
          'e riprende dal punto in cui era al prossimo avvio.\n\n'
          'Per fermarti senza interrompere, usa Pausa: aspetta la fine del passo.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.colors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ferma'),
          ),
        ],
      ),
    );
    _confirming = false;
    if (ok == true) await engine.stopNow();
  }

  /// Space starts, pauses or resumes; Shift+Space stops. Ignored while typing
  /// in a field or with a popup open.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.space) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null &&
        (focus.widget is EditableText || focus.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      if (engine.isActive) _confirmStop();
      return true;
    }
    if (engine.isActive) {
      if (!engine.pauseRequested) engine.requestPause();
    } else if (_blocker() == null && engine.phase != LoopPhase.finished) {
      engine.start();
    }
    return true;
  }

  /// The first thing that prevents a start, with the section it belongs to
  /// and what clicking the warning should do. Null when ready.
  (String, String, VoidCallback)? _blocker() {
    final s = engine.settings;
    if (_loadError != null) return ('Piano', _loadError!, _pickPlan);
    if (_planPath == null || engine.plan == null) return ('Piano', 'Scegli un file di piano', _pickPlan);
    if (_workDir == null || !Directory(_workDir!).existsSync()) {
      return ('Piano', 'Scegli la cartella di lavoro', _pickWorkDir);
    }
    final exe = s.executable;
    if (exe.isEmpty || !File(exe).existsSync()) {
      return ('Agente', '${s.agent.label}: CLI non trovata', _openAccounts);
    }
    final account = _accounts[s.agent];
    if (account != null && !account.loggedIn) {
      return ('Account', 'Accedi a ${s.agent.label}', _openAccounts);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final active = engine.isActive;
    final blocker = active ? null : _blocker();
    final dark = widget.themeMode.value == ThemeMode.dark;
    return Scaffold(
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: _onDrop,
        child: Stack(
          children: [
            Column(
              children: [
                _TopBar(
                  engine: engine,
                  dark: dark,
                  onToggleTheme: () => widget.themeMode.value = dark ? ThemeMode.light : ThemeMode.dark,
                  onAccounts: _openAccounts,
                  onOpenLogs: _workDir == null ? null : _openLogs,
                  onStart: blocker != null || active || engine.phase == LoopPhase.finished ? null : engine.start,
                  blocker: blocker == null ? null : (blocker.$2, blocker.$3),
                  onPause: active && !engine.pauseRequested ? engine.requestPause : null,
                  onStop: active && engine.phase != LoopPhase.stopping ? _confirmStop : null,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 330,
                          child: Panel(
                            child: SettingsPanel(
                              settings: engine.settings,
                              locked: active,
                              workDir: _workDir,
                              planPath: _planPath,
                              versions: _versions,
                              catalogs: _catalogs,
                              accounts: _accounts,
                              onOpenAccounts: _openAccounts,
                              issues: {?blocker?.$1},
                              projectDir: _projectDir,
                              onPickPlan: _pickPlan,
                              onPickWorkDir: _pickWorkDir,
                              onReloadPlan: _planPath == null || active ? null : _reload,
                              onDetect: () => _detectClis(force: true),
                              onChanged: _saveSettings,
                              onStrategyChanged: () {
                                _saveSettings();
                                _reload();
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 360,
                          child: Panel(
                            child: _loadError != null
                                ? _EmptyState(
                                    icon: Icons.error_outline_rounded,
                                    title: 'Piano non caricato',
                                    text: _loadError!,
                                  )
                                : engine.plan == null
                                ? _EmptyState(
                                    icon: Icons.description_outlined,
                                    title: 'Nessun piano',
                                    text:
                                        'Scegli un file .md o .txt: verrà diviso in blocchi '
                                        'che l\'agente svolge uno alla volta.',
                                    action: FilledButton.icon(
                                      onPressed: _pickPlan,
                                      icon: const Icon(Icons.upload_file_rounded, size: 18),
                                      label: const Text('Scegli piano'),
                                    ),
                                  )
                                : BlocksPanel(engine: engine, planName: p.basename(_planPath!)),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Panel(
                            child: LogPanel(
                              engine: engine,
                              onOpenLogs: _workDir == null
                                  ? null
                                  : () {
                                      LoopState.ensureDir(_workDir!);
                                      Process.run('explorer.exe', [LoopState.dirOf(_workDir!)]);
                                    },
                              onOpenProgress:
                                  _workDir == null || !File(LoopState.progressFileOf(_workDir!)).existsSync()
                                  ? null
                                  : () => Process.run('cmd.exe', [
                                      '/c',
                                      'start',
                                      '',
                                      LoopState.progressFileOf(_workDir!),
                                    ]),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (_dragging) const Positioned.fill(child: _DropOverlay()),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.engine,
    required this.dark,
    required this.onToggleTheme,
    required this.onAccounts,
    this.onOpenLogs,
    this.blocker,
    this.onStart,
    this.onPause,
    this.onStop,
  });

  final LoopEngine engine;
  final bool dark;
  final VoidCallback onToggleTheme, onAccounts;
  final VoidCallback? onOpenLogs;

  /// Why the start button is disabled, and how to fix it.
  final (String, VoidCallback)? blocker;
  final VoidCallback? onStart, onPause, onStop;

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '${h}h ${m}m' : (m > 0 ? '${m}m ${s.toString().padLeft(2, '0')}s' : '${s}s');
  }

  static String _compact(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)}M'
      : n >= 1000
      ? '${(n / 1000).toStringAsFixed(1)}k'
      : '$n';

  /// What the bar says next to the status: the plan when idle, the block
  /// being worked on while running, the reason when it stopped on its own.
  (String, String?) _context() {
    final plan = engine.plan;
    if (plan == null) return ('Nessun piano', null);
    final name = p.basename(engine.planPath ?? '');
    final i = engine.currentBlock;
    switch (engine.phase) {
      case LoopPhase.running || LoopPhase.verifying || LoopPhase.stopping when i != null:
        final b = plan.blocks[i];
        return (
          'Blocco ${i + 1} di ${plan.blocks.length}',
          '${b.title} · invocazione ${engine.blockState(b).attempts}',
        );
      case LoopPhase.waiting:
        return ('Richiamo in attesa', name);
      case LoopPhase.quotaWait:
        return ('Quota esaurita', engine.statusMessage);
      case LoopPhase.paused when !const ['In pausa.', 'Fermato.', ''].contains(engine.statusMessage):
        return (name, engine.statusMessage);
      default:
        return (name, null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final plan = engine.plan;
    final state = engine.state;
    final width = MediaQuery.sizeOf(context).width;
    final active = engine.isActive;
    final paused = engine.phase == LoopPhase.paused;
    final (headline, detail) = _context();
    final total = plan?.blocks.length ?? 0;
    final progress = total == 0 ? 0.0 : engine.doneCount / total;

    // The native title bar is hidden: this bar is draggable and carries the
    // window buttons at its top-right corner.
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: WindowDragArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 14, 14),
                  child: Row(
                    children: [
                      const LogoMark(size: 30),
                      const SizedBox(width: 12),
                      Text(
                        'AutoLoop',
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: c.text),
                      ),
                      const SizedBox(width: 22),
                      _StatusPill(engine: engine, format: _fmt),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: headline,
                                style: TextStyle(fontWeight: FontWeight.w600, color: c.text),
                              ),
                              if (detail != null) TextSpan(text: '  ·  $detail'),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.muted, fontSize: 13),
                        ),
                      ),
                      // On narrower windows the stats give way instead of overflowing.
                      if (state != null && width >= (blocker == null ? 1150 : 1380)) ...[
                        _Stat(value: _compact(state.totalTokens), label: 'token'),
                        if (width >= (blocker == null ? 1260 : 1500))
                          _Stat(value: _fmt(engine.totalTime), label: 'tempo'),
                        const SizedBox(width: 6),
                      ],
                      _MoreMenu(
                        dark: dark,
                        onAccounts: onAccounts,
                        onToggleTheme: onToggleTheme,
                        onOpenLogs: onOpenLogs,
                      ),
                      const SizedBox(width: 8),
                      if (blocker case (final reason, final fix)) ...[
                        Flexible(
                          child: _BlockerChip(reason: reason, onTap: fix),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // Only the controls that make sense right now.
                      if (active) ...[
                        _RoundAction(
                          icon: Icons.pause_rounded,
                          tooltip: engine.pauseRequested
                              ? 'Pausa richiesta: si ferma alla fine del passo'
                              : 'Pausa alla fine del passo (Spazio)',
                          onPressed: onPause,
                        ),
                        const SizedBox(width: 8),
                        _RoundAction(
                          icon: Icons.stop_rounded,
                          tooltip: 'Ferma ora (Maiusc+Spazio)',
                          onPressed: onStop,
                          danger: true,
                        ),
                      ] else
                        _RoundAction(
                          icon: Icons.play_arrow_rounded,
                          tooltip: engine.phase == LoopPhase.finished
                              ? 'Piano completato'
                              : paused
                              ? 'Riprendi (Spazio)'
                              : 'Avvia (Spazio)',
                          onPressed: onStart,
                          primary: true,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const WindowButtons(),
          ],
        ),
        _ProgressLine(value: progress, working: active && engine.phase != LoopPhase.quotaWait),
      ],
    );
  }
}

/// Thin full-width plan progress under the bar; while the agent works, the
/// remaining part shimmers so activity is visible even at a glance.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.value, required this.working});
  final double value;
  final bool working;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 3,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (working)
            LinearProgressIndicator(color: c.primary.withValues(alpha: 0.35), backgroundColor: c.primarySoft)
          else
            ColoredBox(color: value > 0 ? c.primarySoft : Colors.transparent),
          TweenAnimationBuilder<double>(
            tween: Tween(end: value),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) =>
                LinearProgressIndicator(value: v, color: c.primary, backgroundColor: Colors.transparent),
          ),
        ],
      ),
    );
  }
}

/// Settings-like actions that are not about the loop itself.
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.dark, required this.onAccounts, required this.onToggleTheme, this.onOpenLogs});
  final bool dark;
  final VoidCallback onAccounts, onToggleTheme;
  final VoidCallback? onOpenLogs;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    PopupMenuItem<VoidCallback> item(IconData icon, String label, VoidCallback? action) => PopupMenuItem(
      value: action,
      enabled: action != null,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 18, color: action == null ? c.muted.withValues(alpha: 0.5) : c.muted),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(fontSize: 13.5, color: action == null ? c.muted : c.text)),
        ],
      ),
    );
    return PopupMenuButton<VoidCallback>(
      tooltip: 'Altro',
      position: PopupMenuPosition.under,
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      icon: Icon(Icons.more_horiz_rounded, color: c.muted),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        item(Icons.manage_accounts_outlined, 'Account e CLI', onAccounts),
        item(
          dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          dark ? 'Tema chiaro' : 'Tema scuro',
          onToggleTheme,
        ),
        item(Icons.folder_open_outlined, 'Apri la cartella dei log', onOpenLogs),
      ],
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.primarySoft.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.primary, width: 2),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.file_download_outlined, size: 44, color: c.primary),
              const SizedBox(height: 10),
              Text(
                'Rilascia per aprire',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.primary),
              ),
              const SizedBox(height: 4),
              Text(
                'Un file .md o .txt diventa il piano, una cartella diventa la cartella di lavoro.',
                style: TextStyle(fontSize: 13, color: c.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlockerChip extends StatelessWidget {
  const _BlockerChip({required this.reason, required this.onTap});
  final String reason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Avvia è disabilitato: clicca per risolvere',
      child: Material(
        color: c.danger.withValues(alpha: 0.1),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: c.danger),
                const SizedBox(width: 6),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      reason,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.danger),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.engine, required this.format});
  final LoopEngine engine;
  final String Function(Duration) format;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (engine.phase) {
      LoopPhase.running || LoopPhase.verifying || LoopPhase.waiting => c.primary,
      LoopPhase.quotaWait => c.warning,
      LoopPhase.finished => c.success,
      LoopPhase.paused || LoopPhase.stopping => c.danger,
      LoopPhase.idle => c.muted,
    };
    String? timer;
    if (engine.waitUntil != null) {
      final left = engine.waitUntil!.difference(DateTime.now());
      timer = format(left.isNegative ? Duration.zero : left);
    } else if (engine.runStartedAt != null) {
      timer = format(DateTime.now().difference(engine.runStartedAt!));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulseDot(color: color, pulsing: engine.phase == LoopPhase.running || engine.phase == LoopPhase.verifying),
          const SizedBox(width: 8),
          Text(
            engine.phase.label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
          ),
          if (timer != null) ...[
            const SizedBox(width: 6),
            Text(
              timer,
              style: TextStyle(
                color: color.withValues(alpha: 0.8),
                fontSize: 12.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color, required this.pulsing});
  final Color color;
  final bool pulsing;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _c.repeat();
  }

  @override
  void didUpdateWidget(_PulseDot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !_c.isAnimating) _c.repeat();
    if (!widget.pulsing && _c.isAnimating) _c.reset();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 14,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Stack(
        alignment: Alignment.center,
        children: [
          if (widget.pulsing)
            Container(
              width: 6 + 8 * _c.value,
              height: 6 + 8 * _c.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
              ),
            ),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
          ),
        ],
      ),
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value, label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: c.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.danger = false,
    this.primary = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool danger;

  /// Filled blue: the main action (start / resume).
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: primary ? c.primary : c.surface,
        foregroundColor: primary ? Colors.white : (danger ? c.danger : c.text),
        disabledBackgroundColor: primary ? c.border : c.surface,
        disabledForegroundColor: c.muted.withValues(alpha: 0.5),
        side: primary ? null : BorderSide(color: c.border),
        fixedSize: const Size(44, 44),
      ),
      icon: Icon(icon, size: primary ? 24 : 20),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.text, this.action});
  final IconData icon;
  final String title, text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(16)),
              child: Icon(icon, color: c.primary, size: 26),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.text),
            ),
            const SizedBox(height: 6),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, height: 1.45),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}
