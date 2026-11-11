import 'package:flutter/material.dart';

import '../engine/loop_engine.dart';
import '../engine/loop_state.dart';
import '../engine/plan_parser.dart';
import 'app_theme.dart';

/// Joins the non-empty parts with a middle dot.
String _join(List<String> parts) => parts.where((p) => p.isNotEmpty).join(' · ');

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
    ? '${(n / 1000).toStringAsFixed(1)}k'
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
  const BlocksPanel({super.key, required this.engine, required this.planName});
  final LoopEngine engine;
  final String planName;

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
        PopupMenuItem(value: 'details', height: 40, child: _MenuRow(Icons.info_outline_rounded, 'Mostra dettagli')),
        const PopupMenuDivider(height: 8),
        for (final (label, icon, target) in _actionsFor(status))
          PopupMenuItem(value: target, height: 40, enabled: !engine.isActive, child: _MenuRow(icon, label)),
      ],
    );
    if (!mounted || picked == null) return;
    if (picked == 'details') {
      setState(() => _selected = block.index);
    } else if (picked is BlockStatus) {
      engine.setBlockStatus(block, picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final plan = engine.plan!;
    final c = context.colors;
    final total = plan.blocks.length;
    final done = engine.doneCount;
    final ratio = total == 0 ? 0.0 : done / total;
    final selected = _selected != null && _selected! < total ? plan.blocks[_selected!] : null;
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
                onTap: () => setState(() => _selected = _selected == i ? null : i),
                onContextMenu: (pos) => _contextMenu(pos, b),
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
                  height: 300,
                  child: _BlockDetail(engine: engine, block: selected, onClose: () => setState(() => _selected = null)),
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
    final lineColor = done ? c.primary.withValues(alpha: 0.45) : c.border;
    final seconds = _blockSeconds(engine, block);
    final note = state.note.split('\n').first.trim();

    // What is useful to know about the block at a glance, by state.
    final (String? subtitle, Color subColor) = current
        ? (
            running
                ? _join(['In corso', _duration(seconds), _invocations(state.attempts)])
                : 'In attesa del richiamo · ${_invocations(state.attempts)}',
            c.primary,
          )
        : switch (state.status) {
            BlockStatus.pending => (
              state.attempts > 0 ? _join(['Da riprendere', _invocations(state.attempts), _duration(seconds)]) : null,
              c.muted,
            ),
            BlockStatus.done => (
              state.attempts > 0 ? _join([_invocations(state.attempts), _duration(seconds)]) : 'Segnato a mano',
              c.muted,
            ),
            BlockStatus.blocked => (note.isEmpty ? 'Bloccato' : note, c.danger),
            BlockStatus.skipped => ('Saltato', c.muted),
          };

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
                SizedBox(
                  width: 44,
                  child: Column(
                    children: [
                      Expanded(child: Container(width: 2, color: isFirst ? Colors.transparent : lineColor)),
                      _Node(index: block.index, status: state.status, running: current),
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
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: subColor),
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

/// The selected block: what came out of it, what it asks, and what can be
/// done with it.
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
    final (String status, Color statusColor) = switch (s.status) {
      BlockStatus.done => ('Completato', c.success),
      BlockStatus.blocked => ('Bloccato', c.danger),
      BlockStatus.skipped => ('Saltato', c.muted),
      BlockStatus.pending => (s.attempts > 0 ? 'Da riprendere' : 'Da fare', c.muted),
    };
    // The block's own heading repeats the title shown above: leave it out.
    final lines = block.body.split('\n');
    final task = (lines.isNotEmpty && lines.first.contains(block.title) ? lines.skip(1) : lines).join('\n').trim();

    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: c.muted),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: c.field,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Blocco ${block.index + 1} · ${block.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: c.text),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: statusColor),
                  ),
                ),
                IconButton(
                  tooltip: 'Chiudi',
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
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
              children: [
                if (s.attempts > 0) ...[
                  Text(
                    _join([
                      _invocations(s.attempts),
                      _duration(_blockSeconds(engine, block)),
                      if (s.totalTokens > 0) '${_tokens(s.totalTokens)} token',
                    ]),
                    style: TextStyle(fontSize: 12, color: c.muted),
                  ),
                  const SizedBox(height: 12),
                ],
                label('Esito'),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: s.status == BlockStatus.blocked ? c.danger.withValues(alpha: 0.08) : c.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: c.border),
                  ),
                  child: SelectableText(
                    s.note.isNotEmpty
                        ? s.note
                        : switch (s.status) {
                            BlockStatus.done => 'Completato, senza un riepilogo dell\'agente.',
                            BlockStatus.skipped => 'Saltato.',
                            _ when s.attempts > 0 => 'L\'agente non ha ancora concluso questo blocco.',
                            _ => 'Non ancora iniziato.',
                          },
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: s.note.isEmpty ? c.muted : c.text),
                  ),
                ),
                const SizedBox(height: 14),
                label('Compito'),
                SelectableText(
                  task.isEmpty ? block.title : task,
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: c.text),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (text, icon, target) in _actionsFor(s.status))
                  OutlinedButton.icon(
                    onPressed: locked ? null : () => engine.setBlockStatus(block, target),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: c.border),
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        fontFamily: uiFont,
                        fontFamilyFallback: uiFallback,
                      ),
                    ),
                    icon: Icon(icon, size: 16),
                    label: Text(text),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
