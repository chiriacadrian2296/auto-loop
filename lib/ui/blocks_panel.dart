import 'package:flutter/material.dart';

import '../engine/loop_engine.dart';
import '../engine/loop_state.dart';
import '../engine/plan_parser.dart';
import 'app_theme.dart';
import 'section_title.dart';

String _invocations(int n) => n == 1 ? '1 invocazione' : '$n invocazioni';

String _duration(int seconds) {
  if (seconds <= 0) return '';
  if (seconds < 60) return '$seconds s';
  final m = seconds ~/ 60;
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}

String _tokens(int n) => n >= 1000000
    ? '${(n / 1000000).toStringAsFixed(1)}M'
    : n >= 1000
    ? '${(n / 1000).toStringAsFixed(n >= 100000 ? 0 : 1)}k'
    : '$n';

/// Seconds spent on [b] so far, including the invocation running right now.
int _blockSeconds(LoopEngine engine, PlanBlock b) {
  final s = engine.blockState(b);
  final running = engine.currentBlock == b.index && engine.runStartedAt != null;
  return s.activeSeconds + (running ? DateTime.now().difference(engine.runStartedAt!).inSeconds : 0);
}

/// The status-changing actions available for a block in its current state.
List<(String, IconData, BlockStatus)> _actionsFor(BlockStatus status) => [
  if (status != BlockStatus.pending) ('Rimetti in coda', Icons.replay_rounded, BlockStatus.pending),
  if (status != BlockStatus.done) ('Segna completato', Icons.check_rounded, BlockStatus.done),
  if (status == BlockStatus.pending) ('Salta', Icons.redo_rounded, BlockStatus.skipped),
];

class BlocksPanel extends StatefulWidget {
  const BlocksPanel({super.key, required this.engine, required this.planName, this.onShowInLog});
  final LoopEngine engine;
  final String planName;

  /// Opens the activity log at this block's invocations.
  final ValueChanged<PlanBlock>? onShowInLog;

  /// The groups (by name) that are closed; shared with the title bar's
  /// expand/collapse-all button.
  static final closed = ValueNotifier<Set<String>>({});

  /// "Espandi tutto" / "Comprimi tutto" for the panel's title bar.
  static Widget expandAllButton() => ValueListenableBuilder<Set<String>>(
    valueListenable: closed,
    builder: (context, value, _) => ExpandAllButton(
      allOpen: value.isEmpty,
      onPressed: () => closed.value = value.isEmpty ? {for (final b in _Bucket.values) b.label} : {},
    ),
  );

  @override
  State<BlocksPanel> createState() => _BlocksPanelState();
}

/// The groups the blocks are shown in, in this order.
enum _Bucket {
  done('Completati'),
  active('In corso'),
  todo('Da fare'),
  skipped('Saltati');

  const _Bucket(this.label);
  final String label;
}

class _BlocksPanelState extends State<BlocksPanel> {
  int? _selected;

