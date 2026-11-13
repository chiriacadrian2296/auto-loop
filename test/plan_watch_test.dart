import 'dart:io';

import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the plan reloads by itself when its file changes', (tester) async {
    final dir = Directory.systemTemp.createTempSync('autoloop_watch_');
    final plan = File(p.join(dir.path, 'piano.md'))..writeAsStringSync('## Uno\nx\n## Due\ny\n');
    SharedPreferences.setMockInitialValues({'workDir': dir.path, 'planPath': plan.path});
    final prefs = await SharedPreferences.getInstance();
    final engine = LoopEngine(LoopSettings());
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(AutoLoopApp(engine: engine, prefs: prefs));
    await tester.pump();
    expect(find.text('0 di 2 blocchi completati'), findsOneWidget);

    await tester.runAsync(() async {
      plan.writeAsStringSync('## Uno\nx\n## Due\ny\n## Tre\nz\n');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 700)); // debounce
    await tester.pump();
    expect(find.text('0 di 3 blocchi completati'), findsOneWidget);
    expect(find.text('3. Tre'), findsOneWidget);
    expect(engine.logs.last.text, contains('Piano ricaricato'));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
}
