import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'history_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';
import '../data/repository.dart';
import '../domain/models.dart';
import '../services/estimate_capture.dart';
import '../services/receipt_api.dart';
import '../services/receipt_pending.dart';
import '../services/receipt_picker.dart';
import '../services/receipt_upload.dart';
import '../services/receipt_pdf.dart';
import '../state/plus_controller.dart';
import '../widgets/common.dart';
import '../widgets/workspace_widgets.dart';
import '../widgets/receipt_work_items.dart';

enum ReceiptChoice { camera, gallery, pdf }

class ReceiptPickerButtons extends StatelessWidget {
  const ReceiptPickerButtons({super.key, required this.onSelected});
  final ValueChanged<ReceiptChoice>? onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final choice in ReceiptChoice.values)
        OutlinedButton.icon(
          onPressed: onSelected == null ? null : () => onSelected!(choice),
          icon: Icon(switch (choice) {
            ReceiptChoice.camera => Icons.camera_alt_outlined,
            ReceiptChoice.gallery => Icons.photo_library_outlined,
            ReceiptChoice.pdf => Icons.picture_as_pdf_outlined,
          }),
          label: Text(switch (choice) {
            ReceiptChoice.camera => 'Take photo',
            ReceiptChoice.gallery => 'Choose photo',
            ReceiptChoice.pdf => 'Choose PDF',
          }),
        ),
    ],
  );
}

class HistoryReceiptsScreen extends StatefulWidget {
  const HistoryReceiptsScreen({
    super.key,
    required this.controller,
    required this.recordId,
    this.store,
    this.captureService,
    this.pdfPicker,
    this.initialChoice,
    this.onDone,
  });
  final PlusController controller;
  final String recordId;
  final ReceiptPendingStore? store;
  final EstimateCaptureService? captureService;
  final Future<XFile?> Function()? pdfPicker;
  final ReceiptChoice? initialChoice;
  final VoidCallback? onDone;
  @override
  State<HistoryReceiptsScreen> createState() => _HistoryReceiptsScreenState();
}

