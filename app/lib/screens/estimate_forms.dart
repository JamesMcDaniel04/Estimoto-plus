import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../services/estimate_capture.dart';
import '../services/estimate_capture_steps.dart';
import '../widgets/estimate_capture_guide.dart';
import '../widgets/estimate_submission_review.dart';
import 'garage_forms.dart';
import 'guided_capture_screen.dart';
import '../widgets/workspace_widgets.dart';

Future<void> newEstimate(
  BuildContext context,
  PlusController controller,
) async {
  if (controller.selectedVehicle == null) {
    showMessage(context, 'Add a vehicle in your garage first.');
    controller.selectTab(0);
    return;
  }
  final owner = controller.snapshot!.profile.id;
  final id = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EstimateForm(controller: controller),
  );
  if (id != null && context.mounted && controller.isCurrentCustomer(owner)) {
    controller.selectTab(1);
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            EstimateDetailScreen(controller: controller, estimateId: id),
      ),
    );
  }
}

/// Opens the shared estimate form prefilled for an unshared draft.
Future<void> editEstimate(
  BuildContext context,
  PlusController controller,
  CustomerEstimate estimate,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _EstimateForm(controller: controller, estimate: estimate),
);

class _EstimateForm extends StatefulWidget {
  const _EstimateForm({required this.controller, this.estimate});
  final PlusController controller;
  final CustomerEstimate? estimate;
  @override
  State<_EstimateForm> createState() => _EstimateFormState();
}

class _EstimateFormState extends WorkspaceState<_EstimateForm> {
  @override
  PlusController get controller => widget.controller;
  final description = TextEditingController();
  final claim = TextEditingController();
  DateTime? lossDate;
  late String discipline;
  bool get editing => widget.estimate != null;
  @override
  void initState() {
    super.initState();
    final e = widget.estimate;
    discipline = e?.discipline ?? widget.controller.discipline;
    if (e != null) {
      description.text = e.description;
      claim.text = textOf(e.json, 'claim_number');
      final loss = textOf(e.json, 'date_of_loss');
      if (loss.isNotEmpty) lossDate = DateTime.tryParse(loss);
    }
  }

  @override
  void dispose() {
    description.dispose();
    claim.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!active || busy || (!editing && controller.selectedVehicle == null)) {
      return;
    }
    if (description.text.trim().length < 5) {
      setState(() => error = 'Describe the damage in a few words.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final Json result;
      if (editing) {
        result = await widget.controller.repository
            .updateEstimate(widget.estimate!.id, {
              'description': description.text.trim(),
              'claim_number': claim.text.trim(),
              'date_of_loss': lossDate?.toIso8601String().substring(0, 10),
            });
      } else {
        result = await widget.controller.repository.createEstimate({
          'vehicle_id': widget.controller.selectedVehicle!.id,
          'discipline': discipline,
          'description': description.text.trim(),
          'claim_number': claim.text.trim(),
          'date_of_loss': lossDate?.toIso8601String().substring(0, 10),
        });
      }
      if (!active) return;
      if (!editing) widget.controller.selectDiscipline(discipline);
      await widget.controller.refresh();
      if (active && mounted) Navigator.pop(context, result['id'] as String);
    } catch (e) {
      if (active) {
        setState(() {
          error = PlusController.readableError(e);
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => !current
      ? unavailable
      : FormSheet(
          title: editing ? 'Edit estimate details' : 'Start an estimate',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!editing) ...[
                VehiclePicker(controller: widget.controller),
                const SizedBox(height: 20),
              ],
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'pdr',
                      label: Text('PDR'),
                      icon: Icon(Icons.auto_fix_high_outlined),
                    ),
                    ButtonSegment(
                      value: 'collision',
                      label: Text('Collision'),
                      icon: Icon(Icons.car_crash_outlined),
                    ),
                  ],
                  selected: {discipline},
                  onSelectionChanged: busy || editing
                      ? null
                      : (v) => setState(() => discipline = v.first),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                discipline == 'pdr'
                    ? 'Door dings, small dents or hail damage.'
                    : 'Body damage, paint repairs or accident damage.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 18),
              TextField(
                controller: description,
                maxLines: 3,
                maxLength: 2000,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Describe the damage',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: claim,
                enabled: !busy,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: 'Claim number (if you have one)',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: lossDate ?? DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now(),
                        );
                        if (date != null && mounted) {
                          setState(() => lossDate = date);
                        }
                      },
                icon: const Icon(Icons.event_outlined),
                label: Text(
                  lossDate == null
                      ? 'Date of damage (optional)'
                      : dateText(lossDate!.toIso8601String()),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                editing
                    ? 'Your saved photos stay attached. Changes apply only while this draft is unshared.'
                    : 'Your saved vehicle and insurance details stay in your garage. Next, add photos to this draft.',
              ),
              const SizedBox(height: 20),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              BusyButton(
                busy: busy,
                label: editing ? 'Save changes' : 'Save draft & add photos',
                icon: editing ? Icons.check : Icons.add_a_photo_outlined,
                onPressed: save,
              ),
            ],
          ),
        );
}

