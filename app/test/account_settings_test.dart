import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/settings_screen.dart';
import 'package:estimoto_plus/screens/welcome_screen.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

/// A signed-in shaped repository: the demo workspace without the demo flag.
class _LiveRepository extends DemoPlusRepository {
  int deletions = 0, exports = 0;
  Object? deleteError;
  @override
  bool get isDemo => false;
  @override
  Future<PlusSnapshot> bootstrap() async {
    final snapshot = await super.bootstrap();
    return PlusSnapshot.fromJson({
      'profile': {'id': snapshot.profile.id, 'email': snapshot.profile.email},
      'capabilities': {'demo': false},
    });
  }

  @override
  Future<Json> exportAccount() async {
    exports++;
    return {'format': 'estimoto-plus/1', 'vehicles': <Json>[]};
  }

  @override
  Future<Json> deleteAccount() async {
    deletions++;
    if (deleteError != null) throw deleteError!;
    return {'deleted': true, 'sign_in_removed': true};
  }
}

Future<PlusController> _controller(PlusRepository repository) async {
  final controller = PlusController(repository);
  await controller.refresh();
  return controller;
}

Future<void> _mount(
  WidgetTester tester,
  PlusController controller, {
  VoidCallback? onExit,
  VoidCallback? onAccountDeleted,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      home: SettingsScreen(
        controller: controller,
        onExit: onExit,
        onAccountDeleted: onAccountDeleted,
        saveExport: (_) async => 'Saved to the test folder',
      ),
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
  testWidgets('settings lists data, legal, support and deletion controls', (
    tester,
  ) async {
    await _mount(tester, await _controller(DemoPlusRepository()));
    for (final label in [
      'Download my data',
      'Privacy policy',
      'Terms of use',
      'Open-source licenses',
      'Contact support',
      'support@estimoto.io',
      'Delete my account',
    ]) {
      await tester.ensureVisible(find.text(label));
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await _tap(tester, find.text('Open-source licenses'));
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('download my data offers the JSON on the clipboard', (
    tester,
  ) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final repository = _LiveRepository();
    await _mount(tester, await _controller(repository));
    await _tap(tester, find.text('Download my data'));
    expect(repository.exports, 1);
    expect(find.text('Your data is ready'), findsOneWidget);
    expect(find.textContaining('Saved to the test folder'), findsOneWidget);
    await _tap(tester, find.text('Copy JSON'));
    expect(clipboard.single, contains('"format": "estimoto-plus/1"'));
    expect(find.text('Copied to the clipboard'), findsOneWidget);
  });

  testWidgets('demo deletion explains the demo and offers to leave it', (
    tester,
  ) async {
    var exits = 0;
    await _mount(
      tester,
      await _controller(DemoPlusRepository()),
      onExit: () => exits++,
    );
    await _tap(tester, find.text('Delete my account'));
    expect(find.text('This is the demo'), findsOneWidget);
    await _tap(tester, find.text('Stay'));
    expect(exits, 0);
    await _tap(tester, find.text('Delete my account'));
    await _tap(tester, find.widgetWithText(FilledButton, 'Leave demo'));
    expect(exits, 1);
  });

  testWidgets(
    'deleting a live account needs the typed phrase, then hands off',
    (tester) async {
      var handoffs = 0;
      final repository = _LiveRepository();
      final controller = await _controller(repository);
      await _mount(tester, controller, onAccountDeleted: () => handoffs++);
      await _tap(tester, find.text('Delete my account'));
      expect(find.text('Delete your account?'), findsOneWidget);
      final confirm = find.widgetWithText(FilledButton, 'Delete permanently');
      expect(tester.widget<FilledButton>(confirm).enabled, isFalse);
      await tester.enterText(find.byType(TextField).last, 'delete');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).enabled, isTrue);
      await _tap(tester, find.text('Keep my account'));
      expect(repository.deletions, 0);

      await _tap(tester, find.text('Delete my account'));
      await tester.enterText(find.byType(TextField).last, 'DELETE');
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Delete permanently'),
      );
      expect(repository.deletions, 1);
      expect(find.text('Account deleted'), findsOneWidget);
      expect(handoffs, 0);
      await _tap(tester, find.widgetWithText(FilledButton, 'OK'));
      expect(handoffs, 1);
      expect(controller.accountDeleted, isTrue);
      expect(
        controller.isCurrentCustomer(controller.snapshot!.profile.id),
        isFalse,
      );
    },
  );

  testWidgets(
    'a refused deletion shows the server reason and keeps the session',
    (tester) async {
      var handoffs = 0;
      final repository = _LiveRepository()
        ..deleteError = const PlusApiException(
          'Your open shop requests were cancelled, but a shop could not be notified yet. Please try again in a few minutes.',
          409,
          'open_requests',
        );
      final controller = await _controller(repository);
      await _mount(tester, controller, onAccountDeleted: () => handoffs++);
      await _tap(tester, find.text('Delete my account'));
      await tester.enterText(find.byType(TextField).last, 'DELETE');
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Delete permanently'),
      );
      expect(repository.deletions, 1);
      expect(find.textContaining('could not be notified yet'), findsOneWidget);
      expect(handoffs, 0);
      expect(controller.accountDeleted, isFalse);
      expect(
        controller.isCurrentCustomer(controller.snapshot!.profile.id),
        isTrue,
      );
    },
  );

  testWidgets('welcome links to the terms and privacy policy', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: plusTheme(),
        home: WelcomeScreen(authAvailable: false, onDemo: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Privacy policy'));
    expect(find.text('Terms of use'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
  });
}
