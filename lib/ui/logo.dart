import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The AutoLoop mark (same geometry as assets/logo/logo.svg): a ring cut by a
/// 45-degree band, with a bar running along the band.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 28, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _LogoPainter(color ?? Theme.of(context).colorScheme.primary)),
  );
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Design space is -128..128, centred on the origin.
    canvas
      ..translate(size.width / 2, size.height / 2)
      ..scale(size.shortestSide / 256);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    Path piece(double rotation) {
      final outer = Rect.fromCircle(center: Offset.zero, radius: 125);
      final inner = Rect.fromCircle(center: Offset.zero, radius: 88);
      final o0 = math.atan2(-100, -75) + rotation;
      final o1 = math.atan2(75, 100) + rotation;
      final i0 = math.atan2(-73.457, -48.457) + rotation;
      final i1 = math.atan2(48.457, 73.457) + rotation;
      return Path()
        ..arcTo(outer, o0, o1 - o0, true)
        ..arcTo(inner, i1, i0 - i1, false)
        ..close();
    }

    canvas
      ..drawPath(piece(0), paint)
      ..drawPath(piece(math.pi), paint)
      ..drawPath(
        Path()
          ..moveTo(-72, -47)
          ..lineTo(-22, -47)
          ..lineTo(72, 47)
          ..lineTo(22, 47)
          ..close(),
        paint,
      );
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.color != color;
}
