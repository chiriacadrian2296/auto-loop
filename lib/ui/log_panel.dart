import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../engine/agents.dart';
import '../engine/loop_engine.dart';
import '../engine/loop_state.dart';
import '../engine/plan_parser.dart';
import '../engine/settings.dart';
import 'agent_badge.dart';
import 'app_theme.dart';
import 'markdown_text.dart';
import 'section_title.dart';

enum _Filter {
  all('Tutto', Icons.all_inclusive_rounded),
  messages('Messaggi', Icons.chat_bubble_outline_rounded),
  commands('Comandi', Icons.terminal_rounded),
  events('Eventi', Icons.flag_outlined);

  const _Filter(this.label, this.icon);
  final IconData icon;
  final String label;

  bool accepts(LogEntry e) => switch (this) {
    _Filter.all => true,
    _Filter.messages => e.kind == LogKind.agent,
    _Filter.commands => e.kind == LogKind.tool,
    // Everything AutoLoop itself reports: checks, commits, warnings, errors.
    _Filter.events => e.kind != LogKind.agent && e.kind != LogKind.tool,
  };
}

enum _Outcome { done, again, blocked, interrupted, failed, running, none }

/// One invocation of the agent: its header line and what followed it. The
/// lines before the first invocation form a group without header.
class _Group {
  _Group(this.header);
  final LogEntry? header;
  final entries = <LogEntry>[];

  DateTime? get start => header?.at ?? (entries.isEmpty ? null : entries.first.at);
  DateTime? get end => entries.isEmpty ? header?.at : entries.last.at;

  Duration duration({required bool live}) => (live ? DateTime.now() : end!).difference(start!);

  /// Tokens in, tokens out and cost, from the invocation's (hidden)
  /// "Token: X in / Y out · $c" line.
  (int, int, String?) get usage {
    var input = 0, output = 0;
    String? cost;
    for (final e in entries) {
      if (e.kind != LogKind.system || !e.text.startsWith('Token:')) continue;
      input += int.tryParse(RegExp(r'(\d+) in').firstMatch(e.text)?.group(1) ?? '') ?? 0;
      output += int.tryParse(RegExp(r'(\d+) out').firstMatch(e.text)?.group(1) ?? '') ?? 0;
      cost = RegExp(r'\$[\d.]+').firstMatch(e.text)?.group(0) ?? cost;
    }
    return (input, output, cost);
  }

  _Outcome outcome({required bool live}) {
    // Every invocation closes with a result line that says how it ended.
    final result = entries.where((e) => e.kind == LogKind.result && e.outcome != null).lastOrNull;
    if (result != null) {
      return switch (result.outcome!) {
        RunOutcome.done => _Outcome.done,
        RunOutcome.again => _Outcome.again,
        RunOutcome.blocked => _Outcome.blocked,
        RunOutcome.interrupted => _Outcome.interrupted,
        RunOutcome.failed => _Outcome.failed,
      };
    }
    if (live) return _Outcome.running;
    // Logs written before result lines existed.
    if (entries.any((e) => e.kind == LogKind.result || (e.kind == LogKind.success && e.text.contains('completato')))) {
      return _Outcome.done;
    }
    if (entries.any((e) => e.kind == LogKind.error)) return _Outcome.failed;
    if (entries.any((e) => e.kind == LogKind.warning)) return _Outcome.interrupted;
    if (entries.any((e) => e.text.contains('continuare'))) return _Outcome.again;
    return _Outcome.none;
  }

  /// "Blocco 3/6", the block title and the invocation number, from the header.
  (String, String?, String?) get parts {
    final raw = header!.text.substring(1).trim();
    final m = RegExp(r'^(Blocco \d+/\d+) «(.*)» — invocazione (\d+)$').firstMatch(raw);
    return m == null ? (raw, null, null) : (m.group(1)!, m.group(2), m.group(3));
  }
}

/// System lines (token counts, and in older logs the session start and the
/// CLI's echoed output) and the loop-start notice are not shown as lines.
bool _shown(LogEntry e) => e.kind != LogKind.system && !e.text.startsWith('Avvio del loop con');

