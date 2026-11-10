import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/cli_locator.dart';
import '../engine/loop_engine.dart';
import '../engine/loop_state.dart';
import '../engine/settings.dart';
import 'blocks_panel.dart';
import 'log_panel.dart';
import 'settings_panel.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.engine, required this.prefs});

  final LoopEngine engine;
  final SharedPreferences prefs;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LoopEngine get engine => widget.engine;
  String? _workDir;
  String? _planPath;
  String? _loadError;
  final _versions = <AgentKind, String?>{};
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _workDir = widget.prefs.getString('workDir');
    _planPath = widget.prefs.getString('planPath');
    engine.addListener(_onEngine);
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
    }
    _saveSettings();
  }

  void _saveSettings() {
    widget.prefs.setString('settings', engine.settings.encode());
    if (mounted) setState(() {});
  }

  void _reload() {
    if (_workDir == null || _planPath == null) return;
    _loadError = engine.load(workDir: _workDir!, planPath: _planPath!);
    setState(() {});
  }

  Future<void> _pickPlan() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Scegli il piano',
      type: FileType.custom,
      allowedExtensions: const ['md', 'markdown', 'txt'],
      initialDirectory: _planPath == null ? _workDir : p.dirname(_planPath!),
    );
    final path = file?.path;
    if (path == null) return;
    _planPath = path;
    _workDir ??= p.dirname(path);
    await widget.prefs.setString('planPath', path);
    await widget.prefs.setString('workDir', _workDir!);
    _reload();
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

  void _openInExplorer(String path) {
    Process.run('explorer.exe', [path]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = engine.isActive;
    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            engine: engine,
            onStart: engine.plan == null || active ? null : engine.start,
            onPause: active && !engine.pauseRequested ? engine.requestPause : null,
            onStop: active ? engine.stopNow : null,
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 340,
                  child: SettingsPanel(
                    settings: engine.settings,
                    locked: active,
                    workDir: _workDir,
                    planPath: _planPath,
                    versions: _versions,
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
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                SizedBox(
                  width: 380,
                  child: _loadError != null
                      ? _Message(icon: Icons.error_outline, text: _loadError!)
                      : engine.plan == null
                          ? const _Message(
                              icon: Icons.description_outlined,
                              text: 'Scegli un file di piano (.md o .txt).\n'
                                  'Verrà diviso in blocchi che l\'agente svolge uno alla volta.',
                            )
                          : BlocksPanel(engine: engine),
                ),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                Expanded(
                  child: LogPanel(
                    engine: engine,
                    onOpenLogs: _workDir == null
                        ? null
                        : () {
                            LoopState.ensureDir(_workDir!);
                            _openInExplorer(LoopState.dirOf(_workDir!));
                          },
                    onOpenProgress: _workDir == null ||
                            !File(LoopState.progressFileOf(_workDir!)).existsSync()
                        ? null
                        : () => Process.run('cmd.exe',
                            ['/c', 'start', '', LoopState.progressFileOf(_workDir!)]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.engine, this.onStart, this.onPause, this.onStop});

  final LoopEngine engine;
  final VoidCallback? onStart, onPause, onStop;

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '${h}h ${m}m' : (m > 0 ? '${m}m ${s.toString().padLeft(2, '0')}s' : '${s}s');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final plan = engine.plan;
    final state = engine.state;
    String? timer;
    if (engine.waitUntil != null) {
      final left = engine.waitUntil!.difference(DateTime.now());
      timer = 'tra ${_fmt(left.isNegative ? Duration.zero : left)}';
    } else if (engine.runStartedAt != null) {
      timer = 'da ${_fmt(DateTime.now().difference(engine.runStartedAt!))}';
    }
    final (color, icon) = switch (engine.phase) {
      LoopPhase.running || LoopPhase.verifying => (scheme.primary, Icons.autorenew),
      LoopPhase.waiting => (scheme.tertiary, Icons.hourglass_bottom),
      LoopPhase.quotaWait => (Colors.orange, Icons.battery_alert),
      LoopPhase.finished => (Colors.green, Icons.check_circle),
      LoopPhase.paused || LoopPhase.stopping => (scheme.error, Icons.pause_circle),
      LoopPhase.idle => (scheme.outline, Icons.radio_button_unchecked),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Icon(Icons.all_inclusive, color: scheme.primary, size: 28),
          const SizedBox(width: 10),
          Text('AutoLoop', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 24),
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  engine.phase.label + (timer == null ? '' : ' · $timer'),
                  style: t.titleSmall?.copyWith(color: color),
                ),
                Text(engine.statusMessage,
                    style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (plan != null && state != null) ...[
            _Stat('Blocchi', '${engine.doneCount}/${plan.blocks.length}'),
            _Stat('Invocazioni', '${state.runs}'),
            _Stat('Token', _compact(state.totalTokens)),
            const SizedBox(width: 12),
          ],
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.play_arrow),
            label: Text(engine.phase == LoopPhase.paused ? 'Riprendi' : 'Avvia'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onPause,
            icon: const Icon(Icons.pause),
            label: const Text('Pausa'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onStop,
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            icon: const Icon(Icons.stop),
            label: const Text('Ferma ora'),
          ),
        ],
      ),
    );
  }

  static String _compact(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)}M'
      : n >= 1000
          ? '${(n / 1000).toStringAsFixed(1)}k'
          : '$n';
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          Text(label, style: t.labelSmall),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}
