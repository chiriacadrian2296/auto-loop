import 'package:auto_loop/engine/agents.dart';
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
}