/// Consecutive invocations of the same block, shown under one heading.
List<List<_Group>> _runs(List<_Group> groups) {
  final runs = <List<_Group>>[];
  String? previous;
  for (final g in groups) {
    final block = g.header == null ? null : g.parts.$1;
    if (runs.isEmpty || block == null || block != previous) {
      runs.add([g]);
    } else {
      runs.last.add(g);
    }
    previous = block;
  }
  return runs;
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

String _span(Duration d) => d.inSeconds < 60
    ? '${d.inSeconds} s'
    : d.inMinutes < 60
    ? '${d.inMinutes} min'
    : '${d.inHours} h ${d.inMinutes % 60} min';

class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.engine, this.onOpenLogs, this.onOpenProgress, this.reveal});
  final LoopEngine engine;
  final VoidCallback? onOpenLogs, onOpenProgress;

  /// Requests to show a block's invocations: (block index, request number).
  final ValueNotifier<(int, int)?>? reveal;

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

  /// Blocks whose open/closed state the user changed (by their first
  /// invocation's header); the default is: only the latest block open.
  final _toggledBlocks = <LogEntry>{};

  final _headerKeys = <LogEntry, GlobalKey>{};

  /// Header briefly highlighted after "Mostra nel registro".
  LogEntry? _flash;

  /// Where the header to reveal sits among the rows (for lazy lists).
  final _rowIndex = <LogEntry, int>{};
  int _rowCount = 0;

  bool _isHeaderOf(LogEntry h, int block) => h.text.contains('Blocco ${block + 1}/');

  void _onReveal() {
    final request = widget.reveal?.value;
    if (request == null) return;
    final block = request.$1;
    final headers = [
      for (final e in widget.engine.logs)
        if (e.kind == LogKind.info && e.text.startsWith('▶') && _isHeaderOf(e, block)) e,
    ];
    if (headers.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Nessuna attività registrata per questo blocco.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final mine = _runs(_groupLogs(widget.engine.logs))
        .where((r) => r.first.header != null && _isHeaderOf(r.first.header!, block))
        .map((r) => r.first.header!)
        .toSet();
    setState(() {
      // Everything is open unless closed: open this block wherever it appears.
      _toggledBlocks.removeAll(mine);
      _filter = _Filter.all;
      _atBottom = false;
      _unseen = false;
      _toggled.removeAll(headers);
      _flash = headers.first;
    });
    _scrollTo(headers.first);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted && identical(_flash, headers.first)) setState(() => _flash = null);
    });
  }

  /// Brings [header] into view; rows are built lazily, so jump close first.
  void _scrollTo(LogEntry header, [int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final ctx = _headerKeys[header]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.05, duration: const Duration(milliseconds: 250));
        return;
      }
      if (attempt > 4) return;
      final i = _rowIndex[header];
      if (i != null && _rowCount > 0) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent * (i / _rowCount));
      }
      _scrollTo(header, attempt + 1);
    });
  }

  @override
  void initState() {
    super.initState();
    widget.reveal?.addListener(_onReveal);
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
    widget.reveal?.removeListener(_onReveal);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Svuotare l\'attività?'),
        content: const Text(
          'Toglie le righe da questo pannello e cancella la loro copia salvata, quindi non '
          'ricompariranno alla riapertura.\n\n'
          'Restano: i log completi di ogni invocazione (.autoloop/logs), PROGRESS.md e '
          'l\'avanzamento dei blocchi.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Svuota')),
        ],
      ),
    );
    if (ok == true) widget.engine.clearLogs();
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
    final runs = _runs(groups);
    final heads = [for (final r in runs) ?r.first.header];
    final headers = [for (final g in groups) ?g.header];
    // Everything starts open; the sets hold what the user closed.
    final allOpen = _toggledBlocks.isEmpty && _toggled.isEmpty;
    void setAll(bool open) => setState(() {
      _toggledBlocks
        ..clear()
        ..addAll(open ? const <LogEntry>[] : heads);
      _toggled
        ..clear()
        ..addAll(open ? const <LogEntry>[] : headers);
    });
    final rows = <Widget>[];
    var previousOpen = false;
    for (var r = 0; r < runs.length; r++) {
      final run = runs[r];
      final lastRun = r == runs.length - 1;
      final shown = {for (final g in run) g: g.entries.where((e) => _shown(e) && _filter.accepts(e)).toList()};
      if (_filter != _Filter.all && shown.values.every((v) => v.isEmpty)) continue;
      final head = run.first.header;
      var blockOpen = true;
      if (head != null) {
        // The block is named once, with the totals of its invocations.
        blockOpen = !_toggledBlocks.contains(head);
        final (block, title, _) = run.first.parts;
        var input = 0, output = 0;
        var time = Duration.zero;
        for (final g in run) {
          final (i, o, _) = g.usage;
          input += i;
          output += o;
          time += g.duration(live: lastRun && identical(g, run.last) && engine.isActive);
        }
        _rowIndex[head] = rows.length;
        rows.add(
          _BlockHeading(
            key: _headerKeys.putIfAbsent(head, GlobalKey.new),
            number: RegExp(r'\d+').firstMatch(block)?.group(0),
            title: title ?? block,
            invocations: run.length,
            time: time,
            tokensIn: input,
            tokensOut: output,
            open: blockOpen,
            // Open blocks breathe; closed ones sit close together.
            gap: rows.isEmpty ? 0 : (previousOpen || blockOpen ? 22 : 4),
            start: run.first.start,
            highlighted: identical(head, _flash),
            // How the block ended here: as its latest invocation did.
            outcome: run.last.outcome(live: lastRun && engine.isActive),
            onTap: () =>
                setState(() => _toggledBlocks.contains(head) ? _toggledBlocks.remove(head) : _toggledBlocks.add(head)),
          ),
        );
      }
      previousOpen = blockOpen;
      if (!blockOpen) continue;
      // Invocations sit one step in from their block, like a tab.
      final indent = head == null ? 0.0 : _indent;
      Widget tab(Widget w) => indent == 0
          ? w
          : Padding(
              padding: EdgeInsets.only(left: indent),
              child: w,
            );
      for (final g in run) {
        final visible = shown[g]!;
        if (_filter != _Filter.all && visible.isEmpty) continue;
        final last = lastRun && identical(g, run.last);
        final header = g.header;
        final open = header == null || !_toggled.contains(header);
        if (header != null) {
          rows.add(
            tab(
              _InvocationHeader(
                group: g,
                open: open,
                live: last && engine.isActive,
                onTap: () => setState(() => _toggled.contains(header) ? _toggled.remove(header) : _toggled.add(header)),
              ),
            ),
          );
        }
        if (open) rows.addAll(visible.map((e) => tab(_LogLine(e, agent: engine.settings.agent))));
      }
    }
    _rowCount = rows.length;
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
            ExpandAllButton(allOpen: allOpen, onPressed: heads.isEmpty ? null : () => setAll(!allOpen)),
            IconButton(
              tooltip: 'Vedi progresso',
              onPressed: widget.onOpenProgress,
              iconSize: 19,
              icon: const Icon(Icons.sticky_note_2_outlined),
            ),
            IconButton(
              tooltip: 'Vedi log completi',
              onPressed: widget.onOpenLogs,
              iconSize: 19,
              icon: const Icon(Icons.receipt_long_outlined),
            ),
            IconButton(
              tooltip: 'Svuota attività',
              onPressed: logs.isEmpty ? null : _confirmClear,
              iconSize: 19,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          ],
        ),
        if (_focusBlock(engine, groups) case final block?) _BlockProgress(engine: engine, block: block),
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
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
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
  const _FilterBar({required this.value, required this.onChanged, this.compact = false});
  final _Filter value;

  /// Only the icon of the chosen filter, for narrow places.
  final bool compact;
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
                Icon(f.icon, size: 16, color: f == value ? c.primary : c.muted),
                const SizedBox(width: 10),
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
            Icon(compact ? value.icon : Icons.filter_list_rounded, size: 15, color: active ? c.primary : c.muted),
            if (!compact) ...[
              const SizedBox(width: 6),
              Text(
                value.label,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: active ? c.primary : c.muted),
              ),
            ],
            Icon(Icons.expand_more_rounded, size: 16, color: active ? c.primary : c.muted),
          ],
        ),
      ),
    );
  }
}

