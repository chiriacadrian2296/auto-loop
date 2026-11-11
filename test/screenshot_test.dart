// Renders the main window with real Windows fonts into PNG files, to review
// the design without launching the app. Skipped unless SCREENSHOT_DIR is set:
//   $env:SCREENSHOT_DIR = 'shots'; flutter test test/screenshot_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auto_loop/engine/agents.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/loop_state.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/engine/accounts.dart';
import 'package:auto_loop/engine/cli_locator.dart';
import 'package:auto_loop/main.dart';
import 'package:auto_loop/ui/accounts_dialog.dart';
import 'package:auto_loop/ui/app_theme.dart';
import 'package:auto_loop/ui/choice_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final file = File(f);
    if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  final out = Platform.environment['SCREENSHOT_DIR'];

  setUpAll(() async {
    if (out == null) return;
    const fonts = r'C:\Windows\Fonts';
    final ui = ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf'].map((f) => p.join(fonts, f)).toList();
    await _loadFont('Segoe UI Variable Text', ui);
    await _loadFont('Segoe UI', ui);
    await _loadFont('Cascadia Mono', [p.join(fonts, 'CascadiaMono.ttf')]);
    // flutter_tester lives in <flutter>/bin/cache/artifacts/engine/...
    final flutterRoot = p.dirname(Platform.resolvedExecutable.replaceAll(RegExp(r'[\\/]cache[\\/].*'), ''));
    await _loadFont('MaterialIcons', [
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts', 'materialicons-regular.otf'),
    ]);
  });

  for (final dark in [false, true]) {
    testWidgets('screenshot ${dark ? 'dark' : 'light'}', (tester) async {
      final dir = Directory.systemTemp.createTempSync('autoloop_shot_');
      final plan = File(p.join(dir.path, 'piano-todo-app.md'))
        ..writeAsStringSync('# Todo app\n\nObiettivo.\n\n'
            '## Struttura del progetto\nCrea il progetto Flutter.\n'
            '## Modello e persistenza\nModello Todo con JSON.\n'
            '## Interfaccia principale con lista, filtri e swipe per eliminare\nUI.\n'
            '## Tema chiaro e scuro\nTema.\n'
            '## README e rifinitura finale\nDocs.\n');
      SharedPreferences.setMockInitialValues({
        'workDir': dir.path,
        'planPath': plan.path,
        'theme': dark ? 'dark' : 'light',
      });
      final prefs = await SharedPreferences.getInstance();
      final engine = LoopEngine(LoopSettings(agent: AgentKind.claude, verifyCommand: 'flutter test'));

      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: key, child: AutoLoopApp(engine: engine, prefs: prefs)));
      await tester.pump();

      // Fake a run in progress: two blocks done, the third running.
      final blocks = engine.plan!.blocks;
      engine.state!
        ..runs = 5
        ..inputTokens = 412000
        ..outputTokens = 9800;
      engine.blockState(blocks[0])
        ..status = BlockStatus.done
        ..attempts = 1;
      engine.blockState(blocks[1])
        ..status = BlockStatus.done
        ..attempts = 2;
      engine.blockState(blocks[2]).attempts = 2;
      engine
        ..phase = LoopPhase.running
        ..currentBlock = 2
        ..runStartedAt = DateTime.now().subtract(const Duration(minutes: 3, seconds: 12))
        ..statusMessage = 'Blocco 3: Interfaccia principale con lista, filtri e swipe per eliminare';
      final t = DateTime(2026, 11, 10, 17, 4, 10);
      engine.logs.addAll([
        LogEntry(LogKind.info, 'Avvio del loop con Claude Code su piano-todo-app.md.', at: t),
        LogEntry(LogKind.info, '▶ Blocco 2/5 «Modello e persistenza» — invocazione 2', at: t),
        LogEntry(LogKind.system, 'Sessione Claude avviata (claude-sonnet-5-5)', at: t),
        LogEntry(LogKind.tool, 'Read: lib/models/todo.dart', at: t),
        LogEntry(LogKind.tool, 'Bash: flutter test test/models', at: t),
        LogEntry(LogKind.agent,
            'Ho completato il repository JSON e i test per serializzazione e caricamento. Tutti i 14 test passano.',
            at: t),
        LogEntry(LogKind.tool, 'Verifica: flutter test', at: t),
        LogEntry(LogKind.success, 'Verifica superata.', at: t),
        LogEntry(LogKind.success, 'Commit creato: autoloop: Modello e persistenza', at: t),
        LogEntry(LogKind.success, 'Blocco 2 completato.', at: t),
        LogEntry(LogKind.info,
            '▶ Blocco 3/5 «Interfaccia principale con lista, filtri e swipe per eliminare» — invocazione 1',
            at: t),
        LogEntry(LogKind.tool, 'Edit: lib/ui/home_screen.dart', at: t),
        LogEntry(LogKind.warning, 'Agente terminato dal supervisore: nessun output per 10 minuti.', at: t),
        LogEntry(LogKind.info, '▶ Blocco 3/5 «Interfaccia principale con lista, filtri e swipe per eliminare» — invocazione 2',
            at: t),
        LogEntry(LogKind.agent, 'Riprendo da PROGRESS.md: manca il filtro "completati" e lo swipe per eliminare.', at: t),
        LogEntry(LogKind.tool, 'Write: lib/ui/widgets/todo_tile.dart', at: t),
      ]);
      engine.notifyListeners();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Modello e persistenza'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(out!).createSync(recursive: true);
        File(p.join(out, 'main_${dark ? 'dark' : 'light'}.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });

      engine.phase = LoopPhase.idle;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
    }, skip: out == null);
  }

  testWidgets('screenshot empty', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
        RepaintBoundary(key: key, child: AutoLoopApp(engine: LoopEngine(LoopSettings()), prefs: prefs)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(out!, 'main_empty.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: out == null);

  for (final dark in [false, true]) {
    testWidgets('screenshot model dialog ${dark ? 'dark' : 'light'}', (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      late BuildContext ctx;
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(dark ? Brightness.dark : Brightness.light),
          home: Builder(builder: (c) {
            ctx = c;
            return const Scaffold();
          }),
        ),
      ));
      showChoiceDialog<String>(
        context: ctx,
        title: 'Modello',
        subtitle: '8 modelli dal catalogo di Codex',
        selected: 'gpt-6.1-sol',
        choices: const [
          Choice(value: '', label: 'Predefinito della CLI', description: 'Il modello configurato nella CLI.', dividerAfter: true),
          Choice(value: 'gpt-6.1-sol', label: 'GPT-6.1-Sol', tag: 'gpt-6.1-sol',
              description: 'Latest workhorse model for coding and everyday work.'),
          Choice(value: 'gpt-6-astra', label: 'GPT-6-Astra', tag: 'gpt-6-astra',
              description: 'Frontier model for the hardest problems.'),
          Choice(value: 'gpt-6-luna', label: 'GPT-6-Luna', tag: 'gpt-6-luna', description: 'Fast and inexpensive.'),
        ],
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(out!, 'dialog_${dark ? 'dark' : 'light'}.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }, skip: out == null);
  }

  testWidgets('screenshot accounts dialog', (tester) async {
    final codex = await tester.runAsync(() => locateCli(AgentKind.codex));
    final claude = await tester.runAsync(() => locateCli(AgentKind.claude));
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = LoopSettings(codexPath: codex ?? '', claudePath: claude ?? '',
        profiles: [const AccountProfile(id: 'pshot', name: 'Lavoro')]);
    final key = GlobalKey();
    late BuildContext ctx;
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold();
        }),
      ),
    ));
    showAccountsDialog(ctx, settings: settings, locked: false, onChanged: () {});
    // Let the real CLIs answer their status commands.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(out!, 'accounts.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    deleteProfileData('pshot');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: out == null);

  for (final dark in [false, true]) {
    testWidgets('screenshot sidebar ${dark ? 'dark' : 'light'}', (tester) async {
      final dir = Directory.systemTemp.createTempSync('autoloop_side_');
      final plan = File(p.join(dir.path, 'piano-todo-app.md'))..writeAsStringSync('## Uno\nx\n## Due\ny\n');
      SharedPreferences.setMockInitialValues({
        'workDir': dir.path,
        'planPath': plan.path,
        'theme': dark ? 'dark' : 'light',
      });
      final prefs = await SharedPreferences.getInstance();
      final engine = LoopEngine(LoopSettings(agent: AgentKind.claude, verifyCommand: 'flutter test'));
      tester.view.physicalSize = const Size(1440, 1900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: key, child: AutoLoopApp(engine: engine, prefs: prefs)));
      // Let version, account and catalog detection run against the real CLIs.
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (final title in ['RICHIAMO', 'QUOTA E BUDGET', 'FINE BLOCCO', 'ISTRUZIONI']) {
        final f = find.text(title);
        if (f.evaluate().isEmpty) continue;
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(out!, 'sidebar_${dark ? 'dark' : 'light'}.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
    }, skip: out == null);
  }
}