  Set<String> get _closed => BlocksPanel.closed.value;

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    BlocksPanel.closed.addListener(_changed);
  }

  @override
  void dispose() {
    BlocksPanel.closed.removeListener(_changed);
    super.dispose();
  }

  _Bucket _bucketOf(PlanBlock b) {
    final engine = widget.engine;
    final s = engine.blockState(b);
    if (engine.currentBlock == b.index && engine.isActive) return _Bucket.active;
    return switch (s.status) {
      BlockStatus.done => _Bucket.done,
      BlockStatus.blocked => _Bucket.active,
      BlockStatus.skipped => _Bucket.skipped,
      BlockStatus.pending => s.attempts > 0 ? _Bucket.active : _Bucket.todo,
    };
  }

  /// Title of a group: its name, an icon for how it is going, and the totals
  /// of its blocks.
  Widget _groupTitle(_Bucket bucket, List<PlanBlock> blocks, {required bool first}) {
    final engine = widget.engine;
    final c = context.colors;
    var invocations = 0, seconds = 0, input = 0, output = 0;
    for (final b in blocks) {
      final s = engine.blockState(b);
      invocations += s.attempts;
      seconds += _blockSeconds(engine, b);
      input += s.inputTokens;
      output += s.outputTokens;
    }
    final running = blocks.any((b) => engine.currentBlock == b.index && engine.isActive);
    final blocked = blocks.any((b) => engine.blockState(b).status == BlockStatus.blocked);
    final Widget badge = switch (bucket) {
      _Bucket.done => Icon(Icons.check_circle_rounded, size: 15, color: c.success),
      _Bucket.active when running => SizedBox.square(
        dimension: 12,
        child: CircularProgressIndicator(strokeWidth: 2, color: c.primary),
      ),
      _Bucket.active when blocked => Icon(Icons.error_rounded, size: 15, color: c.danger),
      _Bucket.active => Icon(Icons.play_circle_rounded, size: 15, color: c.primary),
      // On the same grey disc as the progress nodes still to do.
      _Bucket.todo => _greyDisc(c, Icons.more_horiz_rounded),
      _Bucket.skipped => _greyDisc(c, Icons.redo_rounded),
    };
    final open = !_closed.contains(bucket.label);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 10, bottom: 2),
      child: SectionTitle(
        title: bucket.label,
        open: open,
        onTap: () =>
            BlocksPanel.closed.value = open ? {..._closed, bucket.label} : ({..._closed}..remove(bucket.label)),
        badge: badge,
        stats: [
          IconStat(
            Icons.layers_outlined,
            '${blocks.length}',
            blocks.length == 1 ? '1 blocco' : '${blocks.length} blocchi',
          ),
          if (invocations > 0) IconStat(Icons.replay_rounded, '$invocations', _invocations(invocations)),
          if (seconds > 0) IconStat(Icons.schedule_rounded, _duration(seconds), 'Durata totale'),
          if (input + output > 0)
            IconStat(
              Icons.toll_outlined,
              _tokens(input + output),
              'Token: ${_tokens(input)} in / ${_tokens(output)} out',
            ),
        ],
      ),
    );
  }

  Future<void> _contextMenu(Offset position, PlanBlock block) async {
    final engine = widget.engine;
    final status = engine.blockState(block).status;
    final pause = engine.blockState(block).pauseAfter;
    final c = context.colors;
    final picked = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      items: [
        for (final (label, icon, target) in _actionsFor(status))
          PopupMenuItem(value: target, height: 40, enabled: !engine.isActive, child: _MenuRow(icon, label)),
        if (status == BlockStatus.pending || status == BlockStatus.blocked)
          PopupMenuItem(
            value: 'pause',
            height: 40,
            child: _MenuRow(
              Icons.pan_tool_outlined,
              pause ? 'Non fermarti dopo questo blocco' : 'Fermati dopo questo blocco',
            ),
          ),
      ],
    );
    if (!mounted || picked == null) return;
    if (picked is BlockStatus) engine.setBlockStatus(block, picked);
    if (picked == 'pause') engine.setPauseAfter(block, !pause);
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final plan = engine.plan!;
    final c = context.colors;
    final total = plan.blocks.length;
    final done = engine.doneCount;
    final ratio = total == 0 ? 0.0 : done / total;
    final finished = engine.phase == LoopPhase.finished;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProgressSummary(
          title: widget.planName,
          ratio: ratio,
          label: '$done di $total blocchi completati',
          color: finished ? c.success : null,
        ),
        Expanded(
          flex: 3,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
            children: [
              for (final bucket in _Bucket.values)
                if (plan.blocks.where((b) => _bucketOf(b) == bucket).toList() case final blocks
                    when blocks.isNotEmpty) ...[
                  _groupTitle(
                    bucket,
                    blocks,
                    first: bucket == _Bucket.values.firstWhere((x) => plan.blocks.any((b) => _bucketOf(b) == x)),
                  ),
                  if (!_closed.contains(bucket.label))
                    for (final (k, b) in blocks.indexed)
                      _TimelineItem(
                        engine: engine,
                        block: b,
                        isFirst: k == 0,
                        isLast: k == blocks.length - 1,
                        selected: _selected == b.index,
                        // Selecting a block shows its invocations in the activity log;
                        // a second click drops the selection.
                        onTap: () {
                          if (_selected == b.index) {
                            setState(() => _selected = null);
                            return;
                          }
                          setState(() => _selected = b.index);
                          if (engine.blockState(b).attempts > 0) widget.onShowInLog?.call(b);
                        },
                        onDeselect: () {
                          if (_selected == b.index) setState(() => _selected = null);
                        },
                        onContextMenu: (pos) => _contextMenu(pos, b),
                      ),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Icon(icon, size: 17, color: c.muted),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13.5, color: c.text),
          ),
        ),
      ],
    );
  }
}

