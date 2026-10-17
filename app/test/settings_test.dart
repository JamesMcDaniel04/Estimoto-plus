import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/app.dart';
import 'package:estimoto_plus/build_info.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/settings_screen.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

class _Repository extends DemoPlusRepository {
  final bodies = <Json>[];
  @override
  Future<Json> saveProfile(Json body) {
    bodies.add(Map.of(body));
    return super.saveProfile(body);
  }
}

Future<PlusController> _controller(_Repository repository) async {
  await repository.saveProfile({'phone': '3035550100'});
  final controller = PlusController(repository);
  await controller.refresh();
  return controller;
}

Future<void> _mountScreen(
  WidgetTester tester,
  PlusController controller, {
  VoidCallback? onExit,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      home: SettingsScreen(controller: controller, onExit: onExit),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('account menu sign-out also asks for confirmation', (
    tester,
  ) async {
    var exits = 0;
    final controller = await _controller(_Repository());
    await tester.pumpWidget(
      EstimotoPlusApp(controller: controller, onExit: () => exits++),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Account options'));
    await _tap(tester, find.text('Leave demo'));
    expect(exits, 0);
    expect(find.text('Leave the demo?'), findsOneWidget);
    await _tap(tester, find.text('Stay'));
    expect(exits, 0);
  });
  testWidgets('settings opens from the account menu with the email read-only', (
    tester,
  ) async {
    final controller = await _controller(_Repository());
    await tester.pumpWidget(
      EstimotoPlusApp(controller: controller, onExit: () {}),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Account options'));
    await _tap(tester, find.text('Settings'));
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('alex@example.com'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Email'), findsNothing);
    expect(find.textContaining('Demo session'), findsOneWidget);
  });

  testWidgets('garage profile button opens settings', (tester) async {
    final controller = await _controller(_Repository());
    await tester.pumpWidget(
      EstimotoPlusApp(controller: controller, onExit: () {}),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Your profile'));
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('saving a changed name sends the whole profile', (tester) async {
    final repository = _Repository();
    final controller = await _controller(repository);
    repository.bodies.clear();
    await _mountScreen(tester, controller);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Jordan Lee',
    );
    await _tap(tester, find.text('Save profile'));
    expect(repository.bodies, hasLength(1));
    expect(repository.bodies.single, {
      'name': 'Jordan Lee',
      'phone': '3035550100',
      'postal_code': '80202',
      'contact_preference': 'email',
      'expected_revision': 1,
    });
    expect(find.text('Profile saved'), findsOneWidget);
    expect(controller.snapshot!.profile.name, 'Jordan Lee');
  });

  testWidgets('clearing the phone sends an empty phone', (tester) async {
    final repository = _Repository();
    final controller = await _controller(repository);
    repository.bodies.clear();
    await _mountScreen(tester, controller);
    await _tap(tester, find.byTooltip('Clear phone'));
    await _tap(tester, find.text('Save profile'));
    expect(repository.bodies.single['phone'], '');
    expect(controller.snapshot!.profile.phone, '');
  });

  testWidgets('an invalid ZIP blocks the save', (tester) async {
    final repository = _Repository();
    final controller = await _controller(repository);
    repository.bodies.clear();
    await _mountScreen(tester, controller);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'ZIP code'),
      '123',
    );
    await _tap(tester, find.text('Save profile'));
    expect(find.text('Enter a five-digit ZIP code'), findsOneWidget);
    expect(repository.bodies, isEmpty);
  });

  testWidgets('sign out asks for confirmation before calling exit', (
    tester,
  ) async {
    var exits = 0;
    final controller = await _controller(_Repository());
    await _mountScreen(tester, controller, onExit: () => exits++);
    await _tap(tester, find.widgetWithText(OutlinedButton, 'Leave demo'));
    expect(find.text('Leave the demo?'), findsOneWidget);
    await _tap(tester, find.text('Stay'));
    expect(exits, 0);
    await _tap(tester, find.widgetWithText(OutlinedButton, 'Leave demo'));
    await _tap(tester, find.widgetWithText(FilledButton, 'Leave demo'));
    expect(exits, 1);
  });

  testWidgets('settings shows the app version from pubspec', (tester) async {
    final controller = await _controller(_Repository());
    await _mountScreen(tester, controller);
    expect(find.text(PlusBuildInfo.label), findsOneWidget);
    final version = RegExp(
      r'^version:\s*([0-9.]+)\+([0-9]+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!;
    expect(PlusBuildInfo.versionName, version.group(1));
    expect(PlusBuildInfo.buildNumber, version.group(2));
  });
}
