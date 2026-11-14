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
import 'package:auto_loop/ui/agent_badge.dart';
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
        ..writeAsStringSync(
          '# Todo app\n\nObiettivo.\n\n'
          '## Struttura del progetto\nCrea il progetto Flutter.\n'
          '## Modello e persistenza\nModello Todo con JSON.\n'
          '## Interfaccia principale con lista, filtri e swipe per eliminare\nUI.\n'
          '## Tema chiaro e scuro\nTema.\n'
          '## README e rifinitura finale\nDocs.\n',
        );
      SharedPreferences.setMockInitialValues({
        'workDir': dir.path,
        'planPath': plan.path,
        'theme': dark ? 'dark' : 'light',
        'sidebarOpen': !dark, // the dark shot shows the closed control panel
      });
      final prefs = await SharedPreferences.getInstance();
      final engine = LoopEngine(LoopSettings(agent: AgentKind.claude, verifyCommand: 'flutter test'));

      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: AutoLoopApp(engine: engine, prefs: prefs),
        ),
      );
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
      engine.blockState(blocks[3]).pauseAfter = true; // shows the hand on its tile
      engine
        ..phase = LoopPhase.running
        ..currentBlock = 2
        ..runStartedAt = DateTime.now().subtract(const Duration(minutes: 3, seconds: 12))
        ..statusMessage = 'Blocco 3: Interfaccia principale con lista, filtri e swipe per eliminare';
      // Realistic times, so the activity map shows its shape.
      final t = DateTime.now().subtract(const Duration(minutes: 31));
      engine.logs.addAll([
        LogEntry(
          LogKind.info,
          'Avvio del loop con Claude Code su piano-todo-app.md.',
          at: t.add(const Duration(seconds: 0)),
        ),
        LogEntry(
          LogKind.info,
          '▶ Blocco 2/5 «Modello e persistenza» — invocazione 2',
          at: t.add(const Duration(seconds: 5)),
        ),
        LogEntry(LogKind.system, 'Sessione Claude avviata (claude-sonnet-5-5)', at: t.add(const Duration(seconds: 6))),
        LogEntry(LogKind.tool, 'Read: lib/models/todo.dart', at: t.add(const Duration(seconds: 40))),
        LogEntry(LogKind.tool, 'Bash: flutter test test/models', at: t.add(const Duration(seconds: 120))),
        LogEntry(
          LogKind.agent,
          'Ho completato il repository JSON e i test per serializzazione e caricamento. Tutti i 14 test passano.',
          at: t.add(const Duration(seconds: 260)),
        ),
        LogEntry(LogKind.tool, 'Verifica: flutter test', at: t.add(const Duration(seconds: 300))),
        LogEntry(
          LogKind.success,
          'Verifica superata in 21 s · All tests passed!',
          at: t.add(const Duration(seconds: 320)),
        ),
        LogEntry(LogKind.success, 'Commit 9c41e07 · 4 file · +188 −2', at: t.add(const Duration(seconds: 330))),
        LogEntry(
          LogKind.result,
          'Blocco completato.',
          at: t.add(const Duration(seconds: 331)),
          outcome: RunOutcome.done,
        ),
        LogEntry(
          LogKind.info,
          '▶ Blocco 3/5 «Interfaccia principale con lista, filtri e swipe per eliminare» — invocazione 1',
          at: t.add(const Duration(seconds: 340)),
        ),
        LogEntry(
          LogKind.task,
          'Lista dei todo con filtri tutti/attivi/completati e swipe per eliminare.',
          at: t.add(const Duration(seconds: 342)),
        ),
        LogEntry(LogKind.tool, 'Edit: lib/ui/home_screen.dart', at: t.add(const Duration(seconds: 400))),
        LogEntry(
          LogKind.result,
          'Terminata dal supervisore: nessun output per 10 minuti.',
          at: t.add(const Duration(seconds: 1000)),
          outcome: RunOutcome.interrupted,
        ),
        LogEntry(
          LogKind.info,
          '▶ Blocco 3/5 «Interfaccia principale con lista, filtri e swipe per eliminare» — invocazione 2',
          at: t.add(const Duration(seconds: 1030)),
        ),
        LogEntry(
          LogKind.agent,
          'Riprendo da PROGRESS.md: manca il filtro "completati" e lo swipe per eliminare.',
          at: t.add(const Duration(seconds: 1400)),
        ),
        LogEntry(LogKind.tool, 'Write: lib/ui/widgets/todo_tile.dart', at: t.add(const Duration(seconds: 1700))),
      ]);
      engine.notifyListeners();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('2. Modello e persistenza').first);
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

  // The window on the folder left by test/real_scenario_test.dart: real
  // activity, real block states. Skipped unless AUTOLOOP_SCENARIO_DIR is set.
  final scenario = Platform.environment['AUTOLOOP_SCENARIO_DIR'];
  for (final agent in AgentKind.values) {
    final dir = scenario == null ? null : p.join(scenario, agent.name);
    testWidgets('screenshot scenario ${agent.name}', (tester) async {
      SharedPreferences.setMockInitialValues({
        'workDir': dir!,
        'planPath': p.join(dir, 'piano-collaudo.md'),
        'theme': 'dark',
      });
      final prefs = await SharedPreferences.getInstance();
      final engine = LoopEngine(LoopSettings(agent: agent, verifyCommand: 'findstr /c:ciao hello.txt'));
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: AutoLoopApp(engine: engine, prefs: prefs),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(out!).createSync(recursive: true);
        File(p.join(out, 'scenario_${agent.name}.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
    }, skip: out == null || dir == null || !Directory(dir).existsSync());
  }

  testWidgets('screenshot empty', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: AutoLoopApp(engine: LoopEngine(LoopSettings()), prefs: prefs),
      ),
    );
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
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(dark ? Brightness.dark : Brightness.light),
            home: Builder(
              builder: (c) {
                ctx = c;
                return const Scaffold();
              },
            ),
          ),
        ),
      );
      showChoiceDialog<String>(
        context: ctx,
        title: 'Modello',
        subtitle: '8 modelli dal catalogo di Codex',
        selected: 'gpt-6.1-sol',
        choices: const [
          Choice(
            value: '',
            label: 'Predefinito della CLI',
            description: 'Il modello configurato nella CLI.',
            dividerAfter: true,
          ),
          Choice(
            value: 'gpt-6.1-sol',
            label: 'GPT-6.1-Sol',
            tag: 'gpt-6.1-sol',
            description: 'Latest workhorse model for coding and everyday work.',
          ),
          Choice(
            value: 'gpt-6-astra',
            label: 'GPT-6-Astra',
            tag: 'gpt-6-astra',
            description: 'Frontier model for the hardest problems.',
          ),
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
    final settings = LoopSettings(codexPath: codex ?? '', claudePath: claude ?? '', profiles: []);
    final key = GlobalKey();
    late BuildContext ctx;
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (c) {
              ctx = c;
              return const Scaffold();
            },
          ),
        ),
      ),
    );
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
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: AutoLoopApp(engine: engine, prefs: prefs),
        ),
      );
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

  testWidgets('screenshot agent dialog', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    late BuildContext ctx;
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (c) {
              ctx = c;
              return const Scaffold();
            },
          ),
        ),
      ),
    );
    showChoiceDialog<AgentKind>(
      context: ctx,
      title: 'Agente',
      subtitle: 'Chi svolge il piano, un blocco alla volta.',
      selected: AgentKind.claude,
      choices: [
        for (final k in AgentKind.values)
          Choice(
            value: k,
            label: k.label,
            tag: k == AgentKind.codex ? 'v0.167.0' : 'v2.1.319',
            description: k == AgentKind.codex
                ? 'L\'agente di OpenAI, con il tuo account ChatGPT.'
                : 'L\'agente di Anthropic, con il tuo account Claude.',
            leading: AgentBadge(kind: k, size: 32, selected: k == AgentKind.claude),
          ),
      ],
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500))); // svg assets
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(out!, 'agent_dialog.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }, skip: out == null);
}
