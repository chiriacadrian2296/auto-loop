import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings.dart';

/// A set of CLI logins. The default profile uses the accounts already set up
/// on this computer; every other profile gets its own configuration folders
/// (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`), so its logins never touch the ones
/// the user's own Codex app or Claude Code rely on.
class AccountProfile {
  const AccountProfile({required this.id, required this.name});

  static const defaultId = 'default';
  static const builtIn = AccountProfile(id: defaultId, name: 'Questo computer');

  final String id;
  final String name;

  bool get isDefault => id == defaultId;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  static AccountProfile? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    if (id is! String || name is! String || id.isEmpty || id == defaultId) return null;
    return AccountProfile(id: id, name: name);
  }
}

String profilesRoot() {
  final base = Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? Directory.systemTemp.path;
  return p.join(base, 'AutoLoop', 'profiles');
}

String profileDir(String profileId, AgentKind kind) =>
    p.join(profilesRoot(), profileId, kind == AgentKind.codex ? 'codex' : 'claude');

/// Environment for running [kind] under [profileId]. Empty for the default
/// profile, so the CLI uses its usual configuration.
Map<String, String> profileEnvironment(String profileId, AgentKind kind) {
  if (profileId == AccountProfile.defaultId) return const {};
  final dir = profileDir(profileId, kind);
  Directory(dir).createSync(recursive: true);
  return {kind == AgentKind.codex ? 'CODEX_HOME' : 'CLAUDE_CONFIG_DIR': dir};
}

String newProfileId() => 'p${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

/// Deletes a profile's folders, including its saved logins.
void deleteProfileData(String profileId) {
  if (profileId == AccountProfile.defaultId) return;
  final dir = Directory(p.join(profilesRoot(), profileId));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

class AccountStatus {
  const AccountStatus({required this.loggedIn, this.email, this.plan, this.method, this.error});

  static const unknown = AccountStatus(loggedIn: false, error: 'CLI non disponibile');

  final bool loggedIn;
  final String? email;
  final String? plan;

  /// How the CLI is authenticated (ChatGPT, claude.ai, API key…).
  final String? method;
  final String? error;
}

Future<AccountStatus> accountStatus(AgentKind kind, String exe, String profileId) async {
  if (exe.isEmpty || !File(exe).existsSync()) return AccountStatus.unknown;
  final env = profileEnvironment(profileId, kind);
  try {
    if (kind == AgentKind.claude) {
      final r = await Process.run(
        exe,
        ['auth', 'status'],
        environment: env,
        stdoutEncoding: utf8,
      ).timeout(const Duration(seconds: 20));
      return parseClaudeStatus(r.stdout.toString());
    }
    final r = await Process.run(
      exe,
      ['login', 'status'],
      environment: env,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 20));
    final text = '${r.stdout}\n${r.stderr}';
    final line = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .firstWhere(
          (l) => l.toLowerCase().startsWith('logged in') || l.toLowerCase().startsWith('not logged'),
          orElse: () => '',
        );
    if (r.exitCode != 0 || !line.toLowerCase().startsWith('logged in')) {
      return const AccountStatus(loggedIn: false);
    }
    final method = RegExp(r'using (.+)$', caseSensitive: false).firstMatch(line)?.group(1)?.trim();
    final home = env['CODEX_HOME'] ?? p.join(Platform.environment['USERPROFILE'] ?? '', '.codex');
    final (email, plan) = codexIdentity(p.join(home, 'auth.json'));
    return AccountStatus(loggedIn: true, method: method, email: email, plan: plan);
  } catch (e) {
    return AccountStatus(loggedIn: false, error: '$e');
  }
}

AccountStatus parseClaudeStatus(String json) {
  try {
    final j = jsonDecode(json.trim()) as Map;
    final logged = j['loggedIn'] == true;
    return AccountStatus(
      loggedIn: logged,
      email: j['email'] as String?,
      plan: (j['subscriptionType'] ?? j['planTier']) as String?,
      method: j['authMethod'] == 'none' ? null : j['authMethod'] as String?,
    );
  } catch (_) {
    return const AccountStatus(loggedIn: false, error: 'Stato non leggibile');
  }
}

/// Codex does not print the account, but its login file holds an OpenID
/// token whose public claims name it. Only those two claims are read.
(String?, String?) codexIdentity(String authFile) {
  try {
    final f = File(authFile);
    if (!f.existsSync()) return (null, null);
    final j = jsonDecode(f.readAsStringSync()) as Map;
    final token = (j['tokens'] as Map?)?['id_token'];
    if (token is! String) return (null, null);
    final parts = token.split('.');
    if (parts.length < 2) return (null, null);
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
    final auth = claims['https://api.openai.com/auth'];
    return (claims['email'] as String?, auth is Map ? auth['chatgpt_plan_type'] as String? : null);
  } catch (_) {
    return (null, null);
  }
}

/// Opens the CLI's own sign-in in a console window (it shows a browser page
/// and sometimes asks to paste a code). Completes when that window closes.
Future<void> startLogin(AgentKind kind, String exe, String profileId) async {
  final env = profileEnvironment(profileId, kind);
  final name = kind == AgentKind.codex ? 'Codex' : 'Claude';
  final command = kind == AgentKind.codex ? 'login' : 'auth login';
  final script = File(p.join(Directory.systemTemp.path, 'autoloop-login-${kind.name}.cmd'));
  final sets = env.entries.map((e) => 'set "${e.key}=${e.value}"').join('\r\n');
  script.writeAsStringSync(
    [
      '@echo off',
      'chcp 65001 >nul',
      'title Accesso a $name - AutoLoop',
      sets,
      'echo Accesso a $name: completa la procedura nel browser che si apre.',
      'echo.',
      '"$exe" $command',
      'echo.',
      'echo Fatto. Premi un tasto per chiudere questa finestra e tornare ad AutoLoop.',
      'pause >nul',
    ].where((l) => l.isNotEmpty).join('\r\n'),
  );
  // Start-Process gives the script a visible console of its own (the app's
  // other child processes run hidden) and -Wait returns when it is closed.
  final quoted = script.path.replaceAll("'", "''");
  final proc = await Process.start('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "Start-Process -FilePath '$quoted' -Wait",
  ]);
  await proc.exitCode;
}

Future<String?> logout(AgentKind kind, String exe, String profileId) async {
  final env = profileEnvironment(profileId, kind);
  final args = kind == AgentKind.codex ? ['logout'] : ['auth', 'logout'];
  try {
    final r = await Process.run(exe, args, environment: env).timeout(const Duration(seconds: 30));
    return r.exitCode == 0 ? null : '${r.stderr}${r.stdout}'.trim();
  } catch (e) {
    return '$e';
  }
}
