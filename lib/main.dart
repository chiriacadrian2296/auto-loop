import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine/loop_engine.dart';
import 'engine/settings.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final engine = LoopEngine(LoopSettings.decode(prefs.getString('settings')));
  runApp(AutoLoopApp(engine: engine, prefs: prefs));
}

class AutoLoopApp extends StatelessWidget {
  const AutoLoopApp({super.key, required this.engine, required this.prefs});

  final LoopEngine engine;
  final SharedPreferences prefs;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D7BFD), brightness: b),
          visualDensity: VisualDensity.compact,
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        );
    return MaterialApp(
      title: 'AutoLoop',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomePage(engine: engine, prefs: prefs),
    );
  }
}
