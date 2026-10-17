import 'dart:async';
import 'support/receipt_proof.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:estimoto_plus/data/demo_repository.dart';
import 'package:estimoto_plus/data/repository.dart';
import 'package:estimoto_plus/domain/models.dart';
import 'package:estimoto_plus/screens/history_receipts_screen.dart';
import 'package:estimoto_plus/screens/history_screen.dart';
import 'package:estimoto_plus/services/estimate_capture.dart';
import 'package:estimoto_plus/services/customer_workspace.dart';
import 'package:estimoto_plus/services/receipt_api.dart';
import 'package:estimoto_plus/services/receipt_pending.dart';
import 'package:estimoto_plus/state/plus_controller.dart';
import 'package:estimoto_plus/theme.dart';
import 'package:estimoto_plus/widgets/history_cost_summary.dart';

class _Repo extends DemoPlusRepository {
  Json? totalResult;
  bool failFirst = false, failKnowledge = false;
  bool commitBeforeUploadFailure = false;
  bool uncertainHistory = false;
  Completer<void>? historyGate;
  final historyWrites = <(Json, String)>[];
  @override
  Future<Json> addKnowledgeRecord(Json body, String idempotencyKey) async {
    historyWrites.add((Map<String, dynamic>.from(body), idempotencyKey));
    final result = await super.addKnowledgeRecord(body, idempotencyKey);
    await historyGate?.future;
    if (uncertainHistory && historyWrites.length == 1) {
      throw const PlusApiException(
        'Connection lost while saving history.',
        408,
      );
    }
    return result;
  }

  Completer<Json>? delayedKnowledge;
  int reads = 0;
  @override
  Future<Json> getKnowledge() async {
    reads++;
    if (failKnowledge) throw const PlusApiException("Unavailable", 503);
    final pending = delayedKnowledge;
    delayedKnowledge = null;
    return pending == null ? super.getKnowledge() : pending.future;
  }

  final uploads = <ReceiptPending>[];
  @override
  ReceiptApi openReceiptRecord(
    String recordId, {
    required bool Function() isCurrent,
  }) => _Api(super.openReceiptRecord(recordId, isCurrent: isCurrent), this);
}

class _Api extends ReceiptApi {
  _Api(this.delegate, this.repo);
  final ReceiptApi delegate;
  final _Repo repo;
  @override
  Future<Json> upload(ReceiptPending value) async {
    repo.uploads.add(value);
    if (repo.failFirst && repo.uploads.length == 1) {
      if (repo.commitBeforeUploadFailure) await delegate.upload(value);
      throw const PlusApiException(
        'Connection lost. Retry the saved receipt.',
        408,
      );
    }
    final result = await delegate.upload(value);
    return {...result, ...?repo.totalResult};
  }

  @override
  Future<Uint8List> read(String id) => delegate.read(id);
  @override
  Future<void> delete(String id) => delegate.delete(id);
}

class _Picker extends EstimatePhotoPicker {
  Future<XFile?> Function()? callback;
  XFile? lost;
  int recovered = 0;
  final sources = <ImageSource>[];
  @override
  Future<XFile?> pick(ImageSource source) async {
    sources.add(source);
    return callback?.call();
  }

  @override
  Future<XFile?> recover() async {
    recovered++;
    return lost;
  }
}

Future<(PlusController, Json)> _setup(_Repo repo) async {
  final c = PlusController(repo);
  await c.refresh();
  final entry = await repo.addKnowledgeRecord({
    'vehicle_id': c.selectedVehicle!.id,
    'service_type': 'repair',
    'service_date': '2025-01-03',
    'cost_cents': 12550,
  }, 'history-1');
  return (c, entry);
}

