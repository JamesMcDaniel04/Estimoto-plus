import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/vehicle_scope_filter.dart';
import '../widgets/workspace_widgets.dart';
import 'estimate_forms.dart';

class EstimatesScreen extends StatefulWidget {
  const EstimatesScreen({super.key, required this.controller});
  final PlusController controller;
  @override
  State<EstimatesScreen> createState() => _EstimatesScreenState();
}

class _EstimatesScreenState extends WorkspaceState<EstimatesScreen> {
  @override
  PlusController get controller => widget.controller;
  final search = TextEditingController();
  String? vehicleId;
  String status = 'all';
  static const statuses = {
    'all': 'All statuses',
    'draft': 'Drafts',
    'progress': 'In progress',
    'ready': 'Ready to review',
    'approved': 'Approved',
    'attention': 'Needs attention',
  };

  @override
  void changed() {
    if (vehicleId != null && controller.snapshot?.vehicle(vehicleId!) == null) {
      vehicleId = null;
    }
    super.changed();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void clearFilters() => setState(() {
    vehicleId = null;
    status = 'all';
    search.clear();
  });

  String category(CustomerEstimate estimate) {
    if (textOf(estimate.json, 'delivery_status') == 'failed' ||
        textOf(estimate.json, 'processing_state') == 'failed') {
      return 'attention';
    }
    return switch (estimate.status) {
      'draft' => 'draft',
      'ready' => 'ready',
      'approved' => 'approved',
      _ => 'progress',
    };
  }

  int newestFirst(CustomerEstimate a, CustomerEstimate b) {
    DateTime? timestamp(CustomerEstimate e) =>
        DateTime.tryParse(textOf(e.json, 'updated_at')) ??
        DateTime.tryParse(textOf(e.json, 'created_at'));
    final first = timestamp(a), second = timestamp(b);
    final compared = first == null
        ? (second == null ? 0 : 1)
        : (second == null ? -1 : second.compareTo(first));
    return compared == 0 ? a.id.compareTo(b.id) : compared;
  }

  @override
  Widget build(BuildContext context) {
    if (!current) return const SizedBox.shrink();
    final data = controller.snapshot!;
    final disciplineEstimates = data.estimates
        .where((e) => e.discipline == controller.discipline)
        .toList();
    final terms = search.text
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty);
    final estimates = disciplineEstimates.where((estimate) {
      if (vehicleId != null && estimate.vehicleId != vehicleId) return false;
      if (status != 'all' && category(estimate) != status) return false;
      final content = [
        estimate.description,
        estimate.providerName,
        data.vehicle(estimate.vehicleId)?.title ?? '',
        textOf(estimate.json, 'claim_number'),
      ].join(' ').toLowerCase();
      return terms.every(content.contains);
    }).toList()..sort(newestFirst);
    final filtered =
        vehicleId != null || status != 'all' || search.text.isNotEmpty;
    return PageBody(
      children: [
        const PageHeading(
          'Know where you stand.',
          'Your estimates, photos and next steps.',
        ),
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
            selected: {controller.discipline},
            onSelectionChanged: (value) =>
                controller.selectDiscipline(value.first),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => newEstimate(context, controller),
            icon: const Icon(Icons.add_a_photo_outlined),
            label: const Text('Start an estimate'),
          ),
        ),
        const SectionHeading('Your estimates'),
        if (data.estimates.isNotEmpty || filtered) ...[
          VehicleScopeFilter(
            controller: controller,
            value: vehicleId,
            onChanged: (id) {
              setState(() => vehicleId = id);
              if (id != null) controller.selectVehicle(id);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: search,
            decoration: InputDecoration(
              labelText: 'Search estimates',
              hintText: 'Vehicle, damage, shop or claim',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear estimate search',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(search.clear),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in statuses.entries)
                ChoiceChip(
                  key: Key('estimate-status-${entry.key}'),
                  label: Text(entry.value),
                  selected: status == entry.key,
                  onSelected: (_) => setState(() => status = entry.key),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Showing ${estimates.length} of ${disciplineEstimates.length} ${controller.discipline == 'pdr' ? 'PDR' : 'collision'} estimates · Latest update first',
          ),
          if (filtered)
            TextButton(
              onPressed: clearFilters,
              child: const Text('Clear filters'),
            ),
          const SizedBox(height: 16),
        ],
        if (estimates.isEmpty && filtered)
          const EmptyState(
            icon: Icons.search_off,
            title: 'No matching estimates',
            message:
                'Try another vehicle, status or search, or clear your filters.',
          )
        else if (estimates.isEmpty)
          const EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'Your next estimate starts here',
            message:
                'Choose your saved vehicle, tell us about the damage and add a few photos.',
          )
        else
          for (final estimate in estimates)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => EstimateDetailScreen(
                        controller: controller,
                        estimateId: estimate.id,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.receipt_long_outlined,
                              color: PlusColors.blue,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                data.vehicle(estimate.vehicleId)?.title ??
                                    'Your vehicle',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              color: PlusColors.muted,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          estimate.description,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            StatusPill(
                              estimate.statusLabel,
                              color: estimate.status == 'approved'
                                  ? const Color(0xFF08796D)
                                  : PlusColors.blue,
                            ),
                            if (category(estimate) == 'attention')
                              const StatusPill(
                                'Needs attention',
                                color: Color(0xFFAF3F24),
                              ),
                            if (estimate.amountCents != null)
                              Text(
                                moneyText(estimate.amountCents!),
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                        if (estimate.providerName.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            estimate.providerName,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
