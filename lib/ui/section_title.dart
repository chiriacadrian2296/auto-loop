import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Width of the open/close arrow; line icons in the activity log are
/// centred on it.
const sectionArrow = 22.0;

/// Column that holds the arrow, so titles start at the same place everywhere.
const sectionGutter = 28.0;

/// The open/close arrow on a dark square, like the action buttons of the
/// progress panel.
class SectionChevron extends StatelessWidget {
  const SectionChevron({super.key, required this.open});
  final bool open;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedRotation(
      turns: open ? 0 : -0.25,
      duration: const Duration(milliseconds: 160),
      child: Container(
        width: sectionArrow,
        height: sectionArrow,
        decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(6)),
        child: Icon(Icons.expand_more_rounded, size: 18, color: c.muted),
      ),
    );
  }
}

/// The title of something that opens and closes — a block in the activity
/// log, a group of blocks in the progress panel, a section of the control
/// panel — so that all of them look and behave the same: arrow, title, an
/// optional outcome icon, then after a dash either numbers or a summary.
class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    required this.open,
    required this.onTap,
    this.badge,
    this.stats = const [],
    this.summary,
    this.titleColor,
    this.highlighted = false,
  });
  final String title;
  final bool open, highlighted;
  final VoidCallback onTap;
  final Widget? badge;
  final List<IconStat> stats;
  final String? summary;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: highlighted ? c.primarySoft : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
          child: Row(
            children: [
              SizedBox(
                width: sectionGutter,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SectionChevron(open: open),
                ),
              ),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: titleColor ?? c.text),
                ),
              ),
              if (badge != null) ...[const SizedBox(width: 10), badge!],
              if (summary != null)
                Expanded(
                  child: Row(
                    children: [
                      const _Dash(),
                      Flexible(
                        child: Text(
                          summary!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: c.muted),
                        ),
                      ),
                    ],
                  ),
                )
              else
                StatsAfterDash(stats: stats),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dash extends StatelessWidget {
  const _Dash();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Text('–', style: TextStyle(fontSize: 12.5, color: context.colors.muted)),
  );
}

/// "– icon value  icon value", leaving out the stats that do not fit.
class StatsAfterDash extends StatelessWidget {
  const StatsAfterDash({super.key, required this.stats});
  final List<IconStat> stats;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: LayoutBuilder(
        builder: (context, box) {
          var used = 36.0; // dash and its padding, with a little slack
          final shown = <IconStat>[];
          for (final s in stats) {
            final w = s.width(context) + (shown.isEmpty ? 0 : 14);
            if (used + w > box.maxWidth) break;
            used += w;
            shown.add(s);
          }
          if (shown.isEmpty) return const SizedBox.shrink();
          return Row(
            children: [
              const _Dash(),
              for (final (i, w) in shown.indexed) ...[if (i > 0) const SizedBox(width: 14), w],
            ],
          );
        },
      ),
    );
  }
}

/// The summary under a panel's title: a name, a bar with its percentage and
/// a line saying "N of M …". The same in every panel.
class ProgressSummary extends StatelessWidget {
  const ProgressSummary({
    super.key,
    required this.title,
    required this.ratio,
    required this.label,
    this.color,
    this.tooltip,
  });
  final String title, label;
  final double ratio;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = color ?? c.primary;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
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
                    tween: Tween(end: ratio.clamp(0.0, 1.0)),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => LinearProgressIndicator(
                      value: v,
                      minHeight: 8,
                      backgroundColor: tint.withValues(alpha: 0.15),
                      color: tint,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${(ratio.clamp(0.0, 1.0) * 100).round()}%',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: tint),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(fontSize: 12, color: c.muted)),
        ],
      ),
    );
    return tooltip == null ? body : Tooltip(message: tooltip!, child: body);
  }
}

/// Opens or closes every section of a panel, for its title bar.
class ExpandAllButton extends StatelessWidget {
  const ExpandAllButton({super.key, required this.allOpen, required this.onPressed});
  final bool allOpen;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: allOpen ? 'Comprimi tutto' : 'Espandi tutto',
    onPressed: onPressed,
    iconSize: 19,
    icon: Icon(allOpen ? Icons.unfold_less_rounded : Icons.unfold_more_rounded),
  );
}
