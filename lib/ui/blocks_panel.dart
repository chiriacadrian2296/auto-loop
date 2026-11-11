import 'package:flutter/material.dart';

import '../engine/loop_engine.dart';
import '../engine/loop_state.dart';
import '../engine/plan_parser.dart';
import 'app_theme.dart';

class BlocksPanel extends StatefulWidget {
  const BlocksPanel({super.key, required this.engine, required this.planName});
  final LoopEngine engine;
  final String planName;

  @override
  State<BlocksPanel> createState() => _BlocksPanelState();
}

class _BlocksPanelState extends State<BlocksPanel> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final plan = engine.plan!;
    final c = context.colors;
    final total = plan.blocks.length;
    final done = engine.doneCount;
    final ratio = total == 0 ? 0.0 : done / total;
    final selected = _selected != null && _selected! < total ? plan.blocks[_selected!] : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel('Avanzamento'),
              const SizedBox(height: 8),
              Text(
                widget.planName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.text, letterSpacing: -0.2),
              ),
              const SizedBox(height: 2),
              Text(
                '$total blocchi · ${plan.strategy.label.toLowerCase()}',
                style: TextStyle(fontSize: 12.5, color: c.muted),
              ),
              const SizedBox(height: 14),
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
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          flex: 3,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
            itemCount: total,
            itemBuilder: (context, i) {
              final b = plan.blocks[i];
              final s = engine.blockState(b);
              return _TimelineItem(
                index: i,
                title: b.title,
                state: s,
                running: engine.currentBlock == i && engine.isActive,
                isFirst: i == 0,
                isLast: i == total - 1,
                selected: _selected == i,
                onTap: () => setState(() => _selected = _selected == i ? null : i),
              );
            },
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: selected == null
              ? const SizedBox(width: double.infinity)
              : SizedBox(
                  height: 260,
                  child: _BlockDetail(engine: engine, block: selected, onClose: () => setState(() => _selected = null)),
                ),
        ),
      ],
    );
  }
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.index,
    required this.title,
    required this.state,
    required this.running,
    required this.isFirst,
    required this.isLast,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final String title;
  final BlockState state;
  final bool running, isFirst, isLast, selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final done = state.status == BlockStatus.done;
    final lineColor = done ? c.primary.withValues(alpha: 0.45) : c.border;
    final subtitle = running
        ? 'In corso · invocazione ${state.attempts}'
        : switch (state.status) {
            BlockStatus.pending => state.attempts > 0 ? 'Da riprendere · ${state.attempts} invocazioni' : null,
            BlockStatus.done => state.attempts > 0 ? 'Completato · ${state.attempts} invocazioni' : 'Completato',
            BlockStatus.blocked => 'Bloccato',
            BlockStatus.skipped => 'Saltato',
          };
    return Material(
      color: selected ? c.primarySoft : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 44,
                child: Column(
                  children: [
                    Expanded(child: Container(width: 2, color: isFirst ? Colors.transparent : lineColor)),
                    _Node(index: index, status: state.status, running: running),
                    Expanded(child: Container(width: 2, color: isLast ? Colors.transparent : lineColor)),
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
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.3,
                          fontWeight: running || selected ? FontWeight.w700 : FontWeight.w500,
                          color: state.status == BlockStatus.skipped ? c.muted : c.text,
                          decoration: state.status == BlockStatus.skipped ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: running
                                ? c.primary
                                : state.status == BlockStatus.blocked
                                ? c.danger
                                : c.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
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
      return SizedBox.square(
        dimension: size,
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
    final (Color bg, Color fg, Color border, Widget child) = switch (status) {
      BlockStatus.done => (
        c.primary,
        Colors.white,
        c.primary,
        const Icon(Icons.check_rounded, size: 16, color: Colors.white),
      ),
      BlockStatus.blocked => (
        c.danger,
        Colors.white,
        c.danger,
        const Icon(Icons.priority_high_rounded, size: 15, color: Colors.white),
      ),
      BlockStatus.skipped => (c.field, c.muted, c.border, Icon(Icons.redo_rounded, size: 14, color: c.muted)),
      BlockStatus.pending => (
        c.surface,
        c.muted,
        c.border,
        Text(
          '${index + 1}',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.muted),
        ),
      ),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 1.6),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: fg),
        child: child,
      ),
    );
  }
}

class _BlockDetail extends StatelessWidget {
  const _BlockDetail({required this.engine, required this.block, required this.onClose});
  final LoopEngine engine;
  final PlanBlock block;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = engine.blockState(block);
    final locked = engine.isActive;
    return Container(
      decoration: BoxDecoration(
        color: c.field,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Blocco ${block.index + 1}',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: c.text),
                  ),
                ),
                if (s.status != BlockStatus.done)
                  _Action(
                    'Completato',
                    Icons.check_rounded,
                    locked ? null : () => engine.setBlockStatus(block, BlockStatus.done),
                  ),
                if (s.status != BlockStatus.pending)
                  _Action(
                    'In coda',
                    Icons.replay_rounded,
                    locked ? null : () => engine.setBlockStatus(block, BlockStatus.pending),
                  ),
                if (s.status == BlockStatus.pending)
                  _Action(
                    'Salta',
                    Icons.redo_rounded,
                    locked ? null : () => engine.setBlockStatus(block, BlockStatus.skipped),
                  ),
                IconButton(
                  onPressed: onClose,
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
              children: [
                if (s.note.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: s.status == BlockStatus.blocked ? c.danger.withValues(alpha: 0.08) : c.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: c.border),
                    ),
                    child: SelectableText(s.note, style: TextStyle(fontSize: 12.5, height: 1.4, color: c.text)),
                  ),
                  const SizedBox(height: 10),
                ],
                SelectableText(
                  block.body,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: c.muted,
                    fontFamily: mono,
                    fontFamilyFallback: monoFallback,
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

class _Action extends StatelessWidget {
  const _Action(this.label, this.icon, this.onPressed);
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        fontFamily: uiFont,
        fontFamilyFallback: uiFallback,
      ),
    ),
    icon: Icon(icon, size: 16),
    label: Text(label),
  );
}
