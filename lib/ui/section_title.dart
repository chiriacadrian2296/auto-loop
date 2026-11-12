import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Width of the open/close arrow; line icons in the activity log are
/// centred on it.
const sectionArrow = 22.0;

/// Column that holds the arrow, so titles start at the same place everywhere.
const sectionGutter = 28.0;

/// Width of the column that holds times, at the right of the activity log.
const sectionTimeWidth = 64.0;

/// The open/close arrow. Closed it points right on a blue square, to stand
/// out as something to click; open it points down on a dark square, like
/// the action buttons of the progress panel.
class SectionChevron extends StatelessWidget {
  const SectionChevron({super.key, required this.open});
  final bool open;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: sectionArrow,
      height: sectionArrow,
      decoration: BoxDecoration(color: open ? c.field : c.primary, borderRadius: BorderRadius.circular(6)),
      child: AnimatedRotation(
        turns: open ? 0 : -0.25,
        duration: const Duration(milliseconds: 160),
        child: Icon(Icons.expand_more_rounded, size: 18, color: open ? c.muted : Colors.white),
      ),
    );
  }
}

/// The title of something that opens and closes — a block in the activity
/// log, a group of blocks in the progress panel — so that all of them look
/// and behave the same: arrow, title, an optional outcome icon, and the
/// numbers lined up on the right (with the time, where there is one).
class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    required this.open,
    required this.onTap,
    this.badge,
    this.stats = const [],
    this.time,
    this.titleColor,
    this.highlighted = false,
    this.icon,
    this.iconIndent = 0,
  });

  /// Shown in the column of the line icons, [iconIndent] after the arrow.
  final Widget? icon;
  final double iconIndent;
  final String title;
  final bool open, highlighted;
  final VoidCallback onTap;
  final Widget? badge;
  final List<IconStat> stats;

  /// Shown in the time column, aligned with the times of the lines.
  final String? time;
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
          // The title takes what the numbers leave; numbers that do not fit
          // next to a readable title are left out, the last ones first.
          child: LayoutBuilder(
            builder: (context, box) {
              final room =
                  box.maxWidth -
                  sectionGutter -
                  (icon == null ? 0 : iconIndent + sectionGutter) -
                  (time == null ? 0 : sectionTimeWidth) -
                  (badge == null ? 0 : 26) -
                  120;
              final shown = fitStats(context, stats, room);
              return Row(
                children: [
                  SizedBox(
                    width: sectionGutter,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SectionChevron(open: open),
                    ),
                  ),
                  if (icon != null) ...[
                    SizedBox(width: iconIndent),
                    SizedBox(
                      width: sectionGutter,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: sectionArrow,
                          child: Center(child: icon),
                        ),
                      ),
                    ),
                  ],
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: titleColor ?? c.text),
                          ),
                        ),
                        if (badge != null) ...[const SizedBox(width: 10), badge!],
                      ],
                    ),
                  ),
                  for (final (i, w) in shown.indexed) ...[SizedBox(width: i == 0 ? 12 : 14), w],
                  if (time != null) SectionTime(time!),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The stats that fit in [room], in order.
List<IconStat> fitStats(BuildContext context, List<IconStat> stats, double room) {
  var used = 0.0;
  final shown = <IconStat>[];
  for (final s in stats) {
    final w = s.width(context) + (shown.isEmpty ? 12 : 14);
    if (used + w > room) break;
    used += w;
    shown.add(s);
  }
  return shown;
}

/// A time in the time column of the activity log.
class SectionTime extends StatelessWidget {
  const SectionTime(this.time, {super.key});
  final String time;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: sectionTimeWidth,
    child: Text(
      time,
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 11,
        color: context.colors.muted.withValues(alpha: 0.8),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

/// Numbers lined up on the right; those that do not fit are left out,
/// the last ones first.
class RightStats extends StatelessWidget {
  const RightStats({super.key, required this.stats});
  final List<IconStat> stats;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: LayoutBuilder(
        builder: (context, box) {
          var used = 16.0; // room kept from the title, with a little slack
          final shown = <IconStat>[];
          for (final s in stats) {
            final w = s.width(context) + (shown.isEmpty ? 0 : 14);
            if (used + w > box.maxWidth) break;
            used += w;
            shown.add(s);
          }
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
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
