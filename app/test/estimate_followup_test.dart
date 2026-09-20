import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/estimate_forms.dart';
import 'package:estimoto_plus/services/estimate_capture.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';
import 'package:estimoto_plus/widgets/shop_profile.dart';

class _Repository extends DemoPlusRepository {
  _Repository({
    String status = 'ready',
    String processing = 'complete',
    String providerId = 'selected-shop',
    bool accepting = true,
  }) : data = {
         'profile': {'id': 'customer-1', 'name': 'Alex'},
         'vehicles': [
           {
             'id': 'vehicle-1',
             'year': 2021,
             'make': 'Toyota',
             'model': 'Tacoma',
           },
         ],
         'providers': [
           {
             'id': 'other-shop',
             'name': 'Saved estimate shop name',
             'kind': 'shop',
             'phone': '303-555-9999',
           },
           {
             'id': 'selected-shop',
             'name': 'Selected Repair Shop',
             'kind': 'shop',
             'phone': '303-555-0142',
             'address': '42 Repair Street, Denver CO',
             'website': 'https://shop.example/contact',
             'specialties': ['pdr', 'collision'],
             'accepting_requests': accepting,
           },
         ],
         'estimates': [
           {
             'id': 'estimate-1',
             'vehicle_id': 'vehicle-1',
             'discipline': 'pdr',
             'description': 'Dents on the driver door.',
             'status': status,
             'delivery_status': status == 'draft' ? 'draft' : 'delivered',
             'processing_state': processing,
             'amount_cents': status == 'ready' ? 32500 : null,
             'provider_id': providerId,
             'provider_name': 'Saved estimate shop name',
             'photos': [],
           },
         ],
         'capabilities': {'live_estimates': true},
       };
  final Json data;
  @override
  bool get isDemo => false;
  @override
  Future<PlusSnapshot> bootstrap() async =>
      PlusSnapshot.fromJson(jsonDecode(jsonEncode(data)) as Json);
}

Future<void> _mount(WidgetTester tester, _Repository repository) async {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = PlusController(repository);
  addTearDown(controller.dispose);
  await controller.refresh();
  await tester.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(1.8)),
        child: child!,
      ),
      home: EstimateDetailScreen(
        controller: controller,
        estimateId: 'estimate-1',
        captureService: EstimateCaptureService(
          store: MemoryEstimateCaptureStore(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openShop(WidgetTester tester) async {
  final button = find.widgetWithText(
    OutlinedButton,
    'View shop & contact options',
  );
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ready estimate opens only the selected shop contact profile', (
    tester,
  ) async {
    await _mount(tester, _Repository());
    expect(find.text('Your estimating shop'), findsOneWidget);
    expect(find.text('303-555-0142'), findsOneWidget);
    expect(find.text('303-555-9999'), findsNothing);
    await _openShop(tester);
    final profile = tester.widget<ShopProfile>(find.byType(ShopProfile));
    expect(profile.provider.id, 'selected-shop');
    expect(find.text('Call shop'), findsOneWidget);
    expect(find.text('Website'), findsOneWidget);
    expect(find.text('Request help'), findsNothing);
    expect(find.text('Save as my dedicated shop'), findsNothing);
    expect(
      find.text('Choose a saved vehicle to save a dedicated shop.'),
      findsNothing,
    );
    expect(find.textContaining('after you request help'), findsNothing);
    expect(find.textContaining('confirm repair arrangements'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed processing gives contact options before a price exists', (
    tester,
  ) async {
    await _mount(
      tester,
      _Repository(status: 'submitted', processing: 'failed'),
    );
    expect(find.text('Your estimating shop'), findsOneWidget);
    await _openShop(tester);
    expect(find.text('Call shop'), findsOneWidget);
    expect(find.text('Request help'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final providerId in ['missing-shop', '']) {
    testWidgets('unavailable provider $providerId never falls back by name', (
      tester,
    ) async {
      await _mount(tester, _Repository(providerId: providerId));
      expect(
        find.textContaining('Contact details for this shop are not available'),
        findsOneWidget,
      );
      expect(find.text('View shop & contact options'), findsNothing);
      expect(find.text('303-555-9999'), findsNothing);
      expect(find.text('303-555-0142'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('existing estimating shop remains reachable when intake closes', (
    tester,
  ) async {
    await _mount(tester, _Repository(accepting: false));
    await _openShop(tester);
    expect(find.text('Call shop'), findsOneWidget);
    expect(find.text('Request help'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draft retains its photo and reviewed submission workflow', (
    tester,
  ) async {
    await _mount(
      tester,
      _Repository(status: 'draft', processing: 'not_started'),
    );
    expect(find.text('Your estimating shop'), findsNothing);
    expect(find.text('View shop & contact options'), findsNothing);
    expect(find.text('Choose shop & review sharing'), findsOneWidget);
    expect(find.text('Start guided photos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
