import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:estimoto_plus/data/api_repository.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/state/plus_controller.dart';

Json _settings({int revision = 1}) => {
  'revision': revision,
  'customized': true,
  'default_vehicle_id': 'second',
  'default_estimate_discipline': 'collision',
  'home_tab': 'repairs',
};

class _Repository extends DemoPlusRepository {
  int reads = 0, writes = 0;
  Completer<Json>? pending;
  Completer<PlusSnapshot>? pendingRefresh;
  bool failRefresh = false, conflict = false;
  Json profile = {
    'id': 'customer',
    'email': 'customer@example.test',
    'name': 'Alex',
    'phone': '',
    'postal_code': '80202',
    'contact_preference': 'email',
    'revision': 0,
  };
  Json settings = _settings();
  final additionalVehicles = <Json>[];
  PlusSnapshot state() => PlusSnapshot.fromJson({
    'profile': Map.of(profile),
    'settings': Map.of(settings),
    'vehicles': [
      {'id': 'first', 'year': 2020, 'make': 'Ford', 'model': 'Focus'},
      {'id': 'second', 'year': 2022, 'make': 'Audi', 'model': 'Q5'},
      ...additionalVehicles,
    ],
  });
  @override
  Future<PlusSnapshot> bootstrap() async {
    reads++;
    if (failRefresh) throw const PlusApiException('Offline');
    return pendingRefresh?.future ?? state();
  }

  @override
  Future<Json> saveProfileSettings(
    Json body, {
    required bool Function() isCurrent,
  }) async {
    writes++;
    if (conflict) {
      profile = {...profile, 'name': 'Saved elsewhere', 'revision': 2};
      throw const PlusApiException(
        'Reload saved profile.',
        409,
        'profile_conflict',
      );
    }
    if (pending != null) return pending!.future;
    profile = {...profile, ...body, 'revision': 1}..remove('expected_revision');
    return Map.of(profile);
  }

  @override
  Future<Json> getProfileSettings({bool Function()? isCurrent}) async =>
      Map.of(profile);
  @override
  Future<Json> saveAppSettings(
    Json body, {
    required bool Function() isCurrent,
  }) async {
    settings = {...body, 'revision': 2, 'customized': true}
      ..remove('expected_revision');
    return Map.of(settings);
  }
}

