import 'dart:io';

import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/main.dart';
import 'package:auto_loop/l10n.dart';
import 'package:auto_loop/engine/accounts.dart';
import 'package:auto_loop/ui/home_page.dart';
import 'package:auto_loop/ui/settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => appLang.value = AppLang.it);

  for (final savedPlan in [false, true]) {
    testWidgets('first launch opens setup (saved plan: $savedPlan); dismissal is remembered', (tester) async {
      SharedPreferences.setMockInitialValues({if (savedPlan) 'planPath': 'saved-plan.md'});
      final prefs = await SharedPreferences.getInstance();
      HomePage.debugCliProbe = (kind) =>
          kind == AgentKind.claude ? ('2.1.319', const AccountStatus(loggedIn: true, email: 'a@b.c')) : (null, null);
      addTearDown(() => HomePage.debugCliProbe = null);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(AutoLoopApp(engine: LoopEngine(LoopSettings()), prefs: prefs));
      await tester.pumpAndSettle();
      expect(find.text('Scegli la lingua'), findsOneWidget);
      expect(find.text('Benvenuto in AutoLoop'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Chiudi'), findsOneWidget);
      expect(find.byIcon(Icons.translate_rounded), findsOneWidget);
      expect(find.text('Lingua'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(tester.getTopLeft(find.text('English')).dy, greaterThan(tester.getTopLeft(find.text('Italiano')).dy));
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Choose your language'), findsOneWidget);
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Scegli la lingua'), findsNothing);
      expect(prefs.getString('lang'), 'en');
      expect(prefs.getBool('setupDone'), isNull);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to AutoLoop'), findsOneWidget);
      expect(find.text('Welcome'), findsOneWidget);
      expect(find.text('Step 1 of 5'), findsOneWidget);
      expect(find.text('Close'), findsNothing);
      final setupDialog = find.byType(Dialog);
      expect(find.descendant(of: setupDialog, matching: find.byType(LinearProgressIndicator)), findsNothing);
      expect(tester.getTopLeft(find.text('Welcome')).dx, tester.getTopLeft(find.text('Project')).dx);
      expect(tester.getTopLeft(find.text('Project')).dy, greaterThan(tester.getTopLeft(find.text('Welcome')).dy));
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Italiano'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continua'));
      await tester.pumpAndSettle();
      expect(find.text('Benvenuto in AutoLoop'), findsOneWidget);
      expect(find.text('Benvenuto'), findsOneWidget);

      // Choosing Claude, which is installed and signed in.
      await tester.tap(find.text('Inizia'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final titleTop = tester.getTopLeft(find.text('Quale agente usi?')).dy;
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Quale agente usi?')).dy, titleTop);
      expect(find.text('Passo 2 di 5'), findsOneWidget);
      expect(find.text('Chiudi'), findsNothing);
      await tester.tap(find.text('Claude').last);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(prefs.getInt('setupStep'), 1);
      await tester.tap(find.byTooltip('Configurazione guidata'));
      await tester.pumpAndSettle();
      expect(find.text('Quale agente usi?'), findsOneWidget);
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
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        AutoLoopApp(engine: LoopEngine(LoopSettings.decode(prefs.getString('settings'))), prefs: prefs),
      );
      await tester.pumpAndSettle();
      expect(find.text('Scegli la lingua'), findsNothing);
      await tester.tap(find.byTooltip('Configurazione guidata'));
      await tester.pumpAndSettle();
      expect(find.text('a@b.c'), findsOneWidget);
      expect(find.text('Passo 4 di 5'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('Indietro'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Scegli la lingua'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Chiudi'));
      await tester.pumpAndSettle();
      expect(find.text('Scegli la lingua'), findsNothing);
      await tester.tap(find.byTooltip('Configurazione guidata'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continua'));
      await tester.pumpAndSettle();
      expect(find.text('Benvenuto in AutoLoop'), findsOneWidget);
      await tester.tap(find.text('Salta, faccio da solo'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('restoring defaults requires confirmation and preserves the agent and account', (tester) async {
    SharedPreferences.setMockInitialValues({'setupDone': true, 'theme': 'dark'});
    final prefs = await SharedPreferences.getInstance();
    final settings = LoopSettings(agent: AgentKind.claude, claudeModel: 'custom-model', maxAttemptsPerBlock: 25);
    HomePage.debugCliProbe = (_) => (null, null);
    addTearDown(() => HomePage.debugCliProbe = null);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AutoLoopApp(engine: LoopEngine(settings), prefs: prefs));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Ripristina predefiniti'));
    await tester.pumpAndSettle();
    final dialogSurface = find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first;
    expect(tester.getSize(dialogSurface).width, lessThanOrEqualTo(460));
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(settings.model, 'custom-model');
    expect(settings.maxAttemptsPerBlock, 25);

    final profile = settings.profileId;
    await tester.tap(find.byTooltip('Ripristina predefiniti'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ripristina'));
    await tester.pumpAndSettle();
    expect(settings.model, LoopSettings().model);
    expect(settings.maxAttemptsPerBlock, LoopSettings().maxAttemptsPerBlock);
    expect(settings.agent, AgentKind.claude);
    expect(settings.profileId, profile);
  });

  testWidgets('main window renders a loaded plan without layout errors', (tester) async {
    final dir = Directory.systemTemp.createTempSync('autoloop_ui_');
    final plan = File(p.join(dir.path, 'piano.md'))
      ..writeAsStringSync(
        '# App\n\n## Setup del progetto\nfai x\n## Schermata login con un titolo molto lungo che va a capo\ny\n',
      );
    SharedPreferences.setMockInitialValues({'workDir': dir.path, 'planPath': plan.path, 'setupDone': true});
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
    expect(find.text('Completato'), findsOneWidget);
    expect(find.text('Pausa dopo'), findsOneWidget);
    await tester.tap(find.text('Pausa dopo'));
    await tester.pumpAndSettle();
    expect(engine.blockState(engine.plan!.blocks.first).pauseAfter, isTrue);
    await tester.tap(find.byTooltip('Opzioni del blocco'));
    await tester.pumpAndSettle();
    expect(find.text('Togli pausa'), findsOneWidget);
    await tester.tap(find.text('Togli pausa'));
    await tester.pumpAndSettle();
    expect(engine.blockState(engine.plan!.blocks.first).pauseAfter, isFalse);

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
      of: find.byKey(const ValueKey('number-attempts')),
      matching: find.byType(TextField),
    );
    await tester.enterText(attempts, '0');
    await tester.pumpAndSettle(); // the section resizes for the error text
    expect(find.text('Minimo 1'), findsOneWidget);
    expect(engine.settings.maxAttemptsPerBlock, 10);
    final up = find.descendant(
      of: find.byKey(const ValueKey('number-attempts')),
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
