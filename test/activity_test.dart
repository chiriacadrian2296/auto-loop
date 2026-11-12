import 'package:auto_loop/demo.dart';
import 'package:auto_loop/engine/agents.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auto_loop/ui/app_theme.dart';
import 'package:auto_loop/ui/markdown_text.dart';
import 'package:flutter/material.dart';
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

  test('log kinds stay distinct for the filters', () {
    expect(LogKind.values, contains(LogKind.warning));
  });

  testWidgets('clicking a block opens its invocations in the log', (tester) async {
    final demo = (await tester.runAsync(DemoData.create))!;
    SharedPreferences.setMockInitialValues({'workDir': demo.workDir, 'planPath': demo.planPath});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AutoLoopApp(engine: LoopEngine(LoopSettings())..demo = true, prefs: prefs));
    await tester.pump();

    // Block 3's invocation is collapsed: its message is not on screen.
    const message = 'Le card ora passano a una colonna sotto i 640 px; ho aggiunto i link mancanti.';
    expect(find.textContaining(message, findRichText: true), findsNothing);

    await tester.tap(find.text('Sezione progetti').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining(message, findRichText: true), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
}