/// Names a block once, above its invocations, with their totals; it opens
/// and closes the whole block.
class _BlockHeading extends StatelessWidget {
  const _BlockHeading({
    super.key,
    required this.number,
    required this.title,
    required this.invocations,
    required this.time,
    required this.tokensIn,
    required this.tokensOut,
    required this.open,
    required this.gap,
    required this.start,
    required this.onTap,
    required this.outcome,
    this.highlighted = false,
  });
  final _Outcome outcome;
  final String? number;
  final String title;
  final int invocations, tokensIn, tokensOut;
  final Duration time;
  final double gap;
  final DateTime? start;
  final bool open, highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(top: gap, bottom: 2),
      child: SectionTitle(
        title: number == null ? title : '$number. $title',
        time: start == null ? null : _clock(start!),
        open: open,
        onTap: onTap,
        highlighted: highlighted,
        badge: _badge(outcome, c),
        stats: [
          IconStat(
            Icons.replay_rounded,
            '$invocations',
            invocations == 1 ? '1 invocazione' : '$invocations invocazioni',
          ),
          if (time.inSeconds > 0) IconStat(Icons.schedule_rounded, _span(time), 'Durata totale'),
          if (tokensIn + tokensOut > 0)
            IconStat(Icons.toll_outlined, _k(tokensIn + tokensOut), 'Token: ${_k(tokensIn)} in / ${_k(tokensOut)} out'),
        ],
      ),
    );
  }
}

