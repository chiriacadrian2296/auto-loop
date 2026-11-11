import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../engine/settings.dart';
import 'app_theme.dart';

/// The agent's logo on a rounded square, in the app's two colours:
/// blue glyph on white (the panel colour), inverted to white on blue when
/// [selected].
class AgentBadge extends StatelessWidget {
  const AgentBadge({super.key, required this.kind, this.size = 32, this.selected = false});

  final AgentKind kind;
  final double size;
  final bool selected;

  static String asset(AgentKind kind) =>
      'assets/images/agents/${kind == AgentKind.codex ? 'codex' : 'claude'}.svg';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bg = selected ? c.primary : c.surface;
    final fg = selected ? Colors.white : c.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.28)),
      child: SvgPicture.asset(
        asset(kind),
        width: size * 0.6,
        height: size * 0.6,
        colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
      ),
    );
  }
}
