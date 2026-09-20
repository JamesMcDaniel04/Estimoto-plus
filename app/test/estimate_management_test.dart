import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/estimates_screen.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

class _Repository extends DemoPlusRepository {
  final Json data = {
    'profile': {'id': 'customer', 'name': 'Alex'},
    'vehicles': [
      {'id': 'audi', 'year': 2022, 'make': 'Audi', 'model': 'Q5'},
      {'id': 'ford', 'year': 2020, 'make': 'Ford', 'model': 'Focus'},
    ],
    'estimates': [
      {
        'id': 'old',
        'vehicle_id': 'audi',
        'discipline': 'pdr',
        'status': 'draft',
        'description': 'Old door ding',
        'provider_name': '',
        'updated_at': '2025-01-01',
      },
      {
        'id': 'ready',
        'vehicle_id': 'ford',
        'discipline': 'pdr',
        'status': 'ready',
        'description': 'Reviewed hail',
        'provider_name': 'Valley Shop',
        'claim_number': 'CLM-204',
        'updated_at': '2025-04-01',
      },
      {
        'id': 'failed',
        'vehicle_id': 'audi',
        'discipline': 'pdr',
        'status': 'submitted',
        'processing_state': 'failed',
        'description': 'Hood review interrupted',
        'provider_name': 'Hill Shop',
        'updated_at': '2025-03-01',
      },
      {
        'id': 'reviewing',
        'vehicle_id': 'audi',
        'discipline': 'pdr',
        'status': 'reviewing',
        'description': 'Dent being reviewed',
        'updated_at': '2025-02-01',
      },
      {
        'id': 'collision',
        'vehicle_id': 'ford',
        'discipline': 'collision',
        'status': 'approved',
        'description': 'Approved bumper work',
        'updated_at': '2025-05-01',
      },
      {
        'id': 'unknown-date',
        'vehicle_id': 'audi',
        'discipline': 'pdr',
        'status': 'draft',
        'description': 'Undated damage',
        'updated_at': 'not-a-date',
      },
    ],
  };
  @override
  Future<PlusSnapshot> bootstrap() async =>
      PlusSnapshot.fromJson(jsonDecode(jsonEncode(data)) as Json);
}

Future<PlusController> _mount(
  WidgetTester t,
  _Repository repo, {
  double scale = 1,
}) async {
  t.view.physicalSize = const Size(320, 740);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final c = PlusController(repo);
  addTearDown(c.dispose);
  await c.refresh();
  await t.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: EstimatesScreen(controller: c)),
    ),
  );
  await t.pumpAndSettle();
  return c;
}

Future<void> tap(WidgetTester t, Finder finder) async {
  await t.ensureVisible(finder);
  await t.tap(finder);
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'estimates combine vehicle, status and search without crossing disciplines',
    (t) async {
      final c = await _mount(t, _Repository());
      await t.enterText(
        find.widgetWithText(TextField, 'Search estimates'),
        'valley CLM-204',
      );
      await t.pumpAndSettle();
      expect(find.text('Reviewed hail'), findsOneWidget);
      expect(find.text('Old door ding'), findsNothing);
      expect(find.text('Approved bumper work'), findsNothing);
      await tap(t, find.byKey(const Key('estimate-status-ready')));
      expect(find.text('Reviewed hail'), findsOneWidget);
      await tap(t, find.byKey(const Key('vehicle-scope-filter')));
      await tap(t, find.text('2022 Audi Q5').last);
      expect(find.text('No matching estimates'), findsOneWidget);
      await tap(t, find.text('Clear filters'));
      expect(find.text('Reviewed hail'), findsOneWidget);
      expect(find.text('Old door ding'), findsOneWidget);
      expect(c.discipline, 'pdr');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'estimate filters distinguish attention, progress and draft states',
    (t) async {
      await _mount(t, _Repository());
      await tap(t, find.byKey(const Key('estimate-status-attention')));
      expect(find.text('Hood review interrupted'), findsOneWidget);
      expect(find.text('Dent being reviewed'), findsNothing);
      await tap(t, find.byKey(const Key('estimate-status-progress')));
      expect(find.text('Dent being reviewed'), findsOneWidget);
      expect(find.text('Hood review interrupted'), findsNothing);
      await tap(t, find.byKey(const Key('estimate-status-draft')));
      expect(find.text('Old door ding'), findsOneWidget);
      expect(find.text('Undated damage'), findsOneWidget);
    },
  );

  testWidgets('estimates use newest updates first and put unknown dates last', (
    t,
  ) async {
    await _mount(t, _Repository());
    final texts = [
      'Reviewed hail',
      'Hood review interrupted',
      'Dent being reviewed',
      'Old door ding',
      'Undated damage',
    ];
    for (var i = 1; i < texts.length; i++) {
      expect(
        t.getTopLeft(find.text(texts[i - 1])).dy,
        lessThan(t.getTopLeft(find.text(texts[i])).dy),
      );
    }
  });

  testWidgets(
    'vehicle filter follows explicit choice and recovers when that vehicle disappears',
    (t) async {
      final repo = _Repository();
      final c = await _mount(t, repo);
      await tap(t, find.byKey(const Key('vehicle-scope-filter')));
      await tap(t, find.text('2020 Ford Focus').last);
      expect(c.selectedVehicleId, 'ford');
      expect(find.text('Reviewed hail'), findsOneWidget);
      expect(find.text('Old door ding'), findsNothing);
      (repo.data['vehicles'] as List).removeWhere((row) => row['id'] == 'ford');
      (repo.data['estimates'] as List).removeWhere(
        (row) => row['vehicle_id'] == 'ford',
      );
      await c.refresh();
      await t.pumpAndSettle();
      expect(find.text('All vehicles'), findsOneWidget);
      expect(find.text('Old door ding'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('estimate management remains usable at 320px and enlarged text', (
    t,
  ) async {
    await _mount(t, _Repository(), scale: 1.8);
    await tap(t, find.byKey(const Key('estimate-status-approved')));
    expect(find.text('No matching estimates'), findsOneWidget);
    await tap(t, find.text('Collision').first);
    expect(find.text('Approved bumper work'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('ending a session removes estimate search and private records', (
    t,
  ) async {
    final c = await _mount(t, _Repository());
    c.invalidateSession();
    await t.pumpAndSettle();
    expect(find.text('Old door ding'), findsNothing);
    expect(find.widgetWithText(TextField, 'Search estimates'), findsNothing);
  });

  testWidgets('filters remain clearable after the last estimate is deleted', (
    t,
  ) async {
    final repo = _Repository();
    repo.data['estimates'] = [(repo.data['estimates'] as List).first];
    final c = await _mount(t, repo);
    await tap(t, find.byKey(const Key('estimate-status-draft')));
    repo.data['estimates'] = <Json>[];
    await c.refresh();
    await t.pumpAndSettle();
    expect(find.text('No matching estimates'), findsOneWidget);
    await tap(t, find.text('Clear filters'));
    expect(find.text('Your next estimate starts here'), findsOneWidget);
    expect(find.text('No matching estimates'), findsNothing);
  });
}
