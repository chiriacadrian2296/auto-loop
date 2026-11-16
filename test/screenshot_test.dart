// Renders the main window with real Windows fonts into PNG files, to review
// the design without launching the app. Skipped unless SCREENSHOT_DIR is set:
//   $env:SCREENSHOT_DIR = 'shots'; flutter test test/screenshot_test.dart
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:auto_loop/engine/agents.dart';
import 'package:auto_loop/engine/loop_engine.dart';
import 'package:auto_loop/engine/loop_state.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:auto_loop/engine/accounts.dart';
import 'package:auto_loop/engine/cli_locator.dart';
import 'package:auto_loop/l10n.dart';
import 'package:auto_loop/main.dart';
import 'package:auto_loop/ui/accounts_dialog.dart';
import 'package:auto_loop/ui/agent_badge.dart';
import 'package:auto_loop/ui/app_theme.dart';
import 'package:auto_loop/ui/choice_dialog.dart';
import 'package:auto_loop/ui/home_page.dart';
import 'package:auto_loop/ui/log_panel.dart';
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
    // SCREENSHOT_LANG=en: the window, the plan and the activity in English.
    if (Platform.environment['SCREENSHOT_LANG'] == 'en') appLang.value = AppLang.en;
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
      final plan = File(p.join(dir.path, tr('piano-todo-app.md', 'todo-app-plan.md')))
        ..writeAsStringSync(
          tr(
            '# Todo app\n\nObiettivo.\n\n'
                '## Struttura del progetto\nCrea il progetto Flutter.\n'
                '## Modello e persistenza\nModello Todo con JSON.\n'
                '## Interfaccia principale con lista, filtri e swipe per eliminare\nUI.\n'
                '## Tema chiaro e scuro\nTema.\n'
                '## README e rifinitura finale\nDocs.\n',
            '# Todo app\n\nGoal.\n\n'
                '## Project structure\nCreate the Flutter project.\n'
                '## Model and storage\nTodo model with JSON.\n'
                '## Main screen with list, filters and swipe to delete\nUI.\n'
                '## Light and dark theme\nTheme.\n'
                '## README and final polish\nDocs.\n',
          ),
        );
      SharedPreferences.setMockInitialValues({
        'setupDone': true,
        'workDir': dir.path,
        'planPath': plan.path,
        'theme': dark ? 'dark' : 'light',
        'sidebarOpen': !dark, // the dark shot shows the closed control panel
      });
      final prefs = await SharedPreferences.getInstance();
      // A CLI that is found and signed in, with a demo account.
      final fake = p.join(Directory.current.path, 'test', 'fake_agent', 'fake_claude.cmd');
      HomePage.debugCliProbe = (_) =>
          ('2.1.319', const AccountStatus(loggedIn: true, email: 'demo@autoloop.dev', plan: 'max'));
      addTearDown(() => HomePage.debugCliProbe = null);
      final engine = LoopEngine(
        LoopSettings(agent: AgentKind.claude, claudePath: fake, codexPath: fake, verifyCommand: 'flutter test'),
      );

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
        ..sessionStartedAt = DateTime.now().subtract(const Duration(minutes: 31))
        ..statusMessage = tr(
          'Blocco 3: Interfaccia principale con lista, filtri e swipe per eliminare',
          'Block 3: Main screen with list, filters and swipe to delete',
        );
      // Realistic times, so the activity map shows its shape.
      final t = DateTime.now().subtract(const Duration(minutes: 31));
      engine.logs.addAll([
        LogEntry(
          LogKind.info,
          tr(
            'Avvio del loop con Claude Code su piano-todo-app.md.',
            'Starting the loop with Claude Code on todo-app-plan.md.',
          ),
          at: t.add(const Duration(seconds: 0)),
        ),
        LogEntry(
          LogKind.info,
          tr('▶ Blocco 2/5 «Modello e persistenza» — invocazione 2', '▶ Block 2/5 «Model and storage» — invocation 2'),
          at: t.add(const Duration(seconds: 5)),
        ),
        LogEntry(
          LogKind.system,
          tr('Sessione Claude avviata (claude-sonnet-5-5)', 'Claude session started (claude-sonnet-5-5)'),
          at: t.add(const Duration(seconds: 6)),
        ),
        LogEntry(LogKind.tool, 'Read: lib/models/todo.dart', at: t.add(const Duration(seconds: 40))),
        LogEntry(LogKind.tool, 'Bash: flutter test test/models', at: t.add(const Duration(seconds: 120))),
        LogEntry(
          LogKind.agent,
          tr(
            'Ho completato il repository JSON e i test per serializzazione e caricamento. Tutti i 14 test passano.',
            'I finished the JSON repository and the tests for serialization and loading. All 14 tests pass.',
          ),
          at: t.add(const Duration(seconds: 260)),
        ),
        LogEntry(
          LogKind.tool,
          tr('Verifica: flutter test', 'Check: flutter test'),
          at: t.add(const Duration(seconds: 300)),
        ),
        LogEntry(
          LogKind.success,
          tr('Verifica superata in 21 s · All tests passed!', 'Check passed in 21 s · All tests passed!'),
          at: t.add(const Duration(seconds: 320)),
        ),
        LogEntry(
          LogKind.success,
          tr('Commit 9c41e07 · 4 file · +188 −2', 'Commit 9c41e07 · 4 files · +188 −2'),
          at: t.add(const Duration(seconds: 330)),
        ),
        LogEntry(
          LogKind.result,
          tr('Blocco completato.', 'Block completed.'),
          at: t.add(const Duration(seconds: 331)),
          outcome: RunOutcome.done,
        ),
        LogEntry(
          LogKind.info,
          tr(
            '▶ Blocco 3/5 «Interfaccia principale con lista, filtri e swipe per eliminare» — invocazione 1',
            '▶ Block 3/5 «Main screen with list, filters and swipe to delete» — invocation 1',
          ),
          at: t.add(const Duration(seconds: 340)),
        ),
        LogEntry(
          LogKind.task,
          tr(
            'Lista dei todo con filtri tutti/attivi/completati e swipe per eliminare.',
            'Todo list with all/active/completed filters and swipe to delete.',
          ),
          at: t.add(const Duration(seconds: 342)),
        ),
        LogEntry(LogKind.tool, 'Edit: lib/ui/home_screen.dart', at: t.add(const Duration(seconds: 400))),
        LogEntry(
          LogKind.result,
          tr(
            'Terminata dal supervisore: nessun output per 10 minuti.',
            'Stopped by the supervisor: no output for 10 minutes.',
          ),
          at: t.add(const Duration(seconds: 1000)),
          outcome: RunOutcome.interrupted,
        ),
        LogEntry(
          LogKind.info,
          tr(
            '▶ Blocco 3/5 «Interfaccia principale con lista, filtri e swipe per eliminare» — invocazione 2',
            '▶ Block 3/5 «Main screen with list, filters and swipe to delete» — invocation 2',
          ),
          at: t.add(const Duration(seconds: 1030)),
        ),
        LogEntry(
          LogKind.agent,
          tr(
            'Riprendo da PROGRESS.md: manca il filtro "completati" e lo swipe per eliminare.',
            'Picking up from PROGRESS.md: the "completed" filter and swipe to delete are missing.',
          ),
          at: t.add(const Duration(seconds: 1400)),
        ),
        LogEntry(LogKind.tool, 'Write: lib/ui/widgets/todo_tile.dart', at: t.add(const Duration(seconds: 1700))),
      ]);
      engine.notifyListeners();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text(tr('2. Modello e persistenza', '2. Model and storage')).first);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        // SCREENSHOT_SCALE=2 renders at twice the size, for sharp crops.
        final scale = double.tryParse(Platform.environment['SCREENSHOT_SCALE'] ?? '') ?? 1;
        final image = await boundary.toImage(pixelRatio: scale);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(out!).createSync(recursive: true);
        File(p.join(out, '${isEnglish ? 'en_' : ''}main_${dark ? 'dark' : 'light'}.png'))
            .writeAsBytesSync(bytes!.buffer.asUint8List());
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
        'setupDone': true,
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

  // The guided setup at the first launch, one picture per step: Claude is
  // installed and signed in, Codex is not installed.
  testWidgets('screenshot setup', (tester) async {
    SharedPreferences.setMockInitialValues({'theme': 'dark'});
    final prefs = await SharedPreferences.getInstance();
    HomePage.debugCliProbe = (kind) => kind == AgentKind.claude
        ? ('2.1.319', const AccountStatus(loggedIn: true, email: 'demo@autoloop.dev', plan: 'max'))
        : (null, null);
    addTearDown(() => HomePage.debugCliProbe = null);
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
    Future<void> shot(String name) async {
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final scale = double.tryParse(Platform.environment['SCREENSHOT_SCALE'] ?? '') ?? 1;
        final image = await boundary.toImage(pixelRatio: scale);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(out!).createSync(recursive: true);
        File(p.join(out, '${isEnglish ? 'en_' : ''}setup_$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    await shot('0_language');
    await tester.tap(find.text(tr('Continua', 'Continue')));
    await shot('1_welcome');
    await tester.tap(find.text(tr('Inizia', 'Get started')));
    await shot('2_agent');
    await tester.tap(find.text(tr('Avanti', 'Next')));
    await shot('3_cli_codex_missing');
    await tester.tap(find.text(tr('Indietro', 'Back')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Claude').last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text(tr('Avanti', 'Next')));
    await shot('4_cli_claude_found');
    await tester.tap(find.text(tr('Avanti', 'Next')));
    await shot('5_login');
    await tester.tap(find.text(tr('Avanti', 'Next')));
    await shot('6_project');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: out == null);

  // Read the user's example history from an isolated copy: no probes, writes
  // or changes to the real project's saved settings and progress.
  testWidgets('screenshot real map', (tester) async {
    final source = Directory(p.join(Directory.current.path, 'examples'));
    final snapshot = Directory.systemTemp.createTempSync('autoloop_landing_map_');
    final plan = File(p.join(source.path, 'piano-esempio.md')).copySync(p.join(snapshot.path, 'piano-esempio.md'));
    final saved = Directory(p.join(snapshot.path, '.autoloop'))..createSync();
    final state = jsonDecode(File(p.join(source.path, '.autoloop', 'state.json')).readAsStringSync()) as Map;
    state['planPath'] = plan.path;
    File(p.join(saved.path, 'state.json')).writeAsStringSync(jsonEncode(state));
    File(p.join(source.path, '.autoloop', 'activity-piano-esempio.jsonl'))
        .copySync(p.join(saved.path, 'activity-piano-esempio.jsonl'));
    final engine = LoopEngine(LoopSettings(agent: AgentKind.claude));
    expect(engine.load(workDir: snapshot.path, planPath: plan.path), isNull);
    expect(engine.logs.length, greaterThan(100));
    tester.view.physicalSize = const Size(1388, 128);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Panel(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ActivityMap(engine: engine, selection: ActivitySelection()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final scale = double.tryParse(Platform.environment['SCREENSHOT_SCALE'] ?? '') ?? 1;
      final image = await boundary.toImage(pixelRatio: scale);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(out!).createSync(recursive: true);
      File(p.join(out, '${isEnglish ? 'en_' : ''}real_map.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
  }, skip: out == null);

  testWidgets('screenshot empty', (tester) async {
    SharedPreferences.setMockInitialValues({'setupDone': true});
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
        'setupDone': true,
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
