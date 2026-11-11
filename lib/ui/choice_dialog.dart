import 'package:flutter/material.dart';

import 'app_theme.dart';

class Choice<T> {
  const Choice({
    required this.value,
    required this.label,
    this.tag = '',
    this.description = '',
    this.accent = false,
    this.short,
  });
  final T value;
  final String label;

  /// Short technical name shown next to the label (model id, CLI value).
  final String tag;
  final String description;
  /// One-line summary shown on the card; the full description stays in the popup.
  final String? short;

  String get cardText => short ?? description;

  /// Rendered as an action rather than an option (e.g. "Altro modello…").
  final bool accent;
}

/// A centred popup listing [choices]; returns the picked value, or null when
/// dismissed.
Future<T?> showChoiceDialog<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required List<Choice<T>> choices,
  required T selected,
}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (context) {
      final c = context.colors;
      return Dialog(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(32),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: c.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 12, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.text)),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(subtitle, style: TextStyle(fontSize: 12.5, color: c.muted)),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      iconSize: 18,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
                  children: [
                    for (final choice in choices)
                      _ChoiceRow(
                        choice: choice,
                        selected: !choice.accent && choice.value == selected,
                        onTap: () => Navigator.pop(context, choice.value),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({required this.choice, required this.selected, required this.onTap});
  final Choice<T> choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? c.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          hoverColor: c.field,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              choice.label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: choice.accent || selected ? c.primary : c.text,
                              ),
                            ),
                          ),
                          if (choice.tag.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(choice.tag,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: c.muted,
                                  fontFamily: mono,
                                  fontFamilyFallback: monoFallback,
                                )),
                          ],
                        ],
                      ),
                      if (choice.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(choice.description,
                            style: TextStyle(fontSize: 12, height: 1.35, color: c.muted)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (selected)
                  Icon(Icons.check_circle_rounded, size: 20, color: c.primary)
                else if (choice.accent)
                  Icon(Icons.edit_outlined, size: 18, color: c.primary)
                else
                  const SizedBox(width: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
