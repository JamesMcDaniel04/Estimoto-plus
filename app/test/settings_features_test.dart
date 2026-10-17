import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/settings_screen.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

class ControlledSettingsRepository extends DemoPlusRepository {
  int profileWrites = 0, appWrites = 0, clearWrites = 0, privacyWrites = 0;
  Completer<void>? profileGate, appGate, privacyGate;
  bool rejectProfile = false,
      rejectPrivacyRead = false,
      losePrivacyReply = false,
      malformedPrivacy = false;
  @override
  Future<Json> saveProfileSettings(
    Json body, {
    required bool Function() isCurrent,
  }) async {
    profileWrites++;
    if (profileGate != null) await profileGate!.future;
    if (rejectProfile) {
      throw const PlusApiException('Profile could not be saved.', 503);
    }
    return super.saveProfileSettings(body, isCurrent: isCurrent);
  }

  @override
  Future<Json> clearProfileSettings(
    int expectedRevision, {
    required bool Function() isCurrent,
  }) {
    clearWrites++;
    return super.clearProfileSettings(expectedRevision, isCurrent: isCurrent);
  }

  @override
  Future<Json> saveAppSettings(
    Json body, {
    required bool Function() isCurrent,
  }) async {
    appWrites++;
    if (appGate != null) await appGate!.future;
    return super.saveAppSettings(body, isCurrent: isCurrent);
  }

  @override
  Future<Json> getKnowledgePreferences({bool Function()? isCurrent}) {
    if (rejectPrivacyRead) {
      throw const PlusApiException('Privacy settings are unavailable.', 503);
    }
    if (malformedPrivacy) {
      return Future.value({'share_aggregate_insights': 'true'});
    }
    return super.getKnowledgePreferences(isCurrent: isCurrent);
  }

  @override
  Future<Json> saveKnowledgePreferencesScoped(
    Json body, {
    required bool Function() isCurrent,
  }) async {
    privacyWrites++;
    if (privacyGate != null) await privacyGate!.future;
    final result = await super.saveKnowledgePreferencesScoped(
      body,
      isCurrent: isCurrent,
    );
    if (losePrivacyReply) {
      throw const PlusApiException('Could not confirm your privacy choice.');
    }
    return result;
  }
}

