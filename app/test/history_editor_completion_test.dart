import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/history_screen.dart';
import 'package:estimoto_plus/services/receipt_pending.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';
import 'package:estimoto_plus/widgets/workspace_widgets.dart';

Future<(DemoPlusRepository, PlusController, Json)> setup() async {
  final repo = DemoPlusRepository();
  final controller = PlusController(repo);
  await controller.refresh();
  final record = await repo.addKnowledgeRecord({
    'vehicle_id': controller.selectedVehicle!.id,
    'service_type': 'repair',
    'service_date': '2025-01-03',
    'shop_name': 'Original shop',
    'cost_cents': 150000,
  }, 'edit-receipt');
  return (repo, controller, record);
}

Future<void> mount(WidgetTester tester, Widget editor) async {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme: plusTheme(), home: editor));
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'editing saves changed details and attaches PDF to the same record',
    (tester) async {
      final (repo, controller, record) = await setup();
      addTearDown(controller.dispose);
      var picks = 0;
      await mount(
        tester,
        HistoryEditor(
          controller: controller,
          record: record,
          receiptStore: MemoryReceiptPendingStore(),
          pdfPicker: () async {
            picks++;
            return XFile.fromData(
              Uint8List.fromList('%PDF-1.4 receipt'.codeUnits),
              name: 'invoice.pdf',
            );
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('history-shop_name')),
        'Updated shop',
      );
      await tap(tester, 'Choose PDF');
      expect(picks, 1);
      final records = rowsOf(await repo.getKnowledge(), 'records');
      expect(records, hasLength(1));
      expect(records.single['id'], record['id']);
      expect(records.single['shop_name'], 'Updated shop');
      expect(records.single['cost_cents'], 150000);
      expect(rowsOf(records.single, 'receipts'), hasLength(1));
      expect(find.text('Receipt saved privately.'), findsOneWidget);
      expect(find.text('View receipt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelling an edit receipt picker keeps changes and the existing entry',
    (tester) async {
      final (repo, controller, record) = await setup();
      addTearDown(controller.dispose);
      var picks = 0;
      await mount(
        tester,
        HistoryEditor(
          controller: controller,
          record: record,
          receiptStore: MemoryReceiptPendingStore(),
          pdfPicker: () async {
            picks++;
            return null;
          },
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('history-shop_name')),
        'Updated shop',
      );
      await tap(tester, 'Choose PDF');
      expect(picks, 1);
      expect(find.textContaining('No receipt attached yet.'), findsOneWidget);
      final records = rowsOf(await repo.getKnowledge(), 'records');
      expect(records, hasLength(1));
      expect(records.single['shop_name'], 'Updated shop');
      expect(rowsOf(records.single, 'receipts'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing identifies the saved vehicle without offering reassignment',
    (tester) async {
      final (_, controller, record) = await setup();
      addTearDown(controller.dispose);
      await mount(
        tester,
        HistoryEditor(controller: controller, record: record),
      );
      expect(find.byType(SavedVehicleField), findsNothing);
      expect(find.text('Saved vehicle'), findsOneWidget);
      expect(
        find.text('This entry stays with its original vehicle.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
