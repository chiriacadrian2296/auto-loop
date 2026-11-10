import 'package:flutter/material.dart';

/// Palette taken from the logo: one blue on clean white surfaces.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.surface,
    required this.field,
    required this.border,
    required this.text,
    required this.muted,
    required this.primary,
    required this.primarySoft,
    required this.success,
    required this.warning,
    required this.danger,
  });

  final Color background, surface, field, border, text, muted;
  final Color primary, primarySoft, success, warning, danger;

  static const light = AppColors(
    background: Color(0xFFF3F6FC),
    surface: Color(0xFFFFFFFF),
    field: Color(0xFFF3F6FC),
    border: Color(0xFFE3E9F3),
    text: Color(0xFF0F172A),
    muted: Color(0xFF66748B),
    primary: Color(0xFF3D7BFD),
    primarySoft: Color(0xFFE9F0FF),
    success: Color(0xFF12A150),
    warning: Color(0xFFD97706),
    danger: Color(0xFFE5484D),
  );

  static const dark = AppColors(
    background: Color(0xFF0A0F1C),
    surface: Color(0xFF111827),
    field: Color(0xFF0D1424),
    border: Color(0xFF1E293B),
    text: Color(0xFFE7ECF5),
    muted: Color(0xFF8792A8),
    primary: Color(0xFF5B8FFF),
    primarySoft: Color(0xFF172544),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    danger: Color(0xFFF87171),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) => t < 0.5 || other == null ? this : other;
}

extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}

const uiFont = 'Segoe UI Variable Text';
const uiFallback = ['Segoe UI'];
const mono = 'Cascadia Mono';
const monoFallback = ['Consolas', 'Courier New'];

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.light ? AppColors.light : AppColors.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: c.primary,
    brightness: brightness,
  ).copyWith(
    primary: c.primary,
    onPrimary: Colors.white,
    surface: c.surface,
    onSurface: c.text,
    error: c.danger,
    outline: c.muted,
    outlineVariant: c.border,
    primaryContainer: c.primarySoft,
  );
  final radius = BorderRadius.circular(10);
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    fontFamily: uiFont,
    fontFamilyFallback: uiFallback,
    visualDensity: VisualDensity.compact,
    splashFactory: InkSparkle.splashFactory,
    extensions: [c],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text),
    dividerTheme: DividerThemeData(color: c.border, space: 1, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      labelStyle: TextStyle(color: c.muted, fontSize: 13),
      floatingLabelStyle: TextStyle(color: c.primary, fontSize: 13),
      hintStyle: TextStyle(color: c.muted.withValues(alpha: 0.7), fontSize: 13),
      helperStyle: TextStyle(color: c.muted, fontSize: 11.5),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c.field)),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c.primary, width: 1.4)),
      disabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: c.border,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, fontFamily: uiFont, fontFamilyFallback: uiFallback),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.muted),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.primarySoft : c.surface),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.primary : c.muted),
        textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w600, fontSize: 13, fontFamily: uiFont, fontFamilyFallback: uiFallback)),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.primary : c.border),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.text, borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(color: c.surface, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(c.muted.withValues(alpha: 0.35)),
    ),
  );
}

/// White rounded panel used for the three main columns.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.border),
        boxShadow: Theme.of(context).brightness == Brightness.light
            ? [BoxShadow(color: const Color(0xFF1E3A8A).withValues(alpha: 0.04), blurRadius: 24, offset: const Offset(0, 8))]
            : null,
      ),
      child: child,
    );
  }
}

/// Small uppercase heading inside panels.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: context.colors.muted,
              ),
            ),
          ),
          ?trailing,
        ],
      );
}
