import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:estimoto_plus/data/api_repository.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/pending_request_store.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/repairs_screen.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

class _RepairsRepository extends DemoPlusRepository {
  @override
  bool get isDemo => false;

  final Json data = {
    'profile': {'id': 'owner', 'postal_code': '80202'},
    'vehicles': [
      {'id': 'sedan', 'year': 2020, 'make': 'Toyota', 'model': 'Camry'},
      {'id': 'truck', 'year': 2022, 'make': 'Ford', 'model': 'F-150'},
    ],
    'providers': [
      {
        'id': 'provider',
        'name': 'Trusted Garage',
        'phone': '303-555-0101',
        'address': '100 Main Street',
        'specialties': ['maintenance'],
      },
    ],
    'repairs': <Json>[],
    'requests': <Json>[],
  };
  final cancellations = <String>[];
  Completer<void>? cancelGate;
  bool failCancellation = false;

  @override
  Future<PlusSnapshot> bootstrap() async =>
      PlusSnapshot.fromJson(jsonDecode(jsonEncode(data)) as Json);

  @override
  Future<Json> getKnowledge() async => {'records': <Json>[], 'preferences': {}};

  @override
  Future<Json> cancelRequest(String id) async {
    cancellations.add(id);
    await cancelGate?.future;
    if (failCancellation) {
      throw const PlusApiException('Please reconnect and try again.', 503);
    }
    final record = (data['requests'] as List<Json>).singleWhere(
      (row) => row['id'] == id,
    );
    if (!['requested', 'accepted', 'scheduled'].contains(record['status'])) {
      throw const PlusApiException(
        'This request can no longer be cancelled.',
        409,
      );
    }
    record['status'] = 'cancelled';
    record['delivery_status'] = 'cancelled';
    return record;
  }
}

Json _repair(String id, String vehicle, {String updated = ''}) => {
  'id': id,
  'vehicle_id': vehicle,
  'title': id,
  'provider_name': 'Trusted Garage',
  'status': 'In progress',
  'updated_at': updated,
  'stages': <Json>[],
};

Json _request(
  String id,
  String vehicle, {
  String status = 'completed',
  String updated = '',
  String created = '',
  String provider = 'provider',
}) => {
  'id': id,
  'vehicle_id': vehicle,
  'provider_id': provider,
  'description': id,
  'specialty': 'maintenance',
  'status': status,
  'updated_at': updated,
  'created_at': created,
  'delivery_status': 'delivered',
};

Future<PlusController> _mount(
  WidgetTester tester,
  PlusRepository repository, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = PlusController(repository);
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
      home: Scaffold(body: RepairsScreen(controller: controller)),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String query) async {
  final field = find.widgetWithText(TextField, 'Search repairs and requests');
  await tester.ensureVisible(field);
  await tester.enterText(field, query);
  await tester.pumpAndSettle();
}

