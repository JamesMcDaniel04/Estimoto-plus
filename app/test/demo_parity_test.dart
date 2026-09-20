import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/widgets/estimate_submission_review.dart';

void main() {
  test(
    'demo preserves vehicles with customer-reported service history',
    () async {
      final repository = DemoPlusRepository();
      final vehicle = await repository.saveVehicle({
        'year': 2024,
        'make': 'Honda',
        'model': 'Civic',
        'mileage': 12000,
      });
      final vehicleId = vehicle['id'] as String;
      final record = await repository.addKnowledgeRecord({
        'vehicle_id': vehicleId,
        'service_type': 'oil_change',
        'service_date': '2026-01-01',
        'shop_name': 'Sample service center',
      }, 'history-one');

      await expectLater(
        repository.deleteVehicle(vehicleId),
        throwsA(
          isA<PlusApiException>().having((e) => e.statusCode, 'status', 409),
        ),
      );
      expect(
        (await repository.bootstrap()).vehicles.any((v) => v.id == vehicleId),
        isTrue,
      );
      expect(
        rowsOf(await repository.getKnowledge(), 'records').single['id'],
        record['id'],
      );

      await repository.deleteKnowledgeRecord(record['id'] as String);
      await repository.deleteVehicle(vehicleId);
      expect(
        (await repository.bootstrap()).vehicles.any((v) => v.id == vehicleId),
        isFalse,
      );
    },
  );

  test(
    'demo nearby shop visits can be requested from their discovery listing',
    () async {
      final repository = DemoPlusRepository();
      await repository.saveProfile({'postal_code': '80220'});
      final vehicleId = (await repository.bootstrap()).vehicles.first.id;
      final discovery = await repository.discoverProviders({
        'vehicle_id': vehicleId,
        'postal_code': '80220',
        'specialty': 'mechanical',
      });
      final shop = rowsOf(discovery, 'providers').single;
      expect(shop['request_modes'], contains('shop_visit'));
      final body = <String, dynamic>{
        'vehicle_id': vehicleId,
        'provider_id': shop['id'],
        'specialty': 'mechanical',
        'service_mode': 'shop_visit',
        'description': 'Check a new engine noise.',
        'share_contact': true,
      };

      final request = await repository.createRequest(body, 'nearby-visit');
      expect(request['status'], 'requested');
      expect(request['delivery_status'], 'local_preview');
      expect(request['scheduled_at'], isNull);
      expect(request['service_mode'], 'shop_visit');
      expect(
        rowsOf(request, 'events').single['message'],
        contains('No provider was contacted'),
      );
      await repository.saveProfile({'postal_code': '10001'});
      final replay = await repository.createRequest(body, 'nearby-visit');
      expect(replay['id'], request['id']);
      expect((await repository.bootstrap()).requests, hasLength(1));
    },
  );

  test(
    'demo mobile requests remain available within the exact service ZIP',
    () async {
      final repository = DemoPlusRepository();
      final vehicleId = (await repository.bootstrap()).vehicles.first.id;
      final request = await repository.createRequest({
        'vehicle_id': vehicleId,
        'provider_id': 'demo-dent',
        'specialty': 'pdr',
        'service_mode': 'mobile',
        'description': 'Inspect a small dent in the driveway.',
        'share_contact': true,
      }, 'covered-mobile');
      expect(request['service_mode'], 'mobile');
      expect(request['delivery_status'], 'local_preview');
      expect(request['scheduled_at'], isNull);
      expect((await repository.bootstrap()).requests.single.id, request['id']);
    },
  );

  for (final (postalCode, providerId, specialty, mode) in [
    ('80202', 'demo-service', 'mechanical', 'mobile'),
    ('80220', 'demo-dent', 'pdr', 'mobile'),
    ('80202', 'demo-dent', 'pdr', 'shop_visit'),
    ('10001', 'demo-service', 'mechanical', 'shop_visit'),
    ('80202', 'demo-service', 'mechanical', 'teleport'),
    ('80220', 'demo-service', 'mechanical', null),
  ]) {
    test(
      'demo rejects unsupported $mode request for $providerId in $postalCode',
      () async {
        final repository = DemoPlusRepository();
        await repository.saveProfile({'postal_code': postalCode});
        final vehicleId = (await repository.bootstrap()).vehicles.first.id;
        await expectLater(
          repository.createRequest({
            'vehicle_id': vehicleId,
            'provider_id': providerId,
            'specialty': specialty,
            'service_mode': ?mode,
            'description': 'Inspect the vehicle.',
            'share_contact': true,
          }, 'unsupported-mode'),
          throwsA(isA<PlusApiException>()),
        );
        expect((await repository.bootstrap()).requests, isEmpty);
      },
    );
  }

  testWidgets(
    'sample completed estimates show sample delivery and review progress',
    (tester) async {
      final repository = DemoPlusRepository();
      final estimates = (await repository.bootstrap()).estimates;
      for (final estimate in estimates) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: EstimateProgress(estimate: estimate)),
          ),
        );
        expect(
          find.text('Demo submission · no shop contacted'),
          findsOneWidget,
        );
        expect(find.text('Your estimate is ready to review.'), findsOneWidget);
        expect(find.text('Checking submission delivery'), findsNothing);
        expect(find.text('Delivered to the shop'), findsNothing);
      }
    },
  );
}