/// The outcome icon of a block or invocation; the word goes in the tooltip.
Widget? _badge(_Outcome outcome, AppColors c) {
  final (Widget? icon, String? label) = switch (outcome) {
    _Outcome.done => (Icon(Icons.check_circle_rounded, size: 15, color: c.success), 'Completato'),
    _Outcome.again => (Icon(Icons.replay_circle_filled_rounded, size: 15, color: c.muted), 'Continua'),
    _Outcome.blocked => (Icon(Icons.error_rounded, size: 15, color: c.danger), 'Bloccato'),
    _Outcome.interrupted => (Icon(Icons.warning_rounded, size: 15, color: c.warning), 'Interrotto'),
    _Outcome.failed => (Icon(Icons.cancel_rounded, size: 15, color: c.danger), 'Problema'),
    _Outcome.running => (
      SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2, color: c.primary)),
      'In corso',
    ),
    _Outcome.none => (null, null),
  };
  return icon == null ? null : Tooltip(message: label!, child: icon);
}

String _k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 100000 ? 0 : 1)}k' : '$n';

/// One invocation: its name and how it ended; how long it took, what it
/// cost and when it started show on hover, like the times of the lines.
class _InvocationHeader extends StatefulWidget {
  const _InvocationHeader({required this.group, required this.open, required this.live, required this.onTap});
  final _Group group;
  final bool open, live;
  final VoidCallback onTap;

  @override
  State<_InvocationHeader> createState() => _InvocationHeaderState();
}