Future<void> mount(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(320, 740);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      theme: const String.fromEnvironment('RECEIPT_FONT_DIR').isEmpty
          ? plusTheme()
          : plusTheme().copyWith(
              textTheme: plusTheme().textTheme.apply(fontFamily: 'Roboto'),
              primaryTextTheme: plusTheme().primaryTextTheme.apply(
                fontFamily: 'Roboto',
              ),
            ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(1.8)),
        child: RepaintBoundary(
          key: const ValueKey('receipt-proof'),
          child: child!,
        ),
      ),
      home: child,
    ),
  );
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String text) async {
  final finder = find.text(text);
  await t.ensureVisible(finder);
  await t.tap(finder);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadReceiptProofFonts);
  testWidgets(
    'uploaded total immediately updates recorded cost and explains the saved amount',
    (t) async {
      final repo = _Repo()
        ..totalResult = {
          'total_extraction': {
            'status': 'applied',
            'amount_cents': 170348,
            'currency': 'USD',
            'source': 'pdf_text',
          },
          'record_cost_cents': 170348,
        };
      final (c, entry) = await _setup(repo);
      await repo.updateKnowledgeRecord(entry['id'], {'cost_cents': null});
      await mount(
        t,
        HistoryReceiptsScreen(
          controller: c,
          recordId: entry['id'],
          store: MemoryReceiptPendingStore(),
          pdfPicker: () async => XFile.fromData(
            Uint8List.fromList('%PDF-1.4 receipt'.codeUnits),
            name: 'total.pdf',
          ),
        ),
      );
      await tap(t, 'Choose PDF');
      expect(
        find.text(r'Receipt saved. $1,703.48 added to Recorded costs.'),
        findsOneWidget,
      );
      expect(find.text(r'Receipt total: $1,703.48'), findsOneWidget);
      expect(find.text('Included in Recorded costs.'), findsOneWidget);
      expect(find.text(r'$1,703.48'), findsOneWidget);
      expect(t.takeException(), isNull);
      c.dispose();
    },
  );
  testWidgets(
    'inline receipt choices validate before saving and keep cancellation honest',
    (t) async {
      final repo = _Repo();
      final c = PlusController(repo);
      await c.refresh();
      final store = MemoryReceiptPendingStore();
      var picks = 0;
      await mount(
        t,
        HistoryEditor(
          controller: c,
          receiptStore: store,
          pdfPicker: () async {
            picks++;
            return picks == 1
                ? null
                : XFile.fromData(
                    Uint8List.fromList('%PDF-1.4 receipt'.codeUnits),
                    name: 'service.pdf',
                  );
          },
        ),
      );
      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Choose photo'), findsOneWidget);
      expect(find.text('Choose PDF'), findsOneWidget);
      expect(
        find.textContaining('saves the details in this form first'),
        findsOneWidget,
      );
      expect(find.text('Save history entry').hitTestable(), findsOneWidget);
      final cost = find.byKey(const ValueKey('history-cost_cents'));
      await t.ensureVisible(cost);
      await t.enterText(cost, '12.345');
      await tap(t, 'Choose PDF');
      expect(picks, 0);
      expect(repo.historyWrites, isEmpty);
      await t.ensureVisible(cost);
      await t.enterText(cost, '81.27');
      await tap(t, 'Choose PDF');
      expect(picks, 1);
      expect(repo.historyWrites, hasLength(1));
      final entry = rowsOf(await repo.getKnowledge(), 'records').single;
      expect(entry['cost_cents'], 8127);
      expect(find.text('History entry saved.'), findsOneWidget);
      expect(find.textContaining('No receipt attached yet.'), findsOneWidget);
      expect(find.text('Done').hitTestable(), findsOneWidget);
      expect(repo.uploads, isEmpty);
      expect(await store.read(c.snapshot!.profile.id), isNull);
      await tap(t, 'Choose PDF');
      expect(repo.historyWrites, hasLength(1));
      expect(repo.uploads.single.recordId, entry['id']);
      expect(repo.uploads.single.ownerId, c.snapshot!.profile.id);
      expect(find.text('Receipt saved privately.'), findsOneWidget);
      expect(find.textContaining('No receipt attached yet.'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'uncertain inline history save never opens picker and recovers the original entry once',
    (t) async {
      final repo = _Repo()..uncertainHistory = true;
      final c = PlusController(repo);
      await c.refresh();
      var picks = 0;
      await mount(
        t,
        HistoryEditor(
          controller: c,
          pdfPicker: () async {
            picks++;
            return null;
          },
        ),
      );
      final shop = find.byKey(const ValueKey('history-shop_name'));
      await t.ensureVisible(shop);
      await t.enterText(shop, 'Original repair shop');
      await tap(t, 'Choose PDF');
      expect(picks, 0);
      expect(repo.historyWrites, hasLength(1));
      expect(rowsOf(await repo.getKnowledge(), 'records'), hasLength(1));
      expect(find.text('Recover saved entry'), findsOneWidget);
      expect(t.widget<TextFormField>(shop).enabled, isFalse);
      final original = await CustomerWorkspace.forController(
        c,
      ).pending('history-record');
      expect(original, isNotNull);
      await mount(t, const SizedBox());
      await mount(
        t,
        HistoryEditor(
          controller: c,
          pdfPicker: () async {
            picks++;
            return null;
          },
        ),
      );
      expect(picks, 0);
      await tap(t, 'Choose PDF');
      expect(picks, 1);
      expect(repo.historyWrites, hasLength(2));
      expect(repo.historyWrites.last.$2, original!.key);
      expect(repo.historyWrites.last.$1, repo.historyWrites.first.$1);
      expect(rowsOf(await repo.getKnowledge(), 'records'), hasLength(1));
      expect(find.text('History entry saved.'), findsOneWidget);
      expect(
        await CustomerWorkspace.forController(c).pending('history-record'),
        isNull,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('account change during inline save never opens a picker', (
    t,
  ) async {
    final repo = _Repo()..historyGate = Completer<void>();
    final c = PlusController(repo);
    await c.refresh();
    var picks = 0;
    await mount(
      t,
      HistoryEditor(
        controller: c,
        pdfPicker: () async {
          picks++;
          return null;
        },
      ),
    );
    await t.ensureVisible(find.text('Choose PDF'));
    await t.tap(find.text('Choose PDF'));
    await t.pump();
    expect(repo.historyWrites, hasLength(1));
    c.invalidateSession();
    repo.historyGate!.complete();
    await t.pumpAndSettle();
    expect(picks, 0);
    expect(repo.uploads, isEmpty);
    expect(find.text('Sign in to view your saved details.'), findsOneWidget);
  });
  for (final source in ImageSource.values) {
    testWidgets(
      'inline $source attaches only to the confirmed history record',
      (t) async {
        final repo = _Repo();
        final c = PlusController(repo);
        await c.refresh();
        final native = MemoryEstimateCaptureStore();
        final store = MemoryReceiptPendingStore();
        String? pickedTarget;
        final picker = _Picker()
          ..callback = () async {
            final entry = rowsOf(await repo.getKnowledge(), 'records').single;
            pickedTarget = native.value!.estimateId;
            expect(pickedTarget, entry['id']);
            expect(native.value!.customerId, c.snapshot!.profile.id);
            expect(native.value!.targetKind, 'receipt');
            return XFile('/private/receipt.jpg');
          };
        await mount(
          t,
          HistoryEditor(
            controller: c,
            receiptStore: store,
            captureService: EstimateCaptureService(
              store: native,
              picker: picker,
              readBytes: (_) async => Uint8List.fromList([255, 216, 255, 1]),
            ),
          ),
        );
        await tap(
          t,
          source == ImageSource.camera ? 'Take photo' : 'Choose photo',
        );
        expect(picker.sources, [source]);
        expect(repo.uploads.single.recordId, pickedTarget);
        expect(repo.historyWrites, hasLength(1));
        expect(native.value, isNull);
        expect(await store.read(c.snapshot!.profile.id), isNull);
        expect(find.text('Receipt saved privately.'), findsOneWidget);
        await t.tap(find.byTooltip('Refresh receipts'));
        await t.pumpAndSettle();
        expect(picker.sources, [source]);
        expect(repo.uploads, hasLength(1));
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'inline receipt retry keeps the exact committed upload after uncertainty',
    (t) async {
      final repo = _Repo()
        ..failFirst = true
        ..commitBeforeUploadFailure = true;
      final c = PlusController(repo);
      await c.refresh();
      final store = MemoryReceiptPendingStore();
      var picks = 0;
      await mount(
        t,
        HistoryEditor(
          controller: c,
          receiptStore: store,
          pdfPicker: () async {
            picks++;
            return XFile.fromData(
              Uint8List.fromList('%PDF-1.4 receipt'.codeUnits),
              name: 'saved.pdf',
            );
          },
        ),
      );
      await tap(t, 'Choose PDF');
      final pending = await store.read(c.snapshot!.profile.id);
      expect(pending, isNotNull);
      expect(repo.uploads, hasLength(1));
      expect(find.text('Attachment waiting to finish'), findsOneWidget);
      expect(
        find.textContaining('A receipt is waiting for confirmation.'),
        findsOneWidget,
      );
      expect(find.textContaining('No receipt attached yet.'), findsNothing);
      await mount(t, const SizedBox());
      await mount(
        t,
        HistoryReceiptsScreen(
          controller: c,
          recordId: pending!.recordId,
          store: store,
        ),
      );
      expect(repo.uploads, hasLength(1));
      expect(picks, 1);
      await tap(t, 'Retry saved receipt');
      expect(repo.uploads, hasLength(2));
      expect(repo.uploads.last.samePayload(pending), isTrue);
      expect(repo.historyWrites, hasLength(1));
      final entry = rowsOf(await repo.getKnowledge(), 'records').single;
      expect(rowsOf(entry, 'receipts'), hasLength(1));
      expect(await store.read(c.snapshot!.profile.id), isNull);
    },
  );
  testWidgets(
    'another entry pending receipt blocks the inline picker without rebinding bytes',
    (t) async {
      final repo = _Repo();
      final (c, original) = await _setup(repo);
      final store = MemoryReceiptPendingStore();
      final pending = ReceiptPending(
        ownerId: c.snapshot!.profile.id,
        recordId: original['id'],
        operationId: '11111111-1111-4111-8111-111111111111',
        filename: 'original.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List.fromList('%PDF-1.4 original'.codeUnits),
      );
      await store.write(pending);
      var picks = 0;
      await mount(
        t,
        HistoryEditor(
          controller: c,
          receiptStore: store,
          pdfPicker: () async {
            picks++;
            return null;
          },
        ),
      );
      await tap(t, 'Choose PDF');
      expect(picks, 0);
      expect(repo.uploads, isEmpty);
      expect(
        (await store.read(c.snapshot!.profile.id))!.samePayload(pending),
        isTrue,
      );
      expect(find.text('History entry saved.'), findsOneWidget);
      expect(
        find.text('Another history entry has an unfinished receipt'),
        findsOneWidget,
      );
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Choose PDF'),
            )
            .onPressed,
        isNull,
      );
      expect(rowsOf(await repo.getKnowledge(), 'records'), hasLength(2));
    },
  );
  testWidgets(
    'inline PDF rejection keeps the entry saved and permits another choice',
    (t) async {
      final repo = _Repo();
      final c = PlusController(repo);
      await c.refresh();
      final store = MemoryReceiptPendingStore();
      final files = [
        XFile.fromData(
          Uint8List.fromList('not a receipt'.codeUnits),
          name: 'fake.pdf',
        ),
        XFile.fromData(Uint8List(maxReceiptBytes + 1), name: 'large.pdf'),
        XFile.fromData(Uint8List(0), name: 'empty.pdf'),
      ];
      var picks = 0;
      await mount(
        t,
        HistoryEditor(
          controller: c,
          receiptStore: store,
          pdfPicker: () async => files[picks++],
        ),
      );
      for (var i = 0; i < files.length; i++) {
        await tap(t, 'Choose PDF');
        expect(picks, i + 1);
        expect(repo.uploads, isEmpty);
        expect(repo.historyWrites, hasLength(1));
        expect(await store.read(c.snapshot!.profile.id), isNull);
        expect(find.text('History entry saved.'), findsOneWidget);
        expect(find.textContaining('No receipt attached yet.'), findsOneWidget);
        expect(
          t
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Choose PDF'),
              )
              .onPressed,
          isNotNull,
        );
      }
      expect(
        find.text('Choose a receipt no larger than 10 MB.'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'inline PDF result is dropped when the account changes in the picker',
    (t) async {
      final repo = _Repo();
      final c = PlusController(repo);
      await c.refresh();
      final owner = c.snapshot!.profile.id;
      final store = MemoryReceiptPendingStore();
      final selected = Completer<XFile?>();
      await mount(
        t,
        HistoryEditor(
          controller: c,
          receiptStore: store,
          pdfPicker: () => selected.future,
        ),
      );
      await t.ensureVisible(find.text('Choose PDF'));
      await t.tap(find.text('Choose PDF'));
      for (var i = 0; i < 5; i++) {
        await t.pump();
      }
      expect(find.text('History entry saved.'), findsOneWidget);
      c.invalidateSession();
      selected.complete(
        XFile.fromData(
          Uint8List.fromList('%PDF-1.4 private'.codeUnits),
          name: 'private.pdf',
        ),
      );
      await t.pumpAndSettle();
      expect(repo.uploads, isEmpty);
      expect(await store.read(owner), isNull);
      expect(find.text('Sign in to view your saved details.'), findsOneWidget);
    },
  );
  testWidgets(
    'receipt retry at 320px large text uses one immutable upload after resume',
    (t) async {
      final repo = _Repo()..failFirst = true;
      final (c, r) = await _setup(repo);
      final store = MemoryReceiptPendingStore();
      final pdf = XFile.fromData(
        Uint8List.fromList('%PDF-1.4 receipt'.codeUnits),
        name: 'service.pdf',
        mimeType: 'application/pdf',
      );
      await mount(
        t,
        HistoryReceiptsScreen(
          controller: c,
          recordId: r['id'],
          store: store,
          pdfPicker: () async => pdf,
        ),
      );
      await saveReceiptProof(t, 'receipt-entry-320-large');
      await tap(t, 'Choose PDF');
      expect(repo.uploads.length, 1);
      expect(await store.read(c.snapshot!.profile.id), isNotNull);
      expect(find.text('Attachment waiting to finish'), findsOneWidget);
      await t.ensureVisible(find.text('Attachment waiting to finish'));
      await t.pumpAndSettle();
      await saveReceiptProof(t, 'receipt-retry-320-large');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(repo.uploads.length, 1);
      await tap(t, 'Retry saved receipt');
      expect(repo.uploads.length, 2);
      expect(repo.uploads.first.samePayload(repo.uploads.last), isTrue);
      expect(await store.read(c.snapshot!.profile.id), isNull);
      expect(find.text('Receipt saved privately.'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('cancelled PDF chooser leaves no upload or pending bytes', (
    t,
  ) async {
    final repo = _Repo();
    final (c, r) = await _setup(repo);
    final store = MemoryReceiptPendingStore();
    await mount(
      t,
      HistoryReceiptsScreen(
        controller: c,
        recordId: r['id'],
        store: store,
        pdfPicker: () async => null,
      ),
    );
    await tap(t, 'Choose PDF');
    expect(repo.uploads, isEmpty);
    expect(await store.read(c.snapshot!.profile.id), isNull);
  });
  testWidgets(
    'account switch while photo picker is open never uploads its result',
    (t) async {
      final repo = _Repo();
      final (c, r) = await _setup(repo);
      final store = MemoryReceiptPendingStore();
      final selected = Completer<XFile?>();
      final owner = c.snapshot!.profile.id;
      final native = MemoryEstimateCaptureStore();
      final picker = _Picker()..callback = () => selected.future;
      final service = EstimateCaptureService(
        store: native,
        picker: picker,
        readBytes: (_) async => Uint8List.fromList([255, 216, 255, 1]),
      );
      await mount(
        t,
        HistoryReceiptsScreen(
          controller: c,
          recordId: r['id'],
          store: store,
          captureService: service,
        ),
      );
      await t.ensureVisible(find.text('Choose photo'));
      await t.tap(find.text('Choose photo'));
      await t.pump();
      c.invalidateSession();
      selected.complete(XFile('/private/receipt.jpg'));
      await t.pumpAndSettle();
      expect(repo.uploads, isEmpty);
      expect(c.snapshot, isNull);
      expect(await store.read(owner), isNull);
      expect(find.text('Sign in again to view your history.'), findsOneWidget);
      expect(native.value!.targetKind, 'receipt');
      expect(native.value!.estimateId, r['id']);
    },
  );
  test(
    'receipt lost data cannot be consumed by vehicle or another owner',
    () async {
      final store = MemoryEstimateCaptureStore()
        ..value = PendingEstimateCapture.fromJson(
          const PendingEstimateCapture(
            id: 'capture',
            customerId: 'alice',
            estimateId: 'record',
            captureKey: '11111111-1111-4111-8111-111111111111',
            targetKind: 'receipt',
          ).toJson(),
        );
      final picker = _Picker()..lost = XFile('/private/receipt.jpg');
      final service = EstimateCaptureService(store: store, picker: picker);
      expect(
        await service.recover(
          customerId: 'alice',
          estimateId: 'record',
          targetKind: 'vehicle',
          isCurrent: () => true,
        ),
        isNull,
      );
      expect(
        await service.recover(
          customerId: 'bob',
          estimateId: 'record',
          targetKind: 'receipt',
          isCurrent: () => true,
        ),
        isNull,
      );
      expect(picker.recovered, 0);
      expect(
        await service.recover(
          customerId: 'alice',
          estimateId: 'record',
          targetKind: 'receipt',
          isCurrent: () => true,
        ),
        isNotNull,
      );
      expect(picker.recovered, 1);
    },
  );
  testWidgets(
    'reusing receipt state for a different history entry hides old receipt actions',
    (t) async {
      final repo = _Repo();
      final (c, r) = await _setup(repo);
      final store = MemoryReceiptPendingStore();
      await mount(
        t,
        HistoryReceiptsScreen(controller: c, recordId: r['id'], store: store),
      );
      expect(find.text('Choose PDF'), findsOneWidget);
      await mount(
        t,
        HistoryReceiptsScreen(
          controller: c,
          recordId: 'different-record',
          store: store,
        ),
      );
      expect(find.text('Choose PDF'), findsNothing);
      expect(find.textContaining('Sign in again'), findsOneWidget);
    },
  );
  testWidgets(
    'cost summary separates saved history categories and missing costs; refreshes after deletion and vehicle switch',
    (t) async {
      final repo = _Repo();
      final (c, _) = await _setup(repo);
      final id = c.selectedVehicle!.id;
      final more = await repo.addKnowledgeRecord({
        'vehicle_id': id,
        'service_type': 'diagnostics',
        'service_date': '2025-01-03',
        'cost_cents': 10000,
      }, 'diag');
      await repo.addKnowledgeRecord({
        'vehicle_id': id,
        'service_type': 'maintenance',
        'service_date': '2025-01-03',
        'cost_cents': 5000,
      }, 'maint');
      await repo.addKnowledgeRecord({
        'vehicle_id': id,
        'service_type': 'modification',
        'service_date': '2025-01-03',
        'cost_cents': 20000,
      }, 'mod');
      await repo.addKnowledgeRecord({
        'vehicle_id': id,
        'service_type': 'other',
        'service_date': '2025-01-03',
        'cost_cents': 123,
      }, 'other');
      await repo.addKnowledgeRecord({
        'vehicle_id': id,
        'service_type': 'repair',
        'service_date': '2025-01-03',
      }, 'unknown');
      await mount(
        t,
        Scaffold(
          body: SingleChildScrollView(child: HistoryCostSummary(controller: c)),
        ),
      );
      expect(find.text('\$225.50'), findsOneWidget);
      expect(find.text('\$476.73'), findsOneWidget);
      expect(find.textContaining('1 missing a cost'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);
      await saveReceiptProof(t, 'repair-costs-320-large');
      expect(t.takeException(), isNull);
      await repo.deleteKnowledgeRecord(more['id']);
      c.historyChanged();
      await t.pumpAndSettle();
      expect(find.text('\$376.73'), findsOneWidget);
      final other = c.snapshot!.vehicles.firstWhere((v) => v.id != id);
      c.selectVehicle(other.id);
      await t.pumpAndSettle();
      expect(find.text('\$0.00'), findsNWidgets(4));
      expect(find.text('0 saved entries'), findsOneWidget);
      expect(find.text('\$376.73'), findsNothing);
    },
  );
  testWidgets(
    'an Other entry with no cost remains explicit and is excluded from totals',
    (t) async {
      final repo = _Repo();
      final (c, _) = await _setup(repo);
      await repo.addKnowledgeRecord({
        'vehicle_id': c.selectedVehicle!.id,
        'service_type': 'other',
        'service_date': '2025-01-03',
      }, 'unknown-other');
      await mount(
        t,
        Scaffold(
          body: SingleChildScrollView(child: HistoryCostSummary(controller: c)),
        ),
      );
      expect(find.text('Other'), findsOneWidget);
      expect(find.textContaining('1 missing a cost'), findsOneWidget);
      expect(find.text('\$125.50'), findsNWidgets(2));
    },
  );
  testWidgets(
    'returning to Repairs refreshes costs; stale delayed response cannot replace another vehicle',
    (t) async {
      final repo = _Repo();
      final (c, _) = await _setup(repo);
      c.selectTab(3);
      await mount(
        t,
        Scaffold(
          body: SingleChildScrollView(child: HistoryCostSummary(controller: c)),
        ),
      );
      final before = repo.reads;
      c.selectTab(2);
      c.selectTab(3);
      await t.pumpAndSettle();
      expect(repo.reads, before + 1);
      final old = await repo.getKnowledge();
      final delayed = Completer<Json>();
      repo.delayedKnowledge = delayed;
      c.historyChanged();
      await t.pump();
      c.selectVehicle(c.snapshot!.vehicles.last.id);
      await t.pumpAndSettle();
      expect(find.text('0 saved entries'), findsOneWidget);
      delayed.complete(old);
      await t.pumpAndSettle();
      expect(find.text('0 saved entries'), findsOneWidget);
      expect(find.text('\$125.50'), findsNothing);
      repo.failKnowledge = true;
      c.historyChanged();
      await t.pumpAndSettle();
      expect(find.text('Retry cost summary'), findsOneWidget);
      expect(find.text('\$0.00'), findsNothing);
      c.invalidateSession();
      await t.pumpAndSettle();
      expect(find.text('Your recorded costs'), findsNothing);
    },
  );
  testWidgets(
    'history editor saves exact USD cents and offers receipt entry afterward',
    (t) async {
      final repo = _Repo();
      final (c, _) = await _setup(repo);
      await mount(t, HistoryEditor(controller: c));
      final cost = find.byKey(const ValueKey('history-cost_cents'));
      await t.ensureVisible(cost);
      await t.enterText(cost, '81.27');
      await tap(t, 'Save history entry');
      final knowledge = await repo.getKnowledge();
      expect(rowsOf(knowledge, 'records').first['cost_cents'], 8127);
    },
  );
}
