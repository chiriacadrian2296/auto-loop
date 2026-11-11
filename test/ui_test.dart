import 'dart:io';

import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('main window renders a loaded plan without layout errors', (tester) async {
    final dir = Directory.systemTemp.createTempSync('autoloop_ui_');
    final plan = File(p.join(dir.path, 'piano.md'))
      ..writeAsStringSync('# App\n\n## Setup del progetto\nfai x\n## Schermata login con un titolo molto lungo che va a capo\ny\n');
    SharedPreferences.setMockInitialValues({'workDir': dir.path, 'planPath': plan.path});
    final prefs = await SharedPreferences.getInstance();
    final engine = LoopEngine(LoopSettings());

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(AutoLoopApp(engine: engine, prefs: prefs));
    await tester.pump();

    expect(find.text('AutoLoop'), findsOneWidget);
    expect(find.textContaining('Setup del progetto'), findsOneWidget);
    expect(find.text('0/2'), findsOneWidget);

    await tester.tap(find.textContaining('Setup del progetto'));
    await tester.pump();
    expect(find.text('Completato'), findsOneWidget);

    // Advanced sections start closed with a summary, and open on click.
    expect(find.text('Richiamo dopo'), findsNothing);
    expect(find.textContaining('10 tentativi'), findsOneWidget);
    await tester.ensureVisible(find.text('RICHIAMO'));
    await tester.tap(find.text('RICHIAMO'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Richiamo dopo'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    // Let the background CLI detection time out inside the fake clock.
    await tester.pump(const Duration(minutes: 5));
  });
}
