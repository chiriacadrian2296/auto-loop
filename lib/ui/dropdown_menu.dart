import 'package:flutter/material.dart';

import 'app_theme.dart';

const dropdownPadding = EdgeInsets.all(6);

RoundedRectangleBorder dropdownShape(BuildContext context) => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(12),
  side: BorderSide(color: context.colors.border),
);

MenuStyle dropdownStyle(BuildContext context) => MenuStyle(
  backgroundColor: WidgetStatePropertyAll(context.colors.surface),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  elevation: const WidgetStatePropertyAll(3),
  padding: const WidgetStatePropertyAll(dropdownPadding),
  shape: WidgetStatePropertyAll(dropdownShape(context)),
);

ButtonStyle dropdownItemStyle(BuildContext context, {bool selected = false}) {
  final c = context.colors;
  return MenuItemButton.styleFrom(
    backgroundColor: Colors.transparent,
    foregroundColor: c.text,
    iconColor: selected ? c.primary : c.muted,
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    textStyle: const TextStyle(fontSize: 13.5, fontFamily: uiFont, fontFamilyFallback: uiFallback),
  );
}

double actionMenuWidth(BuildContext context, Iterable<String> labels) {
  final style = dropdownItemStyle(context).textStyle!.resolve({});
  var longest = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    if (painter.width > longest) longest = painter.width;
    painter.dispose();
  }
  final iconGap = (12 + Theme.of(context).visualDensity.horizontal * 2).clamp(4.0, double.infinity);
  final width = (longest + dropdownPadding.horizontal + 24 + 16 + iconGap).ceilToDouble();
  return width.clamp(0.0, (MediaQuery.sizeOf(context).width - 32).clamp(0.0, double.infinity));
}

/// The same menu rows for a position-based context menu and a MenuAnchor.
class ActionMenuEntry<T> extends PopupMenuEntry<T> {
  const ActionMenuEntry({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    this.enabled = true,
    this.selected = false,
  });
  final T value;
  final String label;
  final IconData icon;
  final bool enabled, selected;

  @override
  double get height => 36;

  @override
  bool represents(T? value) => this.value == value;

  @override
  State<ActionMenuEntry<T>> createState() => _ActionMenuEntryState<T>();
}

class _ActionMenuEntryState<T> extends State<ActionMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => MenuItemButton(
    closeOnActivate: false,
    overflowAxis: Axis.vertical,
    onPressed: widget.enabled ? () => Navigator.pop(context, widget.value) : null,
    style: dropdownItemStyle(context, selected: widget.selected),
    leadingIcon: Icon(widget.icon, size: 16),
    child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}
