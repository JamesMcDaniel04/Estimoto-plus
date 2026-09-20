import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/history_screen.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';

class _HistoryRepo extends DemoPlusRepository {
  List<Json> records = [];

  @override
  Future<Json> getKnowledge() async => {'records': records, 'preferences': {}};
}

Future<PlusController> _mount(
  WidgetTester tester,
  List<Json> records, {
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _HistoryRepo();
  final controller = PlusController(repo);
  await controller.refresh();
  repo.records = [
    for (final record in records)
      {'vehicle_id': controller.selectedVehicle!.id, ...record},
  ];
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: plusTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: HistoryScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String text) async {
  final field = find.widgetWithText(TextField, 'Search service history');
  expect(field, findsOneWidget);
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

final _records = <Json>[
  {
    'id': 'repair',
    'service_type': 'repair',
    'service_date': '2026-02-05',
    'shop_name': 'Acme Repair',
    'cost_cents': 10000,
  },
  {
    'id': 'oil',
    'service_type': 'oil_change',
    'service_date': '2026-03-01',
    'shop_name': 'Acme Oil',
    'parts_source': 'Local supplier',
    'parts_description': 'Synthetic filter',
    'notes': 'Annual visit',
    'cost_cents': 20000,
  },
  {
    'id': 'modification',
    'service_type': 'modification',
    'service_date': '2026-02-20',
    'shop_name': 'Performance Garage',
    'cost_cents': 30000,
  },
  {
    'id': 'other',
    'service_type': 'other',
    'service_date': '2026-01-10',
    'shop_name': 'Detail Studio',
    'cost_cents': 40000,
  },
];

void main() {
  testWidgets(
    'search and category combine while recorded spending stays vehicle-wide',
    (tester) async {
      await _mount(tester, _records, textScale: 1.8);
      await _search(tester, '  ACME  ');
      expect(find.text('Acme Repair'), findsOneWidget);
      expect(find.text('Acme Oil'), findsOneWidget);
      expect(find.text('Performance Garage'), findsNothing);
      expect(find.text('Showing 2 of 4 records'), findsOneWidget);
      await _tap(tester, find.widgetWithText(ChoiceChip, 'Maintenance'));
      expect(find.text('Acme Repair'), findsNothing);
      expect(find.text('Acme Oil'), findsOneWidget);
      expect(find.text('Showing 1 of 4 records'), findsOneWidget);
      expect(find.text(r'$100.00'), findsOneWidget);
      expect(find.text(r'$300.00'), findsOneWidget);
      expect(find.text(r'$400.00'), findsOneWidget);
      expect(
        find.textContaining('All records for this vehicle'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('search matches readable services, parts, shops and notes', (
    tester,
  ) async {
    await _mount(tester, _records);
    for (final query in [
      'oil change',
      'acme oil',
      'local supplier',
      'synthetic filter',
      'annual visit',
      'oil annual',
    ]) {
      await _search(tester, query);
      expect(find.text('Acme Oil'), findsOneWidget, reason: query);
      expect(find.text('Acme Repair'), findsNothing, reason: query);
      expect(find.text('Showing 1 of 4 records'), findsOneWidget);
    }
  });

  testWidgets('no matches are distinct from empty history and filters clear', (
    tester,
  ) async {
    await _mount(tester, _records);
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Repairs'));
    await _search(tester, 'missing service');
    expect(find.text('No matching service records'), findsOneWidget);
    expect(find.text('Start with your last service'), findsNothing);
    await _tap(tester, find.byTooltip('Clear search'));
    expect(find.text('Acme Repair'), findsOneWidget);
    expect(find.text('Acme Oil'), findsNothing);
    expect(find.text('No matching service records'), findsNothing);
    await _search(tester, 'missing again');
    await _tap(tester, find.text('Clear filters'));
    expect(find.text('Acme Repair'), findsOneWidget);
    expect(find.text('Acme Oil'), findsOneWidget);
    expect(find.text('Performance Garage'), findsOneWidget);
    expect(find.text('Detail Studio'), findsOneWidget);
    expect(find.text('Showing 4 of 4 records'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets(
    'vehicle changes clear filters and never show another car history',
    (tester) async {
      final controller = await _mount(tester, _records);
      final firstId = controller.selectedVehicle!.id;
      final other = controller.snapshot!.vehicles.firstWhere(
        (v) => v.id != firstId,
      );
      final repo = controller.repository as _HistoryRepo;
      repo.records.add({
        'id': 'other-car',
        'vehicle_id': other.id,
        'service_type': 'battery',
        'service_date': '2026-04-01',
        'shop_name': 'Second Car Workshop',
      });
      await _tap(tester, find.byTooltip('Refresh service history'));
      expect(find.text('Second Car Workshop'), findsNothing);
      await _search(tester, 'Acme');
      await _tap(tester, find.widgetWithText(ChoiceChip, 'Repairs'));
      controller.selectVehicle(other.id);
      await tester.pumpAndSettle();
      expect(find.text('Second Car Workshop'), findsOneWidget);
      expect(find.text('Acme Repair'), findsNothing);
      expect(find.text('Acme Oil'), findsNothing);
      expect(find.text('Showing 1 of 1 record'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All'))
            .selected,
        isTrue,
      );
      expect(find.text(r'$100.00'), findsNothing);
      repo.records.clear();
      await _tap(tester, find.byTooltip('Refresh service history'));
      expect(find.text('Start with your last service'), findsOneWidget);
      expect(find.text('No matching service records'), findsNothing);
    },
  );

  testWidgets(
    'history sorts newest service first with stable same-date order',
    (tester) async {
      await _mount(tester, [
        {
          'id': 'old',
          'service_type': 'repair',
          'service_date': '2025-01-01',
          'shop_name': 'Old shop',
        },
        {
          'id': 'b',
          'service_type': 'repair',
          'service_date': '2026-03-01',
          'created_at': '2026-03-03T08:00:00Z',
          'shop_name': 'Tie B',
        },
        {
          'id': 'a',
          'service_type': 'repair',
          'service_date': '2026-03-01',
          'created_at': '2026-03-03T08:00:00Z',
          'shop_name': 'Tie A',
        },
        {
          'id': 'new',
          'service_type': 'repair',
          'service_date': '2026-04-01',
          'shop_name': 'Newest shop',
        },
        {
          'id': 'earlier-save',
          'service_type': 'repair',
          'service_date': '2026-03-01',
          'created_at': '2026-03-02T08:00:00Z',
          'shop_name': 'Earlier save',
        },
      ]);
      final shops = [
        'Newest shop',
        'Tie A',
        'Tie B',
        'Earlier save',
        'Old shop',
      ];
      for (var i = 1; i < shops.length; i++) {
        expect(
          tester.getTopLeft(find.text(shops[i - 1])).dy,
          lessThan(tester.getTopLeft(find.text(shops[i])).dy),
        );
      }
    },
  );
}
