import 'dart:io';

import 'package:flutter/foundation.dart';

/// The languages of the interface (and of the instructions to the agent).
enum AppLang {
  it('Italiano'),
  en('English');

  const AppLang(this.label);
  final String label;

  /// The language of Windows, when the user has not chosen one.
  static AppLang get system {
    final locale = Platform.localeName.toLowerCase();
    return locale.startsWith('it') ? AppLang.it : AppLang.en;
  }

  static AppLang fromName(String? name) => AppLang.values.where((l) => l.name == name).firstOrNull ?? system;
}

/// The language in use; the app rebuilds when it changes.
final appLang = ValueNotifier<AppLang>(AppLang.it);

bool get isEnglish => appLang.value == AppLang.en;

/// The text in the language in use: every visible string goes through here,
/// with both versions side by side.
String tr(String it, String en) => appLang.value == AppLang.en ? en : it;
