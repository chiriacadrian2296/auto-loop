import 'package:flutter/material.dart';

import '../engine/agents.dart';
import '../engine/loop_engine.dart';

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
    final scheme = Theme.of(context).colorScheme;
    final entries = widget.engine.logs.where((e) => _showTools || e.kind != LogKind.tool).toList();
    if (_follow && entries.length != _lastCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    _lastCount = entries.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('Attività',
                    style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
              ),
              FilterChip(
                label: const Text('Comandi'),
                selected: _showTools,
                onSelected: (v) => setState(() => _showTools = v),
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('Segui'),
                selected: _follow,
                onSelected: (v) => setState(() => _follow = v),
              ),
              IconButton(
                tooltip: 'Apri PROGRESS.md',
                onPressed: widget.onOpenProgress,
                icon: const Icon(Icons.edit_note),
              ),
              IconButton(
                tooltip: 'Apri cartella dei log',
                onPressed: widget.onOpenLogs,
                icon: const Icon(Icons.folder_open),
              ),
              IconButton(
                tooltip: 'Pulisci',
                onPressed: widget.engine.clearLogs,
                icon: const Icon(Icons.clear_all),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: entries.isEmpty
                ? Center(child: Text('Nessuna attività', style: TextStyle(color: scheme.outline)))
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(10),
                      itemCount: entries.length,
                      itemBuilder: (context, i) => _LogLine(entries[i]),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine(this.entry);
  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (entry.kind) {
      LogKind.agent => scheme.onSurface,
      LogKind.tool => scheme.outline,
      LogKind.system => scheme.outline,
      LogKind.info => scheme.primary,
      LogKind.success => dark ? Colors.greenAccent : Colors.green.shade800,
      LogKind.warning => dark ? Colors.orangeAccent : Colors.orange.shade900,
      LogKind.error => scheme.error,
    };
    final time = '${entry.at.hour.toString().padLeft(2, '0')}:'
        '${entry.at.minute.toString().padLeft(2, '0')}:'
        '${entry.at.second.toString().padLeft(2, '0')}';
    final bold = entry.kind == LogKind.info || entry.kind == LogKind.success;
    return Padding(
      padding: EdgeInsets.only(top: entry.kind == LogKind.info ? 8 : 1, bottom: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$time  ', style: TextStyle(fontFamily: 'Consolas', fontSize: 12, color: scheme.outline)),
          Expanded(
            child: Text(
              entry.text,
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 12.5,
                height: 1.35,
                color: color,
                fontWeight: bold ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