class _InvocationHeaderState extends State<_InvocationHeader> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final group = widget.group;
    final (_, _, invocation) = group.parts;
    final start = group.start!;
    final duration = group.duration(live: widget.live);
    final (tokensIn, tokensOut, cost) = group.usage;
    final badge = _badge(group.outcome(live: widget.live), c);
    final stats = <IconStat>[
      if (duration.inSeconds > 0) IconStat(Icons.schedule_rounded, _span(duration), 'Durata'),
      if (tokensIn + tokensOut > 0)
        IconStat(
          Icons.toll_outlined,
          _k(tokensIn + tokensOut),
          'Token: ${_k(tokensIn)} in / ${_k(tokensOut)} out${cost == null ? '' : ' · $cost'}',
        ),
    ];

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: _sidePad),
              child: Row(
                children: [
                  SizedBox(
                    width: _gutter,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SectionChevron(open: widget.open),
                    ),
                  ),
                  Text(
                    invocation == null ? 'Invocazione' : 'Invocazione $invocation',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text),
                  ),
                  if (badge != null) ...[const SizedBox(width: 10), badge],
                  // Lined up on the right with the time, shown on hover like
                  // the times of the lines (blocks show theirs always).
                  Expanded(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: _hover ? 1 : 0,
                      child: Row(children: [RightStats(stats: stats)]),
                    ),
                  ),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: _hover ? 1 : 0,
                    child: SectionTime(_clock(start)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Every line uses the same grid: [icon column] [text] [time], so texts of
/// all kinds start at the same place and times line up on the right.
const _sidePad = 8.0;
const _gutter = sectionGutter;
const _timeWidth = 64.0;
const _indent = 22.0;

const _arrow = sectionArrow;

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
      padding: const EdgeInsets.fromLTRB(_sidePad, 8, _sidePad, 0),
      child: Row(
        children: [
          SizedBox(
            width: _gutter,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: _arrow,
                child: Center(
                  child: SizedBox.square(
                    dimension: 13,
                    child: CircularProgressIndicator(strokeWidth: 2, color: c.primary.withValues(alpha: 0.7)),
                  ),
                ),
              ),
            ),
          ),
          Text(
            'Al lavoro · nessun output da ${_span(silent)} (limite $limitMinutes min)',
            style: TextStyle(fontSize: 12.5, color: c.muted, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatefulWidget {
  const _LogLine(this.entry, {required this.agent});
  final LogEntry entry;
  final AgentKind agent;

  @override
  State<_LogLine> createState() => _LogLineState();
}

class _LogLineState extends State<_LogLine> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final e = widget.entry;

    // One icon per line, always in the same column and size. Only icons
    // carry color; texts stay neutral.
    final icon = _lineIcon(e, widget.agent, c);

    // One grey for every text: the icon says what kind of line it is.
    final body = TextStyle(fontSize: 13.5, height: 1.5, color: Color.lerp(c.muted, c.text, 0.55));
    final Widget text = switch (e.kind) {
      LogKind.agent => MarkdownText(e.text, style: body),
      LogKind.tool => Text(
        e.text,
        style: body.copyWith(fontSize: 12, height: 1.6, fontFamily: mono, fontFamilyFallback: monoFallback),
      ),
      // Task and result mirror each other: the icon says which is which.
      LogKind.task || LogKind.result => MarkdownText(
        // Earlier versions put "Completato in …" before the summary; the
        // invocation header already shows those numbers.
        e.text.startsWith('Completato in ') && e.text.contains('\n\n')
            ? e.text.substring(e.text.indexOf('\n\n') + 2).trim()
            : e.text,
        style: body,
      ),
      _ => Text(e.text, style: body),
    };

    // Paragraphs breathe a little more than one-line events.
    final roomy = e.kind == LogKind.agent || e.kind == LogKind.task || e.kind == LogKind.result;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _gutter,
          child: Padding(
            padding: EdgeInsets.only(top: e.kind == LogKind.tool ? 3 : 3.5),
            // Centred on the same axis as the headers' arrows.
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: _arrow,
                child: Center(child: icon),
              ),
            ),
          ),
        ),
        Expanded(child: text),
        SizedBox(
          width: _timeWidth,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: _hover ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                _clock(e.at),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 11,
                  color: c.muted.withValues(alpha: 0.8),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _sidePad, vertical: roomy ? 7 : 3),
        child: row,
      ),
    );
  }
}

/// The block the log is about: the one running, otherwise the latest one
/// that appears in the log.
PlanBlock? _focusBlock(LoopEngine engine, List<_Group> groups) {
  final plan = engine.plan;
  if (plan == null) return null;
  final current = engine.currentBlock;
  if (current != null && current < plan.blocks.length) return plan.blocks[current];
  final last = groups.lastWhere((g) => g.header != null, orElse: () => _Group(null)).header;
  if (last == null) return null;
  final n = int.tryParse(RegExp(r'Blocco (\d+)/').firstMatch(last.text)?.group(1) ?? '');
  return n == null || n < 1 || n > plan.blocks.length ? null : plan.blocks[n - 1];
}

/// How far the block in the log has got: the steps the agent reports or,
/// until it reports any, the invocations used out of those allowed.
class _BlockProgress extends StatelessWidget {
  const _BlockProgress({required this.engine, required this.block});
  final LoopEngine engine;
  final PlanBlock block;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = engine.blockState(block);
    final max = engine.settings.maxAttemptsPerBlock;
    final steps = s.stepsTotal > 0;
    final done = s.status == BlockStatus.done;
    final ratio = done
        ? 1.0
        : steps
        ? s.stepsDone / s.stepsTotal
        : (s.attempts / max).clamp(0.0, 1.0);
    final label = steps
        ? '${s.stepsDone} di ${s.stepsTotal} passi completati'
        : done
        ? 'Blocco completato'
        : '${s.attempts} di $max invocazioni usate';
    final color = switch (s.status) {
      BlockStatus.done => c.success,
      BlockStatus.blocked => c.danger,
      _ => c.primary,
    };
    return ProgressSummary(
      title: '${block.index + 1}. ${block.title}',
      ratio: ratio,
      label: label,
      color: color,
      tooltip: steps
          ? 'Passi segnalati dall\'agente'
          : 'L\'agente non ha ancora segnalato i passi: invocazioni usate sul massimo consentito',
    );
  }
}

