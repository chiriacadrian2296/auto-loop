import 'dart:io';

import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/main.dart';
import 'package:auto_loop/ui/settings_panel.dart';
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
    expect(find.text('0%'), findsOneWidget);
    // No CLI configured in this test: Avvia explains why it is disabled.
    expect(find.text('Codex CLI: CLI non trovata'), findsOneWidget);

    await tester.tap(find.textContaining('Setup del progetto'));
    await tester.pump();
    expect(find.text('Completato'), findsOneWidget);

    // Advanced sections start closed with a summary, and open on click.
    expect(find.text('Richiamo dopo'), findsNothing);
    final sidebar = find.descendant(of: find.byType(SettingsPanel), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.textContaining('10 tentativi'), 200, scrollable: sidebar);
    expect(find.textContaining('10 tentativi'), findsOneWidget);
    await tester.tap(find.text('RICHIAMO'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Richiamo dopo'), findsOneWidget);

    // Invalid numbers are reported instead of silently ignored; arrows step.
    final attempts = find.descendant(of: find.byKey(const ValueKey('number-Tentativi per blocco')), matching: find.byType(TextField));
    await tester.enterText(attempts, '0');
    await tester.pumpAndSettle(); // the section resizes for the error text
    expect(find.text('Minimo 1'), findsOneWidget);
    expect(engine.settings.maxAttemptsPerBlock, 10);
    final up = find.descendant(
        of: find.byKey(const ValueKey('number-Tentativi per blocco')), matching: find.byIcon(Icons.keyboard_arrow_up_rounded));
    await tester.ensureVisible(up);
    await tester.pump();
    await tester.tap(up);
    await tester.pump();
    expect(find.text('Minimo 1'), findsNothing);
    expect(engine.settings.maxAttemptsPerBlock, 1);

    // The plan card offers recent plans plus the file browser.
    final planCard = find.text('FILE DEL PIANO');
    await tester.ensureVisible(planCard);
    await tester.pumpAndSettle();
    await tester.tap(planCard);
    await tester.pumpAndSettle();
    expect(find.text('Riapri un piano recente o scegline uno nuovo.'), findsOneWidget);
    expect(find.text('Sfoglia…'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // close the popup
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    // Let the background CLI detection time out inside the fake clock.
    await tester.pump(const Duration(minutes: 5));
  });
}
