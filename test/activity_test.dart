import 'package:auto_loop/demo.dart';
import 'package:auto_loop/engine/agents.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auto_loop/ui/app_theme.dart';
import 'package:auto_loop/ui/markdown_text.dart';
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
    final demo = (await tester.runAsync(() => DemoData.create(folder: 'autoloop-demo-activity-test')))!;
    SharedPreferences.setMockInitialValues({'workDir': demo.workDir, 'planPath': demo.planPath});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AutoLoopApp(engine: LoopEngine(LoopSettings())..demo = true, prefs: prefs));
    await tester.pump();

    // Everything starts open; collapse the log, then a click on the block
    // opens its invocations again.
    const message = 'Le card ora passano a una colonna sotto i 640 px; ho aggiunto i link mancanti.';
    expect(find.textContaining(message, findRichText: true), findsOneWidget);
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

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
}