/// The icon of a line, the same in the log and in the strip at the bottom:
/// only icons carry color.
Widget _lineIcon(LogEntry e, AgentKind agent, AppColors c, {double size = 15}) {
  final agentIcon = Padding(
    padding: const EdgeInsets.all(1),
    child: SvgPicture.asset(
      AgentBadge.asset(agent),
      width: size - 2,
      height: size - 2,
      colorFilter: ColorFilter.mode(c.primary, BlendMode.srcIn),
    ),
  );
  return switch (e.kind) {
    LogKind.agent => agentIcon,
    LogKind.tool => Icon(Icons.terminal_rounded, size: size, color: c.muted),
    LogKind.success => Icon(Icons.check_circle_rounded, size: size, color: c.success),
    // The same flag: empty when the block starts, filled when it is done.
    LogKind.task => Icon(Icons.outlined_flag_rounded, size: size, color: c.text),
    LogKind.result => switch (e.outcome) {
      RunOutcome.done || null => Icon(Icons.flag_rounded, size: size, color: c.text),
      // Going on with the block reads like a word from the agent.
      RunOutcome.again => agentIcon,
      RunOutcome.interrupted => Icon(Icons.warning_amber_rounded, size: size, color: c.warning),
      RunOutcome.blocked || RunOutcome.failed => Icon(Icons.error_outline_rounded, size: size, color: c.danger),
    },
    LogKind.warning => Icon(Icons.warning_amber_rounded, size: size, color: c.warning),
    LogKind.error => Icon(Icons.error_outline_rounded, size: size, color: c.danger),
    LogKind.info || LogKind.system => Icon(Icons.info_outline_rounded, size: size, color: c.muted),
  };
}

/// The whole activity as a row of icons, newest on the right: each icon's
/// tooltip tells the line; block and invocation numbers mark where each
/// invocation starts. Filtered like the activity log.
class ActivityStrip extends StatefulWidget {
  const ActivityStrip({super.key, required this.engine});
  final LoopEngine engine;

  @override
  State<ActivityStrip> createState() => _ActivityStripState();
}

class _ActivityStripState extends State<ActivityStrip> {
  _Filter _filter = _Filter.all;

  static String _short(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 280 ? '${t.substring(0, 280)}…' : t;
  }

  Widget _marker(IconData icon, String value, String tooltip) {
    final c = context.colors;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(6)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: c.muted),
            const SizedBox(width: 3),
            Text(
              value,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.muted, height: 1),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final engine = widget.engine;
    final items = <Widget>[];
    String? lastBlock;
    for (final e in engine.logs) {
      if (e.kind == LogKind.info && e.text.startsWith('▶')) {
        final m = RegExp(r'Blocco (\d+)/\d+ «(.*)» — invocazione (\d+)').firstMatch(e.text);
        if (m == null) continue;
        if (m.group(1) != lastBlock) {
          items.add(_marker(Icons.layers_outlined, m.group(1)!, 'Blocco ${m.group(1)}: ${m.group(2)}'));
        }
        lastBlock = m.group(1);
        items.add(_marker(Icons.replay_rounded, m.group(3)!, 'Invocazione ${m.group(3)} · ${_clock(e.at)}'));
        continue;
      }
      if (!_shown(e) || !_filter.accepts(e)) continue;
      items.add(
        Tooltip(
          message: '${_clock(e.at)}  ${_short(e.text)}',
          constraints: const BoxConstraints(maxWidth: 420),
          waitDuration: const Duration(milliseconds: 150),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: _lineIcon(e, engine.settings.agent, c, size: 16),
          ),
        ),
      );
    }
    return Row(
      children: [
        _FilterBar(value: _filter, onChanged: (f) => setState(() => _filter = f), compact: true),
        const SizedBox(width: 12),
        Expanded(
          child: items.isEmpty
              ? Text('Nessuna attività', style: TextStyle(fontSize: 12.5, color: c.muted))
              // Newest on the right; older ones scroll away to the left.
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 7),
                  itemBuilder: (context, i) => Center(child: items[items.length - 1 - i]),
                ),
        ),
      ],
    );
  }
}
