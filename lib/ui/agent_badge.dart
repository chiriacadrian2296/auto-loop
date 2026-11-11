import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/settings.dart';

/// A small square badge that identifies each agent at a glance. These are
/// AutoLoop's own marks (a prompt for Codex, a starburst for Claude), not the
/// vendors' logos.
class AgentBadge extends StatelessWidget {
  const AgentBadge({super.key, required this.kind, this.size = 32});

  final AgentKind kind;
  final double size;

  static const claudeColor = Color(0xFFD97757);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (Color bg, Widget glyph) = switch (kind) {
      AgentKind.codex => (
          dark ? const Color(0xFF26303F) : const Color(0xFF111827),
          Icon(Icons.terminal_rounded, size: size * 0.58, color: Colors.white),
        ),
      AgentKind.claude => (
          claudeColor,
          CustomPaint(size: Size.square(size * 0.56), painter: _StarburstPainter()),
        ),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.28)),
      child: glyph,
    );
  }
}

class _StarburstPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = r * 0.26
      ..strokeCap = StrokeCap.round;
    const rays = 8;
    for (var i = 0; i < rays; i++) {
      final a = i * math.pi / (rays / 2) + math.pi / 8;
      // Alternate ray lengths for a hand-drawn spark rather than a plain star.
      final len = i.isEven ? r : r * 0.72;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * r * 0.18,
        c + Offset(math.cos(a), math.sin(a)) * len,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StarburstPainter old) => false;
}
