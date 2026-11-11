import 'dart:io';

import 'package:auto_loop/engine/accounts.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('project settings are saved per folder and keep global ones', () {
    final a = Directory.systemTemp.createTempSync('al_proj_a_');
    final b = Directory.systemTemp.createTempSync('al_proj_b_');
    final s = LoopSettings(
      codexPath: 'C:/codex.exe',
      profiles: [const AccountProfile(id: 'pw', name: 'Lavoro')],
    );

    s
      ..agent = AgentKind.claude
      ..claudeModel = 'opus'
      ..verifyCommand = 'flutter test'
      ..profileId = 'pw'
      ..saveProject(a.path);
    expect(File(LoopSettings.projectFile(a.path)).existsSync(), isTrue);
    expect(File('${a.path}/.autoloop/.gitignore').readAsStringSync(), '*\n');

    s
      ..agent = AgentKind.codex
      ..verifyCommand = ''
      ..profileId = AccountProfile.defaultId
      ..saveProject(b.path);

    expect(s.loadProject(a.path), isTrue);
    expect((s.agent, s.claudeModel, s.verifyCommand, s.profileId), (AgentKind.claude, 'opus', 'flutter test', 'pw'));
    expect(s.codexPath, 'C:/codex.exe'); // global, untouched

    expect(s.loadProject(b.path), isTrue);
    expect((s.agent, s.verifyCommand, s.profileId), (AgentKind.codex, '', AccountProfile.defaultId));

    final empty = Directory.systemTemp.createTempSync('al_proj_c_');
    expect(s.loadProject(empty.path), isFalse);
  });

  test('a profile deleted since falls back to the system one', () {
    final dir = Directory.systemTemp.createTempSync('al_proj_d_');
    LoopSettings(profileId: 'gone', profiles: [const AccountProfile(id: 'gone', name: 'X')]).saveProject(dir.path);
    final s = LoopSettings()..loadProject(dir.path);
    expect(s.profileId, AccountProfile.defaultId);
  });
}
