import 'package:flutter/material.dart';

import '../engine/loop_engine.dart';
import '../engine/loop_state.dart';
import '../engine/plan_parser.dart';

class BlocksPanel extends StatefulWidget {
  const BlocksPanel({super.key, required this.engine});
  final LoopEngine engine;

  @override
  State<BlocksPanel> createState() => _BlocksPanelState();
}

class _BlocksPanelState extends State<BlocksPanel> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final plan = engine.plan!;
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected != null && _selected! < plan.blocks.length ? plan.blocks[_selected!] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text('Blocchi · ${plan.strategy.label}', style: Theme.of(context).textTheme.titleSmall),
        ),
        if (plan.blocks.length > 1 || engine.doneCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: engine.doneCount / plan.blocks.length,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          flex: 3,
          child: ListView.builder(
            itemCount: plan.blocks.length,
            itemBuilder: (context, i) {
              final b = plan.blocks[i];
              final s = engine.blockState(b);
              final running = engine.currentBlock == i && engine.isActive;
              return ListTile(
                dense: true,
                selected: _selected == i,
                selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.35),
                leading: _StatusIcon(status: s.status, running: running),
                title: Text('${i + 1}. ${b.title}', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: s.attempts > 0 || s.status != BlockStatus.pending
                    ? Text('${s.status.label}${s.attempts > 0 ? ' · ${s.attempts} invocazioni' : ''}')
                    : null,
                onTap: () => setState(() => _selected = _selected == i ? null : i),
              );
            },
          ),
        ),
        if (selected != null) ...[
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(flex: 2, child: _BlockDetail(engine: engine, block: selected)),
        ],
      ],
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.running});
  final BlockStatus status;
  final bool running;

  @override
  Widget build(BuildContext context) {
    if (running) {
      return const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      BlockStatus.pending => Icon(Icons.radio_button_unchecked, color: scheme.outline),
      BlockStatus.done => const Icon(Icons.check_circle, color: Colors.green),
      BlockStatus.blocked => Icon(Icons.block, color: scheme.error),
      BlockStatus.skipped => Icon(Icons.redo, color: scheme.outline),
    };
  }
}

class _BlockDetail extends StatelessWidget {
  const _BlockDetail({required this.engine, required this.block});
  final LoopEngine engine;
  final PlanBlock block;

  @override
  Widget build(BuildContext context) {
    final s = engine.blockState(block);
    final locked = engine.isActive;
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (s.status != BlockStatus.done)
              ActionChip(
                avatar: const Icon(Icons.check, size: 16),
                label: const Text('Segna completato'),
                onPressed: locked ? null : () => engine.setBlockStatus(block, BlockStatus.done),
              ),
            if (s.status != BlockStatus.pending)
              ActionChip(
                avatar: const Icon(Icons.replay, size: 16),
                label: const Text('Rimetti in coda'),
                onPressed: locked ? null : () => engine.setBlockStatus(block, BlockStatus.pending),
              ),
            if (s.status == BlockStatus.pending)
              ActionChip(
                avatar: const Icon(Icons.redo, size: 16),
                label: const Text('Salta'),
                onPressed: locked ? null : () => engine.setBlockStatus(block, BlockStatus.skipped),
              ),
          ],
        ),
        if (s.note.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Nota', style: t.labelMedium),
          SelectableText(s.note, style: t.bodySmall),
        ],
        const SizedBox(height: 12),
        Text('Testo del blocco', style: t.labelMedium),
        const SizedBox(height: 4),
        SelectableText(block.body, style: t.bodySmall?.copyWith(fontFamily: 'Consolas')),
      ],
    );
  }
}
