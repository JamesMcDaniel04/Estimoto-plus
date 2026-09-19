import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../theme.dart';

/// The photo well sits inside the brand-navy vehicle card in both modes.
const _photoWell = Color(0xFF1A426C);
const _photoWellIcon = Color(0xFFBED9EC);

/// Private image bytes stay scoped to this customer's current vehicle view.
/// Rebuilding a tab or refreshing status never starts another provider lookup.
class VehiclePhotoPanel extends StatefulWidget {
  const VehiclePhotoPanel({
    super.key,
    required this.controller,
    required this.vehicle,
    this.onEdit,
    this.refreshIndex = 0,
  });
  final PlusController controller;
  final Vehicle vehicle;
  final VoidCallback? onEdit;
  final int refreshIndex;
  @override
  State<VehiclePhotoPanel> createState() => _VehiclePhotoPanelState();
}

class _VehiclePhotoPanelState extends State<VehiclePhotoPanel> {
  VehiclePhoto? photo;
  MemoryImage? image;
  bool loading = true;
  String? error;
  int generation = 0;
  String fingerprint(VehiclePhotoPanel value) => jsonEncode([
    value.vehicle.id,
    value.vehicle.year,
    value.vehicle.make,
    value.vehicle.model,
    value.vehicle.imageVersion,
    value.refreshIndex,
  ]);

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant VehiclePhotoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        fingerprint(oldWidget) != fingerprint(widget)) {
      load();
    }
  }

  void clearImage() {
    final previous = image;
    image = null;
    photo = null;
    if (previous != null) unawaited(previous.evict());
  }

  Future<void> load() async {
    final run = ++generation;
    final controller = widget.controller;
    final owner = controller.snapshot?.profile.id;
    final vehicleId = widget.vehicle.id;
    clearImage();
    setState(() {
      loading = true;
      error = null;
    });
    bool current() =>
        mounted &&
        run == generation &&
        owner != null &&
        identical(controller, widget.controller) &&
        controller.isCurrentCustomer(owner) &&
        widget.vehicle.id == vehicleId;
    if (owner == null || !controller.isCurrentCustomer(owner)) {
      if (mounted) setState(() => loading = false);
      return;
    }
    try {
      final result = await controller.repository.getVehicleImage(vehicleId);
      if (!current()) return;
      setState(() {
        photo = result;
        image = result == null ? null : MemoryImage(result.bytes);
      });
    } catch (_) {
      if (current()) {
        setState(() => error = 'Your vehicle photo could not load.');
      }
    } finally {
      if (current()) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    ++generation;
    clearImage();
    super.dispose();
  }

  Widget placeholder(BuildContext context) => ColoredBox(
    color: _photoWell,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.add_photo_alternate_outlined,
              color: _photoWellIcon,
              size: 38,
            ),
            const SizedBox(height: 10),
            Text(
              error ?? 'Add a photo of your car',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.plus.onNavy, fontSize: 14),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: loading
                ? ColoredBox(
                    color: _photoWell,
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.plus.onNavy,
                          semanticsLabel: 'Loading vehicle photo',
                        ),
                      ),
                    ),
                  )
                : image == null
                ? placeholder(context)
                : Image(
                    image: image!,
                    fit: photo!.isUpload ? BoxFit.cover : BoxFit.contain,
                    semanticLabel: '${photo!.label}: ${widget.vehicle.title}',
                    gaplessPlayback: false,
                    errorBuilder: (context, _, _) => placeholder(context),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              photo?.label ?? (loading ? 'Finding a vehicle photo…' : ''),
              style: TextStyle(color: context.plus.onNavyMuted, fontSize: 11),
            ),
            if (error != null)
              IconButton(
                tooltip: 'Retry vehicle photo',
                onPressed: load,
                icon: Icon(Icons.refresh, color: context.plus.onNavy, size: 19),
              ),
            if (widget.onEdit != null)
              TextButton.icon(
                onPressed: widget.onEdit,
                icon: const Icon(Icons.add_a_photo_outlined, size: 16),
                label: Text(
                  photo?.isUpload == true ? 'Change photo' : 'Add your photo',
                  softWrap: true,
                ),
                style: TextButton.styleFrom(
                  foregroundColor: context.plus.onNavy,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