class _HistoryReceiptsScreenState extends State<HistoryReceiptsScreen>
    with WidgetsBindingObserver {
  late final String owner, boundRecordId;
  late final PlusController boundController;
  late final ReceiptPendingStore store;
  late final ReceiptApi api;
  late final ReceiptUpload upload;
  late final EstimateCaptureService capture;
  Json? record;
  ReceiptPending? pending;
  PendingEstimateCapture? pickerPending;
  bool busy = false, loading = true, corrupt = false, otherPicker = false;
  String? error, notice;
  int epoch = 0;
  bool initialChoiceHandled = false;
  bool get current =>
      mounted &&
      identical(widget.controller, boundController) &&
      widget.recordId == boundRecordId &&
      widget.controller.isCurrentCustomer(owner);
  bool valid(int run) => current && run == epoch;
  bool get canAdd =>
      current &&
      !busy &&
      !loading &&
      record != null &&
      pending == null &&
      pickerPending == null &&
      !otherPicker &&
      !corrupt &&
      rowsOf(record!, 'receipts').length < 10;
  @override
  void initState() {
    super.initState();
    boundController = widget.controller;
    boundRecordId = widget.recordId;
    owner = widget.controller.snapshot!.profile.id;
    store =
        widget.store ??
        (widget.controller.isDemo
            ? MemoryReceiptPendingStore()
            : createReceiptPendingStore());
    api = widget.controller.repository.openReceiptRecord(
      widget.recordId,
      isCurrent: () => current,
    );
    upload = ReceiptUpload(
      ownerId: owner,
      recordId: widget.recordId,
      store: store,
      isCurrent: () => current,
      send: api.upload,
    );
    capture =
        widget.captureService ??
        EstimateCaptureService(
          store: widget.controller.isDemo ? MemoryEstimateCaptureStore() : null,
          readBytes: (path) => readReceiptFile(XFile(path)),
        );
    widget.controller.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    epoch++;
    boundController.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy && current) load();
  }

  Future<void> load() async {
    if (!current) return;
    final run = ++epoch;
    var foundEntry = false;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final saved = await store.read(owner);
      if (!valid(run)) return;
      final recovered = await capture.recover(
        customerId: owner,
        estimateId: widget.recordId,
        targetKind: 'receipt',
        isCurrent: () => valid(run),
      );
      if (!valid(run)) return;
      final native = await capture.store.read();
      if (!valid(run)) return;
      setState(() {
        pending = saved;
        pickerPending = recovered;
        otherPicker = native != null && recovered == null;
        corrupt = false;
      });
      final knowledge = await widget.controller.repository.getKnowledge();
      if (!valid(run)) return;
      final found = rowsOf(
        knowledge,
        'records',
      ).where((r) => r['id'] == widget.recordId).firstOrNull;
      foundEntry = found != null;
      setState(() {
        record = found;
        if (found == null) {
          error =
              'This history entry is no longer available. You can discard any unfinished attachment below.';
        }
      });
    } on ReceiptPendingException catch (e) {
      if (valid(run)) {
        setState(() {
          corrupt = e.failure == ReceiptPendingFailure.corrupt;
          error = e.toString();
        });
      }
    } catch (e) {
      if (valid(run)) setState(() => error = PlusController.readableError(e));
    } finally {
      if (valid(run)) setState(() => loading = false);
    }
    if (!valid(run) || initialChoiceHandled) return;
    initialChoiceHandled = true;
    // A browser picker needs a fresh click after the asynchronous history save.
    // Native may open the requested picker once; reopening/recovery never does.
    if (kIsWeb || !foundEntry || !canAdd || widget.initialChoice == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (valid(run) && canAdd) choose(widget.initialChoice!);
    });
  }

  Future<void> choose(ReceiptChoice choice) => switch (choice) {
    ReceiptChoice.camera => photo(ImageSource.camera),
    ReceiptChoice.gallery => photo(ImageSource.gallery),
    ReceiptChoice.pdf => pdf(),
  };

  Future<void> action(Future<void> Function() work) async {
    if (!current || busy || loading) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await work();
    } catch (e) {
      if (current) {
        setState(
          () => error = e is ReceiptPendingException
              ? e.toString()
              : PlusController.readableError(e),
        );
      }
    } finally {
      if (current) {
        try {
          final value = await store.read(owner);
          if (current) setState(() => pending = value);
        } catch (_) {}
        try {
          final native = await capture.store.read();
          if (current) {
            setState(() {
              pickerPending =
                  native?.customerId == owner &&
                      native?.targetKind == 'receipt' &&
                      native?.estimateId == widget.recordId
                  ? native
                  : null;
              otherPicker = native != null && pickerPending == null;
            });
          }
        } catch (_) {
          if (current) {
            setState(
              () => error =
                  'The saved photo could not be checked. Reopen this entry to recover it.',
            );
          }
        }
        if (current) setState(() => busy = false);
      }
    }
  }

  Future<Json> stagePhoto(
    String id,
    Uint8List bytes,
    String filename,
    String operation,
  ) async {
    if (!current || id != widget.recordId) {
      throw const PlusApiException(
        'Your account changed. Reopen history to continue.',
        401,
      );
    }
    final mime = receiptMime(bytes);
    final value = ReceiptPending(
      ownerId: owner,
      recordId: id,
      operationId: operation,
      filename: receiptFilename(filename, mime),
      mimeType: mime,
      bytes: bytes,
    );
    await upload.stage(value);
    return {'id': operation};
  }

  Future<void> sendPending() async {
    final saved = await upload.restore();
    if (!current || saved == null) return;
    setState(() => pending = saved);
    final result = await upload.retry();
    if (!current) return;
    setState(() {
      pending = null;
    });
    acceptReceipt(result);
  }

  void acceptReceipt(Json result) {
    if (!current) return;
    final extraction = result['total_extraction'] as Map? ?? {};
    final amount = extraction['amount_cents'];
    final applied =
        extraction['status'] == 'applied' &&
        amount is int &&
        result['record_cost_cents'] == amount;
    setState(() {
      notice = applied
          ? 'Receipt saved. ${receiptCost(amount)} added to Recorded costs.'
          : 'Receipt saved privately.';
      if (record != null) {
        record = {
          ...record!,
          if (result.containsKey('record_cost_cents'))
            'cost_cents': result['record_cost_cents'],
          'receipts': [
            ...rowsOf(
              record!,
              'receipts',
            ).where((r) => r['id'] != result['id']),
            result,
          ],
        };
      }
    });
    widget.controller.historyChanged();
  }

  Future<void> parseTotal(Json receipt) => action(() async {
    acceptReceipt(await api.parseTotal(textOf(receipt, 'id')));
  });

  Future<void> useTotal(Json receipt) => action(() async {
    final extraction = receipt['total_extraction'] as Map? ?? {};
    final amount = extraction['amount_cents'];
    if (amount is! int || record == null) return;
    final previous = record!['cost_cents'] as int?;
    if (!await confirm(
      'Use receipt total?',
      previous == null
          ? 'Record ${receiptCost(amount)} as the cost for this history entry?'
          : 'Replace the recorded cost of ${receiptCost(previous)} with ${receiptCost(amount)}? This replaces the amount; it does not add a second charge.',
      'Use total',
    )) {
      return;
    }
    acceptReceipt(await api.applyTotal(textOf(receipt, 'id'), previous));
  });

  Future<void> editCost() => action(() async {
    if (record == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            HistoryEditor(controller: widget.controller, record: record),
      ),
    );
    if (current) await load();
  });

  Widget totalDetails(Json receipt) {
    final extraction = receipt['total_extraction'] as Map? ?? {};
    final amount = extraction['amount_cents'];
    final status = extraction['status'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (amount is int) ...[
          Text('Receipt total: ${receiptCost(amount)}'),
          if (record?['cost_cents'] == amount)
            const Text('Included in Recorded costs.')
          else if (!widget.controller.isDemo)
            TextButton(
              onPressed: busy ? null : () => useTotal(receipt),
              child: const Text('Use detected total'),
            ),
        ] else
          Text(
            status == 'unsupported_currency'
                ? 'This receipt uses another currency. Enter its USD cost manually.'
                : status == 'needs_review'
                ? 'Several possible totals need review. Enter the correct cost below.'
                : widget.controller.isDemo
                ? 'Automatic receipt totals are available when signed in.'
                : status == 'not_found'
                ? 'No clear receipt total was found. You can enter it manually.'
                : 'The receipt total has not been read yet.',
          ),
        if (status == 'needs_review' && amount is int)
          const Text('Check this amount against the receipt before using it.'),
        const SizedBox(height: 12),
        const Text(
          'Work listed on this receipt',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ReceiptWorkItems(receipt: receipt),
        Wrap(
          spacing: 8,
          children: [
            if (!widget.controller.isDemo)
              TextButton(
                onPressed: busy ? null : () => parseTotal(receipt),
                child: Text(
                  amount is! int ? 'Read receipt total' : 'Read work details',
                ),
              ),
            TextButton(
              onPressed: busy ? null : editCost,
              child: const Text('Edit recorded cost'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> photo(ImageSource source) => action(() async {
    final result = await capture.capture(
      customerId: owner,
      estimateId: widget.recordId,
      captureKey: newReceiptOperation(),
      targetKind: 'receipt',
      source: source,
      isCurrent: () => current,
      upload: stagePhoto,
    );
    if (current && result != null) await sendPending();
  });
  Future<void> pdf() => action(() async {
    final file = await (widget.pdfPicker ?? chooseReceiptPdf)();
    if (!current || file == null) return;
    final bytes = await readReceiptFile(file);
    if (!current) return;
    final mime = receiptMime(bytes);
    if (mime != 'application/pdf') {
      throw const PlusApiException('Choose a readable PDF receipt.', 415);
    }
    await upload.stage(
      ReceiptPending(
        ownerId: owner,
        recordId: widget.recordId,
        operationId: newReceiptOperation(),
        filename: receiptFilename(file.name, mime),
        mimeType: mime,
        bytes: bytes,
      ),
    );
    if (current) await sendPending();
  });
  Future<void> retry() => action(() async {
    if (pickerPending != null) {
      await capture.retry(
        pending: pickerPending!,
        targetKind: 'receipt',
        isCurrent: () => current,
        upload: stagePhoto,
      );
      if (!current) return;
      setState(() => pickerPending = null);
    }
    await sendPending();
  });
  Future<bool> confirm(String title, String message, String action) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return yes == true && current;
  }

  Future<void> discard() => action(() async {
    if (!await confirm(
      'Discard unfinished attachment?',
      'This removes the saved upload from this device. A receipt already accepted by the server may still appear after refresh.',
      'Discard upload',
    )) {
      return;
    }
    if (pending != null && pending!.recordId == widget.recordId) {
      await upload.discard(pending!);
    }
    if (!current) return;
    if (pickerPending != null) {
      await capture.discard(pickerPending!, () => current);
    }
    if (current) {
      setState(() {
        pending = null;
        pickerPending = null;
        notice =
            'Unfinished attachment discarded. Refresh to check saved receipts.';
      });
    }
  });
  Future<void> remove(Json receipt) => action(() async {
    if (!await confirm(
      'Delete this receipt?',
      'The private document will be removed. Your history entry and recorded cost will remain.',
      'Delete receipt',
    )) {
      return;
    }
    await api.delete(textOf(receipt, 'id'));
    if (!current) return;
    widget.controller.historyChanged();
    setState(() {
      record = {
        ...record!,
        'receipts': rowsOf(
          record!,
          'receipts',
        ).where((r) => r['id'] != receipt['id']).toList(),
      };
      notice = 'Receipt deleted.';
    });
  });
  Future<void> view(Json receipt) => action(() async {
    final bytes = await api.read(textOf(receipt, 'id'));
    if (!mounted || !current) return;
    final mime = receiptMime(bytes);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PrivateReceiptView(
          controller: widget.controller,
          ownerId: owner,
          filename: textOf(receipt, 'filename'),
          bytes: bytes,
          mimeType: mime,
        ),
      ),
    );
  });
  @override
  Widget build(BuildContext context) {
    if (!current) {
      return const UnavailableRecordScreen(
        title: 'History & receipts',
        message: 'Sign in again to view your history.',
      );
    }
    final receipts = record == null ? <Json>[] : rowsOf(record!, 'receipts');
    final ownPending = pending?.recordId == widget.recordId;
    final addingHistory = widget.onDone != null;
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading('Add a receipt'),
        ReceiptPickerButtons(onSelected: canAdd ? choose : null),
        const SizedBox(height: 10),
        Text(
          '${receipts.length} of 10 receipts · Up to 10 MB each\nJPEG, PNG, WebP or PDF',
        ),
      ],
    );
    final vehicle = widget.controller.snapshot!.vehicle(
      textOf(record ?? {}, 'vehicle_id'),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('History & receipts'),
        actions: [
          IconButton(
            tooltip: 'Refresh receipts',
            onPressed: busy || loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: addingHistory
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: FilledButton(
                  onPressed: busy || loading ? null : widget.onDone,
                  child: const Text('Done'),
                ),
              ),
            )
          : null,
      body: PageBody(
        children: [
          if (addingHistory) ...[
            const PageHeading(
              'History entry saved.',
              'Your details are saved. Receipt uploads belong to this entry.',
            ),
            if (!loading && receipts.isEmpty)
              Text(
                ownPending || pickerPending != null
                    ? 'A receipt is waiting for confirmation. Review the unfinished attachment below before retrying.'
                    : 'No receipt attached yet. Choose a photo or PDF below, or tap Done to add one later.',
              ),
            controls,
            const SizedBox(height: 24),
          ],
          PageHeading(
            record == null
                ? 'Your saved history'
                : serviceName(textOf(record!, 'service_type')),
            record == null
                ? 'Recover a receipt or refresh this entry.'
                : '${vehicle?.title ?? 'Your vehicle'} · ${dateText(textOf(record!, 'service_date'))}',
          ),
          if (record != null) ...[
            if (record!['cost_cents'] is int)
              ReviewBlock(
                'Recorded total (USD)',
                receiptCost(record!['cost_cents'] as int),
              ),
            if (record!['mileage'] != null)
              ReviewBlock(
                'Mileage',
                '${mileageText(intOf(record!, 'mileage'))} miles',
              ),
            for (final field in {
              'shop_name': 'Shop or DIY',
              'parts_description': 'Parts',
              'parts_source': 'Parts source',
              'notes': 'Your notes',
            }.entries)
              if (textOf(record!, field.key).isNotEmpty)
                ReviewBlock(field.value, textOf(record!, field.key)),
          ],
          const Text(
            'Keep photos or PDFs of past work with this entry. Receipts stay private to your account and are not automatically shared with shops.',
          ),
          const SizedBox(height: 16),
          if (loading) const Center(child: CircularProgressIndicator()),
          if (error != null) WorkspaceError(error!),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                notice!,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            ),
          if (ownPending || pickerPending != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Attachment waiting to finish',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(pending?.filename ?? 'Your selected receipt photo'),
                    const Text(
                      'Retry uses the same saved file and upload ID. Returning to this page does not upload it automatically.',
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: busy ? null : retry,
                          child: const Text('Retry saved receipt'),
                        ),
                        TextButton(
                          onPressed: busy ? null : discard,
                          child: const Text('Discard upload'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (pending != null && !ownPending)
            Card(
              child: ListTile(
                title: const Text(
                  'Another history entry has an unfinished receipt',
                ),
                subtitle: const Text(
                  'Finish or discard that upload before choosing another.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy
                    ? null
                    : () => Navigator.pushReplacement(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => HistoryReceiptsScreen(
                            controller: widget.controller,
                            recordId: pending!.recordId,
                            store: store,
                          ),
                        ),
                      ),
              ),
            ),
          if (otherPicker) ...[
            const Text(
              'Another photo selection is unfinished on this device. Recover it from its original page, or explicitly discard that selection.',
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      if (!await confirm(
                        'Discard the other photo selection?',
                        'This clears the unfinished device selection so you can choose a receipt. It does not delete a saved server photo.',
                        'Discard selection',
                      )) {
                        return;
                      }
                      await capture.discardOther(
                        customerId: owner,
                        estimateId: widget.recordId,
                        targetKind: 'receipt',
                        isCurrent: () => current,
                      );
                      if (current) setState(() => otherPicker = false);
                    }),
              child: const Text('Discard other selection'),
            ),
          ],
          if (corrupt)
            TextButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      if (!await confirm(
                        'Discard unreadable upload?',
                        'The incomplete local attachment cannot be recovered. Saved server receipts remain available.',
                        'Discard unreadable upload',
                      )) {
                        return;
                      }
                      await store.discardCorrupt(owner);
                      if (current) setState(() => corrupt = false);
                    }),
              child: const Text('Discard unreadable upload'),
            ),
          if (!addingHistory) controls,
          const SectionHeading('Saved receipts'),
          if (!loading && receipts.isEmpty)
            const EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'Ready for your receipts',
              message:
                  'Add a photo or PDF of past repair, maintenance or modification work.',
            ),
          for (final receipt in receipts)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      textOf(receipt, 'filename'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${(intOf(receipt, 'byte_size') / 1024).ceil()} KB · Saved privately',
                    ),
                    totalDetails(receipt),
                    Wrap(
                      spacing: 10,
                      children: [
                        TextButton.icon(
                          onPressed: busy ? null : () => view(receipt),
                          icon: const Icon(Icons.visibility_outlined),
                          label: const Text('View receipt'),
                        ),
                        TextButton.icon(
                          onPressed: busy ? null : () => remove(receipt),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Receipts document your records. A recorded cost is not a verified purchase or an increase in resale value.',
          ),
        ],
      ),
    );
  }
}

