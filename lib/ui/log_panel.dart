import 'package:flutter/material.dart';

import '../engine/agents.dart';
import '../engine/loop_engine.dart';
import 'app_theme.dart';
import 'markdown_text.dart';

enum _Filter {
  all('Tutto'),
  messages('Messaggi'),
  commands('Comandi'),
  problems('Problemi');

  const _Filter(this.label);
  final String label;

  bool accepts(LogEntry e) => switch (this) {
    _Filter.all => true,
    _Filter.messages => e.kind == LogKind.agent,
    _Filter.commands => e.kind == LogKind.tool,
    _Filter.problems => e.kind == LogKind.warning || e.kind == LogKind.error,
  };
}

enum _Outcome { done, error, warning, again, running, none }

/// One invocation of the agent: its header line and what followed it. The
/// lines before the first invocation form a group without header.
class _Group {
  _Group(this.header);
  final LogEntry? header;
  final entries = <LogEntry>[];

  DateTime? get start => header?.at ?? (entries.isEmpty ? null : entries.first.at);
  DateTime? get end => entries.isEmpty ? header?.at : entries.last.at;

  int get tokens {
    var total = 0;
    for (final e in entries) {
      if (e.kind != LogKind.system || !e.text.startsWith('Token:')) continue;
      for (final m in RegExp(r'(\d+) (?:in|out)').allMatches(e.text)) {
        total += int.parse(m.group(1)!);
      }
    }
    return total;
  }

  _Outcome outcome({required bool live}) {
    if (entries.any((e) => e.kind == LogKind.error)) return _Outcome.error;
    if (entries.any((e) => e.kind == LogKind.success && e.text.contains('completato'))) return _Outcome.done;
    if (live) return _Outcome.running;
    if (entries.any((e) => e.kind == LogKind.warning)) return _Outcome.warning;
    if (entries.any((e) => e.text.contains('continuare'))) return _Outcome.again;
    return _Outcome.none;
  }
}

