import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/theme.dart';

void main() {
  test('light theme keeps the original brand colors', () {
    final theme = plusTheme();
    expect(theme.brightness, Brightness.light);
    expect(theme.colorScheme.primary, PlusColors.blue);
    expect(theme.colorScheme.surface, Colors.white);
    expect(theme.scaffoldBackgroundColor, PlusColors.canvas);
    expect(theme.cardTheme.color, Colors.white);
    expect(theme.textTheme.bodyMedium!.color, PlusColors.ink);
    expect(theme.extension<PlusPalette>(), PlusPalette.light);
    expect(PlusPalette.light.banner, const Color(0xFFE5F0F7));
  });

  test('dark theme inverts surfaces and registers the dark palette', () {
    final theme = plusTheme(brightness: Brightness.dark);
    expect(theme.brightness, Brightness.dark);
    final palette = theme.extension<PlusPalette>()!;
    expect(palette, PlusPalette.dark);
    expect(theme.scaffoldBackgroundColor, palette.canvas);
    expect(theme.cardTheme.color, palette.card);
    expect(theme.colorScheme.surface, palette.card);
    expect(theme.textTheme.bodyMedium!.color, palette.ink);
    expect(palette.ink.computeLuminance(), greaterThan(.5));
    expect(palette.card.computeLuminance(), lessThan(.1));
    // Brand navy surfaces stay navy in both modes.
    expect(palette.navyCard, PlusColors.navy);
  });

  testWidgets('context.plus follows the active theme', (tester) async {
    late PlusPalette seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: plusTheme(),
        darkTheme: plusTheme(brightness: Brightness.dark),
        themeMode: ThemeMode.dark,
        home: Builder(
          builder: (context) {
            seen = context.plus;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, PlusPalette.dark);
  });

  testWidgets('context.plus falls back when no palette is registered', (
    tester,
  ) async {
    late PlusPalette seen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            seen = context.plus;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, PlusPalette.light);
  });
}