void main() {
  test(
    'saved defaults apply initially without overriding later navigation on refresh',
    () async {
      final c = PlusController(_Repository());
      addTearDown(c.dispose);
      await c.refresh();
      expect(c.selectedVehicleId, 'second');
      expect(c.discipline, 'collision');
      expect(c.tab, 3);
      c.selectVehicle('first');
      c.selectDiscipline('pdr');
      c.selectTab(4);
      await c.refresh();
      expect(c.selectedVehicleId, 'first');
      expect(c.discipline, 'pdr');
      expect(c.tab, 4);
    },
  );

  test(
    'acknowledged profile values update immediately even when bootstrap is offline',
    () async {
      final repo = _Repository();
      final c = PlusController(repo);
      addTearDown(c.dispose);
      await c.refresh();
      repo.failRefresh = true;
      await c.saveProfileSettings({'name': 'Jordan'}, expectedRevision: 0);
      expect(c.snapshot!.profile.name, 'Jordan');
      expect(c.snapshot!.profile.revision, 1);
      expect(c.snapshot!.vehicles, hasLength(2));
      expect(repo.reads, 1);
    },
  );

  test(
    'saving preferences applies their actual defaults and keeps other account state',
    () async {
      final c = PlusController(_Repository());
      addTearDown(c.dispose);
      await c.refresh();
      await c.saveAppSettings({
        'default_vehicle_id': 'first',
        'default_estimate_discipline': 'pdr',
        'home_tab': 'estimates',
      }, expectedRevision: 1);
      expect(c.tab, 1);
      expect(c.selectedVehicleId, 'first');
      expect(c.discipline, 'pdr');
      expect(c.snapshot!.profile.name, 'Alex');
      expect(c.snapshot!.settings.revision, 2);
    },
  );

  test(
    'pending profile saves reject duplicates and ignore late session responses',
    () async {
      final repo = _Repository()..pending = Completer<Json>();
      final c = PlusController(repo);
      addTearDown(c.dispose);
      await c.refresh();
      final Future<void> first = c.saveProfileSettings({
        'name': 'Changed',
      }, expectedRevision: 0);
      await expectLater(
        c.saveProfileSettings({'name': 'Duplicate'}, expectedRevision: 0),
        throwsA(isA<PlusApiException>()),
      );
      expect(repo.writes, 1);
      final waitingRefresh = c.refresh();
      c.invalidateSession();
      await waitingRefresh;
      final failure = expectLater(first, throwsA(isA<PlusApiException>()));
      repo.pending!.complete({
        ...repo.profile,
        'name': 'Changed',
        'revision': 1,
      });
      await failure;
      expect(c.snapshot, isNull);
      expect(repo.reads, 1);
    },
  );

  test(
    'a refresh begun before a save cannot restore an outdated profile',
    () async {
      final repo = _Repository();
      final c = PlusController(repo);
      addTearDown(c.dispose);
      await c.refresh();
      final old = repo.state();
      repo.pendingRefresh = Completer<PlusSnapshot>();
      final refresh = c.refresh();
      await c.saveProfileSettings({'name': 'Jordan'}, expectedRevision: 0);
      repo.pendingRefresh!.complete(old);
      await refresh;
      expect(c.snapshot!.profile.name, 'Jordan');
    },
  );

  test(
    'refreshes during settings writes coalesce and preserve acknowledged revisions',
    () async {
      final repo = _Repository()..pending = Completer<Json>();
      final c = PlusController(repo);
      addTearDown(c.dispose);
      await c.refresh();
      final save = c.saveProfileSettings({
        'name': 'Jordan',
      }, expectedRevision: 0);
      repo.additionalVehicles.add({
        'id': 'third',
        'make': 'Ford',
        'model': 'F150',
      });
      final refresh = c.refresh();
      final otherRefresh = c.refresh(quiet: true);
      expect(repo.reads, 1);
      repo.pending!.complete({
        ...repo.profile,
        'name': 'Jordan',
        'revision': 1,
      });
      await save;
      await Future.wait([refresh, otherRefresh]);
      expect(repo.reads, 2);
      expect(c.snapshot!.vehicles, hasLength(3));
      expect(c.snapshot!.profile.name, 'Jordan');
      expect(c.snapshot!.profile.revision, 1);
    },
  );

  test(
    'conflict reloads authoritative profile and preserves an explicit failure',
    () async {
      final repo = _Repository()..conflict = true;
      final c = PlusController(repo);
      addTearDown(c.dispose);
      await c.refresh();
      await expectLater(
        c.saveProfileSettings({'name': 'Old edit'}, expectedRevision: 0),
        throwsA(
          isA<PlusApiException>().having(
            (e) => e.code,
            'code',
            'profile_conflict',
          ),
        ),
      );
      expect(c.snapshot!.profile.name, 'Saved elsewhere');
    },
  );

  test(
    'invalidated sessions drop private data and cannot fetch it again',
    () async {
      final repo = _Repository();
      final c = PlusController(repo);
      addTearDown(c.dispose);
      await c.refresh();
      c.messages.add(ChatEntry.user('Private question'));
      c.invalidateSession();
      await c.refresh();
      expect(c.snapshot, isNull);
      expect(c.messages, isEmpty);
      expect(repo.reads, 1);
    },
  );

  test(
    'settings requests stop when the session expires during token resolution',
    () async {
      var active = true;
      var sends = 0;
      final token = Completer<String?>();
      final repo = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () => token.future,
        client: MockClient((_) async {
          sends++;
          return http.Response('{}', 200);
        }),
      );
      final Future<Json> pending = repo.saveAppSettings({
        'expected_revision': 0,
        'default_vehicle_id': null,
        'default_estimate_discipline': 'pdr',
        'home_tab': 'garage',
      }, isCurrent: () => active);
      active = false;
      token.complete('new-session-token');
      await expectLater(pending, throwsA(isA<PlusApiException>()));
      expect(sends, 0);
    },
  );

  test(
    'settings reset and profile clear use guarded revisioned private endpoints',
    () async {
      final requests = <http.Request>[];
      final repo = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () async => 'owner',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode(_settings()), 200);
        }),
      );
      await repo.resetAppSettings(7, isCurrent: () => true);
      await repo.clearProfileSettings(3, isCurrent: () => true);
      expect(requests.map((r) => r.method), ['DELETE', 'DELETE']);
      expect(requests.map((r) => r.url.path), ['/v1/settings', '/v1/profile']);
      expect(requests.map((r) => r.url.queryParameters['expected_revision']), [
        '7',
        '3',
      ]);
      expect(
        requests.every(
          (r) =>
              r.headers['Authorization'] == 'Bearer owner' &&
              !r.followRedirects,
        ),
        isTrue,
      );
    },
  );

  test(
    'known settings conflicts keep safe codes while dropping server detail',
    () async {
      final repo = ApiPlusRepository(
        baseUrl: 'https://plus.example.test',
        token: () async => 'owner',
        client: MockClient(
          (_) async => http.Response(
            '{"code":"settings_conflict","detail":"private server data"}',
            409,
          ),
        ),
      );
      await expectLater(
        repo.saveAppSettings({}, isCurrent: () => true),
        throwsA(
          isA<PlusApiException>()
              .having((e) => e.code, 'code', 'settings_conflict')
              .having(
                (e) => e.message,
                'safe message',
                isNot(contains('private server data')),
              ),
        ),
      );
    },
  );
}
