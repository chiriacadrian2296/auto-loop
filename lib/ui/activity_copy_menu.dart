import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import 'app_theme.dart';
import 'dropdown_menu.dart';

enum ActivityCopyScope {
  selection,
  message,
  invocation,
  block,
  all;

  String get label => switch (this) {
    selection => tr('Copia', 'Copy'),
    message => tr('Copia messaggio', 'Copy message'),
    invocation => tr('Copia invocazione', 'Copy invocation'),
    block => tr('Copia blocco', 'Copy block'),
    all => tr('Copia tutto', 'Copy all'),
  };

  IconData get icon => switch (this) {
    selection => Icons.content_copy_rounded,
    message => Icons.chat_bubble_outline_rounded,
    invocation => Icons.bolt_rounded,
    block => Icons.view_day_outlined,
    all => Icons.select_all_rounded,
  };
}

Future<void> showActivityCopyMenu(
  BuildContext context, {
  required Offset position,
  required Map<ActivityCopyScope, String> content,
}) async {
  final scopes = ActivityCopyScope.values.where(content.containsKey).toList();
  final picked = await showMenu<ActivityCopyScope>(
    context: context,
    position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
    color: context.colors.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 3,
    menuPadding: EdgeInsets.zero,
    shape: dropdownShape(context),
    constraints: BoxConstraints.tightFor(width: actionMenuWidth(context, scopes.map((scope) => scope.label))),
    items: [_ActivityCopyMenuEntry(scopes)],
  );
  if (picked != null) await Clipboard.setData(ClipboardData(text: content[picked]!));
}

class _ActivityCopyMenuEntry extends PopupMenuEntry<ActivityCopyScope> {
  const _ActivityCopyMenuEntry(this.scopes);
  final List<ActivityCopyScope> scopes;

  @override
  double get height => scopes.length * 36 + dropdownPadding.vertical;

  @override
  bool represents(ActivityCopyScope? value) => false;

  @override
  State<_ActivityCopyMenuEntry> createState() => _ActivityCopyMenuEntryState();
}

class _ActivityCopyMenuEntryState extends State<_ActivityCopyMenuEntry> {
  bool _closing = false;

  void _close([ActivityCopyScope? scope]) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.pop(context, scope);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    // The buttons handle their own primary clicks; padding and other mouse
    // buttons dismiss without copying anything.
    onTap: () => _close(),
    onSecondaryTapUp: (_) => _close(),
    onTertiaryTapUp: (_) => _close(),
    child: Padding(
      padding: dropdownPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final scope in widget.scopes)
            MenuItemButton(
              closeOnActivate: false,
              requestFocusOnHover: false,
              overflowAxis: Axis.vertical,
              onPressed: () => _close(scope),
              style: dropdownItemStyle(context),
              leadingIcon: Icon(scope.icon, size: 16),
              child: Text(scope.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    ),
  );
}
