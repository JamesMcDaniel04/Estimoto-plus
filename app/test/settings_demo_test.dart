import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';

bool current() => true;

Json appBody(int revision, {String? vehicle, String home = 'repairs'}) => {
  'expected_revision': revision,
  'default_vehicle_id': vehicle,
  'default_estimate_discipline': 'collision',
  'home_tab': home,
};

Matcher apiError(int status, [String? code]) => isA<PlusApiException>()
    .having((error) => error.statusCode, 'status', status)
    .having((error) => code == null || error.code == code, 'code', isTrue);

void main() {
  test(
    'demo app preferences create, update and reset with revisions',
    () async {
      final dynamic repository = DemoPlusRepository();
      final defaults = await repository.getAppSettings();
      expect(defaults, {
        'revision': 0,
        'customized': false,
        'default_vehicle_id': null,
        'default_estimate_discipline': 'pdr',
        'home_tab': 'garage',
      });
      final created = await repository.saveAppSettings(
        appBody(0, vehicle: 'demo-toyota'),
        isCurrent: current,
      );
      expect(created['revision'], 1);
      expect(created['customized'], true);
      expect(created['default_vehicle_id'], 'demo-toyota');
      final updated = await repository.saveAppSettings(
        appBody(1, home: 'find_help'),
        isCurrent: current,
      );
      expect(updated['revision'], 2);
      expect(updated['default_vehicle_id'], null);
      expect(updated['home_tab'], 'find_help');
      final reset = await repository.resetAppSettings(2, isCurrent: current);
      expect(reset, {...defaults, 'revision': 3});
      await expectLater(
        repository.saveAppSettings(appBody(0), isCurrent: current),
        throwsA(apiError(409, 'settings_conflict')),
      );
      expect(await repository.getAppSettings(), reset);
    },
  );

  test('demo settings responses cannot mutate persisted values', () async {
    final dynamic repository = DemoPlusRepository();
    final Json saved = await repository.saveAppSettings(
      appBody(0),
      isCurrent: current,
    );
    saved['home_tab'] = 'garage';
    final Json read = await repository.getAppSettings();
    expect(read['home_tab'], 'repairs');
    read['revision'] = 99;
    expect((await repository.getAppSettings())['revision'], 1);
    final dynamic other = DemoPlusRepository();
    expect((await other.getAppSettings())['revision'], 0);
    expect((await other.getAppSettings())['home_tab'], 'garage');
  });

  test(
    'deleting the saved default vehicle clears it and advances revision',
    () async {
      final dynamic repository = DemoPlusRepository();
      final vehicle = await repository.saveVehicle({
        'year': 2024,
        'make': 'Honda',
        'model': 'Civic',
      });
      await repository.saveAppSettings(
        appBody(0, vehicle: vehicle['id']),
        isCurrent: current,
      );
      await repository.deleteVehicle(vehicle['id']);
      final settings = await repository.getAppSettings();
      expect(settings['default_vehicle_id'], null);
      expect(settings['revision'], 2);
      expect(settings['home_tab'], 'repairs');
      expect(settings['customized'], true);
      await expectLater(
        repository.saveAppSettings(appBody(1), isCurrent: current),
        throwsA(apiError(409, 'settings_conflict')),
      );
    },
  );

  test('blocked default vehicle deletion preserves all settings', () async {
    final dynamic repository = DemoPlusRepository();
    final before = await repository.saveAppSettings(
      appBody(0, vehicle: 'demo-audi'),
      isCurrent: current,
    );
    await expectLater(
      repository.deleteVehicle('demo-audi'),
      throwsA(apiError(409)),
    );
    expect(await repository.getAppSettings(), before);
  });

  for (final (label, body) in <(String, Json)>[
    ('unknown key', {...appBody(0), 'unexpected': true}),
    ('missing revision', {...appBody(0)}..remove('expected_revision')),
    ('noninteger revision', {...appBody(0), 'expected_revision': 0.0}),
    ('negative revision', {...appBody(0), 'expected_revision': -1}),
    ('foreign vehicle', appBody(0, vehicle: 'another-customers-vehicle')),
    ('empty vehicle', appBody(0, vehicle: '')),
    ('wrong vehicle type', {...appBody(0), 'default_vehicle_id': 7}),
    (
      'invalid discipline',
      {...appBody(0), 'default_estimate_discipline': 'mechanical'},
    ),
    ('invalid home', appBody(0, home: 'admin')),
    ('missing home', {...appBody(0)}..remove('home_tab')),
  ]) {
    test(
      'demo rejects invalid app settings: $label without mutation',
      () async {
        final dynamic repository = DemoPlusRepository();
        final before = await repository.getAppSettings();
        await expectLater(
          repository.saveAppSettings(body, isCurrent: current),
          throwsA(isA<PlusApiException>()),
        );
        expect(await repository.getAppSettings(), before);
      },
    );
  }

  test(
    'profile partial saves preserve omitted fields and copy responses',
    () async {
      final repository = DemoPlusRepository();
      final saved = await repository.saveProfile({
        'name': '  Sam Driver  ',
        'phone': ' +1 (303) 555-0100 ',
        'postal_code': ' 80202-1234 ',
        'contact_preference': 'phone',
      });
      expect(saved['name'], 'Sam Driver');
      expect(saved['phone'], '+1 (303) 555-0100');
      expect(saved['postal_code'], '80202');
      expect(saved['revision'], 1);
      final changed = await repository.saveProfile({'name': 'Taylor'});
      expect(changed['revision'], 2);
      expect(changed['phone'], '+1 (303) 555-0100');
      expect(changed['postal_code'], '80202');
      expect(changed['contact_preference'], 'phone');
      changed['name'] = 'External mutation';
      expect((await repository.bootstrap()).profile.name, 'Taylor');
      final cleared = await repository.saveProfile({
        'phone': '',
        'postal_code': '',
        'contact_preference': 'email',
      });
      expect(cleared['phone'], '');
      expect(cleared['postal_code'], '');
      expect(cleared['name'], 'Taylor');
    },
  );

  test(
    'profile validates trimmed text and contact preference consistently',
    () async {
      final repository = DemoPlusRepository();
      final saved = await repository.saveProfile({
        'name': '  ${'N' * 200}  ',
        'phone': '3035550100',
        'contact_preference': ' phone ',
      });
      expect(saved['name'], 'N' * 200);
      expect(saved['contact_preference'], 'phone');
    },
  );

  test('overlong default vehicle ids fail schema validation', () async {
    final dynamic repository = DemoPlusRepository();
    await expectLater(
      repository.saveAppSettings(
        appBody(0, vehicle: 'v' * 37),
        isCurrent: current,
      ),
      throwsA(apiError(422)),
    );
  });

  test('profile clear preserves account identity and garage/history', () async {
    final dynamic repository = DemoPlusRepository();
    final vehicle = (await repository.bootstrap()).vehicles.first.id;
    await repository.addKnowledgeRecord({
      'vehicle_id': vehicle,
      'service_type': 'oil_change',
      'service_date': '2026-01-01',
    }, 'settings-history');
    final original = await repository.getProfileSettings();
    expect(original['revision'], 0);
    await repository.saveProfileSettings({
      'expected_revision': 0,
      'name': 'Morgan',
      'phone': '3035550101',
    }, isCurrent: current);
    final cleared = await repository.clearProfileSettings(
      1,
      isCurrent: current,
    );
    expect(cleared['revision'], 2);
    expect(cleared['id'], original['id']);
    expect(cleared['email'], original['email']);
    expect(cleared['name'], '');
    expect(cleared['phone'], '');
    expect(cleared['postal_code'], '');
    expect(cleared['contact_preference'], 'email');
    expect((await repository.bootstrap()).vehicles, hasLength(2));
    expect(rowsOf(await repository.getKnowledge(), 'records'), hasLength(1));
    await expectLater(
      repository.saveProfileSettings({
        'expected_revision': 1,
        'name': 'Stale',
      }, isCurrent: current),
      throwsA(apiError(409, 'profile_conflict')),
    );
    await expectLater(
      repository.clearProfileSettings(1, isCurrent: current),
      throwsA(apiError(409, 'profile_conflict')),
    );
    expect(await repository.getProfileSettings(), cleared);
    cleared['email'] = 'changed@example.test';
    expect((await repository.getProfileSettings())['email'], original['email']);
  });

  for (final (label, body) in <(String, Json)>[
    ('account identity', {'id': 'other-user'}),
    ('account email', {'email': 'other@example.test'}),
    ('unknown field', {'administrator': true}),
    ('wrong name type', {'name': 42}),
    ('null name', {'name': null}),
    ('long name', {'name': 'x' * 201}),
    ('phone URL', {'phone': 'tel:3035550100'}),
    ('phone embedded plus', {'phone': '303+5550100'}),
    ('phone repeated plus', {'phone': '++13035550100'}),
    ('name control character', {'name': 'Sam\nDriver'}),
    ('trailing name control character', {'name': 'Sam\t'}),
    ('ZIP control character', {'postal_code': '80202\n'}),
    ('short phone', {'phone': '1234'}),
    ('long phone', {'phone': '1' * 16}),
    ('long phone formatting', {'phone': '+${' ' * 45}3035550100'}),
    ('invalid ZIP', {'postal_code': 'ABC12'}),
    ('trailing ZIP content', {'postal_code': '80202-1234 x'}),
    ('unknown contact mode', {'contact_preference': 'sms'}),
    ('phone preference without phone', {'contact_preference': 'phone'}),
    ('noninteger revision', {'expected_revision': 0.0, 'name': 'New'}),
    ('negative revision', {'expected_revision': -1, 'name': 'New'}),
  ]) {
    test('demo rejects invalid profile: $label without mutation', () async {
      final repository = DemoPlusRepository();
      final before = (await repository.bootstrap()).profile.json;
      await expectLater(repository.saveProfile(body), throwsA(apiError(422)));
      expect((await repository.bootstrap()).profile.json, before);
    });
  }

  test(
    'phone cannot be cleared while the saved contact preference requires it',
    () async {
      final repository = DemoPlusRepository();
      final before = await repository.saveProfile({
        'phone': '3035550100',
        'contact_preference': 'phone',
      });
      await expectLater(
        repository.saveProfile({'phone': ''}),
        throwsA(apiError(422)),
      );
      expect((await repository.bootstrap()).profile.json, before);
    },
  );

  test(
    'privacy preferences reuse history consent and remain isolated',
    () async {
      final dynamic repository = DemoPlusRepository();
      final first = await repository.getKnowledgePreferences();
      expect(first['share_aggregate_insights'], false);
      expect(first['policy_version'], '2026-09-13');
      final saved = await repository.saveKnowledgePreferencesScoped({
        'share_aggregate_insights': true,
      }, isCurrent: current);
      expect(saved['share_aggregate_insights'], true);
      saved['share_aggregate_insights'] = false;
      expect(
        (await repository
            .getKnowledge())['preferences']['share_aggregate_insights'],
        true,
      );
      await repository.saveKnowledgePreferences({
        'share_aggregate_insights': false,
      });
      expect(
        (await repository
            .getKnowledgePreferences())['share_aggregate_insights'],
        false,
      );
      final dynamic other = DemoPlusRepository();
      expect(
        (await other.getKnowledgePreferences())['share_aggregate_insights'],
        false,
      );
      for (final bad in <Json>[
        {},
        {'share_aggregate_insights': 'true'},
        {'share_aggregate_insights': null},
        {'share_aggregate_insights': true, 'extra': true},
      ]) {
        await expectLater(
          repository.saveKnowledgePreferencesScoped(bad, isCurrent: current),
          throwsA(apiError(422)),
        );
      }
      expect(
        (await repository
            .getKnowledgePreferences())['share_aggregate_insights'],
        false,
      );
    },
  );

  test(
    'settings reads and writes reject obsolete sessions before touching data',
    () async {
      final dynamic repository = DemoPlusRepository();
      final beforeSettings = await repository.getAppSettings();
      final beforeProfile = await repository.getProfileSettings();
      final calls = <Future<dynamic> Function()>[
        () => repository.getAppSettings(isCurrent: () => false),
        () => repository.saveAppSettings(appBody(0), isCurrent: () => false),
        () => repository.resetAppSettings(0, isCurrent: () => false),
        () => repository.getProfileSettings(isCurrent: () => false),
        () => repository.saveProfileSettings({
          'name': 'Wrong session',
          'expected_revision': 0,
        }, isCurrent: () => false),
        () => repository.clearProfileSettings(0, isCurrent: () => false),
        () => repository.getKnowledgePreferences(isCurrent: () => false),
        () => repository.saveKnowledgePreferencesScoped({
          'share_aggregate_insights': true,
        }, isCurrent: () => false),
      ];
      for (final call in calls) {
        await expectLater(call(), throwsA(apiError(401)));
      }
      expect(await repository.getAppSettings(), beforeSettings);
      expect(await repository.getProfileSettings(), beforeProfile);
      expect(
        (await repository
            .getKnowledgePreferences())['share_aggregate_insights'],
        false,
      );
    },
  );
}
