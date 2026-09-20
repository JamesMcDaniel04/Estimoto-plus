import 'package:flutter/material.dart';
import '../state/plus_controller.dart';

/// List scope is explicit and independent of the garage's default vehicle.
class VehicleScopeFilter extends StatelessWidget {
  const VehicleScopeFilter({
    super.key,
    required this.controller,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final PlusController controller;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final vehicles = controller.snapshot?.vehicles ?? [];
    final selected = vehicles.any((vehicle) => vehicle.id == value)
        ? value!
        : '';
    return SizedBox(
      key: const Key('vehicle-scope-filter'),
      width: double.infinity,
      child: DropdownButtonFormField<String>(
        key: ValueKey('vehicle-scope-$selected'),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Vehicle'),
        items: [
          const DropdownMenuItem(value: '', child: Text('All vehicles')),
          for (final vehicle in vehicles)
            DropdownMenuItem(
              value: vehicle.id,
              child: Text(vehicle.title, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: !enabled
            ? null
            : (id) => onChanged(id == null || id.isEmpty ? null : id),
      ),
    );
  }
}
