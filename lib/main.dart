import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo.dart';
import 'engine/loop_engine.dart';
import 'engine/settings.dart';
import 'ui/app_theme.dart';
import 'ui/home_page.dart';
import 'ui/notifications.dart';
import 'ui/window_controls.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  setupWindow();
  await Notifier.setup();
  var prefs = await SharedPreferences.getInstance();

  // `--demo`: sample plan and history, in-memory preferences, no agent runs.
  DemoData? demo;
  if (args.contains('--demo')) {
    demo = await DemoData.create();
    // An in-memory store: the demo starts from the user's settings and theme
    // but never writes their real preferences.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'workDir': demo.workDir,
      'planPath': demo.planPath,
      'theme': ?prefs.getString('theme'),
      'settings': ?prefs.getString('settings'),
    });
    prefs = await SharedPreferences.getInstance();
  }

  final engine = LoopEngine(LoopSettings.decode(prefs.getString('settings')));
  if (demo != null) {
    engine
      ..demo = true
      ..logs.addAll(demo.logs);
  }
  runApp(AutoLoopApp(engine: engine, prefs: prefs));
}

class AutoLoopApp extends StatefulWidget {
  const AutoLoopApp({super.key, required this.engine, required this.prefs});

  final LoopEngine engine;
  final SharedPreferences prefs;

  @override
  State<AutoLoopApp> createState() => _AutoLoopAppState();
}

class _AutoLoopAppState extends State<AutoLoopApp> {
  // 'system' (default), 'light' or 'dark'.
  late final ValueNotifier<ThemeMode> _mode =
      ValueNotifier(
        ThemeMode.values.firstWhere((m) => m.name == widget.prefs.getString('theme'), orElse: () => ThemeMode.system),
      )..addListener(() {
        widget.prefs.setString('theme', _mode.value.name);
        setState(() {});
      });

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AutoLoop',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: _mode.value,
    home: HomePage(engine: widget.engine, prefs: widget.prefs, themeMode: _mode),
  );
}