Future<PlusController> mountSettings(
  WidgetTester tester, {
  DemoPlusRepository? repository,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = PlusController(repository ?? DemoPlusRepository());
  await controller.refresh();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: SettingsScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> tapSetting(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> chooseSetting(
  WidgetTester tester,
  String label,
  String value,
) async {
  final dropdown = find.ancestor(
    of: find.text(label),
    matching: find.byType(DropdownButtonFormField<String>),
  );
  await tapSetting(tester, dropdown);
  await tapSetting(tester, find.text(value).last);
}

void main() {
  testWidgets('settings opened before bootstrap displays the loaded account', (
    tester,
  ) async {
    final controller = PlusController(DemoPlusRepository());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    expect(find.text('Sign in to view your settings.'), findsOneWidget);
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(find.text('alex@example.com'), findsOneWidget);
    expect(find.text('App preferences'), findsOneWidget);
  });

  testWidgets('malformed privacy response does not claim consent is off', (
    tester,
  ) async {
    final repository = ControlledSettingsRepository()..malformedPrivacy = true;
    await mountSettings(tester, repository: repository);
    expect(find.byKey(const Key('settings-insights-consent')), findsNothing);
    expect(
      find.text(
        'We could not read your saved privacy choice. Reload to try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('clear confirmation is inert after the account is invalidated', (
    tester,
  ) async {
    final repository = ControlledSettingsRepository();
    final controller = await mountSettings(tester, repository: repository);
    await tapSetting(tester, find.text('Clear profile details'));
    controller.invalidateSession();
    await tester.pump();
    await tapSetting(tester, find.text('Clear details'));
    expect(repository.clearWrites, 0);
    expect(find.text('Profile details cleared'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'settings hides private details immediately after session invalidation',
    (tester) async {
      final controller = await mountSettings(tester);
      controller.invalidateSession();
      await tester.pumpAndSettle();
      expect(find.text('alex@example.com'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Sign in to view your settings.'), findsOneWidget);
    },
  );

  testWidgets(
    'phone preference requires a phone and ZIP plus four is normalized',
    (tester) async {
      final repository = ControlledSettingsRepository();
      final controller = await mountSettings(tester, repository: repository);
      await chooseSetting(tester, 'Preferred contact', 'Phone');
      await tapSetting(tester, find.text('Save profile'));
      expect(find.text('Add a phone number or choose email.'), findsOneWidget);
      expect(repository.profileWrites, 0);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone (optional)'),
        'not a number',
      );
      await tapSetting(tester, find.text('Save profile'));
      expect(repository.profileWrites, 0);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone (optional)'),
        '+1 (303) 555-0100',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'ZIP code'),
        '80202-1234',
      );
      await tapSetting(tester, find.text('Save profile'));
      expect(controller.snapshot!.profile.postalCode, '80202');
      expect(controller.snapshot!.profile.phone, '+1 (303) 555-0100');
      expect(repository.profileWrites, 1);
    },
  );

  testWidgets(
    'clear profile requires confirmation and preserves identity and garage',
    (tester) async {
      final repository = ControlledSettingsRepository();
      final controller = await mountSettings(tester, repository: repository);
      await tapSetting(tester, find.text('Clear profile details'));
      await tapSetting(tester, find.text('Keep details'));
      expect(repository.clearWrites, 0);
      await tapSetting(tester, find.text('Clear profile details'));
      await tapSetting(tester, find.text('Clear details'));
      expect(repository.clearWrites, 1);
      expect(controller.snapshot!.profile.name, '');
      expect(controller.snapshot!.profile.email, 'alex@example.com');
      expect(controller.snapshot!.vehicles, hasLength(2));
      expect(find.text('Profile details cleared'), findsOneWidget);
    },
  );

  testWidgets(
    'captured profile callback is deduplicated and disables all fields',
    (tester) async {
      final repository = ControlledSettingsRepository()
        ..profileGate = Completer<void>();
      await mountSettings(tester, repository: repository);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Pending name',
      );
      final save = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save profile'),
          )
          .onPressed!;
      save();
      save();
      await tester.pump();
      expect(repository.profileWrites, 1);
      for (final field in tester.widgetList<TextFormField>(
        find.byType(TextFormField),
      )) {
        expect(field.enabled, false);
      }
      repository.profileGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Profile saved'), findsOneWidget);
    },
  );

  testWidgets('a failed save retains the draft without a success message', (
    tester,
  ) async {
    final repository = ControlledSettingsRepository()..rejectProfile = true;
    final controller = await mountSettings(tester, repository: repository);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Keep this draft',
    );
    await tapSetting(tester, find.text('Save profile'));
    expect(find.text('Keep this draft'), findsOneWidget);
    expect(find.text('Profile could not be saved.'), findsOneWidget);
    expect(find.text('Profile saved'), findsNothing);
    expect(controller.snapshot!.profile.name, 'Alex Morgan');
  });

  testWidgets(
    'session loss during profile save hides data and discards callbacks',
    (tester) async {
      final repository = ControlledSettingsRepository()
        ..profileGate = Completer<void>();
      final controller = await mountSettings(tester, repository: repository);
      final save = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save profile'),
          )
          .onPressed!;
      save();
      controller.invalidateSession();
      save();
      repository.profileGate!.complete();
      await tester.pumpAndSettle();
      expect(repository.profileWrites, 1);
      expect(find.text('Profile saved'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('profile conflict preserves edits until explicit reload', (
    tester,
  ) async {
    final repository = ControlledSettingsRepository();
    await mountSettings(tester, repository: repository);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'My draft',
    );
    await repository.saveProfile({'name': 'Changed on another device'});
    await tapSetting(tester, find.text('Save profile'));
    expect(find.text('My draft'), findsOneWidget);
    expect(find.text('Profile saved'), findsNothing);
    await tapSetting(tester, find.text('Reload saved profile'));
    expect(find.text('Changed on another device'), findsOneWidget);
  });

  testWidgets(
    'app defaults save, survive reopening and reset only after confirmation',
    (tester) async {
      final repository = ControlledSettingsRepository();
      final controller = await mountSettings(tester, repository: repository);
      await chooseSetting(tester, 'Default vehicle', '2021 Toyota Tacoma');
      await chooseSetting(tester, 'Default estimate type', 'Collision');
      await chooseSetting(tester, 'Start page', 'Repairs');
      await tapSetting(tester, find.text('Save app preferences'));
      expect(repository.appWrites, 1);
      expect(controller.selectedVehicleId, 'demo-toyota');
      expect(controller.discipline, 'collision');
      expect(controller.tab, 3);
      final reopened = PlusController(repository);
      await reopened.refresh();
      expect(reopened.snapshot!.settings.defaultVehicleId, 'demo-toyota');
      expect(reopened.tab, 3);
      await tapSetting(tester, find.text('Reset app preferences'));
      await tapSetting(tester, find.text('Keep preferences'));
      expect(controller.snapshot!.settings.defaultVehicleId, 'demo-toyota');
      await tapSetting(tester, find.text('Reset app preferences'));
      await tapSetting(tester, find.text('Reset preferences'));
      expect(controller.snapshot!.settings.customized, false);
      expect(controller.snapshot!.settings.defaultVehicleId, isNull);
      expect(controller.tab, 0);
      expect(controller.snapshot!.profile.name, 'Alex Morgan');
    },
  );

  testWidgets(
    'dirty app choices survive a background refresh and can be discarded',
    (tester) async {
      final repository = ControlledSettingsRepository();
      final controller = await mountSettings(tester, repository: repository);
      await chooseSetting(tester, 'Start page', 'Repairs');
      await repository.saveAppSettings({
        'expected_revision': 0,
        'default_vehicle_id': null,
        'default_estimate_discipline': 'collision',
        'home_tab': 'estimates',
      }, isCurrent: () => true);
      await controller.refresh(quiet: true);
      await tester.pumpAndSettle();
      expect(find.text('Repairs'), findsOneWidget);
      expect(
        find.textContaining('Your saved app preferences changed.'),
        findsOneWidget,
      );
      await tapSetting(tester, find.text('Discard preference changes'));
      expect(find.text('Estimates'), findsOneWidget);
      expect(find.text('Collision'), findsOneWidget);
    },
  );

  testWidgets(
    'privacy requires a loaded value and retries an uncertain write',
    (tester) async {
      final repository = ControlledSettingsRepository()
        ..rejectPrivacyRead = true;
      final controller = await mountSettings(tester, repository: repository);
      expect(find.byKey(const Key('settings-insights-consent')), findsNothing);
      expect(find.text('Privacy settings are unavailable.'), findsOneWidget);
      repository.rejectPrivacyRead = false;
      await tapSetting(tester, find.text('Reload privacy preference'));
      repository.losePrivacyReply = true;
      await tapSetting(
        tester,
        find.byKey(const Key('settings-insights-consent')),
      );
      expect(repository.privacyWrites, 1);
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings-insights-consent')),
      );
      expect(toggle.value, false);
      expect(toggle.onChanged, isNull);
      final revision = controller.historyRevision;
      repository.losePrivacyReply = false;
      await tapSetting(tester, find.text('Retry privacy change'));
      expect(repository.privacyWrites, 2);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('settings-insights-consent')),
            )
            .value,
        true,
      );
      expect(controller.historyRevision, revision + 1);
      expect(
        (await repository.getKnowledge())['preferences'],
        containsPair('share_aggregate_insights', true),
      );
    },
  );

  testWidgets('captured privacy save cannot write after session invalidation', (
    tester,
  ) async {
    final repository = ControlledSettingsRepository();
    final controller = await mountSettings(tester, repository: repository);
    final callback = tester
        .widget<SwitchListTile>(
          find.byKey(const Key('settings-insights-consent')),
        )
        .onChanged!;
    controller.invalidateSession();
    callback(true);
    await tester.pumpAndSettle();
    expect(repository.privacyWrites, 0);
    expect(find.text('Privacy preference saved'), findsNothing);
  });

  testWidgets(
    'optional profile fields can be cleared without deleting vehicles',
    (tester) async {
      final controller = await mountSettings(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Name'), '');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'ZIP code'),
        '',
      );
      await tapSetting(tester, find.text('Save profile'));
      expect(controller.snapshot!.profile.name, '');
      expect(controller.snapshot!.profile.postalCode, '');
      expect(controller.snapshot!.vehicles, hasLength(2));
    },
  );

  testWidgets(
    'clean profile reloads after refresh and dirty edits can be discarded',
    (tester) async {
      final repository = DemoPlusRepository();
      final controller = await mountSettings(tester, repository: repository);
      await repository.saveProfile({'name': 'Server name'});
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Server name'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Unfinished edit',
      );
      await repository.saveProfile({'name': 'Newer server name'});
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Unfinished edit'), findsOneWidget);
      await tapSetting(tester, find.text('Discard profile changes'));
      expect(find.text('Newer server name'), findsOneWidget);
    },
  );

  testWidgets(
    'settings exposes persistent app defaults and privacy at enlarged text',
    (tester) async {
      await mountSettings(tester, scale: 1.8);
      expect(find.text('App preferences'), findsOneWidget);
      expect(find.text('Default vehicle'), findsOneWidget);
      expect(find.text('Default estimate type'), findsOneWidget);
      expect(find.text('Start page'), findsOneWidget);
      expect(find.text('Help improve repair insights'), findsOneWidget);
      await tester.ensureVisible(find.text('Reset app preferences'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
