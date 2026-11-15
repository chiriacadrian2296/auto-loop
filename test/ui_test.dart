import 'dart:io';

import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/main.dart';
import 'package:auto_loop/engine/accounts.dart';
import 'package:auto_loop/ui/home_page.dart';
import 'package:auto_loop/ui/settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the first launch opens the guided setup; skipping it is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    HomePage.debugCliProbe = (kind) =>
        kind == AgentKind.claude ? ('2.1.319', const AccountStatus(loggedIn: true, email: 'a@b.c')) : (null, null);
    addTearDown(() => HomePage.debugCliProbe = null);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(AutoLoopApp(engine: LoopEngine(LoopSettings()), prefs: prefs));
    await tester.pumpAndSettle();
    expect(find.text('Benvenuto in AutoLoop'), findsOneWidget);

    // Choosing Claude, which is installed and signed in.
    await tester.tap(find.text('Inizia'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Avanti'));
    await tester.pumpAndSettle();
    expect(find.text('Trovata: versione 2.1.319'), findsOneWidget);
    await tester.tap(find.text('Avanti'));
    await tester.pumpAndSettle();
    expect(find.text('a@b.c'), findsOneWidget);
    await tester.tap(find.text('Finisco dopo'));
    await tester.pumpAndSettle();
    expect(find.text('Benvenuto in AutoLoop'), findsNothing);
    expect(prefs.getBool('setupDone'), isTrue);
    expect(LoopSettings.decode(prefs.getString('settings')).agent, AgentKind.claude);

    // It does not come back by itself; the rocket in the panel reopens it.
    await tester.tap(find.byTooltip('Configurazione guidata'));
    await tester.pumpAndSettle();
    expect(find.text('Benvenuto in AutoLoop'), findsOneWidget);
    await tester.tap(find.text('Salta, faccio da solo'));
    await tester.pumpAndSettle();
  });

  testWidgets('main window renders a loaded plan without layout errors', (tester) async {
    final dir = Directory.systemTemp.createTempSync('autoloop_ui_');
    final plan = File(p.join(dir.path, 'piano.md'))
      ..writeAsStringSync(
        '# App\n\n## Setup del progetto\nfai x\n## Schermata login con un titolo molto lungo che va a capo\ny\n',
      );
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
    // No CLI configured in this test: Avvia says why it cannot start.
    expect(find.byTooltip('Non si può avviare: Codex: CLI non trovata. Clicca per risolvere.'), findsOneWidget);

    // Each tile has one options button, shown on hover and when selected;
    // it opens the block's options.
    expect(find.byTooltip('Opzioni del blocco'), findsNothing);
    await tester.tap(find.textContaining('Setup del progetto'));
    await tester.pump();
    expect(find.byTooltip('Opzioni del blocco'), findsOneWidget);
    await tester.tap(find.byTooltip('Opzioni del blocco'));
    await tester.pumpAndSettle();
    expect(find.text('Segna completato'), findsOneWidget);
    expect(find.text('Fermati dopo questo blocco'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // close the menu
    await tester.pumpAndSettle();

    // Every section starts open; closed, it shows a summary of its choices.
    final sidebar = find.descendant(of: find.byType(SettingsPanel), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Richiamo dopo'), 200, scrollable: sidebar);
    expect(find.text('Richiamo dopo'), findsOneWidget);
    await tester.tap(find.text('Richiamo'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Richiamo dopo'), findsNothing);
    expect(find.textContaining('10 tentativi'), findsOneWidget);
    await tester.ensureVisible(find.text('Richiamo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Richiamo'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Richiamo dopo'), findsOneWidget);

    // Invalid numbers are reported instead of silently ignored; arrows step.
    final attempts = find.descendant(
      of: find.byKey(const ValueKey('number-Tentativi per blocco')),
      matching: find.byType(TextField),
    );
    await tester.enterText(attempts, '0');
    await tester.pumpAndSettle(); // the section resizes for the error text
    expect(find.text('Minimo 1'), findsOneWidget);
    expect(engine.settings.maxAttemptsPerBlock, 10);
    final up = find.descendant(
      of: find.byKey(const ValueKey('number-Tentativi per blocco')),
      matching: find.byIcon(Icons.keyboard_arrow_up_rounded),
    );
    await tester.ensureVisible(up);
    await tester.pump();
    await tester.tap(up);
    await tester.pump();
    expect(find.text('Minimo 1'), findsNothing);
    expect(engine.settings.maxAttemptsPerBlock, 5); // arrows move by the field's step

    // The plan card offers recent plans plus the file browser.
    final planCard = find.text('FILE DEL PIANO');
    await tester.scrollUntilVisible(planCard, -300, scrollable: sidebar);
    await tester.ensureVisible(planCard);
    await tester.pumpAndSettle();
    await tester.tap(planCard);
    await tester.pumpAndSettle();
    expect(find.textContaining('Riapri un piano recente o scegline uno nuovo.'), findsOneWidget);
    expect(find.text('Sfoglia…'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // close the popup
    await tester.pumpAndSettle();

    // The control panel stays open: there is no button to hide it.
    expect(find.byTooltip('Chiudi il pannello'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    // Let the background CLI detection time out inside the fake clock.
    await tester.pump(const Duration(minutes: 5));
  });
}
