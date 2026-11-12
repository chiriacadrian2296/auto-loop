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
