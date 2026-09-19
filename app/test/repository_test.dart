import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/services/customer_workspace.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:estimoto_plus/data/api_repository.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';

void main() {
  _accountTests();
  test(
    'API sends bearer and idempotency key to the configured origin',
    () async {
      final repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.com',
        token: () async => 'verified-token',
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://plus.example.com/v1/requests',
          );
          expect(request.headers['Authorization'], 'Bearer verified-token');
          expect(request.headers['Idempotency-Key'], 'request-one');
          expect(jsonDecode(request.body)['share_contact'], isTrue);
          return http.Response('{"id":"r1"}', 201);
        }),
      );
      await repository.createRequest({'share_contact': true}, 'request-one');
    },
  );

  test(
    'API rejects expired sessions and does not return sample data',
    () async {
      final repository = ApiPlusRepository(
        baseUrl: 'https://plus.example.com',
        token: () async => 'expired',
        client: MockClient(
          (_) async => http.Response('{"detail":"Unauthorized"}', 401),
        ),
      );
      expect(repository.bootstrap(), throwsA(isA<PlusApiException>()));
    },
  );

  test(
    'demo request is idempotent and cannot pretend to book a technician',
    () async {
      final repository = DemoPlusRepository();
      final snapshot = await repository.bootstrap();
      final body = <String, dynamic>{
        'vehicle_id': snapshot.vehicles.first.id,
        'provider_id': snapshot.providers.first.id,
        'specialty': 'pdr',
        'description': 'A small dent in the door.',
        'preferred_time': 'Next week',
        'share_contact': true,
      };
      final first = await repository.createRequest(body, 'request-one');
      final second = await repository.createRequest(body, 'request-one');
      expect(first['id'], second['id']);
      expect(first['status'], 'requested');
      expect(first['delivery_status'], 'local_preview');
      expect(first['scheduled_at'], isNull);
      await repository.cancelRequest(first['id'] as String);
      expect((await repository.bootstrap()).requests.last.status, 'cancelled');
    },
  );

  test('demo saves vehicle and reminder within a session', () async {
    final repository = DemoPlusRepository();
    final created = await repository.saveVehicle({
      'year': 2023,
      'make': 'Honda',
      'model': 'Civic',
      'mileage': 18000,
    });
    final reminder = await repository.addReminder({
      'vehicle_id': created['id'],
      'title': 'Oil change',
      'due_mileage': 20000,
    });
    expect(
      (await repository.bootstrap()).vehicles.any((v) => v.id == created['id']),
      isTrue,
    );
    await repository.completeReminder(reminder['id'] as String);
    expect((await repository.bootstrap()).reminders.last.completed, isTrue);
  });
  test('only explicit request rejection decodes as safe to replace', () async {
    for (final code in [null, 'request_not_created']) {
      final api = ApiPlusRepository(
        baseUrl: 'https://plus.example.com',
        token: () async => 'token',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'detail': 'Conflict', 'code': code}),
            409,
          ),
        ),
      );
      await expectLater(
        api.createRequest({'share_contact': true}, 'one'),
        throwsA(isA<PlusApiException>().having((e) => e.code, 'code', code)),
      );
      api.close();
    }
  });
  test(
    'demo quick prompts include common care and urgent repair guidance',
    () async {
      final repo = DemoPlusRepository();
      final vehicleId = (await repo.bootstrap()).vehicles.first.id;
      final care = await repo.askAssistant({
        'message': 'How do I check tire pressure?',
        'vehicle_id': vehicleId,
      });
      expect(care.reply, contains('placard'));
      expect(care.reply, contains('gauge'));
      for (final phrase in [
        'Find repair for brake failure',
        'Find repair because my brakes failed',
      ]) {
        final urgent = await repo.askAssistant({
          'message': phrase,
          'vehicle_id': vehicleId,
          'postal_code': '80202',
        });
        expect(urgent.reply, contains('professional'));
        expect(urgent.videos, isEmpty);
      }
    },
  );

  test('demo reminders can be edited, reopened and deleted', () async {
    final repository = DemoPlusRepository();
    final vehicle = (await repository.bootstrap()).vehicles.first;
    final made = await repository.addReminder({
      'vehicle_id': vehicle.id,
      'title': 'Oil',
      'due_mileage': 1000,
    });
    final id = made['id'] as String;
    final edited = await repository.updateReminder(id, {
      'title': 'Oil and filter',
    });
    expect(edited['title'], 'Oil and filter');
    expect(edited['due_mileage'], 1000);
    expect(
      () => repository.updateReminder(id, {
        'due_date': null,
        'due_mileage': null,
      }),
      throwsA(isA<PlusApiException>()),
    );
    await repository.completeReminder(id);
    expect((await repository.reopenReminder(id))['completed'], false);
    await repository.deleteReminder(id);
    expect(
      (await repository.bootstrap()).reminders.any((r) => r.id == id),
      isFalse,
    );
    expect(
      () => repository.deleteReminder(id),
      throwsA(isA<PlusApiException>()),
    );
  });

  test(
    'demo estimate drafts can be edited, photos removed and drafts deleted',
    () async {
      final repository = DemoPlusRepository();
      final vehicle = (await repository.bootstrap()).vehicles.first;
      final draft = await repository.createEstimate({
        'vehicle_id': vehicle.id,
        'discipline': 'pdr',
        'description': 'Ding',
      });
      final id = draft['id'] as String;
      final edited = await repository.updateEstimate(id, {
        'description': 'Two dings',
      });
      expect(edited['description'], 'Two dings');
      final photo = await repository.uploadPhoto(
        id,
        Uint8List.fromList([1, 2, 3]),
        'a.jpg',
        'front',
      );
      await repository.deletePhoto(id, photo['id'] as String);
      final after = (await repository.bootstrap()).estimates.firstWhere(
        (e) => e.id == id,
      );
      expect(after.photos, isEmpty);
      expect(
        () => repository.getPhoto(id, photo['id'] as String),
        throwsA(isA<PlusApiException>()),
      );
      await repository.deleteEstimate(id);
      expect(
        (await repository.bootstrap()).estimates.any((e) => e.id == id),
        isFalse,
      );
      expect(
        () => repository.deleteEstimate(id),
        throwsA(isA<PlusApiException>()),
      );
    },
  );

  test('demo shared estimates are locked with a code', () async {
    final repository = DemoPlusRepository();
    final shared = (await repository.bootstrap()).estimates.firstWhere(
      (e) => e.status != 'draft',
    );
    expect(
      () => repository.deleteEstimate(shared.id),
      throwsA(
        isA<PlusApiException>().having(
          (e) => e.code,
          'code',
          'estimate_locked',
        ),
      ),
    );
  });

  test(
    'demo scheduling drafts can be discarded and sent requests withdrawn',
    () async {
      final repository = DemoPlusRepository();
      final vehicle = (await repository.bootstrap()).vehicles.first;
      final shop = await repository.saveMyShop({
        'name': 'Shop',
        'email': 'shop@example.test',
        'phone': '',
      });
      Json body() => {
        'shop_id': shop['id'],
        'vehicle_id': vehicle.id,
        'service_summary': 'Brakes',
        'proposed_slots': [
          offsetTimestamp(DateTime.now().add(const Duration(days: 2))),
        ],
      };
      final draft = await repository.createShopOutreach(body(), 'k1');
      await repository.deleteShopOutreach(draft['id'] as String);
      expect(await repository.listShopOutreach(), isEmpty);
      final second = await repository.createShopOutreach(body(), 'k2');
      await repository.authorizeShopOutreach(second['id'] as String, {
        'share_contact': true,
        'review_hash': second['review_hash'],
      }, 'a2');
      expect(
        () => repository.deleteShopOutreach(second['id'] as String),
        throwsA(isA<PlusApiException>()),
      );
      final withdrawn = await repository.withdrawShopOutreach(
        second['id'] as String,
      );
      expect(withdrawn['status'], 'withdrawn');
      expect(
        () => repository.withdrawShopOutreach(second['id'] as String),
        throwsA(isA<PlusApiException>()),
      );
    },
  );

  test('demo history records can be edited in place', () async {
    final repository = DemoPlusRepository();
    final vehicle = (await repository.bootstrap()).vehicles.first;
    final record = await repository.addKnowledgeRecord({
      'vehicle_id': vehicle.id,
      'service_type': 'maintenance',
      'service_date': '2026-09-01',
      'shop_name': 'Old',
    }, 'h1');
    final edited = await repository.updateKnowledgeRecord(
      record['id'] as String,
      {'shop_name': 'New', 'cost_cents': 500},
    );
    expect(edited['shop_name'], 'New');
    expect(edited['cost_cents'], 500);
    expect(edited['service_date'], '2026-09-01');
    expect(
      (await repository.getKnowledge())['records'].first['shop_name'],
      'New',
    );
  });

  test('demo valuation history is listed newest first and deletable', () async {
    final repository = DemoPlusRepository();
    final vehicle = (await repository.bootstrap()).vehicles.first;
    final before =
        (await repository.listVehicleValuations(vehicle.id))['valuations']
            as List;
    expect(before, isNotEmpty);
    final first = before.first as Json;
    expect(
      DateTime.parse(
        first['created_at'] as String,
      ).isAfter(DateTime.parse((before.last as Json)['created_at'] as String)),
      isTrue,
    );
    await repository.deleteVehicleValuation(vehicle.id, first['id'] as String);
    final after =
        (await repository.listVehicleValuations(vehicle.id))['valuations']
            as List;
    expect(after.length, before.length - 1);
    expect(
      () =>
          repository.deleteVehicleValuation(vehicle.id, first['id'] as String),
      throwsA(isA<PlusApiException>()),
    );
  });

  test('demo guided capture reports a typed unavailable code', () {
    final repository = DemoPlusRepository();
    expect(
      () => repository.openGuidedCapture('e1', isCurrent: () => true),
      throwsA(
        isA<PlusApiException>().having(
          (e) => e.code,
          'code',
          'guided_capture_unavailable',
        ),
      ),
    );
  });
}

