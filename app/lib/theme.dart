import 'package:flutter/material.dart';

abstract final class PlusColors {
  static const blue = Color(0xFF1565C0);
  static const navy = Color(0xFF0D3F7A);
  static const teal = Color(0xFF00B8A9);
  static const canvas = Color(0xFFF3F5F8);
  static const ink = Color(0xFF172B4D);
  static const muted = Color(0xFF53657D);
  static const line = Color(0xFFDEE5EE);
}

/// Brightness-aware brand palette. Read it with `context.plus` so screens
/// never hardcode light-only colors.
///
/// * `navy`, `teal`, `success`: accent colors that stay readable on
///   `canvas` / `card` in either mode (dark mode lightens them).
/// * `navyCard`, `onNavy`, `onNavyMuted`: the fixed brand-navy surface used by
///   illustration cards, chat bubbles and the vehicle hero, plus the text
///   colors that read on it in both modes.
@immutable
class PlusPalette extends ThemeExtension<PlusPalette> {
  const PlusPalette({
    required this.navy,
    required this.teal,
    required this.canvas,
    required this.ink,
    required this.muted,
    required this.line,
    required this.banner,
    required this.onBanner,
    required this.card,
    required this.field,
    required this.soft,
    required this.success,
    required this.onSuccess,
    required this.successSoft,
    required this.successLine,
    required this.navyCard,
    required this.onNavy,
    required this.onNavyMuted,
  });

  /// Brand navy as an accent (text, icons, pills) on regular surfaces.
  final Color navy;
  final Color teal;

  /// Scaffold background.
  final Color canvas;

  /// Primary and secondary text.
  final Color ink;
  final Color muted;

  /// Dividers, outlines and input borders.
  final Color line;

  /// Demo banner background and its text color.
  final Color banner;
  final Color onBanner;

  /// Card, sheet and bubble surface.
  final Color card;

  /// Input fill.
  final Color field;

  /// Soft neutral fill (idle steps, tracks).
  final Color soft;

  /// Positive status (approved, completed, saved) and its companions.
  final Color success;
  final Color onSuccess;
  final Color successSoft;
  final Color successLine;

  /// Fixed brand-navy surface that stays navy in both modes.
  final Color navyCard;
  final Color onNavy;
  final Color onNavyMuted;

  static const light = PlusPalette(
    navy: PlusColors.navy,
    teal: PlusColors.teal,
    canvas: PlusColors.canvas,
    ink: PlusColors.ink,
    muted: PlusColors.muted,
    line: PlusColors.line,
    banner: Color(0xFFE5F0F7),
    onBanner: PlusColors.navy,
    card: Colors.white,
    field: Color(0xFFF5F7FA),
    soft: Color(0xFFECF0F5),
    success: Color(0xFF08796D),
    onSuccess: Colors.white,
    successSoft: Color(0xFFE5F5F2),
    successLine: Color(0xFF8BD2C7),
    navyCard: PlusColors.navy,
    onNavy: Colors.white,
    onNavyMuted: Color(0xFFC5DAED),
  );

  static const dark = PlusPalette(
    navy: Color(0xFFA9C9F0),
    teal: Color(0xFF4FD6C8),
    canvas: Color(0xFF0F1620),
    ink: Color(0xFFE7ECF3),
    muted: Color(0xFFA6B3C5),
    line: Color(0xFF2E3B4E),
    banner: Color(0xFF1B2E47),
    onBanner: Color(0xFFBFD8F6),
    card: Color(0xFF1A2330),
    field: Color(0xFF232E3D),
    soft: Color(0xFF2A3546),
    success: Color(0xFF5FD3C3),
    onSuccess: Color(0xFF03302B),
    successSoft: Color(0xFF16332F),
    successLine: Color(0xFF2F6B62),
    navyCard: PlusColors.navy,
    onNavy: Colors.white,
    onNavyMuted: Color(0xFFC5DAED),
  );