class EstimateDetailScreen extends StatefulWidget {
  const EstimateDetailScreen({
    super.key,
    required this.controller,
    required this.estimateId,
    this.captureService,
    this.guidedCaptureBuilder,
  });
  final PlusController controller;
  final String estimateId;
  final EstimateCaptureService? captureService;
  final WidgetBuilder? guidedCaptureBuilder;
  @override
  State<EstimateDetailScreen> createState() => _EstimateDetailScreenState();
}

class _EstimateDetailScreenState extends WorkspaceState<EstimateDetailScreen> {
  @override
  PlusController get controller => widget.controller;
  bool uploading = false;

  bool _editable(CustomerEstimate estimate) =>
      estimate.status == 'draft' &&
      textOf(estimate.json, 'delivery_status', 'draft') == 'draft';

  Future<void> _delete(CustomerEstimate estimate) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this draft?'),
        content: const Text(
          'Its saved photos are removed too. Nothing has been sent to a shop.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !active || !mounted) return;
    final navigator = Navigator.of(context);
    var deleted = false;
    await perform(() async {
      await widget.controller.repository.deleteEstimate(estimate.id);
      deleted = true;
      await widget.controller.refresh();
    });
    if (deleted && active && mounted && navigator.canPop()) navigator.pop();
  }

