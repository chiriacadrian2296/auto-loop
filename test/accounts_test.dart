import 'dart:convert';
import 'dart:io';

import 'package:auto_loop/engine/accounts.dart';
import 'package:auto_loop/engine/cli_locator.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('claude status parsing', () {
    final s = parseClaudeStatus('{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","subscriptionType":"pro"}');
    expect((s.loggedIn, s.email, s.plan), (true, 'a@b.c', 'pro'));
    expect(parseClaudeStatus('{"loggedIn":false,"authMethod":"none"}').loggedIn, isFalse);
  });

  test('codex identity reads only the public token claims', () {
    final dir = Directory.systemTemp.createTempSync('al_auth_');
    String b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final token =
        '${b64({'alg': 'none'})}.${b64({
          'email': 'x@y.z',
          'https://api.openai.com/auth': {'chatgpt_plan_type': 'plus'},
        })}.sig';
    final f = File(p.join(dir.path, 'auth.json'))
      ..writeAsStringSync(
        jsonEncode({
          'tokens': {'id_token': token},
        }),
      );
    expect(codexIdentity(f.path), ('x@y.z', 'plus'));
    expect(codexIdentity(p.join(dir.path, 'missing.json')), (null, null));
  });

  test('profiles round-trip and isolate config folders', () {
    final s = LoopSettings(
      profileId: 'pabc',
      profiles: [const AccountProfile(id: 'pabc', name: 'Lavoro')],
    );
    final back = LoopSettings.decode(s.encode());
    expect(back.profile.name, 'Lavoro');
    expect(back.allProfiles.first.isDefault, isTrue);
    expect(profileEnvironment(AccountProfile.defaultId, AgentKind.codex), isEmpty);
    expect(profileEnvironment('pabc', AgentKind.claude)['CLAUDE_CONFIG_DIR'], endsWith(p.join('pabc', 'claude')));
    deleteProfileData('pabc');
  });

  // Reads the real login state without changing it (no tokens used).
  for (final kind in AgentKind.values) {
    test('real ${kind.name} status: system profile vs empty profile', () async {
      final exe = await locateCli(kind);
      if (exe == null) return markTestSkipped('CLI not installed');
      final system = await accountStatus(kind, exe, AccountProfile.defaultId);
      final empty = await accountStatus(kind, exe, 'ptest');
      deleteProfileData('ptest');
      // ignore: avoid_print
      print(
        '${kind.name}: system loggedIn=${system.loggedIn} method=${system.method} '
        'plan=${system.plan} hasEmail=${system.email != null}; empty loggedIn=${empty.loggedIn}',
      );
      expect(empty.loggedIn, isFalse);
    }, timeout: const Timeout(Duration(minutes: 1)));
  }
}
