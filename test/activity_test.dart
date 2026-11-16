import 'package:auto_loop/demo.dart';
import 'package:auto_loop/engine/agents.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auto_loop/ui/app_theme.dart';
import 'package:auto_loop/ui/markdown_text.dart';
import 'package:auto_loop/ui/activity_copy_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:auto_loop/ui/blocks_panel.dart';
import 'package:auto_loop/ui/log_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('agent markdown: lists, bold, code and fences', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(
          body: MarkdownText(
            '## Fatto\n- uno **importante**\n- due con `codice`\n\n```\nflutter test\n```',
            style: TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
    expect(find.textContaining('Fatto'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.textContaining('importante'), findsOneWidget);
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
  });

  test('a click on the chosen line drops it, also after the click-anywhere clear', () {
    final sel = ActivitySelection();
    final a = LogEntry(LogKind.agent, 'a'), b = LogEntry(LogKind.agent, 'b');
    sel.toggle(a, #log);
    expect(sel.entry, same(a));
    // Every click first clears the choice, then reaches the line clicked.
    sel.clearForClick();
    sel.toggle(a, #map);
    expect(sel.entry, isNull);
    sel.clearForClick();
    sel.toggle(b, #map);
    expect(sel.entry, same(b));
  });

  test('log kinds stay distinct for the filters', () {
    expect(LogKind.values, contains(LogKind.warning));
  });

  testWidgets('clicking a block opens its invocations in the log', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copiedText = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final demo = (await tester.runAsync(() => DemoData.create(folder: 'autoloop-demo-activity-test')))!;
    SharedPreferences.setMockInitialValues({'workDir': demo.workDir, 'planPath': demo.planPath});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = LoopEngine(LoopSettings())..demo = true;
    await tester.pumpWidget(AutoLoopApp(engine: engine, prefs: prefs));
    await tester.pump();

    // Single, partial and all filters have distinct toolbar icons.
    await tester.tap(find.byTooltip('Filtra le attività'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Messaggi'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byTooltip('Filtro: Messaggi'), matching: find.byIcon(Icons.chat_bubble_outline_rounded)),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(MenuItemButton, 'Comandi'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byTooltip('Filtro: Messaggi, Comandi'), matching: find.byIcon(Icons.filter_alt_rounded)),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(MenuItemButton, 'Tutto'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byTooltip('Filtra le attività'), matching: find.byIcon(Icons.filter_list_rounded)),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Everything starts open; collapse the log, then a click on the block
    // opens its invocations again.
    const message = 'Le card ora passano a una colonna sotto i 640 px; ho aggiunto i link mancanti.';
    expect(find.textContaining(message, findRichText: true), findsOneWidget);
    final messagePosition = tester.getTopLeft(find.textContaining(message, findRichText: true)) + const Offset(15, 8);
    await tester.tapAt(messagePosition);
    await tester.pumpAndSettle();
    final selection = tester.widget<ActivityMap>(find.byType(ActivityMap)).selection;
    final selected = selection.entry;
    expect(selected, isNotNull);
    var commandPosition = tester.getCenter(find.text('Edit: style.css'));
    Future<void> openCopyMenu(Offset position) async {
      await tester.tapAt(position, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      for (final scope in ActivityCopyScope.values.where((scope) => scope != ActivityCopyScope.selection)) {
        expect(find.widgetWithText(MenuItemButton, scope.label), findsOneWidget);
      }
      expect(selection.entry, same(selected));
    }

    await openCopyMenu(commandPosition);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: commandPosition - const Offset(40, 0));
    await mouse.moveTo(tester.getCenter(find.widgetWithText(MenuItemButton, 'Copia messaggio')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Copia messaggio'), findsOneWidget);
    await mouse.down(tester.getCenter(find.widgetWithText(MenuItemButton, 'Copia messaggio')));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(copiedText, 'Edit: style.css');
    expect(selection.entry, same(selected));
    expect(find.widgetWithText(MenuItemButton, 'Copia messaggio'), findsNothing);
    await mouse.removePointer();

    await openCopyMenu(commandPosition);
    await tester.tap(find.widgetWithText(MenuItemButton, 'Copia invocazione'));
    await tester.pumpAndSettle();
    expect(copiedText, contains(message));
    expect(copiedText, isNot(contains('Write: contatti.js')));

    final activityScroll = find.descendant(of: find.byType(LogPanel), matching: find.byType(Scrollable)).first;
    final scrollPosition = tester.state<ScrollableState>(activityScroll).position;
    scrollPosition.jumpTo(scrollPosition.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Write: contatti.js'));
    await openCopyMenu(tester.getCenter(find.text('Write: contatti.js')));
    await tester.tap(find.widgetWithText(MenuItemButton, 'Copia blocco'));
    await tester.pumpAndSettle();
    expect(copiedText, contains('invocazione 1'));
    expect(copiedText, contains('invocazione 2'));
    expect(copiedText, isNot(contains('Edit: style.css')));

    scrollPosition.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Edit: style.css'));
    commandPosition = tester.getCenter(find.text('Edit: style.css'));
    await openCopyMenu(commandPosition);
    await tester.tap(find.widgetWithText(MenuItemButton, 'Copia tutto'));
    await tester.pumpAndSettle();
    expect(copiedText, contains(message));
    expect(copiedText, contains('Write: contatti.js'));
    expect(selection.entry, same(selected));

    scrollPosition.jumpTo(0);
    await tester.pumpAndSettle();
    for (final (header, action) in [('Invocazione 3', 'Copia invocazione'), ('3. Sezione progetti', 'Copia blocco')]) {
      final headerRow = find.descendant(of: find.byType(LogPanel), matching: find.text(header));
      await tester.tap(headerRow, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Copia messaggio'), findsNothing);
      expect(find.byType(MenuItemButton), findsNWidgets(header == 'Invocazione 3' ? 3 : 2));
      expect(selection.entry, same(selected));
      await tester.tap(find.widgetWithText(MenuItemButton, action));
      await tester.pumpAndSettle();
      expect(copiedText, contains(message));
      expect(copiedText, contains('Edit: style.css'));
      expect(copiedText, isNot(contains('Write: contatti.js')));
    }

    commandPosition = tester.getCenter(find.text('Edit: style.css'));
    // Any click dismisses: padding, a secondary click inside, or outside.
    await openCopyMenu(commandPosition);
    final menu = find.byWidgetPredicate((widget) => widget is PopupMenuEntry<ActivityCopyScope>);
    await tester.tapAt(tester.getTopLeft(menu) + const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Copia messaggio'), findsNothing);
    await openCopyMenu(commandPosition);
    await tester.tapAt(
      tester.getCenter(find.widgetWithText(MenuItemButton, 'Copia messaggio')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Copia messaggio'), findsNothing);
    for (final button in [kPrimaryMouseButton, kSecondaryMouseButton]) {
      await openCopyMenu(commandPosition);
      await tester.tapAt(const Offset(5, 5), buttons: button);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Copia messaggio'), findsNothing);
    }
    expect(selection.entry, same(selected));

    // A partial text selection adds Copy before the four scope actions.
    final textStart = tester.getTopLeft(find.text('Edit: style.css')) + const Offset(1, 7);
    for (final header in [null, 'Invocazione 3', '3. Sezione progetti']) {
      final textDrag = await tester.startGesture(textStart, kind: PointerDeviceKind.mouse);
      await textDrag.moveTo(textStart + const Offset(60, 0));
      await textDrag.up();
      await tester.pumpAndSettle();
      final contextPosition = header == null
          ? textStart + const Offset(25, 0)
          : tester.getCenter(find.descendant(of: find.byType(LogPanel), matching: find.text(header)));
      await tester.tapAt(contextPosition, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      final copySelection = find.widgetWithText(MenuItemButton, 'Copia');
      expect(copySelection, findsOneWidget);
      expect(find.descendant(of: find.byType(MenuItemButton).first, matching: find.text('Copia')), findsOneWidget);
      await tester.tap(copySelection);
      await tester.pumpAndSettle();
      expect(copiedText, isNotEmpty);
      expect('Edit: style.css', contains(copiedText));
      expect(copiedText, isNot('Edit: style.css'));
    }

    await tester.tap(find.descendant(of: find.byType(LogPanel), matching: find.byTooltip('Comprimi tutto')));
    await tester.pump();
    expect(find.textContaining(message, findRichText: true), findsNothing);

    await tester.tap(find.descendant(of: find.byType(BlocksPanel), matching: find.text('3. Sezione progetti')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining(message, findRichText: true), findsOneWidget);

    // The map at the bottom: clicking an icon opens its line in the log.
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.descendant(of: find.byType(LogPanel), matching: find.byTooltip('Espandi tutto')));
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(LogPanel), matching: find.byTooltip('Comprimi tutto')));
    await tester.pump();
    const check = 'Verifica superata in 8 s';
    expect(find.textContaining(check, findRichText: true), findsNothing);
    final icon = find.descendant(
      of: find.byType(ActivityMap),
      matching: find.byWidgetPredicate(
        (w) => w.key is ValueKey<LogEntry> && (w.key! as ValueKey<LogEntry>).value.text.contains(check),
      ),
    );
    await tester.tap(icon);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining(check, findRichText: true), findsOneWidget);

    final logCount = engine.logs.length;
    await tester.tap(find.byTooltip('Svuota attività'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.descendant(of: find.byType(Dialog), matching: find.byType(Divider)), findsNothing);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(engine.logs.length, logCount);
    await tester.tap(find.byTooltip('Svuota attività'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Svuota'));
    await tester.pumpAndSettle();
    expect(engine.logs, isEmpty);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
