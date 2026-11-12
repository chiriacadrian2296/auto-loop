import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../engine/agents.dart';
import '../engine/loop_engine.dart';
import '../engine/settings.dart';
import 'agent_badge.dart';
import 'app_theme.dart';
import 'markdown_text.dart';

enum _Filter {
  all('Tutto'),
  messages('Messaggi'),
  commands('Comandi'),
  events('Eventi');

  const _Filter(this.label);
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
    final lastHeader = widget.engine.logs.lastWhere((e) => e.kind == LogKind.info && e.text.startsWith('▶'));
    setState(() {
      _filter = _Filter.all;
      _atBottom = false;
      _unseen = false;
      // Open exactly this block's invocations (the latest is open by default).
      _toggled
        ..clear()
        ..addAll(headers.where((h) => !identical(h, lastHeader)));
      if (!headers.any((h) => identical(h, lastHeader))) _toggled.add(lastHeader);
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
        title: const Text('Svuotare il registro attività?'),
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
    final rows = <Widget>[];
    String? lastBlock;
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      final last = i == groups.length - 1;
      final visible = g.entries.where((e) => _shown(e) && _filter.accepts(e)).toList();
      if (_filter != _Filter.all && visible.isEmpty) continue;
      final header = g.header;
      final open = header == null || (last != _toggled.contains(header));
      if (header != null) {
        // The block is named once; its consecutive invocations follow.
        final (block, title, _) = g.parts;
        if (block != lastBlock) {
          _rowIndex[header] = rows.length;
          rows.add(
            _BlockHeading(
              key: _headerKeys.putIfAbsent(header, GlobalKey.new),
              block: block,
              title: title,
              first: rows.isEmpty,
              highlighted: identical(header, _flash),
            ),
          );
        }
        lastBlock = block;
        rows.add(
          _InvocationHeader(
            group: g,
            open: open,
            live: last && engine.isActive,
            onTap: () => setState(() => _toggled.contains(header) ? _toggled.remove(header) : _toggled.add(header)),
          ),
        );
      } else {
        lastBlock = null;
      }
      if (open) rows.addAll(visible.map((e) => _LogLine(e, agent: engine.settings.agent)));
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
              tooltip: 'Svuota il registro',
              onPressed: logs.isEmpty ? null : _confirmClear,
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
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
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

/// Names a block once, above its invocations.
class _BlockHeading extends StatelessWidget {
  const _BlockHeading({
    super.key,
    required this.block,
    required this.title,
    required this.first,
    this.highlighted = false,
  });
  final String block;
  final String? title;
  final bool first, highlighted;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(top: first ? 4 : 26, bottom: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: _sidePad),
        decoration: BoxDecoration(
          color: highlighted ? c.primarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: c.primarySoft, borderRadius: BorderRadius.circular(99)),
              child: Text(
                block,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.primary),
              ),
            ),
            if (title != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 100000 ? 0 : 1)}k' : '$n';

/// One invocation: how it ended, then how long it took and what it cost.
class _InvocationHeader extends StatelessWidget {
  const _InvocationHeader({required this.group, required this.open, required this.live, required this.onTap});
  final _Group group;
  final bool open, live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (_, _, invocation) = group.parts;
    final start = group.start!;
    final duration = (live ? DateTime.now() : group.end!).difference(start);
    final (tokensIn, tokensOut, cost) = group.usage;
    final (Widget? badge, String? status) = switch (group.outcome(live: live)) {
      _Outcome.done => (Icon(Icons.check_circle_rounded, size: 15, color: c.success), 'completato'),
      _Outcome.again => (Icon(Icons.replay_circle_filled_rounded, size: 15, color: c.primary), 'continua'),
      _Outcome.blocked => (Icon(Icons.error_rounded, size: 15, color: c.danger), 'bloccato'),
      _Outcome.interrupted => (Icon(Icons.warning_rounded, size: 15, color: c.warning), 'interrotto'),
      _Outcome.failed => (Icon(Icons.cancel_rounded, size: 15, color: c.danger), 'problema'),
      _Outcome.running => (
        SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2, color: c.primary)),
        'in corso',
      ),
      _Outcome.none => (null, null),
    };
    final stats = [
      if (duration.inSeconds > 0) IconStat(Icons.schedule_rounded, _span(duration), 'Durata'),
      if (tokensIn + tokensOut > 0)
        IconStat(
          Icons.toll_outlined,
          _k(tokensIn + tokensOut),
          'Token: ${_k(tokensIn)} in / ${_k(tokensOut)} out${cost == null ? '' : ' · $cost'}',
        ),
    ];
    final muted = TextStyle(fontSize: 12.5, color: c.muted);

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: _sidePad),
            child: Row(
              children: [
                SizedBox(
                  width: _gutter,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedRotation(
                      turns: open ? 0 : -0.25,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(Icons.expand_more_rounded, size: 20, color: c.muted),
                    ),
                  ),
                ),
                Text(
                  invocation == null ? 'Invocazione' : 'Invocazione $invocation',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.text),
                ),
                if (badge != null) ...[const SizedBox(width: 10), badge, const SizedBox(width: 6)],
                if (status != null) Text(status, style: muted),
                // On a narrow panel the numbers give way before the state does.
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final room = box.maxWidth;
                      final shown = room >= 170 ? stats : (room >= 90 ? stats.take(1).toList() : const <Widget>[]);
                      if (shown.isEmpty) return const SizedBox.shrink();
                      return Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Text('–', style: muted),
                          ),
                          for (final (i, w) in shown.indexed) ...[if (i > 0) const SizedBox(width: 14), w],
                        ],
                      );
                    },
                  ),
                ),
                SizedBox(
                  width: _timeWidth,
                  child: Text(
                    _clock(start),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
                      color: c.muted.withValues(alpha: 0.8),
                      fontFeatures: const [FontFeature.tabularFigures()],
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

/// Every line uses the same grid: [icon column] [text] [time], so texts of
/// all kinds start at the same place and times line up on the right.
const _sidePad = 8.0;
const _gutter = 28.0;
const _timeWidth = 64.0;

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
              child: SizedBox.square(
                dimension: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: c.primary.withValues(alpha: 0.7)),
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
    const size = 15.0;
    final Widget icon = switch (e.kind) {
      LogKind.agent => Padding(
        padding: const EdgeInsets.all(1),
        child: SvgPicture.asset(
          AgentBadge.asset(widget.agent),
          width: size - 2,
          height: size - 2,
          colorFilter: ColorFilter.mode(c.primary, BlendMode.srcIn),
        ),
      ),
      LogKind.tool => Icon(Icons.terminal_rounded, size: size, color: c.text),
      LogKind.success => Icon(Icons.check_circle_rounded, size: size, color: c.success),
      // The same flag: empty when the block starts, filled when it is done.
      LogKind.task => Icon(Icons.outlined_flag_rounded, size: size, color: c.primary),
      LogKind.result => Icon(Icons.flag_rounded, size: size, color: c.primary),
      LogKind.warning => Icon(Icons.warning_amber_rounded, size: size, color: c.warning),
      LogKind.error => Icon(Icons.error_outline_rounded, size: size, color: c.danger),
      LogKind.info || LogKind.system => Icon(Icons.info_outline_rounded, size: size, color: c.primary),
    };

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
            child: Align(alignment: Alignment.topLeft, child: icon),
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