void main() {
  test('scheduled request cancellation matches the API and demo', () async {
    expect(ServiceRequest.fromJson({'status': 'scheduled'}).canCancel, isTrue);
    for (final status in ['cancelled', 'completed', 'declined', 'unknown']) {
      expect(ServiceRequest.fromJson({'status': status}).canCancel, isFalse);
    }
    final repository = DemoPlusRepository();
    final snapshot = await repository.bootstrap();
    final created = await repository.createRequest({
      'vehicle_id': snapshot.vehicles.first.id,
      'provider_id': snapshot.providers.first.id,
      'specialty': snapshot.providers.first.specialties.first,
      'description': 'Oil service',
      'share_contact': true,
    }, 'scheduled-cancellation');
    created['status'] = 'scheduled';
    final cancelled = await repository.cancelRequest(created['id'] as String);
    expect(cancelled['status'], 'cancelled');
    expect(cancelled['delivery_status'], 'cancelled');
  });

  testWidgets(
    'all vehicles stay visible and latest valid timestamps sort first',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['repairs'] = [
        _repair('Undated repair', 'sedan', updated: 'invalid'),
        _repair('Older repair', 'sedan', updated: '2026-01-01T00:00:00Z'),
        _repair('Latest repair', 'truck', updated: '2026-09-19T00:00:00Z'),
      ];
      repository.data['requests'] = [
        _request('Latest request', 'truck', updated: '2026-09-19T00:00:00Z'),
        _request('Undated request', 'truck', updated: 'invalid'),
        _request('Older request', 'sedan', updated: '2026-01-01T00:00:00Z'),
        _request(
          'Created fallback',
          'sedan',
          updated: 'invalid',
          created: '2026-04-01T00:00:00Z',
        ),
      ];
      await _mount(tester, repository);
      expect(find.text('All vehicles'), findsOneWidget);
      final labels = [
        'Latest repair',
        'Older repair',
        'Undated repair',
        'Latest request',
        'Created fallback',
        'Older request',
        'Undated request',
      ];
      for (var i = 0; i < labels.length - 1; i++) {
        expect(
          tester.getTopLeft(find.text(labels[i])).dy,
          lessThan(tester.getTopLeft(find.text(labels[i + 1])).dy),
        );
      }
      expect(find.text('Showing 7 of 7 activities'), findsOneWidget);
    },
  );

  testWidgets(
    'vehicle, activity and search combine on a narrow large-text screen',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['repairs'] = [
        _repair('Sedan repair', 'sedan'),
        _repair('Truck repair', 'truck'),
      ];
      repository.data['requests'] = [
        _request('Sedan oil service', 'sedan'),
        _request('Truck oil service', 'truck'),
      ];
      final controller = await _mount(tester, repository, scale: 1.8);
      await _tap(tester, find.byType(DropdownButtonFormField<String>));
      await _tap(tester, find.text('2022 Ford F-150').last);
      expect(controller.selectedVehicle?.id, 'truck');
      await _tap(tester, find.widgetWithText(ChoiceChip, 'Service requests'));
      await _search(tester, '  TRUSTED oil  ');
      expect(find.text('Truck oil service'), findsOneWidget);
      expect(find.text('Sedan oil service'), findsNothing);
      expect(find.text('Truck repair'), findsNothing);
      expect(find.text('Showing 1 of 4 activities'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('Clear filters'));
      expect(find.text('Sedan repair'), findsOneWidget);
      expect(find.text('Truck repair'), findsOneWidget);
      expect(find.text('All vehicles'), findsOneWidget);
      expect(controller.selectedVehicle?.id, 'truck');
    },
  );

  testWidgets(
    'no matches can clear filters and pending recovery remains reachable',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['requests'] = [_request('Oil service', 'sedan')];
      final controller = await _mount(tester, repository);
      controller.pendingRequest = PendingRequest(
        body: {'vehicle_id': 'truck'},
        key: 'pending',
        provider: controller.snapshot!.providers.first,
      );
      controller.selectTab(3);
      await _search(tester, 'unmatched');
      expect(find.text('No matching activity'), findsOneWidget);
      expect(find.text('Review saved request'), findsOneWidget);
      await _tap(tester, find.text('Clear filters'));
      expect(find.text('Oil service'), findsOneWidget);
    },
  );

  testWidgets('removing a scoped vehicle permanently restores all vehicles', (
    tester,
  ) async {
    final repository = _RepairsRepository();
    repository.data['repairs'] = [
      _repair('Sedan repair', 'sedan'),
      _repair('Truck repair', 'truck'),
    ];
    final controller = await _mount(tester, repository);
    await _tap(tester, find.byType(DropdownButtonFormField<String>));
    await _tap(tester, find.text('2022 Ford F-150').last);
    expect(find.text('Sedan repair'), findsNothing);
    final vehicles = repository.data['vehicles'] as List;
    final removed = vehicles.removeLast();
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(find.text('All vehicles'), findsOneWidget);
    expect(find.text('Sedan repair'), findsOneWidget);
    vehicles.add(removed);
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(find.text('All vehicles'), findsOneWidget);
    expect(find.text('Sedan repair'), findsOneWidget);
  });

  testWidgets(
    'request contact resolves exact provider and opens only contact actions',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['requests'] = [
        _request('Scheduled oil service', 'sedan', status: 'scheduled'),
      ];
      await _mount(tester, repository);
      await _tap(tester, find.text('View provider & contact options'));
      expect(find.text('303-555-0101'), findsOneWidget);
      expect(find.text('100 Main Street'), findsOneWidget);
      expect(find.text('Call shop'), findsOneWidget);
      expect(find.text('Request service'), findsNothing);
      expect(find.text('Save to My shops'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing provider cannot pick another shop or match a saved name',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['requests'] = [
        {
          ..._request('Unavailable shop', 'sedan', provider: 'gone'),
          'provider_name': 'Trusted Garage',
        },
      ];
      await _mount(tester, repository);
      expect(find.text('View provider & contact options'), findsNothing);
      expect(
        find.textContaining(
          'Contact details for this provider are not available',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'scheduled cancellation is confirmed and concurrent taps send once',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['requests'] = [
        _request('Scheduled service', 'sedan', status: 'scheduled'),
      ];
      repository.cancelGate = Completer<void>();
      final controller = await _mount(tester, repository);
      final action = find.widgetWithText(TextButton, 'Cancel request');
      expect(action, findsOneWidget);
      final callback = tester.widget<TextButton>(action).onPressed!;
      await _tap(tester, action);
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.textContaining('Contact your provider to confirm changes'),
        findsOneWidget,
      );
      await _tap(tester, find.widgetWithText(FilledButton, 'Cancel request'));
      callback();
      await tester.pump();
      expect(repository.cancellations, ['Scheduled service']);
      repository.cancelGate!.complete();
      await tester.pumpAndSettle();
      expect(controller.snapshot!.requests.single.status, 'cancelled');
      expect(find.text('Cancellation saved.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel request'), findsNothing);
    },
  );

  testWidgets(
    'session invalidation during confirmation prevents cancellation',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['requests'] = [
        _request('Scheduled service', 'sedan', status: 'scheduled'),
      ];
      final controller = await _mount(tester, repository);
      await _tap(tester, find.widgetWithText(TextButton, 'Cancel request'));
      controller.invalidateSession();
      await tester.pumpAndSettle();
      await _tap(tester, find.widgetWithText(FilledButton, 'Cancel request'));
      expect(repository.cancellations, isEmpty);
    },
  );

  testWidgets(
    'provider completion during cancellation review prevents a stale write',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['requests'] = [
        _request('Scheduled service', 'sedan', status: 'scheduled'),
      ];
      final controller = await _mount(tester, repository);
      await _tap(tester, find.widgetWithText(TextButton, 'Cancel request'));
      (repository.data['requests'] as List<Json>).single['status'] =
          'completed';
      await controller.refresh();
      await tester.pumpAndSettle();
      await _tap(tester, find.widgetWithText(FilledButton, 'Cancel request'));
      expect(repository.cancellations, isEmpty);
      expect(
        find.text('This request can no longer be cancelled.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('scheduled cancellation uses the authenticated API contract', (
    tester,
  ) async {
    final data = _RepairsRepository().data;
    final request = _request('scheduled-request', 'sedan', status: 'scheduled');
    data['requests'] = [request];
    var cancellations = 0;
    final repository = ApiPlusRepository(
      baseUrl: 'https://plus.example.test',
      token: () async => 'customer-token',
      client: MockClient((call) async {
        expect(call.headers['Authorization'], 'Bearer customer-token');
        expect(call.followRedirects, isFalse);
        if (call.method == 'GET' && call.url.path == '/v1/bootstrap') {
          return http.Response(jsonEncode(data), 200);
        }
        if (call.method == 'GET' && call.url.path == '/v1/knowledge') {
          return http.Response('{"records":[],"preferences":{}}', 200);
        }
        expect(call.method, 'POST');
        expect(call.url.path, '/v1/requests/scheduled-request/cancel');
        expect(call.body, isEmpty);
        cancellations++;
        request['status'] = 'cancelled';
        request['delivery_status'] = 'cancelled';
        return http.Response(jsonEncode(request), 200);
      }),
    );
    final controller = await _mount(tester, repository);
    await _tap(tester, find.widgetWithText(TextButton, 'Cancel request'));
    await _tap(tester, find.widgetWithText(FilledButton, 'Cancel request'));
    expect(cancellations, 1);
    expect(controller.snapshot!.requests.single.status, 'cancelled');
  });

  testWidgets(
    'cancellation failure preserves the request and permits a retry',
    (tester) async {
      final repository = _RepairsRepository();
      repository.data['requests'] = [
        _request('Scheduled service', 'sedan', status: 'scheduled'),
      ];
      repository.failCancellation = true;
      await _mount(tester, repository);
      await _tap(tester, find.widgetWithText(TextButton, 'Cancel request'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Cancel request'));
      expect(find.text('Please reconnect and try again.'), findsOneWidget);
      expect(find.text('Scheduled'), findsOneWidget);
      repository.failCancellation = false;
      await _tap(tester, find.widgetWithText(TextButton, 'Cancel request'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Cancel request'));
      expect(repository.cancellations, [
        'Scheduled service',
        'Scheduled service',
      ]);
      expect(find.text('Cancelled'), findsOneWidget);
    },
  );
}