void _accountTests() {
  test('API export and deletion use the account routes', () async {
    final calls = <String>[];
    final repository = ApiPlusRepository(
      baseUrl: 'https://plus.example.com',
      token: () async => 'verified-token',
      client: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        expect(request.headers['Authorization'], 'Bearer verified-token');
        return http.Response(
          request.method == 'GET'
              ? '{"format":"estimoto-plus/1","vehicles":[]}'
              : '{"deleted":true,"sign_in_removed":true}',
          200,
        );
      }),
    );
    expect((await repository.exportAccount())['format'], 'estimoto-plus/1');
    expect((await repository.deleteAccount())['deleted'], isTrue);
    expect(calls, ['GET /v1/account/export', 'DELETE /v1/account']);
  });

  test('API surfaces the server wording for open-request conflicts', () async {
    final repository = ApiPlusRepository(
      baseUrl: 'https://plus.example.com',
      token: () async => 'verified-token',
      client: MockClient(
        (_) async => http.Response(
          '{"detail":"A shop could not be notified yet. Please try again in a few minutes.","code":"open_requests"}',
          409,
        ),
      ),
    );
    try {
      await repository.deleteAccount();
      fail('expected a conflict');
    } on PlusApiException catch (error) {
      expect(error.statusCode, 409);
      expect(error.code, 'open_requests');
      expect(error.message, contains('could not be notified yet'));
    }
  });

  test(
    'demo export is labelled fictional and demo deletion is refused',
    () async {
      final repository = DemoPlusRepository();
      final export = await repository.exportAccount();
      expect(export['demo'], isTrue);
      expect(export['profile'], isA<Map>());
      expect(repository.deleteAccount(), throwsA(isA<PlusApiException>()));
    },
  );
}