/// Opens once every block is done: what the whole plan took.
Future<void> showPlanCompleted(BuildContext context, LoopEngine engine) {
  final c = context.colors;
  final s = engine.state!;
  Widget stat(String value, String label) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
      ],
    ),
  );
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: c.success.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(Icons.celebration_outlined, size: 26, color: c.success),
              ),
              const SizedBox(height: 14),
              Text(
                'Piano completato',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text),
              ),
              const SizedBox(height: 4),
              Text(
                'Tutti i ${engine.plan!.blocks.length} blocchi sono stati svolti.',
                style: TextStyle(fontSize: 13, color: c.muted),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  stat(_duration(engine.totalTime.inSeconds), 'tempo'),
                  stat(_tokens(s.totalTokens), 'token'),
                  stat('${s.runs}', s.runs == 1 ? 'invocazione' : 'invocazioni'),
                  stat('${s.commits}', 'commit'),
                ],
              ),
              const SizedBox(height: 22),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TimelineItem extends StatefulWidget {
  const _TimelineItem({
    required this.engine,
    required this.block,
    required this.isFirst,
    required this.isLast,
    required this.selected,
    required this.onTap,
    required this.onDeselect,
    required this.onContextMenu,
  });

  final LoopEngine engine;
  final PlanBlock block;
  final bool isFirst, isLast, selected;
  final VoidCallback onTap, onDeselect;
  final ValueChanged<Offset> onContextMenu;

  @override
  State<_TimelineItem> createState() => _TimelineItemState();
}

