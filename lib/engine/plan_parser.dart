/// Splits a free-form text plan (Markdown or plain text) into ordered blocks.
///
/// The loop works one block at a time, so the parser tries the most natural
/// structure first: Markdown headings, then a top-level numbered list, then
/// checkboxes, then top-level bullets. If nothing fits, the whole document is a
/// single block and the agent decides how to proceed.
library;

enum SplitStrategy {
  auto('Automatico'),
  headings('Titoli Markdown'),
  numbered('Elenco numerato'),
  checkboxes('Checkbox'),
  bullets('Elenco puntato'),
  whole('Piano unico');

  const SplitStrategy(this.label);
  final String label;
}

class PlanBlock {
  PlanBlock({
    required this.index,
    required this.title,
    required this.body,
    this.preChecked = false,
  });

  final int index;
  final String title;

  /// Full text of the block, including its title line.
  final String body;

  /// The block was already ticked (`- [x]`) in the source document.
  final bool preChecked;

  /// Stable across re-parses as long as the block's text is unchanged, so the
  /// progress of untouched blocks survives edits to other parts of the plan.
  String get id => fnv1a('${title.trim()}\n${body.trim()}');
}

class ParsedPlan {
  ParsedPlan({
    required this.raw,
    required this.preamble,
    required this.blocks,
    required this.strategy,
  });

  final String raw;

  /// Text before the first block (goals, context, constraints).
  final String preamble;
  final List<PlanBlock> blocks;

  /// The strategy that was actually applied (never [SplitStrategy.auto]).
  final SplitStrategy strategy;

  String get hash => fnv1a(raw);
}

String fnv1a(String input) {
  var hash = 0xcbf29ce484222325;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

final _heading = RegExp(r'^(#{1,6})\s+(.+?)\s*#*\s*$');
final _numbered = RegExp(r'^(\d{1,3})[.)]\s+(.+)$');
final _checkbox = RegExp(r'^[-*+]\s+\[([ xX])\]\s+(.+)$');
final _bullet = RegExp(r'^[-*+]\s+(?!\[[ xX]\])(.+)$');
final _fence = RegExp(r'^\s*(```|~~~)');

ParsedPlan parsePlan(String raw, {SplitStrategy strategy = SplitStrategy.auto}) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = text.split('\n');

  // Lines inside fenced code blocks must never start a block.
  final inFence = List<bool>.filled(lines.length, false);
  var open = false;
  for (var i = 0; i < lines.length; i++) {
    if (_fence.hasMatch(lines[i])) {
      inFence[i] = true;
      open = !open;
    } else {
      inFence[i] = open;
    }
  }

  ParsedPlan? tryStrategy(SplitStrategy s) {
    switch (s) {
      case SplitStrategy.headings:
        return _splitByHeadings(text, lines, inFence);
      case SplitStrategy.numbered:
        return _splitByPattern(text, lines, inFence, s, (line) {
          final m = _numbered.firstMatch(line);
          return m == null ? null : (m.group(2)!, false);
        });
      case SplitStrategy.checkboxes:
        return _splitByPattern(text, lines, inFence, s, (line) {
          final m = _checkbox.firstMatch(line);
          return m == null ? null : (m.group(2)!, m.group(1)!.toLowerCase() == 'x');
        });
      case SplitStrategy.bullets:
        return _splitByPattern(text, lines, inFence, s, (line) {
          final m = _bullet.firstMatch(line);
          return m == null ? null : (m.group(1)!, false);
        });
      case SplitStrategy.whole:
      case SplitStrategy.auto:
        return null;
    }
  }

  if (strategy == SplitStrategy.auto) {
    for (final s in const [
      SplitStrategy.headings,
      SplitStrategy.numbered,
      SplitStrategy.checkboxes,
      SplitStrategy.bullets,
    ]) {
      final parsed = tryStrategy(s);
      if (parsed != null) return parsed;
    }
  } else if (strategy != SplitStrategy.whole) {
    final parsed = tryStrategy(strategy);
    if (parsed != null) return parsed;
  }
  return _whole(text);
}

ParsedPlan _whole(String text) {
  final firstLine = text
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => 'Piano');
  return ParsedPlan(
    raw: text,
    preamble: '',
    strategy: SplitStrategy.whole,
    blocks: [
      PlanBlock(
        index: 0,
        title: _clean(firstLine.replaceFirst(RegExp(r'^#+\s*'), '')),
        body: text.trim(),
      ),
    ],
  );
}

ParsedPlan? _splitByHeadings(String text, List<String> lines, List<bool> inFence) {
  final counts = <int, int>{};
  for (var i = 0; i < lines.length; i++) {
    if (inFence[i]) continue;
    final m = _heading.firstMatch(lines[i]);
    if (m != null) counts.update(m.group(1)!.length, (v) => v + 1, ifAbsent: () => 1);
  }
  // The shallowest level that occurs at least twice is the "section" level; a
  // lone `# Title` above it becomes part of the preamble.
  final levels = counts.keys.where((l) => counts[l]! >= 2).toList()..sort();
  if (levels.isEmpty) return null;
  final level = levels.first;
  return _splitByPattern(text, lines, inFence, SplitStrategy.headings, (line) {
    final m = _heading.firstMatch(line);
    if (m == null || m.group(1)!.length != level) return null;
    return (m.group(2)!, false);
  });
}

ParsedPlan? _splitByPattern(
  String text,
  List<String> lines,
  List<bool> inFence,
  SplitStrategy strategy,
  (String, bool)? Function(String line) match,
) {
  final starts = <int>[];
  final titles = <String>[];
  final checked = <bool>[];
  for (var i = 0; i < lines.length; i++) {
    if (inFence[i]) continue;
    final m = match(lines[i]);
    if (m != null) {
      starts.add(i);
      titles.add(m.$1);
      checked.add(m.$2);
    }
  }
  if (starts.length < 2) return null;

  final preamble = lines.sublist(0, starts.first).join('\n').trim();
  final blocks = <PlanBlock>[];
  for (var b = 0; b < starts.length; b++) {
    final end = b + 1 < starts.length ? starts[b + 1] : lines.length;
    blocks.add(PlanBlock(
      index: b,
      title: _clean(titles[b]),
      body: lines.sublist(starts[b], end).join('\n').trim(),
      preChecked: checked[b],
    ));
  }
  return ParsedPlan(raw: text, preamble: preamble, blocks: blocks, strategy: strategy);
}

String _clean(String title) {
  var t = title.replaceAll(RegExp(r'[*_`]'), '').trim();
  if (t.length > 120) t = '${t.substring(0, 117)}...';
  return t.isEmpty ? 'Blocco' : t;
}
