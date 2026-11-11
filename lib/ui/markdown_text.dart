import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The small part of Markdown agents actually write in their messages:
/// headings, bullet and numbered lists, fenced code, **bold**, *italic* and
/// `inline code`. Anything else is shown as plain text.
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.text, {super.key, required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final blocks = <Widget>[];
    final lines = text.split('\n');
    final code = StringBuffer();
    var inCode = false;

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trimLeft().startsWith('```')) {
        if (inCode) {
          blocks.add(_CodeBlock(code.toString().trimRight()));
          code.clear();
        }
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        code.writeln(raw);
        continue;
      }
      if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 6));
        continue;
      }
      final heading = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line);
      final bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$').firstMatch(line);
      final numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$').firstMatch(line);
      if (heading != null) {
        blocks.add(Text.rich(_inline(heading.group(1)!, style.copyWith(fontWeight: FontWeight.w700), c)));
      } else if (bullet != null || numbered != null) {
        final indent = (bullet?.group(1) ?? numbered!.group(1)!).length;
        final marker = bullet != null ? '•' : '${numbered!.group(2)}.';
        final body = bullet?.group(2) ?? numbered!.group(3)!;
        blocks.add(
          Padding(
            padding: EdgeInsets.only(left: 4.0 + indent * 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 18,
                  child: Text(marker, style: style.copyWith(color: c.muted)),
                ),
                Expanded(child: Text.rich(_inline(body, style, c))),
              ],
            ),
          ),
        );
      } else {
        blocks.add(Text.rich(_inline(line, style, c)));
      }
    }
    if (inCode && code.isNotEmpty) blocks.add(_CodeBlock(code.toString().trimRight()));

    // Drop blank spacers at the edges.
    while (blocks.isNotEmpty && blocks.first is SizedBox) {
      blocks.removeAt(0);
    }
    while (blocks.isNotEmpty && blocks.last is SizedBox) {
      blocks.removeLast();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks);
  }

  static final _token = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*|_[^_\s][^_]*_)');

  TextSpan _inline(String text, TextStyle base, AppColors c) {
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start)));
      final t = m.group(0)!;
      if (t.startsWith('**')) {
        spans.add(
          TextSpan(
            text: t.substring(2, t.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (t.startsWith('`')) {
        spans.add(
          TextSpan(
            text: t.substring(1, t.length - 1),
            style: TextStyle(
              fontFamily: mono,
              fontFamilyFallback: monoFallback,
              fontSize: (base.fontSize ?? 13.5) - 1,
              backgroundColor: c.field,
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: t.substring(1, t.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      pos = m.end;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return TextSpan(style: base, children: spans);
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.code);
  final String code;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(8)),
      child: Text(
        code,
        style: TextStyle(fontFamily: mono, fontFamilyFallback: monoFallback, fontSize: 12, height: 1.45, color: c.text),
      ),
    );
  }
}
