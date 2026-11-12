import 'package:flutter/material.dart';

import '../engine/loop_engine.dart';
import '../engine/loop_state.dart';
import '../engine/plan_parser.dart';
import 'app_theme.dart';

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

  @override
  State<BlocksPanel> createState() => _BlocksPanelState();
}

class _BlocksPanelState extends State<BlocksPanel> {
  int? _selected;

  Future<void> _contextMenu(Offset position, PlanBlock block) async {
    final engine = widget.engine;
    final status = engine.blockState(block).status;
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
      ],
    );
    if (!mounted || picked == null) return;
    if (picked is BlockStatus) engine.setBlockStatus(block, picked);
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
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.planName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: ratio),
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOutCubic,
                        builder: (context, v, _) => LinearProgressIndicator(
                          value: v,
                          minHeight: 8,
                          backgroundColor: c.primarySoft,
                          color: c.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${(ratio * 100).round()}%',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: c.primary),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('$done di $total blocchi completati', style: TextStyle(fontSize: 12, color: c.muted)),
            ],
          ),
        ),
        if (finished) _Summary(engine: engine),
        const SizedBox(height: 6),
        Expanded(
          flex: 3,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
            itemCount: total,
            itemBuilder: (context, i) {
              final b = plan.blocks[i];
              return _TimelineItem(
                engine: engine,
                block: b,
                isFirst: i == 0,
                isLast: i == total - 1,
                selected: _selected == i,
                // Selecting a block shows its invocations in the activity log.
                onTap: () {
                  setState(() => _selected = i);
                  if (engine.blockState(b).attempts > 0) widget.onShowInLog?.call(b);
                },
                onContextMenu: (pos) => _contextMenu(pos, b),
              );
            },
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
        Text(label, style: TextStyle(fontSize: 13.5, color: c.text)),
      ],
    );
  }
}

/// Shown above the list once every block is done: what the whole plan took.
class _Summary extends StatelessWidget {
  const _Summary({required this.engine});
  final LoopEngine engine;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = engine.state!;
    Widget stat(String value, String label) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text),
          ),
          Text(label, style: TextStyle(fontSize: 11.5, color: c.muted)),
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: c.success.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.celebration_outlined, size: 18, color: c.success),
              const SizedBox(width: 8),
              Text(
                'Piano completato',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.success),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              stat(_duration(engine.totalTime.inSeconds), 'tempo'),
              stat(_tokens(s.totalTokens), 'token'),
              stat('${s.runs}', s.runs == 1 ? 'invocazione' : 'invocazioni'),
              stat('${s.commits}', s.commits == 1 ? 'commit' : 'commit'),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.engine,
    required this.block,
    required this.isFirst,
    required this.isLast,
    required this.selected,
    required this.onTap,
    required this.onContextMenu,
  });

  final LoopEngine engine;
  final PlanBlock block;
  final bool isFirst, isLast, selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onContextMenu;

  @override
  Widget build(BuildContext context) {
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
    final actions = _actionsFor(state.status);

    return GestureDetector(
      onSecondaryTapUp: (d) => onContextMenu(d.globalPosition),
      child: Material(
        color: selected ? c.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: IntrinsicHeight(
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
                          block.title,
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
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (label, icon, target) in actions) ...[
                        const SizedBox(width: 4),
                        _ActionButton(
                          icon: icon,
                          tooltip: label,
                          onPressed: engine.isActive ? null : () => engine.setBlockStatus(block, target),
                        ),
                      ],
                    ],
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
      BlockStatus.done => (c.success, const Icon(Icons.check_rounded, size: 16, color: Colors.white)),
      BlockStatus.blocked => (c.danger, const Icon(Icons.priority_high_rounded, size: 15, color: Colors.white)),
      BlockStatus.skipped => (
        Color.alphaBlend(c.muted.withValues(alpha: 0.18), c.surface),
        Icon(Icons.redo_rounded, size: 14, color: c.muted),
      ),
      // Solid, so the line behind does not show through.
      BlockStatus.pending => (Color.alphaBlend(c.muted.withValues(alpha: 0.28), c.surface), number),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: child,
    );
  }
}

/// Small square button with a tinted background, one per available action.
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 16,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(30),
        minimumSize: const Size.square(30),
        padding: EdgeInsets.zero,
        backgroundColor: c.field,
        foregroundColor: c.muted,
        disabledBackgroundColor: c.field.withValues(alpha: 0.5),
        disabledForegroundColor: c.muted.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon),
    );
  }
}