  Future<void> _removePhoto(CustomerEstimate estimate, String photoId) =>
      perform(() async {
        await widget.controller.repository.deletePhoto(estimate.id, photoId);
        await widget.controller.refresh();
      });
  Future<void> _review(CustomerEstimate estimate) async {
    if (!active) return;
    final edit = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => EstimateSubmissionReview(
        controller: widget.controller,
        estimate: estimate,
        onEditProfile: () => Navigator.pop(sheetContext, true),
      ),
    );
    if (edit == true && active && mounted) {
      final navigator = Navigator.of(context);
      widget.controller.selectTab(0);
      navigator.pop();
      await editProfile(navigator.context, widget.controller);
    }
  }

  @override
  Widget build(BuildContext context) => !current
      ? unavailable
      : ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final snapshot = widget.controller.snapshot;
            final estimate = snapshot?.estimates
                .where((e) => e.id == widget.estimateId)
                .firstOrNull;
            final pending = widget.controller.pendingEstimate(
              widget.estimateId,
            );
            return Scaffold(
              appBar: AppBar(
                title: const Text('Your estimate'),
                actions: [
                  IconButton(
                    tooltip: 'Refresh estimate',
                    onPressed: widget.controller.loading
                        ? null
                        : () => widget.controller.refresh(),
                    icon: const Icon(Icons.refresh),
                  ),
                  if (estimate != null)
                    PopupMenuButton<String>(
                      tooltip: 'Estimate options',
                      itemBuilder: (_) => _editable(estimate)
                          ? const [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Edit details'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete draft'),
                              ),
                            ]
                          : const [
                              PopupMenuItem(
                                enabled: false,
                                value: 'locked',
                                child: Text(
                                  'This estimate has been shared and can no longer be changed.',
                                ),
                              ),
                            ],
                      onSelected: (value) => value == 'edit'
                          ? editEstimate(context, widget.controller, estimate)
                          : value == 'delete'
                          ? _delete(estimate)
                          : null,
                    ),
                ],
              ),
              body: estimate == null || snapshot == null
                  ? const Center(
                      child: Text('This estimate is no longer available.'),
                    )
                  : PageBody(
                      children: [
                        if (widget.controller.isDemo)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: StatusPill('Demo · sample data'),
                          ),
                        PageHeading(
                          specialtyLabel(estimate.discipline),
                          snapshot.vehicle(estimate.vehicleId)?.title ??
                              'Your vehicle',
                        ),
                        StatusPill(estimate.statusLabel),
                        const SizedBox(height: 20),
                        Text(
                          estimate.description,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (estimate.amountCents != null) ...[
                          const SizedBox(height: 20),
                          Text(
                            moneyText(estimate.amountCents!),
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          Text(
                            widget.controller.isDemo
                                ? 'Example amount for this demo'
                                : estimate.providerName,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (estimate.status == 'draft') ...[
                          const SizedBox(height: 20),
                          const Card(
                            child: Padding(
                              padding: EdgeInsets.all(18),
                              child: Text(
                                'This is a saved draft. A price will appear after your photos and damage are reviewed.',
                              ),
                            ),
                          ),
                          EstimateCaptureGuide(
                            key: ValueKey(
                              '${snapshot.profile.id}/${estimate.id}',
                            ),
                            controller: widget.controller,
                            estimate: estimate,
                            captureService: widget.captureService,
                            recoveryOnly: !widget.controller.isDemo,
                            onBusyChanged: (value) {
                              if (mounted) setState(() => uploading = value);
                            },
                          ),
                          const SizedBox(height: 16),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.view_in_ar_outlined,
                                    color: context.plus.success,
                                    size: 36,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    'Your vehicle, step by step',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'Follow the 3D vehicle guide for clear angles, your driver-door VIN label and damage photos. Ask the capture helper whenever you need a hand.',
                                  ),
                                  const SizedBox(height: 18),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      key: const Key('open-guided-capture'),
                                      onPressed: uploading
                                          ? null
                                          : () async {
                                              if (!active) return;
                                              await Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder:
                                                      widget
                                                          .guidedCaptureBuilder ??
                                                      (
                                                        _,
                                                      ) => GuidedCaptureScreen(
                                                        controller: controller,
                                                        estimateId: estimate.id,
                                                      ),
                                                ),
                                              );
                                              if (active) {
                                                await controller.refresh();
                                              }
                                            },
                                      icon: const Icon(
                                        Icons.camera_alt_outlined,
                                      ),
                                      label: Text(
                                        estimate.photos.isEmpty
                                            ? 'Start guided photos'
                                            : 'Continue guided photos',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          EstimatePhotoGallery(
                            controller: controller,
                            estimate: estimate,
                            editable: _editable(estimate),
                            onDelete: (photoId) =>
                                _removePhoto(estimate, photoId),
                          ),
                          const SizedBox(height: 26),
                          if (!estimatePhotosReady(snapshot, estimate))
                            Text(
                              'Complete the guided photos, then choose a shop and review what to share.',
                            ),
                          if (!snapshot.capabilities.liveEstimates)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text(
                                'Your draft is saved. Submission is currently unavailable.',
                              ),
                            ),
                          const SizedBox(height: 12),
                          BusyButton(
                            key: const Key('estimate-review'),
                            busy: uploading,
                            label: pending != null
                                ? 'Check saved submission'
                                : 'Choose shop & review sharing',
                            onPressed: uploading
                                ? null
                                : () => _review(estimate),
                          ),
                        ] else ...[
                          const SizedBox(height: 20),
                          EstimateProgress(estimate: estimate),
                          EstimatePhotoGallery(
                            controller: widget.controller,
                            estimate: estimate,
                          ),
                          if (pending != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 20),
                              child: FilledButton(
                                onPressed: () => _review(estimate),
                                child: const Text('Check saved submission'),
                              ),
                            ),
                        ],
                        if (widget.controller.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              widget.controller.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
            );
          },
        );
}
