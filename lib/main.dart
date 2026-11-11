import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine/loop_engine.dart';
import 'engine/settings.dart';
import 'ui/app_theme.dart';
import 'ui/home_page.dart';
import 'ui/notifications.dart';
import 'ui/window_controls.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupWindow();
  await Notifier.setup();
  final prefs = await SharedPreferences.getInstance();
  final engine = LoopEngine(LoopSettings.decode(prefs.getString('settings')));
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
