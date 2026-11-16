import 'package:flutter/material.dart';

import '../l10n.dart';
import 'app_theme.dart';

Future<bool?> showConfirmationDialog(
  BuildContext context, {
  required String title,
  required IconData icon,
  required String message,
  required String detail,
  required String confirmLabel,
}) => showDialog<bool>(
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
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
              child: Row(
                children: [
                  Icon(icon, color: c.primary, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.text),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message, style: TextStyle(fontSize: 14, height: 1.45, color: c.text)),
                    const SizedBox(height: 12),
                    Text(detail, style: TextStyle(fontSize: 13, height: 1.4, color: c.muted)),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annulla', 'Cancel'))),
                  const SizedBox(width: 10),
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(confirmLabel)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  },
);