  static PlusPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  @override
  PlusPalette copyWith({
    Color? navy,
    Color? teal,
    Color? canvas,
    Color? ink,
    Color? muted,
    Color? line,
    Color? banner,
    Color? onBanner,
    Color? card,
    Color? field,
    Color? soft,
    Color? success,
    Color? onSuccess,
    Color? successSoft,
    Color? successLine,
    Color? navyCard,
    Color? onNavy,
    Color? onNavyMuted,
  }) => PlusPalette(
    navy: navy ?? this.navy,
    teal: teal ?? this.teal,
    canvas: canvas ?? this.canvas,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    line: line ?? this.line,
    banner: banner ?? this.banner,
    onBanner: onBanner ?? this.onBanner,
    card: card ?? this.card,
    field: field ?? this.field,
    soft: soft ?? this.soft,
    success: success ?? this.success,
    onSuccess: onSuccess ?? this.onSuccess,
    successSoft: successSoft ?? this.successSoft,
    successLine: successLine ?? this.successLine,
    navyCard: navyCard ?? this.navyCard,
    onNavy: onNavy ?? this.onNavy,
    onNavyMuted: onNavyMuted ?? this.onNavyMuted,
  );

  @override
  PlusPalette lerp(ThemeExtension<PlusPalette>? other, double t) {
    if (other is! PlusPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return PlusPalette(
      navy: mix(navy, other.navy),
      teal: mix(teal, other.teal),
      canvas: mix(canvas, other.canvas),
      ink: mix(ink, other.ink),
      muted: mix(muted, other.muted),
      line: mix(line, other.line),
      banner: mix(banner, other.banner),
      onBanner: mix(onBanner, other.onBanner),
      card: mix(card, other.card),
      field: mix(field, other.field),
      soft: mix(soft, other.soft),
      success: mix(success, other.success),
      onSuccess: mix(onSuccess, other.onSuccess),
      successSoft: mix(successSoft, other.successSoft),
      successLine: mix(successLine, other.successLine),
      navyCard: mix(navyCard, other.navyCard),
      onNavy: mix(onNavy, other.onNavy),
      onNavyMuted: mix(onNavyMuted, other.onNavyMuted),
    );
  }
}

extension PlusThemeX on BuildContext {
  /// The brand palette for the current theme. Falls back to the palette for
  /// the theme's brightness when a bare `ThemeData` (tests) is in use.
  PlusPalette get plus {
    final theme = Theme.of(this);
    return theme.extension<PlusPalette>() ?? PlusPalette.of(theme.brightness);
  }
}

ThemeData plusTheme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;
  final palette = PlusPalette.of(brightness);
  final scheme = dark
      ? ColorScheme.fromSeed(
          seedColor: PlusColors.blue,
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFF8DBBF5),
          onPrimary: const Color(0xFF062A52),
          secondary: palette.teal,
          surface: palette.card,
          onSurface: palette.ink,
          onSurfaceVariant: palette.muted,
          outline: palette.line,
          outlineVariant: palette.line,
        )
      : ColorScheme.fromSeed(seedColor: PlusColors.blue).copyWith(
          primary: PlusColors.blue,
          secondary: PlusColors.teal,
          surface: Colors.white,
          onSurface: PlusColors.ink,
          onSurfaceVariant: PlusColors.muted,
        );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    extensions: [palette],
    scaffoldBackgroundColor: palette.canvas,
    textTheme: base.textTheme.copyWith(
      headlineMedium: TextStyle(
        fontSize: 28,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -.7,
        color: palette.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
        color: palette.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: palette.ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: palette.ink),
      bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: palette.ink),
      bodySmall: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.canvas,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: palette.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.field,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.line),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: palette.line),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: palette.line,
      thickness: 1,
      space: 1,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.card,
      showDragHandle: true,
    ),
    dialogTheme: dark
        ? DialogThemeData(
            backgroundColor: palette.card,
            surfaceTintColor: Colors.transparent,
          )
        : null,
    popupMenuTheme: dark
        ? PopupMenuThemeData(
            color: palette.card,
            surfaceTintColor: Colors.transparent,
          )
        : null,
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