class _TimelineItemState extends State<_TimelineItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine, block = widget.block, selected = widget.selected;
    final isFirst = widget.isFirst, isLast = widget.isLast;
    final c = context.colors;
    final state = engine.blockState(block);
    final current = engine.currentBlock == block.index && engine.isActive;
    final running = current && engine.runStartedAt != null;
    final done = state.status == BlockStatus.done;
    final lineColor = done ? c.success.withValues(alpha: 0.45) : c.border;
    final seconds = _blockSeconds(engine, block);
    // The same numbers for every block, as icons; the state in words only
    // when the node alone does not say it.
    final stats = <IconStat>[
      if (state.attempts > 0) IconStat(Icons.replay_rounded, '${state.attempts}', _invocations(state.attempts)),
      if (seconds > 0) IconStat(Icons.schedule_rounded, _duration(seconds), 'Durata'),
      if (state.totalTokens > 0)
        IconStat(
          Icons.toll_outlined,
          _tokens(state.totalTokens),
          'Token: ${_tokens(state.inputTokens)} in / ${_tokens(state.outputTokens)} out',
        ),
    ];
    final String? status = current
        ? (running ? 'In corso' : 'In attesa del richiamo')
        : switch (state.status) {
            BlockStatus.pending => state.attempts > 0 ? 'Da riprendere' : null,
            BlockStatus.done => state.attempts > 0 ? null : 'Segnato a mano',
            BlockStatus.blocked => state.attempts > 0 ? null : 'Bloccato',
            BlockStatus.skipped => 'Saltato',
          };
    final subColor = current ? c.primary : c.muted;
    final Widget? subtitle = status == null && stats.isEmpty
        ? null
        // Fixed height: the tile measures its rows, and a LayoutBuilder
        // cannot be measured in advance.
        : SizedBox(
            height: 18,
            child: LayoutBuilder(
              builder: (context, box) {
                // The state comes first; numbers that do not fit are left out,
                // last first, instead of overflowing.
                final style = TextStyle(fontSize: 11.5, color: subColor);
                var used = status == null ? 0.0 : IconStat.textWidth(context, '$status –', style) + 16;
                final shown = <IconStat>[];
                for (final s in stats) {
                  final w = s.width(context) + (shown.isEmpty ? 0 : 12);
                  if (used + w > box.maxWidth) break;
                  used += w;
                  shown.add(s);
                }
                return Row(
                  children: [
                    if (status != null)
                      Flexible(
                        child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                      ),
                    if (status != null && shown.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text('–', style: style),
                      ),
                    for (final (i, w) in shown.indexed) ...[if (i > 0) const SizedBox(width: 12), w],
                  ],
                );
              },
            ),
          );
    // The buttons show on hover and on the selected block; the stop asked
    // for after this block stays in view, so it is not forgotten.
    final showActions = _hover || selected;
    final pause = state.pauseAfter;
    // The stop asked for after this block: a plain red hand, no background.
    final pauseMark = Tooltip(
      message: 'Si fermerà dopo questo blocco',
      child: Icon(Icons.pan_tool_outlined, size: 16, color: c.danger),
    );
    // One button for all the block's options, in a menu.
    final more = Builder(
      builder: (context) => IconButton(
        tooltip: 'Opzioni del blocco',
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        color: c.muted,
        icon: const Icon(Icons.more_horiz_rounded),
        onPressed: () {
          // Opening a block's options selects it.
          if (!selected) widget.onTap();
          final box = context.findRenderObject()! as RenderBox;
          widget.onContextMenu(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
        },
      ),
    );
    // What the tile looks like behind the buttons, so they sit on it cleanly.
    // Selected and hovered stack up, as they do on the tile itself.
    var tileColor = c.surface;
    if (selected) tileColor = Color.alphaBlend(c.primarySoft, tileColor);
    if (_hover) tileColor = Color.alphaBlend(Theme.of(context).hoverColor, tileColor);

    final tile = GestureDetector(
      onSecondaryTapUp: (d) => widget.onContextMenu(d.globalPosition),
      child: Material(
        color: selected ? c.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onTap,
          onHover: (h) => setState(() => _hover = h),
          child: Stack(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The line runs behind; the node sits on top of it.
                    SizedBox(
                      width: 44,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Column(
                            children: [
                              Expanded(child: Container(width: 2, color: isFirst ? Colors.transparent : lineColor)),
                              Expanded(child: Container(width: 2, color: isLast ? Colors.transparent : lineColor)),
                            ],
                          ),
                          _Node(index: block.index, status: state.status, running: current),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(4, 12, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              // Numbered like in the activity log: the disc may
                              // show a tick or a "!" instead of the number.
                              '${block.index + 1}. ${block.title}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.3,
                                fontWeight: current || selected ? FontWeight.w700 : FontWeight.w500,
                                color: state.status == BlockStatus.skipped ? c.muted : c.text,
                                decoration: state.status == BlockStatus.skipped ? TextDecoration.lineThrough : null,
                              ),
                            ),
                            if (subtitle != null) ...[const SizedBox(height: 3), subtitle],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // On the right end of the tile: the hand when the loop is to stop
              // after this block, and on hover or when selected the options
              // button, which pushes the hand to its left. They come over the
              // tile, so the title keeps all its room.
              if (pause || showActions)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  // A fade, then the tile's colour all behind the hand and the
                  // button: the text underneath is hidden well before them.
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [tileColor.withValues(alpha: 0), tileColor]),
                        ),
                      ),
                      Container(
                        padding: EdgeInsets.fromLTRB(10, 0, showActions ? 4 : 12, 0),
                        decoration: BoxDecoration(
                          color: tileColor,
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (pause) pauseMark,
                            if (showActions) ...[if (pause) const SizedBox(width: 10), more],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    // A click anywhere else drops the selection.
    return selected ? TapRegion(onTapOutside: (_) => widget.onDeselect(), child: tile) : tile;
  }
}

class _Node extends StatelessWidget {
  const _Node({required this.index, required this.status, required this.running});
  final int index;
  final BlockStatus status;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const size = 26.0;
    if (running) {
      // Opaque disc behind the ring, so the line does not show through it.
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(strokeWidth: 2.4, color: c.primary, backgroundColor: c.primarySoft),
            Text(
              '${index + 1}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.primary),
            ),
          ],
        ),
      );
    }
    // Filled discs without border; the number sits exactly in the middle.
    final number = Text(
      '${index + 1}',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        height: 1,
        fontWeight: FontWeight.w700,
        color: c.text.withValues(alpha: 0.8),
        leadingDistribution: TextLeadingDistribution.even,
      ),
      textHeightBehavior: const TextHeightBehavior(applyHeightToFirstAscent: false, applyHeightToLastDescent: false),
    );
    final (Color bg, Widget child) = switch (status) {
      // Icons in coloured discs take the background colour, like the others.
      BlockStatus.done => (c.success, Icon(Icons.check_rounded, size: 16, color: c.background)),
      BlockStatus.blocked => (c.danger, Icon(Icons.priority_high_rounded, size: 15, color: c.background)),
      BlockStatus.skipped => (
        Color.alphaBlend(c.muted.withValues(alpha: 0.18), c.surface),
        Icon(Icons.redo_rounded, size: 14, color: c.muted),
      ),
      // Solid, so the line behind does not show through.
      BlockStatus.pending => (Color.alphaBlend(c.muted.withValues(alpha: 0.28), c.surface), number),
    };
    // Grey discs look smaller than coloured ones of the same size.
    final grey = status == BlockStatus.pending || status == BlockStatus.skipped;
    return Container(
      width: grey ? size + 3 : size,
      height: grey ? size + 3 : size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: child,
    );
  }
}

/// A small solid grey disc with an icon, like the nodes of blocks to do.
Widget _greyDisc(AppColors c, IconData icon) => Container(
  width: 15,
  height: 15,
  decoration: BoxDecoration(
    color: Color.alphaBlend(c.muted.withValues(alpha: 0.45), c.surface),
    shape: BoxShape.circle,
  ),
  child: Icon(icon, size: 11, color: c.text),
);