class PrivateReceiptView extends StatefulWidget {
  const PrivateReceiptView({
    super.key,
    required this.controller,
    required this.ownerId,
    required this.filename,
    required this.bytes,
    required this.mimeType,
  });
  final PlusController controller;
  final String ownerId, filename, mimeType;
  final Uint8List bytes;
  @override
  State<PrivateReceiptView> createState() => _PrivateReceiptViewState();
}

class _PrivateReceiptViewState extends State<PrivateReceiptView> {
  late final PlusController boundController;
  late final String boundOwner;
  late final Uint8List boundBytes;
  bool get current =>
      identical(widget.controller, boundController) &&
      widget.ownerId == boundOwner &&
      identical(widget.bytes, boundBytes) &&
      boundController.isCurrentCustomer(boundOwner);
  PdfControllerPinch? pdf;
  ReceiptPdfDocument? opened;
  bool released = false;
  @override
  void initState() {
    super.initState();
    boundController = widget.controller;
    boundOwner = widget.ownerId;
    boundBytes = widget.bytes;
    boundController.addListener(changed);
    if (widget.mimeType == 'application/pdf') {
      pdf = PdfControllerPinch(document: openPdf());
    }
  }

  bool get allowed => mounted && !released && current;
  Future<PdfDocument> openPdf() async {
    final doc = await openPrivateReceiptPdf(
      boundBytes,
      isCurrent: () => allowed,
    );
    if (!allowed) {
      await doc.close();
      throw const PlusApiException('Sign in again to view your receipt.', 401);
    }
    opened = doc;
    return doc.document;
  }

  void release() {
    if (released) return;
    released = true;
    final doc = opened;
    opened = null;
    doc?.close().catchError((Object _) {});
  }

  void changed() {
    if (!current) release();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant PrivateReceiptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!current) release();
  }

  @override
  void dispose() {
    release();
    boundController.removeListener(changed);
    pdf?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!current) {
      return const UnavailableRecordScreen(
        title: 'Receipt',
        message: 'Sign in again to view your receipt.',
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.filename)),
      body: pdf != null
          ? PdfViewPinch(
              controller: pdf!,
              builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
                options: const DefaultBuilderOptions(),
                documentLoaderBuilder: (_) =>
                    const Center(child: CircularProgressIndicator()),
                errorBuilder: (_, error) => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'This PDF could not be displayed. It may be encrypted or damaged. Your saved receipt is unchanged.',
                    ),
                  ),
                ),
              ),
            )
          : InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Center(
                child: Image.memory(
                  widget.bytes,
                  semanticLabel: 'Receipt photo',
                  errorBuilder: (_, error, stack) =>
                      const Text('This receipt photo could not be displayed.'),
                ),
              ),
            ),
    );
  }
}
