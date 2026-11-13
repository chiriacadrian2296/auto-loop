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

/// The line (or invocation start) chosen in the activity panel or in the
/// strip at the bottom: both show it, and it stays chosen until something
/// else, or empty space, is clicked.
class ActivitySelection extends ChangeNotifier {
  LogEntry? entry;

  /// The block itself was chosen (its first invocation's start is [entry]),
  /// not that invocation.
  bool block = false;

  /// Who chose it, so that the other side follows (opens, scrolls).
  Object? source;

  /// One filter for the activity panel and the strip.
  final _filter = ValueNotifier<_Filter>(_Filter.all);

  void select(LogEntry? e, Object source, {bool block = false}) {
    entry = e;
    this.block = block;
    this.source = source;
    notifyListeners();
  }
}

/// The kinds of lines one can filter on.
enum _Kind {
  messages('Messaggi', Icons.chat_bubble_outline_rounded),
  commands('Comandi', Icons.terminal_rounded),
  // Everything AutoLoop itself reports: checks, commits, warnings, errors.
  events('Eventi', Icons.flag_outlined);

  const _Kind(this.label, this.icon);
  final String label;
  final IconData icon;

  bool has(LogEntry e) => switch (this) {
    _Kind.messages => e.kind == LogKind.agent,
    _Kind.commands => e.kind == LogKind.tool,
    _Kind.events => e.kind != LogKind.agent && e.kind != LogKind.tool,
  };
}

/// Which kinds of lines are shown; several can be chosen at once.
class _Filter {
  const _Filter(this.kinds);
  final Set<_Kind> kinds;

  static const all = _Filter({_Kind.messages, _Kind.commands, _Kind.events});

  bool get isAll => kinds.length == _Kind.values.length;
  bool accepts(LogEntry e) => kinds.any((k) => k.has(e));

  /// Adds or removes [k]; removing the last one shows everything again.
  _Filter toggle(_Kind k) {
    final next = kinds.contains(k) ? ({...kinds}..remove(k)) : {...kinds, k};
    return next.isEmpty ? all : _Filter(next);
  }

  @override
  bool operator ==(Object other) =>
      other is _Filter && other.kinds.length == kinds.length && other.kinds.containsAll(kinds);

  @override
  int get hashCode => Object.hashAll(kinds.map((k) => k.index).toList()..sort());
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
  const LogPanel({super.key, required this.engine, this.onOpenLogs, this.onOpenProgress, this.reveal, this.selection});
  final LoopEngine engine;
  final VoidCallback? onOpenLogs, onOpenProgress;

  /// Requests to show a block's invocations: (block index, request number).
  final ValueNotifier<(int, int)?>? reveal;

  /// The chosen line, shared with the strip at the bottom of the window.
  final ActivitySelection? selection;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();
  _Filter _ownFilter = _Filter.all;

  /// Shared with the strip at the bottom when there is a selection object.
  _Filter get _filter => widget.selection?._filter.value ?? _ownFilter;
  set _filter(_Filter f) => widget.selection == null ? _ownFilter = f : widget.selection!._filter.value = f;

  void _filterChanged() => setState(() {});

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

  /// The chosen line or header, highlighted until something else is chosen.
  LogEntry? get _flash => widget.selection?.entry;

  void _select(LogEntry? e, {bool block = false}) => widget.selection?.select(e, this, block: block);

  bool get _blockChosen => widget.selection?.block ?? false;

  /// Keys and row positions of block headings, apart from those of lines
  /// and invocations (a block shares its entry with its first invocation).
  final _blockKeys = <LogEntry, GlobalKey>{};
  final _blockRowIndex = <LogEntry, int>{};

