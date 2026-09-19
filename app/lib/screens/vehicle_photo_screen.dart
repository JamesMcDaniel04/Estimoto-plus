import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../data/repository.dart';
import '../domain/models.dart';
import '../services/estimate_capture.dart';
import '../state/plus_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/vehicle_photo.dart';
import '../widgets/workspace_widgets.dart';

void openVehiclePhoto(
  BuildContext context,
  PlusController controller,
  String id,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VehiclePhotoScreen(controller: controller, vehicleId: id),
    ),
  );
}

class VehiclePhotoScreen extends StatefulWidget {
  const VehiclePhotoScreen({
    super.key,
    required this.controller,
    required this.vehicleId,
    this.captureService,
  });
  final PlusController controller;
  final String vehicleId;
  final EstimateCaptureService? captureService;
  @override
  State<VehiclePhotoScreen> createState() => _VehiclePhotoScreenState();
}

class _VehiclePhotoScreenState extends State<VehiclePhotoScreen> {
  late final String owner;
  late final EstimateCaptureService capture;
  PendingEstimateCapture? pending;
  bool busy = false, otherPending = false;
  String? error;
  int revision = 0;
  Vehicle? get vehicle => widget.controller.snapshot?.vehicle(widget.vehicleId);
  bool get current =>
      mounted && widget.controller.isCurrentCustomer(owner) && vehicle != null;
  @override
  void initState() {
    super.initState();
    owner = widget.controller.snapshot!.profile.id;
    capture =
        widget.captureService ??
        EstimateCaptureService(
          store: widget.controller.isDemo ? MemoryEstimateCaptureStore() : null,
        );
    widget.controller.addListener(changed);
    recover();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    super.dispose();
  }

  Future<void> action(Future<void> Function() work) async {
    if (!current || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
    } catch (e) {
      if (current) setState(() => error = PlusController.readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> recover() => action(() async {
    final result = await capture.recover(
      customerId: owner,
      estimateId: widget.vehicleId,
      targetKind: 'vehicle',
      isCurrent: () => current,
    );
    if (!current) return;
    final saved = await capture.store.read();
    if (current) {
      setState(() {
        pending = result;
        otherPending = saved != null && result == null;
      });
    }
  });

  Future<Json> upload(String id, Uint8List bytes, String filename, String _) {
    if (!current || id != widget.vehicleId) {
      throw const PlusApiException(
        'Your account changed. Reopen your vehicle to continue.',
      );
    }
    return widget.controller.repository.uploadVehicleImage(id, bytes, filename);
  }

  Future<void> pick(ImageSource source) => action(() async {
    try {
      final result = await capture.capture(
        customerId: owner,
        estimateId: widget.vehicleId,
        captureKey: 'vehicle_photo',
        targetKind: 'vehicle',
        source: source,
        isCurrent: () => current,
        upload: upload,
      );
      if (!current) return;
      if (result != null) {
        await widget.controller.refresh(quiet: true);
        if (current) {
          setState(() {
            revision++;
            pending = null;
          });
        }
      }
    } finally {
      final saved = await capture.store.read();
      if (current) {
        setState(() {
          pending =
              saved?.customerId == owner &&
                  saved?.estimateId == widget.vehicleId &&
                  saved?.targetKind == 'vehicle'
              ? saved
              : null;
          otherPending = saved != null && pending == null;
        });
      }
    }
  });

  Future<void> retry() => action(() async {
    if (pending == null) return;
    await capture.retry(
      pending: pending!,
      targetKind: 'vehicle',
      isCurrent: () => current,
      upload: upload,
    );
    if (!current) return;
    await widget.controller.refresh(quiet: true);
    if (current) {
      setState(() {
        pending = null;
        revision++;
      });
    }
  });

  Future<void> remove() => action(() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove your photo?'),
        content: const Text(
          'Your vehicle will use a representative image when one is available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep photo'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove photo'),
          ),
        ],
      ),
    );
    if (yes != true || !current) return;
    await widget.controller.repository.deleteVehicleImage(widget.vehicleId);
    if (!current) return;
    await widget.controller.refresh(quiet: true);
    if (current) setState(() => revision++);
  });

  @override
  Widget build(BuildContext context) {
    if (!current) {
      return UnavailableRecordScreen(
        title: 'Vehicle photo',
        message: widget.controller.isCurrentCustomer(owner)
            ? 'This vehicle is no longer available.'
            : 'Sign in to view this vehicle.',
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle photo')),
      body: PageBody(
        children: [
          PageHeading(vehicle!.title, 'Make your garage feel like yours.'),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: context.plus.navyCard,
              borderRadius: BorderRadius.circular(20),
            ),
            child: VehiclePhotoPanel(
              controller: widget.controller,
              vehicle: vehicle!,
              refreshIndex: revision,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            widget.controller.isDemo
                ? 'Your photo stays in this demo and clears when you leave it.'
                : 'Your uploaded photo stays private in your garage. Representative images may show a different trim or color.',
          ),
          const SizedBox(height: 20),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (busy) const LinearProgressIndicator(),
          if (pending != null) ...[
            const Text('A vehicle photo is waiting to finish uploading.'),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: busy || pending!.localPath == null ? null : retry,
              child: const Text('Retry saved vehicle photo'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      await capture.discard(pending!, () => current);
                      if (current) setState(() => pending = null);
                    }),
              child: const Text('Discard saved photo'),
            ),
          ] else if (otherPending) ...[
            const Text(
              'Finish your other saved photo before opening the camera again.',
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Discard the unfinished photo?'),
                          content: const Text(
                            'It will not be uploaded to its previous destination.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Keep photo'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Discard photo'),
                            ),
                          ],
                        ),
                      );
                      if (yes != true || !current) return;
                      await capture.discardOther(
                        customerId: owner,
                        estimateId: widget.vehicleId,
                        targetKind: 'vehicle',
                        isCurrent: () => current,
                      );
                      if (current) setState(() => otherPending = false);
                    }),
              child: const Text('Discard unfinished photo'),
            ),
          ] else ...[
            FilledButton.icon(
              onPressed: busy ? null : () => pick(ImageSource.camera),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Take a photo'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy ? null : () => pick(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Choose from photos'),
            ),
            if (vehicle!.imageVersion.isNotEmpty)
              TextButton(
                onPressed: busy ? null : remove,
                child: const Text('Remove my photo'),
              ),
          ],
        ],
      ),
    );
  }
}
