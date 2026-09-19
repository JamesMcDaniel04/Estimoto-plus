import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/screens/welcome_screen.dart';
import 'package:estimoto_plus/theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'welcome screen lays out without overflow at 200% text scale '
      '(${brightness.name})',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          MaterialApp(
            theme: plusTheme(brightness: brightness),
            home: WelcomeScreen(authAvailable: true, onDemo: () {}),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Estimoto +'), findsOneWidget);
        expect(find.text('A better home\nfor your car care.'), findsOneWidget);
        // The headline scales at most 1.6x even though the system asks for 2x.
        final headline = tester.widget<Text>(
          find.text('A better home\nfor your car care.'),
        );
        final scaler = MediaQuery.textScalerOf(
          tester.element(find.byWidget(headline)),
        );
        expect(scaler.scale(10), closeTo(16, .01));
        await tester.ensureVisible(find.text('Explore demo'));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