  /// Chosen elsewhere (the strip, the progress panel): open what holds it
  /// and scroll to it. Chosen here: just redraw the highlight.
  void _onSelection() {
    final target = widget.selection?.entry;
    if (target == null || identical(widget.selection?.source, this)) {
      if (mounted) setState(() {});
      return;
    }
    final groups = _groupLogs(widget.engine.logs);
    final group = groups
        .where((g) => identical(g.header, target) || g.entries.any((e) => identical(e, target)))
        .firstOrNull;
    if (group == null) return;
    final run = _runs(groups).where((r) => r.contains(group)).firstOrNull;
    setState(() {
      if (run?.first.header case final head?) _toggledBlocks.remove(head);
      if (group.header case final header?) _toggled.remove(header);
      if (!identical(group.header, target) && !_filter.accepts(target)) _filter = _Filter.all;
      _atBottom = false;
      _unseen = false;
    });
    _scrollTo(target, block: widget.selection?.block ?? false);
  }

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
    });
    widget.selection?.select(headers.first, #progress, block: true);
  }

  /// Brings [header] into view; rows are built lazily, so jump close first.
  void _scrollTo(LogEntry header, {bool block = false, int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final ctx = (block ? _blockKeys : _headerKeys)[header]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0, duration: const Duration(milliseconds: 250));
        return;
      }
      if (attempt > 4) return;
      final i = (block ? _blockRowIndex : _rowIndex)[header];
      if (i != null && _rowCount > 0) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent * (i / _rowCount));
      }
      _scrollTo(header, block: block, attempt: attempt + 1);
    });
  }

  @override
  void initState() {
    super.initState();
    widget.reveal?.addListener(_onReveal);
    widget.selection?.addListener(_onSelection);
    widget.selection?._filter.addListener(_filterChanged);
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
    widget.selection?.removeListener(_onSelection);
    widget.selection?._filter.removeListener(_filterChanged);
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
        _blockRowIndex[head] = rows.length;
        rows.add(
          _BlockHeading(
            key: _blockKeys.putIfAbsent(head, GlobalKey.new),
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
            highlighted: identical(head, _flash) && _blockChosen,
            // How the block ended here: as its latest invocation did.
            outcome: run.last.outcome(live: lastRun && engine.isActive),
            onTap: () =>
                setState(() => _toggledBlocks.contains(head) ? _toggledBlocks.remove(head) : _toggledBlocks.add(head)),
            onSelect: () => _select(head, block: true),
          ),
        );
      }
      previousOpen = blockOpen;
      if (!blockOpen) continue;
      // Invocations sit one step in from their block, their lines one more:
      // the arrows step in, the icons all share one column.
      Widget tab(Widget w, [int steps = 1]) => Padding(
        padding: EdgeInsets.only(left: _indent * steps),
        child: w,
      );
      for (final g in run) {
        final visible = shown[g]!;
        if (_filter != _Filter.all && visible.isEmpty) continue;
        final last = lastRun && identical(g, run.last);
        final header = g.header;
        final open = header == null || !_toggled.contains(header);
        if (header != null) {
          final chosen = identical(header, _flash) && !_blockChosen;
          if (chosen) _rowIndex[header] = rows.length;
          rows.add(
            tab(
              _InvocationHeader(
                key: chosen ? _headerKeys.putIfAbsent(header, GlobalKey.new) : null,
                highlighted: chosen,
                group: g,
                open: open,
                live: last && engine.isActive,
                onTap: () => setState(() => _toggled.contains(header) ? _toggled.remove(header) : _toggled.add(header)),
                onSelect: () => _select(header),
              ),
            ),
          );
        }
        if (open) {
          for (final e in visible) {
            final target = identical(e, _flash);
            if (target) _rowIndex[e] = rows.length;
            rows.add(
              tab(
                _LogLine(
                  e,
                  key: target ? _headerKeys.putIfAbsent(e, GlobalKey.new) : null,
                  agent: engine.settings.agent,
                  highlighted: target,
                  onTap: () => _select(e),
                ),
                2,
              ),
            );
          }
        }
      }
    }
    _rowCount = rows.length;
    final silent = engine.phase == LoopPhase.running && engine.lastOutputAt != null
        ? DateTime.now().difference(engine.lastOutputAt!)
        : null;
    if (silent != null && silent.inSeconds >= 20 && _filter == _Filter.all) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(left: _indent * 2),
          child: _WorkingLine(silent: silent, limitMinutes: engine.settings.idleTimeoutMinutes),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          'Attività',
          titleActions: [ExpandAllButton(allOpen: allOpen, onPressed: heads.isEmpty ? null : () => setAll(!allOpen))],
          actions: [
            _FilterBar(value: _filter, onChanged: (f) => setState(() => _filter = f)),
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
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => _select(null),
                      child: SelectionArea(
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                          itemCount: rows.length,
                          itemBuilder: (context, i) => rows[i],
                        ),
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
/// An icon button like the others of the title bar: the icon of the one
/// kind chosen, or the filter icon; the menu lets one pick several kinds.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.value, required this.onChanged});
  final _Filter value;
  final ValueChanged<_Filter> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = !value.isAll;
    Widget item({required IconData icon, required String label, required bool on, required VoidCallback onTap}) =>
        MenuItemButton(
          closeOnActivate: false,
          onPressed: onTap,
          style: MenuItemButton.styleFrom(
            backgroundColor: on ? c.primarySoft : Colors.transparent,
            foregroundColor: on ? c.primary : c.text,
            iconColor: on ? c.primary : c.muted,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            textStyle: const TextStyle(fontSize: 13.5, fontFamily: uiFont, fontFamilyFallback: uiFallback),
          ),
          leadingIcon: Icon(icon, size: 16),
          child: Text(label),
        );
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: c.border),
          ),
        ),
      ),
      menuChildren: [
        item(icon: Icons.filter_list_rounded, label: 'Tutto', on: value.isAll, onTap: () => onChanged(_Filter.all)),
        for (final k in _Kind.values)
          item(
            icon: k.icon,
            label: k.label,
            on: !value.isAll && value.kinds.contains(k),
            // From "everything", a click picks just that kind.
            onTap: () => onChanged(value.isAll ? _Filter({k}) : value.toggle(k)),
          ),
      ],
      builder: (context, menu, _) => IconButton(
        tooltip: active ? 'Filtro: ${value.kinds.map((k) => k.label).join(', ')}' : 'Filtra le attività',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        iconSize: 19,
        color: active ? c.primary : null,
        icon: Icon(value.kinds.length == 1 ? value.kinds.single.icon : Icons.filter_list_rounded),
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
    required this.onSelect,
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
  final VoidCallback onTap, onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(top: gap, bottom: 2),
      child: SectionTitle(
        title: number == null ? title : '$number. $title',
        icon: highlighted
            ? _invertedDisc(c, Icon(Icons.layers_outlined, size: 15, color: c.background), size: 21)
            : Icon(Icons.layers_outlined, size: 15, color: c.text),
        time: start == null ? null : _clock(start!),
        open: open,
        onTap: onTap,
        onSelect: onSelect,
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
  const _InvocationHeader({
    super.key,
    required this.group,
    required this.open,
    required this.live,
    required this.onTap,
    required this.onSelect,
    this.highlighted = false,
  });
  final bool highlighted;
  final _Group group;
  final bool open, live;
  final VoidCallback onTap, onSelect;

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
        child: Row(
          children: [
            // The arrow only opens and closes.
            Padding(
              padding: const EdgeInsets.only(left: _sidePad),
              child: SizedBox(
                width: _gutter,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: widget.onTap,
                    child: SectionChevron(open: widget.open),
                  ),
                ),
              ),
            ),
            // The rest of the row chooses the invocation.
            Expanded(
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  hoverColor: c.field,
                  onTap: widget.onSelect,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 6, _sidePad, 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: _gutter,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: _arrow,
                              child: Center(
                                child: widget.highlighted
                                    ? _invertedDisc(
                                        c,
                                        Icon(Icons.replay_rounded, size: 15, color: c.background),
                                        size: 21,
                                      )
                                    : Icon(Icons.replay_rounded, size: 15, color: c.text),
                              ),
                            ),
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
          ],
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
const _indent = sectionGutter;

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
  const _LogLine(this.entry, {super.key, required this.agent, this.highlighted = false, this.onTap});
  final LogEntry entry;
  final bool highlighted;
  final VoidCallback? onTap;
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
    // The chosen line shows its icon inverted, like on the map.
    final icon = widget.highlighted
        ? _invertedDisc(c, _lineIcon(e, widget.agent, c, inverted: true), size: e.kind == LogKind.tool ? 12 : 21)
        : _lineIcon(e, widget.agent, c);

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
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: _hover ? c.field : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: EdgeInsets.symmetric(horizontal: _sidePad, vertical: roomy ? 7 : 3),
          child: row,
        ),
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

