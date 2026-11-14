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
import 'section_title.dart';
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
    engine.onAttention = (title, body) {
      Notifier.show(title, body);
      // The plan's summary opens as a popup over the window.
      if (title == 'Piano completato' && mounted) showPlanCompleted(context, engine);
    };
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
    _planWatch?.cancel();
    _planDebounce?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  void _onEngine() {
    // A plan edited while the loop was running is picked up once it stops.
    if (_planChanged && !engine.isActive) {
      _planChanged = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _reload();
        engine.note('Piano ricaricato: il file era stato modificato durante l\'esecuzione.');
      });
    }
    if (mounted) setState(() {});
  }

  // ---- the plan file on disk

  StreamSubscription<FileSystemEvent>? _planWatch;
  String? _watchedPlan;
  Timer? _planDebounce;
  bool _planChanged = false;

  /// Reloads the plan when its file changes on disk (editors save in bursts,
  /// hence the short debounce). While running, the reload waits for the stop.
  void _watchPlan() {
    final plan = _planPath;
    if (plan == _watchedPlan) return;
    _planWatch?.cancel();
    _planWatch = null;
    _watchedPlan = plan;
    if (plan == null || !File(plan).existsSync()) return;
    try {
      _planWatch = File(plan).parent.watch().listen((event) {
        if (!p.equals(event.path, plan)) return;
        _planDebounce?.cancel();
        _planDebounce = Timer(const Duration(milliseconds: 600), () {
          if (!mounted || !File(plan).existsSync()) return;
          if (engine.isActive) {
            if (!_planChanged) engine.note('Il piano è stato modificato: verrà ricaricato quando il loop si ferma.');
            _planChanged = true;
          } else {
            _reload();
            engine.note('Piano ricaricato: il file è stato modificato.');
          }
        });
      });
    } catch (_) {
      // Watching is a convenience; the plan can always be reopened by hand.
    }
  }

  void _openPlanInEditor() {
    final plan = _planPath;
    if (plan != null) _openInEditor(plan);
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

  /// Puts the project's settings back to their starting values, after
  /// asking. The agent and its account stay as they are.
  Future<void> _resetDefaults() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ripristinare le impostazioni predefinite?'),
        content: Text(
          'Modello, ragionamento, permessi, richiamo, quota, verifica, commit, suddivisione e istruzioni '
          'tornano ai valori di partenza per questo progetto. Agente e account restano '
          '${engine.settings.agent.label} e il profilo scelto.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ripristina')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final s = engine.settings;
    final keep = (s.agent, s.profileId);
    final strategy = s.strategy;
    s.applyProject(LoopSettings().projectJson());
    s
      ..agent = keep.$1
      ..profileId = keep.$2;
    _saveSettings();
    if (s.strategy != strategy) _reload();
    setState(() {});
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
    _watchPlan();
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
      subtitle: 'Riapri un piano recente o scegline uno nuovo. Ogni progetto ritrova le sue impostazioni.',
      selected: '${recent.indexWhere((r) => _planPath != null && p.equals(r.$1, _planPath!))}',
      // Choosing a new file comes first, like the default choice of the other
      // popups; the recent plans follow.
      choices: [
        Choice(
          value: _browse,
          icon: Icons.folder_open_outlined,
          label: 'Sfoglia…',
          description: 'Scegli un file .md o .txt dal computer.',
          dividerAfter: recent.isNotEmpty,
        ),
        for (final (i, r) in recent.indexed)
          Choice(
            value: '$i',
            icon: Icons.description_outlined,
            label: p.basename(r.$1),
            description: 'Cartella di lavoro: ${short(r.$2)}',
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

  /// Opens a file with its default editor, like the plan.
  void _openInEditor(String path) => Process.run('cmd.exe', ['/c', 'start', '', path]);

  void _openLogs() {
    final file = engine.exportActivity();
    if (file != null) _openInEditor(file.path);
  }

  void _openProgress() {
    LoopState.ensureDir(_workDir!);
    final f = File(LoopState.progressFileOf(_workDir!));
    if (!f.existsSync()) {
      f.writeAsStringSync(
        '# Progresso AutoLoop\n\nL\'agente annota qui cosa ha fatto e cosa resta, tra un\'invocazione e l\'altra.\n',
      );
    }
    _openInEditor(f.path);
  }

  bool _confirming = false;

  /// "Mostra nel registro": (block index, request number), so repeating the
  /// same block still notifies.
  final _revealInLog = ValueNotifier<(int, int)?>(null);

  /// The line chosen in the activity panel or the strip at the bottom.
  final _selection = ActivitySelection();

  // The control panel no longer closes (the rail is kept for now).
  late bool _sidebarOpen = true;

  /// True once the opening animation has finished: the content appears only
  /// then, so it is never laid out wider than the space it has.
  late bool _sidebarShown = _sidebarOpen;

  void _setSidebar(bool open) {
    setState(() {
      _sidebarOpen = open;
      if (!open) _sidebarShown = false;
    });
    widget.prefs.setBool('sidebarOpen', open);
  }

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

  /// Everything a start needs, in order, and whether it is in place.
  List<(String, bool)> _requirements() {
    final s = engine.settings;
    final exe = s.executable;
    return [
      ('il file del piano', _planPath != null && engine.plan != null && _loadError == null),
      ('la cartella di lavoro', _workDir != null && Directory(_workDir!).existsSync()),
      ('la CLI di ${s.agent.label}', exe.isNotEmpty && File(exe).existsSync()),
      ('l\'accesso a ${s.agent.label}', _accounts[s.agent]?.loggedIn ?? false),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final active = engine.isActive;
    final blocker = active ? null : _blocker();
    return Scaffold(
      // A click anywhere drops the chosen line; a click on a line (or on
      // the map) then chooses it again.
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          _selection.clearForClick();
        },
        child: DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: _onDrop,
          child: Stack(
            children: [
              Column(
                children: [
                  _TopBar(themeMode: widget.themeMode.value, onThemeChanged: (m) => widget.themeMode.value = m),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // The control panel slides closed to a thin rail once set up.
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            width: _sidebarOpen ? 330 : 56,
                            onEnd: () => setState(() => _sidebarShown = _sidebarOpen),
                            child: Panel(
                              child: _sidebarOpen && _sidebarShown
                                  // Shown once the panel has reached full width.
                                  ? OverflowBox(
                                      alignment: Alignment.topLeft,
                                      minWidth: 330,
                                      maxWidth: 330,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          PanelHeader(
                                            'Pannello di controllo',
                                            titleActions: [SettingsPanel.expandAllButton()],
                                            actions: [
                                              IconButton(
                                                tooltip: 'Ripristina predefiniti',
                                                onPressed: active ? null : _resetDefaults,
                                                iconSize: 19,
                                                icon: const Icon(Icons.settings_backup_restore_rounded),
                                              ),
                                            ],
                                          ),
                                          Expanded(
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
                                              requirements: _requirements(),
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
                                        ],
                                      ),
                                    )
                                  : _SidebarRail(onOpen: () => _setSidebar(true)),
                            ),
                          ),
                          const SizedBox(width: 16),
                          SizedBox(
                            width: 360,
                            child: Panel(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  PanelHeader(
                                    'Avanzamento',
                                    titleActions: [if (engine.plan != null) BlocksPanel.expandAllButton()],
                                    actions: [
                                      IconButton(
                                        tooltip: 'Apri il piano nell\'editor',
                                        onPressed: _planPath == null ? null : _openPlanInEditor,
                                        iconSize: 19,
                                        icon: const Icon(Icons.edit_note_rounded),
                                      ),
                                    ],
                                  ),
                                  Expanded(
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
                                        : BlocksPanel(
                                            engine: engine,
                                            planName: p.basename(_planPath!),
                                            onShowInLog: (b) =>
                                                _revealInLog.value = (b.index, (_revealInLog.value?.$2 ?? 0) + 1),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Panel(
                              child: LogPanel(
                                engine: engine,
                                reveal: _revealInLog,
                                selection: _selection,
                                onOpenLogs: engine.plan == null ? null : _openLogs,
                                onOpenProgress: _workDir == null ? null : _openProgress,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _BottomBar(
                    engine: engine,
                    onStart: blocker != null || active || engine.phase == LoopPhase.finished ? null : engine.start,
                    blocker: blocker == null ? null : (blocker.$2, blocker.$3),
                    onPause: active && !engine.pauseRequested ? engine.requestPause : null,
                    onStop: active && engine.phase != LoopPhase.stopping ? _confirmStop : null,
                    selection: _selection,
                  ),
                ],
              ),
              if (_dragging) const Positioned.fill(child: _DropOverlay()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The window's title bar: the app's name, and the window buttons.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.themeMode, required this.onThemeChanged});
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: WindowDragArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 12, 16),
              child: Row(
                children: [
                  const LogoMark(size: 28),
                  const SizedBox(width: 10),
                  Text(
                    'AutoLoop',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: c.text),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
        // Window frame: the theme switch sits with the window buttons.
        WindowButtons(
          leading: [ThemeCaptionButton(mode: themeMode, onChanged: onThemeChanged)],
        ),
      ],
    );
  }
}

/// The bar under the panels: the main control lined up with the logo above,
/// what it does where the app's name is, then the plan's totals and the
/// whole activity as a strip of icons.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.engine, this.blocker, this.onStart, this.onPause, this.onStop, this.selection});

  final LoopEngine engine;

  /// The chosen line, shared with the activity panel.
  final ActivitySelection? selection;

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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = engine.state;
    final active = engine.isActive;
    final paused = engine.phase == LoopPhase.paused;
    final finished = engine.phase == LoopPhase.finished;

    final (IconData icon, String label, String tooltip, VoidCallback? action) = active
        ? (
            Icons.pause_rounded,
            engine.pauseRequested ? 'Pausa richiesta' : 'Pausa',
            engine.pauseRequested ? 'Si ferma alla fine del passo' : 'Pausa alla fine del passo (Spazio)',
            onPause,
          )
        : finished
        ? (Icons.check_rounded, 'Piano completato', 'Riepilogo del piano', () => showPlanCompleted(context, engine))
        : blocker != null
        // Cannot start yet: the tooltip says why, a click goes to fix it.
        ? (Icons.play_arrow_rounded, 'Avvia', 'Non si può avviare: ${blocker!.$1}. Clicca per risolvere.', blocker!.$2)
        : paused
        ? (Icons.play_arrow_rounded, 'Riprendi', 'Riprendi (Spazio)', onStart)
        : (Icons.play_arrow_rounded, 'Avvia', 'Avvia (Spazio)', onStart);

    final plan = engine.plan;
    final stats = state == null
        ? <IconStat>[]
        : [
            IconStat(Icons.schedule_rounded, _fmt(engine.totalTime), 'Tempo di lavoro', iconColor: c.text),
            IconStat(
              Icons.toll_outlined,
              _compact(state.totalTokens),
              'Token: ${_compact(state.inputTokens)} in / ${_compact(state.outputTokens)} out',
              iconColor: c.text,
            ),
            if (plan != null)
              IconStat(
                Icons.layers_outlined,
                '${engine.doneCount}/${plan.blocks.length}',
                'Blocchi completati',
                iconColor: c.text,
              ),
            IconStat(
              Icons.replay_rounded,
              '${state.runs}',
              state.runs == 1 ? '1 invocazione' : '${state.runs} invocazioni',
              iconColor: c.text,
            ),
            IconStat(
              Icons.commit_rounded,
              '${state.commits}',
              state.commits == 1 ? '1 commit' : '${state.commits} commit',
              iconColor: c.text,
            ),
          ];

    // Not a drag area: only the title bar moves the window.
    return KeyedSubtree(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: SizedBox(
          height: 56,
          // Three cards lined up with the panels above: the controls, the
          // totals, the map of the activity.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 330,
                child: Panel(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _MainAction(
                        icon: icon,
                        label: label,
                        tooltip: tooltip,
                        onTap: action,
                        // Grey while it cannot start; green once the plan is done.
                        color: finished ? c.success : (blocker != null && !active ? c.border : null),
                      ),
                      if (active) ...[
                        const SizedBox(width: 24),
                        _MainAction(
                          icon: Icons.stop_rounded,
                          label: 'Ferma',
                          tooltip: 'Ferma ora (Maiusc+Spazio)',
                          onTap: onStop,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 360,
                child: Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final shown = fitStats(context, stats, box.maxWidth);
                      return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: shown);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: selection == null ? const SizedBox() : ActivityMap(engine: engine, selection: selection!),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A control of the bottom bar: a round button whose icon takes the colour
/// of the background, and its name, both clickable.
class _MainAction extends StatelessWidget {
  const _MainAction({required this.icon, required this.label, required this.tooltip, this.onTap, this.color});
  final IconData icon;
  final String label, tooltip;
  final VoidCallback? onTap;

  /// The disc's colour, when not the usual blue.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color ?? (onTap == null ? c.border : c.primary),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: c.background),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: onTap == null ? c.muted : c.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the closed control panel leaves behind: the same round button as
/// the close one, in the same place; the space below is empty.
class _SidebarRail extends StatelessWidget {
  const _SidebarRail({required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        SizedBox(
          height: 54,
          child: Center(
            child: IconButton(
              tooltip: 'Apri il pannello di controllo',
              onPressed: onOpen,
              iconSize: 20,
              icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
            ),
          ),
        ),
        Divider(height: 1, color: c.border),
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
