import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../domain/models.dart';
import '../services/customer_workspace.dart';
import '../services/estimate_capture.dart';
import '../state/plus_controller.dart';
import '../widgets/common.dart';
import '../widgets/workspace_widgets.dart';
import 'garage_forms.dart';
import 'history_receipts_screen.dart';
import '../services/receipt_pending.dart';
import '../services/receipt_upload.dart';

void openVehicleHistory(BuildContext context, PlusController controller) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HistoryScreen(controller: controller),
    ),
  );
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.controller});
  final PlusController controller;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends WorkspaceState<HistoryScreen> {
  @override
  PlusController get controller => widget.controller;
  List<Json> records = [];
  bool loading = true, loaded = false, share = false, pendingRecord = false;
  bool? uncertainPreference;
  int generation = 0;
  ReceiptPending? pendingReceipt;
  final search = TextEditingController();
  String category = 'All';
  String? filterVehicleId;

  @override
  void initState() {
    super.initState();
    filterVehicleId = controller.selectedVehicle?.id;
    load();
  }

  @override
  void changed() {
    final vehicleId = controller.selectedVehicle?.id;
    if (filterVehicleId != vehicleId) {
      filterVehicleId = vehicleId;
      search.clear();
      category = 'All';
    }
    super.changed();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void clearFilters() {
    setState(() {
      search.clear();
      category = 'All';
    });
  }

  int newestFirst(Json a, Json b) {
    for (final field in ['service_date', 'created_at']) {
      final aDate = DateTime.tryParse(textOf(a, field));
      final bDate = DateTime.tryParse(textOf(b, field));
      final order = aDate == null
          ? (bDate == null ? 0 : 1)
          : (bDate == null ? -1 : bDate.compareTo(aDate));
      if (order != 0) return order;
    }
    return textOf(a, 'id').compareTo(textOf(b, 'id'));
  }

  Future<void> load() async {
    if (!active) return;
    final run = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final values = await Future.wait<Object?>([
        controller.repository.getKnowledge(),
        workspace.pending('history-record'),
        controller.isDemo
            ? Future<ReceiptPending?>.value()
            : createReceiptPendingStore()
                  .read(workspace.customerId)
                  .catchError((Object _) => null),
      ]);
      if (!active || run != generation) return;
      final data = values[0] as Json;
      setState(() {
        loaded = true;
        records = rowsOf(data, 'records');
        share =
            (data['preferences'] as Map?)?['share_aggregate_insights'] == true;
        pendingRecord = values[1] != null;
        pendingReceipt = values[2] as ReceiptPending?;
        uncertainPreference = null;
      });
    } catch (e) {
      if (active && run == generation) {
        setState(() {
          error = PlusController.readableError(e);
        });
      }
    } finally {
      if (active && run == generation) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  Future<void> add() async {
    await Navigator.of(context).push<Json>(
      MaterialPageRoute<Json>(
        builder: (_) => HistoryEditor(controller: controller),
      ),
    );
    if (active) await load();
  }

  Future<void> edit(Json record) async {
    await Navigator.of(context).push<Json>(
      MaterialPageRoute<Json>(
        builder: (_) => HistoryEditor(controller: controller, record: record),
      ),
    );
    if (active) await load();
  }

  Future<void> openReceipts(String id) async {
    if (!active) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            HistoryReceiptsScreen(controller: controller, recordId: id),
      ),
    );
    if (active) await load();
  }

  Future<void> preference(bool selected) async {
    await perform(() async {
      setState(() {
        uncertainPreference = selected;
      });
      final result = await controller.repository.saveKnowledgePreferences({
        'share_aggregate_insights': selected,
      });
      if (active) {
        setState(() {
          share = result['share_aggregate_insights'] == true;
          uncertainPreference = null;
        });
      }
    });
  }

  Future<void> remove(Json record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this history entry?'),
        content: Text(
          '${serviceName(textOf(record, 'service_type'))} on ${dateText(textOf(record, 'service_date'))} will be removed from your personal history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep entry'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete entry'),
          ),
        ],
      ),
    );
    if (confirmed != true || !active) return;
    await perform(() async {
      await controller.repository.deleteKnowledgeRecord(record['id'] as String);
      if (active) {
        controller.historyChanged();
        await load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!current) return unavailable;
    final vehicle = controller.selectedVehicle;
    final vehicleRecords =
        records
            .where((r) => vehicle != null && r['vehicle_id'] == vehicle.id)
            .toList()
          ..sort(newestFirst);
    final terms = search.text
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty);
    final visible = vehicleRecords.where((record) {
      if (category != 'All' &&
          historyCategory(textOf(record, 'service_type')) != category) {
        return false;
      }
      final content = [
        serviceName(textOf(record, 'service_type')),
        textOf(record, 'shop_name'),
        textOf(record, 'parts_source'),
        textOf(record, 'parts_description'),
        textOf(record, 'notes'),
      ].join(' ').toLowerCase();
      return terms.every(content.contains);
    }).toList();
    final filtered = search.text.isNotEmpty || category != 'All';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Service history & receipts'),
        actions: [
          IconButton(
            tooltip: 'Refresh service history',
            onPressed: busy || loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: PageBody(
        children: [
          const PageHeading(
            'The story of your car.',
            'Save past repairs, maintenance and modifications with receipts, costs and parts details. These are your own records.',
          ),
          VehiclePicker(controller: controller),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: busy || loading
                ? null
                : vehicle == null
                ? () => editVehicle(context, controller)
                : add,
            icon: const Icon(Icons.add),
            label: Text(
              vehicle == null
                  ? 'Add a vehicle'
                  : pendingRecord
                  ? 'Recover saved history entry'
                  : 'Add service history',
            ),
          ),
          if (error != null) WorkspaceError(error!),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (pendingReceipt != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('A receipt is waiting to finish'),
                subtitle: const Text(
                  'Review the original entry to retry its saved attachment.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy
                    ? null
                    : () => openReceipts(pendingReceipt!.recordId),
              ),
            ),
          if (vehicleRecords.any((r) => r['cost_cents'] is int)) ...[
            const SectionHeading('Documented costs'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final category in [
                      'Repairs',
                      'Maintenance',
                      'Modifications',
                      'Other',
                    ])
                      ReviewBlock(
                        category,
                        receiptCost(
                          vehicleRecords
                              .where(
                                (r) =>
                                    historyCategory(
                                      textOf(r, 'service_type'),
                                    ) ==
                                    category,
                              )
                              .fold<int>(
                                0,
                                (sum, r) =>
                                    sum +
                                    (r['cost_cents'] is int
                                        ? r['cost_cents'] as int
                                        : 0),
                              ),
                        ),
                      ),
                    const Text(
                      'All records for this vehicle, regardless of filters. Your recorded spending in USD. Costs are not an estimate of resale value.',
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SectionHeading('Your service records'),
          if (vehicleRecords.isNotEmpty) ...[
            TextField(
              controller: search,
              decoration: InputDecoration(
                labelText: 'Search service history',
                hintText: 'Service, shop, parts or notes',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () => setState(search.clear),
                        icon: const Icon(Icons.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in [
                  'All',
                  'Repairs',
                  'Maintenance',
                  'Modifications',
                  'Other',
                ])
                  ChoiceChip(
                    label: Text(option),
                    selected: category == option,
                    onSelected: (_) => setState(() => category = option),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                'Showing ${visible.length} of ${vehicleRecords.length} ${vehicleRecords.length == 1 ? 'record' : 'records'}',
              ),
            ),
            const Text('Newest service first'),
            if (filtered)
              TextButton.icon(
                onPressed: clearFilters,
                icon: const Icon(Icons.filter_alt_off_outlined),
                label: const Text('Clear filters'),
              ),
            const SizedBox(height: 12),
          ],
          if (!loading && vehicleRecords.isEmpty)
            const EmptyState(
              icon: Icons.history_outlined,
              title: 'Start with your last service',
              message:
                  'Save its date, mileage, shop and any parts details you want to remember.',
            ),
          if (!loading && vehicleRecords.isNotEmpty && visible.isEmpty)
            const EmptyState(
              icon: Icons.search_off,
              title: 'No matching service records',
              message:
                  'Try another search or clear your filters to see this vehicle’s history.',
            ),
          for (final record in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              serviceName(textOf(record, 'service_type')),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Edit history entry',
                            onPressed: busy ? null : () => edit(record),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: 'Delete history entry',
                            onPressed: busy ? null : () => remove(record),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      Text(dateText(textOf(record, 'service_date'))),
                      if (record['mileage'] != null)
                        Text('${mileageText(intOf(record, 'mileage'))} miles'),
                      const SizedBox(height: 12),
                      if (textOf(record, 'shop_name').isNotEmpty)
                        ReviewBlock('Shop', textOf(record, 'shop_name')),
                      if (textOf(record, 'parts_source').isNotEmpty)
                        ReviewBlock(
                          'Parts source',
                          textOf(record, 'parts_source'),
                        ),
                      if (textOf(record, 'parts_description').isNotEmpty)
                        ReviewBlock(
                          'Parts',
                          textOf(record, 'parts_description'),
                        ),
                      if (textOf(record, 'notes').isNotEmpty)
                        ReviewBlock('Your notes', textOf(record, 'notes')),
                      if (record['cost_cents'] is int)
                        ReviewBlock(
                          'Recorded total (USD)',
                          receiptCost(record['cost_cents'] as int),
                        ),
                      const StatusPill('Added by you'),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => openReceipts(textOf(record, 'id')),
                        icon: const Icon(Icons.receipt_long_outlined),
                        label: Text(
                          'Receipts (${rowsOf(record, 'receipts').length}) · View or add',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SectionHeading('Your choice about insights'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!loaded)
                    const Text(
                      'Refresh to load your saved insights-sharing choice.',
                    ),
                  if (loaded)
                    SwitchListTile(
                      key: const Key('insights-consent'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Help improve repair insights'),
                      value: share,
                      onChanged: loading || busy || uncertainPreference != null
                          ? null
                          : preference,
                    ),
                  const Text(
                    'Optionally share grouped service needs, requests and parts-source trends. Contact details, VIN, insurance and free-text notes are excluded. You can turn this off at any time; your personal history will still work.',
                  ),
                  if (uncertainPreference != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Your change to turn insights sharing ${uncertainPreference! ? 'on' : 'off'} has not been confirmed. Retry or refresh to check the saved setting.',
                    ),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => preference(uncertainPreference!),
                      child: const Text('Retry preference change'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HistoryEditor extends StatefulWidget {
  const HistoryEditor({
    super.key,
    required this.controller,
    this.record,
    this.receiptStore,
    this.captureService,
    this.pdfPicker,
  });
  final PlusController controller;

  /// When set, the editor changes this saved entry instead of creating one.
  final Json? record;
  final ReceiptPendingStore? receiptStore;
  final EstimateCaptureService? captureService;
  final Future<XFile?> Function()? pdfPicker;
  @override
  State<HistoryEditor> createState() => _HistoryEditorState();
}

class _HistoryEditorState extends WorkspaceState<HistoryEditor> {
  @override
  PlusController get controller => widget.controller;
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  String? vehicleId;
  String type = 'maintenance';
  DateTime date = DateTime.now();
  PendingWorkspaceWrite? pending;
  Json? savedRecord;
  ReceiptChoice? receiptChoice;
  bool restoring = true;
  @override
  void initState() {
    super.initState();
    for (final key in [
      'mileage',
      'cost_cents',
      'shop_name',
      'parts_source',
      'parts_description',
      'notes',
    ]) {
      fields[key] = TextEditingController();
    }
    vehicleId = controller.selectedVehicle?.id;
    final record = widget.record;
    if (record != null) {
      vehicleId = textOf(record, 'vehicle_id');
      type = textOf(record, 'service_type', 'maintenance');
      date =
          DateTime.tryParse(textOf(record, 'service_date')) ?? DateTime.now();
      for (final entry in fields.entries) {
        final value = record[entry.key];
        entry.value.text = entry.key == 'cost_cents' && value is int
            ? receiptCost(value).substring(1).replaceAll(',', '')
            : value?.toString() ?? '';
      }
      restoring = false;
      return;
    }
    restore();
  }

  bool get editing => widget.record != null;
  int get attachedReceipts =>
      widget.record == null ? 0 : rowsOf(widget.record!, 'receipts').length;

  Future<void> restore() async {
    try {
      final saved = await workspace.pending('history-record');
      if (!active) return;
      setState(() {
        pending = saved;
        if (saved != null) {
          vehicleId = saved.body['vehicle_id'] as String?;
          type = textOf(saved.body, 'service_type');
          date = DateTime.parse(textOf(saved.body, 'service_date'));
          for (final entry in fields.entries) {
            entry.value.text =
                entry.key == 'cost_cents' && saved.body[entry.key] is int
                ? receiptCost(
                    saved.body[entry.key] as int,
                  ).substring(1).replaceAll(',', '')
                : saved.body[entry.key]?.toString() ?? '';
          }
        }
        restoring = false;
      });
    } catch (e) {
      if (active) {
        setState(() {
          error = PlusController.readableError(e);
        });
      }
    }
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> pickDate() async {
    final result = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
    );
    if (result != null && active) {
      setState(() {
        date = result;
      });
    }
  }

  Future<void> save({ReceiptChoice? attach}) async {
    if (restoring || (pending == null && !form.currentState!.validate())) {
      return;
    }
    await perform(() async {
      final body =
          pending?.body ??
          <String, dynamic>{
            'vehicle_id': vehicleId,
            'service_type': type,
            'service_date':
                '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
            for (final entry in fields.entries)
              entry.key: entry.key == 'mileage'
                  ? int.tryParse(entry.value.text.trim())
                  : entry.key == 'cost_cents'
                  ? parseReceiptCost(entry.value.text)
                  : entry.value.text.trim(),
          };
      if (editing) {
        final changes = Map<String, dynamic>.from(body)..remove('vehicle_id');
        final result = await workspace.updateHistory(
          textOf(widget.record!, 'id'),
          changes,
        );
        if (mounted && active) {
          controller.historyChanged();
          if (attach == null) {
            Navigator.pop(context, result);
          } else {
            setState(() {
              savedRecord = result;
              receiptChoice = attach;
            });
          }
        }
        return;
      }
      try {
        final result = await workspace.addHistory(body);
        if (mounted && active) {
          controller.historyChanged();
          setState(() {
            savedRecord = result;
            receiptChoice = attach;
          });
        }
      } catch (_) {
        if (active) {
          final saved = await workspace.pending('history-record');
          if (active) {
            setState(() {
              pending = saved;
            });
          }
        }
        rethrow;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!current) return unavailable;
    if (savedRecord != null) {
      return HistoryReceiptsScreen(
        key: ValueKey('saved-history-${textOf(savedRecord!, 'id')}'),
        controller: controller,
        recordId: textOf(savedRecord!, 'id'),
        store: widget.receiptStore,
        captureService: widget.captureService,
        pdfPicker: widget.pdfPicker,
        initialChoice: receiptChoice,
        onDone: () => Navigator.pop(context, savedRecord),
      );
    }
    final locked = busy || restoring || pending != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit service history' : 'Add service history'),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (editing && attachedReceipts > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '$attachedReceipts receipt${attachedReceipts == 1 ? '' : 's'} stays attached to this entry.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              BusyButton(
                busy: busy,
                label: editing
                    ? 'Save changes'
                    : pending != null
                    ? 'Recover saved entry'
                    : 'Save history entry',
                onPressed: restoring ? null : () => save(),
              ),
            ],
          ),
        ),
      ),
      body: PageBody(
        children: [
          const PageHeading(
            'Remember the details.',
            'Save work that has already happened. Leave unknown details blank.',
          ),
          if (pending != null)
            const Padding(
              padding: EdgeInsets.only(bottom: 18),
              child: Text(
                'This entry may already be saved. Retry its original details to recover the result without adding a duplicate.',
              ),
            ),
          if (restoring && error == null) const CircularProgressIndicator(),
          if (restoring && error != null)
            OutlinedButton(
              onPressed: restore,
              child: const Text('Retry history recovery'),
            ),
          Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeading('Attach a receipt (optional)'),
                const Text(
                  'Choosing a photo or PDF saves the details in this form first, then attaches your receipt to that saved entry. You can cancel the picker and add it later.',
                ),
                const SizedBox(height: 12),
                ReceiptPickerButtons(
                  onSelected: busy || restoring
                      ? null
                      : (choice) => save(attach: choice),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Photos or PDFs · Up to 10 MB each · Private to you',
                ),
                const SectionHeading('Service details'),
                if (pending != null || editing)
                  ReviewBlock(
                    'Saved vehicle',
                    controller.snapshot!.vehicle(vehicleId ?? '')?.title ??
                        'Previously selected vehicle',
                  )
                else
                  SavedVehicleField(
                    controller: controller,
                    value: vehicleId,
                    enabled: !locked,
                    onChanged: (value) => setState(() {
                      vehicleId = value;
                    }),
                  ),
                if (editing)
                  const Text('This entry stays with its original vehicle.'),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  key: ValueKey('history-type-$type'),
                  initialValue: type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Service type'),
                  items: [
                    for (final key in [
                      'oil_change',
                      'tires',
                      'brakes',
                      'battery',
                      'maintenance',
                      'repair',
                      'modification',
                      'diagnostics',
                      'collision',
                      'pdr',
                      'other',
                    ])
                      DropdownMenuItem(
                        value: key,
                        child: Text(serviceName(key)),
                      ),
                  ],
                  onChanged: locked
                      ? null
                      : (value) => setState(() {
                          type = value!;
                        }),
                ),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: locked ? null : pickDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    'Service date: ${dateText(date.toIso8601String())}',
                  ),
                ),
                const SizedBox(height: 18),
                for (final key in fields.keys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: TextFormField(
                      key: ValueKey('history-$key'),
                      controller: fields[key],
                      enabled: !locked,
                      maxLength: key == 'notes'
                          ? 1000
                          : key == 'mileage'
                          ? 7
                          : 200,
                      maxLines: key == 'notes' ? 4 : 1,
                      keyboardType: key == 'mileage'
                          ? TextInputType.number
                          : key == 'cost_cents'
                          ? const TextInputType.numberWithOptions(decimal: true)
                          : TextInputType.text,
                      decoration: InputDecoration(
                        labelText: const {
                          'mileage': 'Mileage (optional)',
                          'cost_cents': 'Total cost in USD (optional)',
                          'shop_name': 'Shop or DIY (optional)',
                          'parts_source':
                              'Where the parts came from (optional)',
                          'parts_description': 'Parts used (optional)',
                          'notes': 'Notes (optional)',
                        }[key],
                        counterText: '',
                      ),
                      validator: (value) {
                        if (key == 'cost_cents') {
                          try {
                            parseReceiptCost(value ?? '');
                          } on FormatException {
                            return 'Enter USD 0–1,000,000 with up to two decimal places.';
                          }
                        }
                        return key == 'mileage' &&
                                value!.trim().isNotEmpty &&
                                (int.tryParse(value.trim()) == null ||
                                    int.parse(value.trim()) < 0)
                            ? 'Enter mileage as a whole number.'
                            : null;
                      },
                    ),
                  ),
                if (error != null) WorkspaceError(error!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