List<_Group> _groupLogs(List<LogEntry> logs) {
  final groups = <_Group>[_Group(null)];
  for (final e in logs) {
    if (e.kind == LogKind.info && e.text.startsWith('▶')) {
      groups.add(_Group(e));
    } else {
      groups.last.entries.add(e);
    }
  }
  if (groups.first.entries.isEmpty) groups.removeAt(0);
  return groups;
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

String _span(Duration d) => d.inSeconds < 60 ? '${d.inSeconds} s' : '${d.inMinutes} min';

class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.engine, this.onOpenLogs, this.onOpenProgress});
  final LoopEngine engine;
  final VoidCallback? onOpenLogs, onOpenProgress;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();
  _Filter _filter = _Filter.all;

  /// Follow new lines while the view sits at the bottom; stop when the user
  /// scrolls up to read, and offer a way back.
  bool _atBottom = true;
  bool _unseen = false;
  int _lastCount = 0;

  /// Groups whose open/closed state the user changed (by header entry);
  /// the default is: only the latest invocation open.
  final _toggled = <LogEntry>{};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final bottom = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
      if (bottom != _atBottom || (bottom && _unseen)) {
        setState(() {
          _atBottom = bottom;
          if (bottom) _unseen = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom({bool animate = true}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (animate) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final engine = widget.engine;
    final logs = engine.logs;

    if (logs.length != _lastCount) {
      if (_atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
      } else if (logs.length > _lastCount) {
        _unseen = true;
      }
      _lastCount = logs.length;
    }

    final groups = _groupLogs(logs);
    final rows = <Widget>[];
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      final last = i == groups.length - 1;
      final visible = g.entries.where(_filter.accepts).toList();
      if (_filter != _Filter.all && visible.isEmpty) continue;
      final header = g.header;
      final open = header == null || (last != _toggled.contains(header));
      if (header != null) {
        rows.add(
          _GroupHeader(
            group: g,
            open: open,
            live: last && engine.isActive,
            onTap: () => setState(() => _toggled.contains(header) ? _toggled.remove(header) : _toggled.add(header)),
          ),
        );
      }
      if (open) rows.addAll(visible.map(_LogLine.new));
    }
    final silent = engine.phase == LoopPhase.running && engine.lastOutputAt != null
        ? DateTime.now().difference(engine.lastOutputAt!)
        : null;
    if (silent != null && silent.inSeconds >= 20 && _filter == _Filter.all) {
      rows.add(_WorkingLine(silent: silent, limitMinutes: engine.settings.idleTimeoutMinutes));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          'Attività',
          actions: [
            _FilterBar(value: _filter, onChanged: (f) => setState(() => _filter = f)),
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
              onPressed: logs.isEmpty ? null : engine.clearLogs,
              iconSize: 19,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          ],
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.terminal_rounded, size: 28, color: c.muted.withValues(alpha: 0.5)),
                      const SizedBox(height: 8),
                      Text(
                        logs.isEmpty ? 'L\'attività dell\'agente apparirà qui' : 'Nessuna riga per questo filtro',
                        style: TextStyle(color: c.muted),
                      ),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                        itemCount: rows.length,
                        itemBuilder: (context, i) => rows[i],
                      ),
                    ),
                    if (_unseen && !_atBottom)
                      Positioned(
                        bottom: 16,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: FilledButton.icon(
                            onPressed: () {
                              setState(() => _unseen = false);
                              _toBottom();
                            },
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            ),
                            icon: const Icon(Icons.arrow_downward_rounded, size: 17),
                            label: const Text('Nuove attività'),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// A compact pill showing the current filter; the choices open in a menu.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.value, required this.onChanged});
  final _Filter value;
  final ValueChanged<_Filter> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = value != _Filter.all;
    return PopupMenuButton<_Filter>(
      tooltip: 'Filtra le attività',
      position: PopupMenuPosition.under,
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final f in _Filter.values)
          PopupMenuItem(
            value: f,
            height: 38,
            child: Row(
              children: [
                SizedBox(width: 24, child: f == value ? Icon(Icons.check_rounded, size: 16, color: c.primary) : null),
                Text(f.label, style: TextStyle(fontSize: 13.5, color: f == value ? c.primary : c.text)),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        decoration: BoxDecoration(color: active ? c.primarySoft : c.field, borderRadius: BorderRadius.circular(99)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_list_rounded, size: 15, color: active ? c.primary : c.muted),
            const SizedBox(width: 6),
            Text(
              value.label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: active ? c.primary : c.muted),
            ),
            Icon(Icons.expand_more_rounded, size: 16, color: active ? c.primary : c.muted),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group, required this.open, required this.live, required this.onTap});
  final _Group group;
  final bool open, live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final raw = group.header!.text.substring(1).trim();
    // "Blocco 3/6 «Titolo» — invocazione 2" → pill, title and invocation.
    final m = RegExp(r'^(Blocco \d+/\d+) «(.*)» — invocazione (\d+)$').firstMatch(raw);
    final pill = m?.group(1) ?? raw;
    final title = m?.group(2);
    final invocation = m?.group(3);
    final start = group.start!;
    final duration = (live ? DateTime.now() : group.end!).difference(start);
    final tokens = group.tokens;
    final (Widget? badge, String? outcomeText) = switch (group.outcome(live: live)) {
      _Outcome.done => (Icon(Icons.check_circle_rounded, size: 15, color: c.success), 'completato'),
      _Outcome.error => (Icon(Icons.error_rounded, size: 15, color: c.danger), 'problema'),
      _Outcome.warning => (Icon(Icons.warning_amber_rounded, size: 15, color: c.warning), 'interrotto'),
      _Outcome.again => (Icon(Icons.replay_rounded, size: 15, color: c.muted), 'da continuare'),
      _Outcome.running => (
        SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2, color: c.primary)),
        'in corso',
      ),
      _Outcome.none => (null, null),
    };
    final summary = [
      if (invocation != null) 'invocazione $invocation',
      ?outcomeText,
      if (duration.inSeconds > 0) _span(duration),
      if (tokens > 0) '${tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : tokens} token',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: open ? 0 : -0.25,
                  duration: const Duration(milliseconds: 160),
                  child: Icon(Icons.expand_more_rounded, size: 18, color: c.muted),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(99)),
                  child: Text(
                    pill,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c.primary),
                  ),
                ),
                if (title != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.text),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                ?badge,
                if (badge != null) const SizedBox(width: 6),
                Text(summary, maxLines: 1, style: TextStyle(fontSize: 11.5, color: c.muted)),
                const Spacer(),
                const SizedBox(width: 10),
                Text(
                  _clock(start),
                  style: TextStyle(
                    fontSize: 11,
                    color: c.muted.withValues(alpha: 0.8),
                    fontFeatures: const [FontFeature.tabularFigures()],
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

/// Reassures that a quiet agent is still at work, and how long until the
/// supervisor would restart it.
class _WorkingLine extends StatelessWidget {
  const _WorkingLine({required this.silent, required this.limitMinutes});
  final Duration silent;
  final int limitMinutes;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.primary.withValues(alpha: 0.7)),
            ),
          ),
          Text(
            'Al lavoro · nessun output da ${_span(silent)} (limite $limitMinutes min)',
            style: TextStyle(fontSize: 12, color: c.muted, fontStyle: FontStyle.italic),
          ),
        ],
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
    // The time of each line is there on hover; the group header carries the
    // start time, so the stream itself stays quiet.
    return Tooltip(
      message: _clock(entry.at),
      waitDuration: const Duration(milliseconds: 700),
      child: Padding(
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
            Expanded(
              child: agent ? MarkdownText(entry.text, style: style) : Text(entry.text, style: style),
            ),
          ],
        ),
      ),
    );
  }
}
