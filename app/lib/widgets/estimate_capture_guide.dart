import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../domain/models.dart';
import '../services/estimate_capture.dart';
import '../services/estimate_capture_steps.dart';
import '../state/plus_controller.dart';
import '../theme.dart';
import 'common.dart';
import 'private_estimate_photo.dart';

class EstimateCaptureGuide extends StatefulWidget {
  const EstimateCaptureGuide({
    super.key,
    required this.controller,
    required this.estimate,
    this.captureService,
    this.recoveryOnly = false,
    this.onBusyChanged,
  });
  final PlusController controller;
  final CustomerEstimate estimate;
  final EstimateCaptureService? captureService;
  final bool recoveryOnly;
  final ValueChanged<bool>? onBusyChanged;
  @override
  State<EstimateCaptureGuide> createState() => _EstimateCaptureGuideState();
}

class _EstimateCaptureGuideState extends State<EstimateCaptureGuide> {
  late final EstimateCaptureService service;
  late final String customerId;
  String? selectedKey, panel, error, notice;
  PendingEstimateCapture? pending;
  bool otherPending = false;
  bool busy = false;
  final guideKey = GlobalKey();
  void _showGuide() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && guideKey.currentContext != null) {
        Scrollable.ensureVisible(
          guideKey.currentContext!,
          duration: const Duration(milliseconds: 180),
        );
      }
    });
  }

  bool get current =>
      widget.controller.isCurrentCustomer(customerId) &&
      widget.controller.snapshot!.estimates.any(
        (e) => e.id == widget.estimate.id && e.status == 'draft',
      );
  @override
  void initState() {
    super.initState();
    customerId = widget.controller.snapshot!.profile.id;
    service =
        widget.captureService ??
        EstimateCaptureService(
          store: widget.controller.isDemo ? MemoryEstimateCaptureStore() : null,
        );
    _recover();
  }

  Future<void> _recover() async {
    try {
      final recovered = await service.recover(
        customerId: customerId,
        estimateId: widget.estimate.id,
        isCurrent: () => current,
      );
      final saved = await service.store.read();
      if (mounted && current) {
        setState(() {
          pending = recovered;
          otherPending =
              saved != null &&
              (saved.customerId != customerId ||
                  saved.estimateId != widget.estimate.id);
        });
      }
    } catch (e) {
      // Camera permission errors and interrupted iOS pickers can leave a
      // scoped intent without a recoverable file. Keep a visible retake path.
      PendingEstimateCapture? unfinished;
      try {
        final saved = await service.store.read();
        if (saved?.customerId == customerId &&
            saved?.estimateId == widget.estimate.id) {
          unfinished = saved;
        }
      } catch (_) {}
      if (mounted && current) {
        setState(() {
          pending = unfinished;
          error =
              'We could not finish recovering this photo. ${PlusController.readableError(e)}';
        });
      }
    }
  }

  Future<void> _discardOther() async {
    widget.onBusyChanged?.call(true);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await service.discardOther(
        customerId: customerId,
        estimateId: widget.estimate.id,
        isCurrent: () => current,
      );
      if (mounted && current) setState(() => otherPending = false);
    } catch (e) {
      if (mounted && current) {
        setState(() => error = PlusController.readableError(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _capture(String key, ImageSource source) async {
    widget.onBusyChanged?.call(true);
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await service.capture(
        customerId: customerId,
        estimateId: widget.estimate.id,
        captureKey: key,
        source: source,
        isCurrent: () => current,
        upload: widget.controller.repository.uploadPhoto,
      );
      if (result != null && current) {
        await widget.controller.refresh();
        if (mounted && current) {
          setState(() {
            selectedKey = null;
            _showGuide();
            notice =
                '${captureLabel(key)} saved. Continue with the next view below.';
          });
        }
      }
    } catch (e) {
      if (mounted && current) {
        setState(() => error = PlusController.readableError(e));
        await _recover();
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _retry() async {
    final saved = pending;
    if (saved == null) return;
    widget.onBusyChanged?.call(true);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await service.retry(
        pending: saved,
        isCurrent: () => current,
        upload: widget.controller.repository.uploadPhoto,
      );
      if (current) await widget.controller.refresh();
      if (mounted && current) {
        setState(() {
          pending = null;
          selectedKey = null;
          notice = '${captureLabel(saved.captureKey)} saved.';
        });
      }
    } catch (e) {
      if (mounted && current) {
        setState(() => error = PlusController.readableError(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _retake() async {
    final saved = pending;
    if (saved == null) return;
    try {
      await service.discard(saved, () => current);
      if (mounted && current) {
        setState(() {
          pending = null;
          selectedKey = saved.captureKey;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && current) {
        setState(() => error = PlusController.readableError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!current) return const SizedBox.shrink();
    if (widget.recoveryOnly &&
        pending == null &&
        !otherPending &&
        error == null) {
      return const SizedBox.shrink();
    }
    final snapshot = widget.controller.snapshot!;
    final keys = estimateRequiredKeys(snapshot);
    final saved = savedCaptureKeys(widget.estimate);
    final missing = missingEstimateViews(snapshot, widget.estimate);
    final damageNeeded =
        widget.estimate.discipline == 'pdr' &&
        !hasDamagePhoto(snapshot, widget.estimate);
    final step = selectedKey ?? missing.firstOrNull;
    final damageMode = step == null || step.startsWith('panel_');
    final captureKey = damageMode
        ? (step ?? (panel == null ? null : 'panel_$panel'))
        : step;
    final ready = missing.isEmpty && !damageNeeded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.recoveryOnly) ...[
          const SectionHeading('Add clear photos'),
          Text(
            '${keys.length - missing.length} of ${keys.length} required vehicle views saved',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: keys.isEmpty
                ? 0
                : (keys.length - missing.length) / keys.length,
          ),
          const SizedBox(height: 12),
          Text(
            widget.estimate.discipline == 'pdr'
                ? 'Add all required vehicle views, then photograph the damaged panel. These photos help the shop review your estimate.'
                : 'Add all required vehicle views. Photos of the damaged panels can help the shop understand the repair.',
          ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(notice!, semanticsLabel: notice),
          ),
        const SizedBox(height: 18),
        if (otherPending)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'An unfinished photo is waiting on this device',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'To start photos for this estimate, discard that unfinished capture. Photos already saved to an estimate will stay saved.',
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      key: const Key('discard-other-capture'),
                      onPressed: busy ? null : _discardOther,
                      child: const Text('Discard unfinished photo'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (pending != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Finish your ${captureLabel(pending!.captureKey).toLowerCase()} photo',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    pending!.localPath == null
                        ? 'The camera did not finish this view. Retake it to continue.'
                        : 'An unfinished photo was recovered for this estimate. Save it, or retake this view if the photo is no longer available.',
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: busy || pending!.localPath == null
                          ? null
                          : _retry,
                      child: const Text('Save recovered photo'),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: busy ? null : _retake,
                      child: const Text('Retake this view'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (!widget.recoveryOnly && pending == null && !otherPending)
          Card(
            key: guideKey,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (ready && selectedKey == null) ...[
                    Icon(
                      Icons.check_circle_outline,
                      color: context.plus.success,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Photos ready for your review',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Choose a shop and review what you will share below. You can also add another damage photo.',
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    damageMode
                        ? (damageNeeded
                              ? 'Next: the damaged panel'
                              : 'Add a damage photo')
                        : 'Next: ${captureLabel(step)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  if (damageMode) ...[
                    DropdownButtonFormField<String>(
                      key: const Key('damage-panel'),
                      initialValue: step?.startsWith('panel_') == true
                          ? step!.substring(6)
                          : panel,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Which panel is damaged?',
                      ),
                      items:
                          estimatePanelTypes(
                                snapshot,
                                widget.estimate.discipline,
                              )
                              .map(
                                (key) => DropdownMenuItem(
                                  value: key,
                                  child: Text(
                                    captureLabel(key),
                                    softWrap: true,
                                  ),
                                ),
                              )
                              .toList(),
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                              panel = value;
                              selectedKey = value == null
                                  ? null
                                  : 'panel_$value';
                            }),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(captureGuidance(captureKey ?? 'panel_')),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('capture-camera'),
                      onPressed: busy || captureKey == null
                          ? null
                          : () => _capture(captureKey, ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: Text(busy ? 'Saving photo…' : 'Take photo'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const Key('capture-gallery'),
                      onPressed: busy || captureKey == null
                          ? null
                          : () => _capture(captureKey, ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Choose existing photo'),
                    ),
                  ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        if (!widget.recoveryOnly) ...[
          for (final key in keys)
            ListTile(
              key: Key('capture-check-$key'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                saved.contains(key)
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: saved.contains(key) ? context.plus.success : null,
              ),
              title: Text(captureLabel(key)),
              subtitle: Text(
                saved.contains(key)
                    ? 'Saved · tap to add another view'
                    : 'Still needed',
              ),
              onTap: busy || pending != null || otherPending
                  ? null
                  : () {
                      setState(() => selectedKey = key);
                      _showGuide();
                    },
            ),
          if (widget.estimate.discipline == 'pdr')
            ListTile(
              key: const Key('capture-check-damage'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                damageNeeded
                    ? Icons.radio_button_unchecked
                    : Icons.check_circle,
                color: damageNeeded ? null : context.plus.success,
              ),
              title: const Text('Damaged panel'),
              subtitle: Text(damageNeeded ? 'Still needed for PDR' : 'Saved'),
            ),
        ],
      ],
    );
  }
}

class EstimatePhotoGallery extends StatelessWidget {
  const EstimatePhotoGallery({
    super.key,
    required this.controller,
    required this.estimate,
    this.editable = false,
    this.onDelete,
  });
  final PlusController controller;
  final CustomerEstimate estimate;
  final bool editable;
  final Future<void> Function(String photoId)? onDelete;

  Future<void> _confirmDelete(BuildContext context, String photoId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this photo?'),
        content: const Text('You can take it again from the guided photos.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onDelete!(photoId);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeading('Saved photos (${estimate.photos.length})'),
      if (estimate.photos.isEmpty)
        const Text('No photos attached yet.')
      else
        Wrap(
          spacing: 12,
          runSpacing: 16,
          children: [
            for (final photo in estimate.photos)
              SizedBox(
                width: 124,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 124,
                        height: 96,
                        child: PrivateEstimatePhoto(
                          key: ValueKey(
                            '${controller.snapshot!.profile.id}/${textOf(photo, 'id')}',
                          ),
                          controller: controller,
                          customerId: controller.snapshot!.profile.id,
                          estimateId: estimate.id,
                          photoId: textOf(photo, 'id'),
                          label: captureLabel(textOf(photo, 'label')),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      captureLabel(textOf(photo, 'label')),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (editable && onDelete != null)
                      IconButton(
                        tooltip: 'Remove photo',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () =>
                            _confirmDelete(context, textOf(photo, 'id')),
                      ),
                  ],
                ),
              ),
          ],
        ),
    ],
  );
}