/// The icon of a line, the same in the log and on the map at the bottom:
/// only icons carry color. Commands are just a small grey dot. [inverted]
/// draws it for a light tile (the chosen one on the map): white icons turn
/// dark there.
Widget _lineIcon(LogEntry e, AgentKind agent, AppColors c, {double size = 15, bool inverted = false}) {
  final white = inverted ? c.background : c.text;
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
    LogKind.tool => SizedBox.square(
      dimension: size,
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: inverted ? c.background : c.muted, shape: BoxShape.circle),
        ),
      ),
    ),
    LogKind.success => Icon(Icons.check_circle_rounded, size: size, color: c.success),
    // The same flag: empty when the block starts, filled when it is done.
    LogKind.task => Icon(Icons.outlined_flag_rounded, size: size, color: white),
    LogKind.result => switch (e.outcome) {
      RunOutcome.done || null => Icon(Icons.flag_rounded, size: size, color: white),
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

/// How the chosen line shows its icon, in the log and on the map: on a
/// light disc, colours inverted.
Widget _invertedDisc(AppColors c, Widget icon, {double size = 22}) => Container(
  width: size,
  height: size,
  alignment: Alignment.center,
  decoration: BoxDecoration(color: c.text, shape: BoxShape.circle),
  child: icon,
);

/// The whole activity as a map, laid out in time: each block is a neutral
/// band with its invocations marked inside, every line is its icon
/// (commands a grey dot), kept a little apart so none hides another. It
/// scrolls when it gets long; a click or a drag picks the nearest line,
/// shown in the activity panel too.
class ActivityMap extends StatefulWidget {
  const ActivityMap({super.key, required this.engine, required this.selection});
  final LoopEngine engine;
  final ActivitySelection selection;

  @override
  State<ActivityMap> createState() => _ActivityMapState();
}

class _ActivityMapState extends State<ActivityMap> {
  final _scroll = ScrollController();
  int _lastCount = -1;

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_redraw);
    widget.selection._filter.addListener(_redraw);
  }

  @override
  void dispose() {
    widget.selection.removeListener(_redraw);
    widget.selection._filter.removeListener(_redraw);
    _scroll.dispose();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  static const _pad = 12.0;
  static const _icon = 22.0;
  static const _dot = 12.0;

  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final engine = widget.engine;
    final sel = widget.selection;
    final filter = sel._filter.value;
    final logs = engine.logs;
    if (logs.isEmpty) {
      return Center(
        child: Text('L\'attività apparirà qui', style: TextStyle(fontSize: 12.5, color: c.muted)),
      );
    }
    final groups = _groupLogs(logs);
    final runs = _runs(groups).where((r) => r.first.header != null).toList();
    final t0 = logs.first.at;
    var t1 = logs.last.at;
    if (engine.isActive && DateTime.now().isAfter(t1)) t1 = DateTime.now();
    if (!t1.isAfter(t0)) t1 = t0.add(const Duration(seconds: 1));

    // What goes on the map, in order: invocation starts (no icon of their
    // own, they open the bands) and the lines the filter lets through.
    bool isHeader(LogEntry e) => e.kind == LogKind.info && e.text.startsWith('▶');
    // Every block opens with its task flag: when the log has none for it
    // (it began before the log), one stands in, pointing at the block.
    final starts = <LogEntry, LogEntry>{};
    final firstHeaders = {for (final r in runs) r.first.header!};
    final items = <LogEntry>[];
    for (final (i, e) in logs.indexed) {
      final header = isHeader(e);
      if (!header && !(_shown(e) && filter.accepts(e))) continue;
      items.add(e);
      if (header && firstHeaders.contains(e) && filter.kinds.contains(_Kind.events)) {
        final hasTask = logs.skip(i + 1).takeWhile((x) => !isHeader(x)).any((x) => x.kind == LogKind.task);
        if (!hasTask) {
          final m = RegExp(r'Blocco (\d+)/\d+ «(.*)»').firstMatch(e.text);
          final flag = LogEntry(
            LogKind.task,
            m == null ? 'Compito' : 'Compito del blocco ${m.group(1)}: ${m.group(2)}',
            at: e.at,
          );
          starts[flag] = e;
          items.add(flag);
        }
      }
    }
    double half(LogEntry e) => isHeader(e) ? 2 : (e.kind == LogKind.tool ? _dot / 2 : _icon / 2);

    // Keep up with new lines while the end is in view.
    if (logs.length != _lastCount) {
      final atEnd = !_scroll.hasClients || _scroll.position.pixels >= _scroll.position.maxScrollExtent - 4;
      _lastCount = logs.length;
      if (atEnd) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    }

    final hm = TextStyle(fontSize: 11, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()]);
    return Row(
      children: [
        Text(_hm(t0), style: hm),
        const SizedBox(width: 10),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              // Positions follow time, but each item keeps a little room so
              // none hides the next; then the map may get longer than the
              // card and scrolls.
              final scale = (box.maxWidth - 2 * _pad) / t1.difference(t0).inMilliseconds;
              final xs = <LogEntry, double>{};
              double? prevX;
              LogEntry? prev;
              for (final e in items) {
                var x = _pad + e.at.difference(t0).inMilliseconds * scale;
                if (prevX != null) {
                  final min = prevX + half(prev!) + half(e) + 3;
                  if (x < min) x = min;
                }
                xs[e] = x;
                prevX = x;
                prev = e;
              }
              final last = prevX ?? _pad;
              final liveEnd = engine.isActive
                  ? [_pad + t1.difference(t0).inMilliseconds * scale, last + 14].reduce((a, b) => a > b ? a : b)
                  : last;
              final width = [box.maxWidth, liveEnd + _pad].reduce((a, b) => a > b ? a : b);
              final mid = box.maxHeight / 2;

              final bands = <(double, double, List<double>, bool, String)>[];
              for (final (i, run) in runs.indexed) {
                final head = run.first.header!;
                final live = i == runs.length - 1 && engine.isActive;
                // From the centre of its first icon to the centre of its last:
                // half of each sits inside the band, half outside.
                final first = items.indexOf(head);
                final next = runs.length > i + 1 ? items.indexOf(runs[i + 1].first.header!) : items.length;
                final icons = [
                  for (final e in items.sublist(first, next))
                    if (!isHeader(e)) e,
                ];
                final left = icons.isEmpty ? xs[head]! - 6 : xs[icons.first]!;
                var right = live ? liveEnd : (icons.isEmpty ? xs[head]! + 6 : xs[icons.last]!);
                if (right < left + 6) right = left + 6;
                final m = RegExp(r'Blocco (\d+)/\d+ «(.*)»').firstMatch(head.text);
                bands.add((
                  left,
                  right,
                  [
                    for (final g in run.skip(1))
                      if (xs[g.header] case final x?) x - 3,
                  ],
                  identical(sel.entry, head),
                  m == null ? '' : 'Blocco ${m.group(1)}: ${m.group(2)}',
                ));
              }

              void pick(double dx) {
                LogEntry? best;
                var dist = double.infinity;
                for (final e in items) {
                  final d = (xs[e]! - dx).abs();
                  if (d < dist) {
                    dist = d;
                    best = e;
                  }
                }
                if (best == null) return;
                final head = starts[best];
                sel.select(head ?? best, this, block: head != null);
              }

              final chosen = sel.entry;
              // Where the map goes on beyond an edge, that edge fades out
              // instead of cutting the icons off.
              return ListenableBuilder(
                listenable: _scroll,
                builder: (context, child) {
                  final pos = _scroll.hasClients ? _scroll.position : null;
                  final fadeLeft = pos != null && pos.hasContentDimensions && pos.pixels > 1;
                  final fadeRight = pos != null && pos.hasContentDimensions && pos.pixels < pos.maxScrollExtent - 1;
                  if (!fadeLeft && !fadeRight) return child!;
                  final f = 28 / box.maxWidth;
                  return ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => LinearGradient(
                      colors: [
                        fadeLeft ? Colors.transparent : Colors.black,
                        Colors.black,
                        Colors.black,
                        fadeRight ? Colors.transparent : Colors.black,
                      ],
                      stops: [0, f, 1 - f, 1],
                    ).createShader(rect),
                    child: child,
                  );
                },
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => pick(d.localPosition.dx),
                      onHorizontalDragUpdate: (d) => pick(d.localPosition.dx),
                      child: SizedBox(
                        width: width,
                        height: box.maxHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _MapPainter(
                                  bands: [for (final b in bands) (b.$1, b.$2, b.$3, b.$4)],
                                  band: c.muted,
                                  line: c.muted.withValues(alpha: 0.7),
                                  chosenBand: c.text,
                                  mid: mid,
                                ),
                              ),
                            ),
                            // Block names on hover.
                            for (final b in bands)
                              Positioned(
                                left: b.$1,
                                width: b.$2 - b.$1,
                                top: mid - 10,
                                height: 20,
                                child: Tooltip(message: b.$5, child: const SizedBox.expand()),
                              ),
                            for (final e in items)
                              if (!isHeader(e))
                                () {
                                  // Commands sit on a smaller disc.
                                  final size = e.kind == LogKind.tool ? 12.0 : _icon;
                                  final head = starts[e];
                                  final isChosen = head == null
                                      ? identical(chosen, e)
                                      : identical(chosen, head) && sel.block;
                                  return Positioned(
                                    left: xs[e]! - size / 2,
                                    top: mid - size / 2,
                                    width: size,
                                    height: size,
                                    child: Tooltip(
                                      message: '${_clock(e.at)}  ${e.text.replaceAll(RegExp(r'\s+'), ' ').trim()}',
                                      constraints: const BoxConstraints(maxWidth: 420),
                                      child: GestureDetector(
                                        onTap: () => sel.select(head ?? e, this, block: head != null),
                                        // The chosen one is shown inverted: a light
                                        // disc behind the icon.
                                        child: Container(
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: isChosen ? c.text : c.surface,
                                            shape: BoxShape.circle,
                                          ),
                                          // Triangles look low in their box: lift them a little.
                                          child: Transform.translate(
                                            offset: Offset(0, _warns(e) ? -1 : 0),
                                            child: _lineIcon(
                                              e,
                                              engine.settings.agent,
                                              c,
                                              size: e.kind == LogKind.tool ? 10 : 15,
                                              inverted: isChosen,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 10),
        Text(engine.isActive ? 'adesso' : _hm(t1), style: hm),
      ],
    );
  }

  static bool _warns(LogEntry e) =>
      e.kind == LogKind.warning || (e.kind == LogKind.result && e.outcome == RunOutcome.interrupted);
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.bands,
    required this.band,
    required this.line,
    required this.chosenBand,
    required this.mid,
  });

  /// Left, right, invocation cuts, chosen.
  final List<(double, double, List<double>, bool)> bands;
  final Color band, line, chosenBand;
  final double mid;

  @override
  void paint(Canvas canvas, Size size) {
    // Blocks: a light band; its outline and the cuts between invocations
    // stay faint, so the time line through the middle reads first.
    for (final (left, right, cuts, chosen) in bands) {
      final r = RRect.fromLTRBR(left, mid - 13, right, mid + 13, const Radius.circular(8));
      canvas.drawRRect(r, Paint()..color = band.withValues(alpha: 0.10));
      canvas.drawRRect(
        r,
        Paint()
          ..color = chosen ? chosenBand : band.withValues(alpha: 0.18)
          ..style = PaintingStyle.stroke
          ..strokeWidth = chosen ? 1.6 : 1,
      );
      for (final x in cuts) {
        canvas.drawLine(
          Offset(x, mid - 13),
          Offset(x, mid + 13),
          Paint()
            ..color = band.withValues(alpha: 0.22)
            ..strokeWidth = 1,
        );
      }
    }
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = line
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_MapPainter old) => true;
}
