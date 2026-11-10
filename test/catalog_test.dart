import 'package:auto_loop/engine/cli_locator.dart';
import 'package:auto_loop/engine/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('claude help parsing', () {
    const help = '''
  --effort <level>                      Effort level for the current session
                                        (low, medium, high, xhigh, max)
  --model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
                                        model's full name.
  -n, --name <name>                     Set a display name
''';
    final c = parseClaudeHelp(help);
    expect(c.models.map((m) => m.id), ['fable', 'opus', 'sonnet']);
    expect(c.effortsFor('opus'), ['low', 'medium', 'high', 'xhigh', 'max']);
  });

  test('codex catalog parsing hides hidden models and keeps per-model levels', () {
    const json = '{"models":['
        '{"slug":"b","display_name":"B","visibility":"list","priority":2,"default_reasoning_level":"medium",'
        '"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]},'
        '{"slug":"a","display_name":"A","visibility":"list","priority":1,"default_reasoning_level":"low",'
        '"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"ultra"}]},'
        '{"slug":"h","visibility":"hide"}]}';
    final c = parseCodexCatalog(json);
    expect(c.models.map((m) => m.id), ['a', 'b']);
    expect(c.effortsFor('a'), contains('ultra'));
    expect(c.effortsFor(''), ['low', 'medium']); // common to every model
    expect(c.find('b')!.defaultEffort, 'medium');
  });

  for (final kind in AgentKind.values) {
    test('real ${kind.name} catalog (no tokens)', () async {
      final exe = await locateCli(kind);
      if (exe == null) return markTestSkipped('CLI not installed');
      final c = await discoverCatalog(kind, exe);
      // ignore: avoid_print
      print('${kind.name}: ${c.models.map((m) => '${m.id}[${c.effortsFor(m.id).join('/')}]').join(', ')}'
          ' | global: ${c.efforts}');
      expect(c.models, isNotEmpty);
      expect(c.effortsFor(''), isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
