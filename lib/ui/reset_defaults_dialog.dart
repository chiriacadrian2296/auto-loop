import 'package:flutter/material.dart';

import '../l10n.dart';
import 'confirmation_dialog.dart';

Future<bool?> showResetDefaultsDialog(BuildContext context, {required String agent}) => showConfirmationDialog(
  context,
  title: tr('Ripristina predefiniti', 'Restore defaults'),
  icon: Icons.restore_rounded,
  message: tr(
    'Modello, ragionamento, permessi, richiamo, quota, verifica, commit, suddivisione e istruzioni '
        'tornano ai valori di partenza per questo progetto.',
    'Model, reasoning, permissions, relaunch, quota, check, commit, splitting and instructions '
        'go back to their starting values for this project.',
  ),
  detail: tr(
    'Agente e account restano $agent e il profilo scelto.',
    'Agent and account stay $agent and the chosen profile.',
  ),
  confirmLabel: tr('Ripristina', 'Restore'),
);
