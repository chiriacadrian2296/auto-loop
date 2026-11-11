import 'package:flutter/material.dart';

import '../engine/agents.dart';
import '../engine/loop_engine.dart';
import 'app_theme.dart';

class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.engine, this.onOpenLogs, this.onOpenProgress});
  final LoopEngine engine;
  final VoidCallback? onOpenLogs, onOpenProgress;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();
  bool _follow = true;
  bool _showTools = true;
  int _lastCount = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entries = widget.engine.logs.where((e) => _showTools || e.kind != LogKind.tool).toList();
    if (_follow && entries.length != _lastCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });
    }
    _lastCount = entries.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          'Attività',
          actions: [
            _Toggle(label: 'Comandi', value: _showTools, onChanged: (v) => setState(() => _showTools = v)),
            const SizedBox(width: 6),
            _Toggle(label: 'Segui', value: _follow, onChanged: (v) => setState(() => _follow = v)),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Apri PROGRESS.md',
              onPressed: widget.onOpenProgress,
              iconSize: 19,
              icon: const Icon(Icons.sticky_note_2_outlined),
            ),
            IconButton(
              tooltip: 'Apri cartella dei log',
              onPressed: widget.onOpenLogs,
              iconSize: 19,
              icon: const Icon(Icons.folder_open_outlined),
            ),
            IconButton(
              tooltip: 'Pulisci',
              onPressed: widget.engine.logs.isEmpty ? null : widget.engine.clearLogs,
              iconSize: 19,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          ],
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.terminal_rounded, size: 28, color: c.muted.withValues(alpha: 0.5)),
                      const SizedBox(height: 8),
                      Text('L\'attività dell\'agente apparirà qui', style: TextStyle(color: c.muted)),
                    ],
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                    itemCount: entries.length,
                    itemBuilder: (context, i) => _LogLine(entries[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: value ? c.primarySoft : Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: value ? Colors.transparent : c.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: value ? c.primary : c.muted),
          ),
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine(this.entry);
  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final time =
        '${entry.at.hour.toString().padLeft(2, '0')}:'
        '${entry.at.minute.toString().padLeft(2, '0')}:'
        '${entry.at.second.toString().padLeft(2, '0')}';
    final timeText = Text(
      time,
      style: TextStyle(
        fontSize: 11,
        color: c.muted.withValues(alpha: 0.75),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    // Start of an invocation: a section header that separates the stream.
    if (entry.kind == LogKind.info && entry.text.startsWith('▶')) {
      return Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(99)),
              child: Text(
                entry.text.substring(1).trim(),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c.primary),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Divider(color: c.border)),
            const SizedBox(width: 10),
            timeText,
          ],
        ),
      );
    }

    final (IconData? icon, Color color, bool monoText) = switch (entry.kind) {
      LogKind.agent => (null, c.text, false),
      LogKind.tool => (Icons.chevron_right_rounded, c.muted, true),
      LogKind.system => (null, c.muted, false),
      LogKind.info => (Icons.info_outline_rounded, c.primary, false),
      LogKind.success => (Icons.check_circle_rounded, c.success, false),
      LogKind.warning => (Icons.warning_amber_rounded, c.warning, false),
      LogKind.error => (Icons.error_outline_rounded, c.danger, false),
    };

    final style = TextStyle(
      fontSize: monoText ? 12 : (entry.kind == LogKind.system ? 12 : 13.5),
      height: 1.5,
      color: color,
      fontFamily: monoText ? mono : null,
      fontFamilyFallback: monoText ? monoFallback : null,
      fontWeight: entry.kind == LogKind.success || entry.kind == LogKind.error ? FontWeight.w600 : null,
    );

    final agent = entry.kind == LogKind.agent;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: agent ? 5 : 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: icon == null
                ? (agent
                      ? Align(
                          alignment: Alignment.topLeft,
                          child: Container(
                            margin: const EdgeInsets.only(top: 4, left: 5),
                            width: 3,
                            height: 15,
                            decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.circular(2)),
                          ),
                        )
                      : null)
                : Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 15, color: color),
                  ),
          ),
          Expanded(child: Text(entry.text, style: style)),
          const SizedBox(width: 12),
          Padding(padding: const EdgeInsets.only(top: 3), child: timeText),
        ],
      ),
    );
  }
}
