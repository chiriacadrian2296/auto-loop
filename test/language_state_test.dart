import 'package:auto_loop/demo.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/l10n.dart';
import 'package:auto_loop/main.dart';
import 'package:auto_loop/ui/blocks_panel.dart';
import 'package:auto_loop/ui/home_page.dart';
import 'package:auto_loop/ui/log_panel.dart';
import 'package:auto_loop/ui/resizable_text_field.dart';
import 'package:auto_loop/ui/settings_panel.dart';
import 'package:auto_loop/ui/window_controls.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<LoopEngine> openDemo(WidgetTester tester, String folder) async {
    appLang.value = AppLang.it;
    BlocksPanel.closed.value = {};
    HomePage.debugCliProbe = (_) => (null, null);
    addTearDown(() => HomePage.debugCliProbe = null);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final demo = (await tester.runAsync(() => DemoData.create(folder: folder)))!;
    SharedPreferences.setMockInitialValues({'workDir': demo.workDir, 'planPath': demo.planPath});
    final prefs = await SharedPreferences.getInstance();
    final engine = LoopEngine(LoopSettings(extraInstructions: 'Regole da conservare'))..demo = true;
    await tester.pumpWidget(AutoLoopApp(engine: engine, prefs: prefs));
    await tester.pumpAndSettle();
    return engine;
  }

  testWidgets('language changes preserve settings sections, drafts, caret and resized text fields', (tester) async {
    final engine = await openDemo(tester, 'autoloop-language-settings');
    final sidebar = find.descendant(of: find.byType(SettingsPanel), matching: find.byType(Scrollable)).first;
    var position = tester.state<ScrollableState>(sidebar).position;
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('settings-section-plan')), matching: find.text('Piano')),
    );
    await tester.pumpAndSettle();
    final attempts = find.descendant(
      of: find.byKey(const ValueKey('number-attempts')),
      matching: find.byType(TextField),
    );
    await tester.scrollUntilVisible(attempts, 200, scrollable: sidebar);
    await tester.enterText(attempts, '0');
    await tester.pumpAndSettle();
    final controller = tester.widget<TextField>(attempts).controller!;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
    final offset = position.pixels;
    final settings = engine.settings.encode();
    await tester.tap(find.byType(LanguageCaptionButton));
    await tester.pumpAndSettle();
    position = tester.state<ScrollableState>(sidebar).position;
    expect(tester.widget<TextField>(attempts).controller, same(controller));
    expect(controller.text, '0');
    expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 1));
    expect(find.text('Minimum 1'), findsOneWidget);
    expect(position.pixels, offset);
    expect(engine.settings.encode(), settings);
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('PLAN FILE'), findsNothing);

    final instructions = find.byWidgetPredicate(
      (widget) => widget is ResizableTextField && widget.initialValue == 'Regole da conservare',
    );
    await tester.scrollUntilVisible(instructions, 250, scrollable: sidebar);
    final field = find.byKey(tester.widget<ResizableTextField>(instructions).key!);
    final form = find.descendant(of: field, matching: find.byType(TextFormField));
    await tester.enterText(form, 'Testo in modifica');
    final handle = find.descendant(of: field, matching: find.byKey(const ValueKey('resize-text-field')));
    await tester.ensureVisible(handle);
    final before = tester.getSize(field).height;
    await tester.drag(handle, const Offset(0, 100));
    await tester.pumpAndSettle();
    final height = tester.getSize(field).height;
    expect(height, greaterThan(before));
    await tester.tap(find.byType(LanguageCaptionButton));
    await tester.pumpAndSettle();
    expect(tester.getSize(field).height, height);
    expect(engine.settings.extraInstructions, 'Testo in modifica');
    expect(
      tester.widget<TextField>(find.descendant(of: form, matching: find.byType(TextField))).controller!.text,
      'Testo in modifica',
    );
  });

  testWidgets('language and secondary clicks preserve activity selections, filters and collapsed groups', (
    tester,
  ) async {
    await openDemo(tester, 'autoloop-language-activity');
    Finder inLog(Finder finder) => find.descendant(of: find.byType(LogPanel), matching: finder);
    Finder inProgress(Finder finder) => find.descendant(of: find.byType(BlocksPanel), matching: finder);
    await tester.tap(inProgress(find.text('5. Tema scuro')));
    await tester.pumpAndSettle();
    await tester.tap(inProgress(find.text('Completati')));
    await tester.pumpAndSettle();
    await tester.tap(inLog(find.text('4. Modulo contatti')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filtra le attività'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Messaggi'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Eventi'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    const message = 'Le card ora passano a una colonna sotto i 640 px; ho aggiunto i link mancanti.';
    await tester.tap(find.textContaining(message, findRichText: true));
    await tester.pumpAndSettle();
    final selection = tester.widget<ActivityMap>(find.byType(ActivityMap)).selection;
    final selected = selection.entry;
    expect(selected, isNotNull);
    for (final header in ['Invocazione 3', '3. Sezione progetti']) {
      await tester.tap(inLog(find.text(header)), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(selection.entry, same(selected));
      expect(find.byType(Dialog), findsNothing);
      expect(find.widgetWithText(MenuItemButton, 'Copia blocco'), findsOneWidget);
      expect(find.widgetWithText(MenuItemButton, 'Copia tutto'), findsOneWidget);
      expect(find.widgetWithText(MenuItemButton, 'Copia messaggio'), findsNothing);
      expect(
        find.widgetWithText(MenuItemButton, 'Copia invocazione'),
        header == 'Invocazione 3' ? findsOneWidget : findsNothing,
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byType(LanguageCaptionButton));
    await tester.pumpAndSettle();
    expect(selection.entry, same(selected));
    expect(BlocksPanel.closed.value, contains('done'));
    expect(inProgress(find.text('3. Sezione progetti')), findsNothing);
    expect(find.byTooltip('Filter: Messages, Events'), findsOneWidget);
    expect(inLog(find.text('Invocation 1')), findsNothing);
    expect(inLog(find.text('Invocation 3')), findsOneWidget);
    expect(find.text('Demo · Ready'), findsOneWidget);
    await tester.tap(find.byType(LanguageCaptionButton));
    await tester.pumpAndSettle();
    expect(selection.entry, same(selected));
    expect(find.byTooltip('Filtro: Messaggi, Eventi'), findsOneWidget);
    expect(inProgress(find.text('3. Sezione progetti')), findsNothing);
    await tester.tap(inProgress(find.text('6. Rifinitura e README')));
    await tester.pumpAndSettle();
    expect(inProgress(find.byTooltip('Opzioni del blocco')), findsOneWidget);
    await tester.tap(find.byType(LanguageCaptionButton));
    await tester.pumpAndSettle();
    expect(inProgress(find.byTooltip('Block options')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
