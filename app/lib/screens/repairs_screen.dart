import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'request_sheet.dart';
import '../widgets/history_cost_summary.dart';
import '../services/calendar_time.dart';
import '../widgets/calendar_booking_details.dart';
import '../widgets/shop_profile.dart';
import '../widgets/vehicle_scope_filter.dart';
import '../widgets/workspace_widgets.dart';

class RepairsScreen extends StatefulWidget {
  const RepairsScreen({super.key, required this.controller});
  final PlusController controller;
  @override
  State<RepairsScreen> createState() => _RepairsScreenState();
}

enum _Activity { all, repairs, requests }

class _RepairsScreenState extends WorkspaceState<RepairsScreen> {
  @override
  PlusController get controller => widget.controller;
  final search = TextEditingController();
  final cancelling = <String>{};
  String? vehicleId;
  _Activity activity = _Activity.all;

  @override
  void changed() {
    if (current &&
        vehicleId != null &&
        controller.snapshot!.vehicle(vehicleId!) == null) {
      vehicleId = null;
    }
    super.changed();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  bool matchesSearch(Iterable<String> fields) {
    final text = fields.join(' ').toLowerCase();
    return search.text
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .every(text.contains);
  }

  void clearFilters() {
    if (!active) return;
    setState(() {
      search.clear();
      vehicleId = null;
      activity = _Activity.all;
    });
  }

  ProviderProfile? requestProviderProfile(ServiceRequest request) => controller
      .snapshot!
      .providers
      .where(
        (provider) =>
            provider.id == request.providerId && !provider.independent,
      )
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    if (!current) return unavailable;
    final data = controller.snapshot!;
    final scope = data.vehicles.any((vehicle) => vehicle.id == vehicleId)
        ? vehicleId
        : null;
    final repairs =
        data.repairs
            .where(
              (repair) =>
                  activity != _Activity.requests &&
                  (scope == null || repair.vehicleId == scope) &&
                  matchesSearch([
                    repair.title,
                    repair.providerName,
                    repair.status,
                    data.vehicle(repair.vehicleId)?.title ?? '',
                    for (final stage in repair.stages) textOf(stage, 'title'),
                  ]),
            )
            .toList()
          ..sort((a, b) => _compareRecent(a.json, b.json));
    final requests =
        data.requests
            .where(
              (request) =>
                  activity != _Activity.repairs &&
                  (scope == null || request.vehicleId == scope) &&
                  matchesSearch([
                    request.description,
                    requestProviderProfile(request)?.name ?? '',
                    data.vehicle(request.vehicleId)?.title ?? '',
                    specialtyLabel(request.specialty),
                    request.statusLabel,
                    request.deliveryLabel,
                    request.preferredTime,
                  ]),
            )
            .toList()
          ..sort((a, b) => _compareRecent(a.json, b.json));
    final filtered =
        scope != null || activity != _Activity.all || search.text.isNotEmpty;
    final total = data.repairs.length + data.requests.length;
    return PageBody(
      children: [
        const PageHeading(
          'Every step, in view.',
          'Follow your repairs and service requests.',
        ),
        HistoryCostSummary(controller: controller),
        if (controller.pendingRequest != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: EmptyState(
              icon: Icons.sync_problem_outlined,
              title: 'Confirm your last request',
              message:
                  'The response was interrupted. Review the saved request before starting another.',
              action: 'Review saved request',
              onAction: () => requestProvider(
                context,
                controller,
                controller.pendingRequest!.provider,
              ),
            ),
          ),
        if (data.repairs.isEmpty && data.requests.isEmpty)
          EmptyState(
            icon: Icons.build_circle_outlined,
            title: 'Need help with your next repair?',
            message:
                'Connect with a provider to start a request. Updates from participating shops will appear here.',
            action: 'Find help',
            onAction: () => controller.selectTab(4),
          ),
        if (total > 0) ...[
          const SectionHeading('Repair and request activity'),
          VehicleScopeFilter(
            controller: controller,
            value: scope,
            onChanged: (id) {
              if (!active) return;
              setState(() => vehicleId = id);
              if (id != null) controller.selectVehicle(id);
            },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Search repairs and requests',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () => setState(search.clear),
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final choice in _Activity.values)
                ChoiceChip(
                  label: Text(switch (choice) {
                    _Activity.all => 'All activity',
                    _Activity.repairs => 'Repairs',
                    _Activity.requests => 'Service requests',
                  }),
                  selected: activity == choice,
                  onSelected: (_) => setState(() => activity = choice),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Showing ${repairs.length + requests.length} of $total activities',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (filtered)
            TextButton(
              onPressed: clearFilters,
              child: const Text('Clear filters'),
            ),
          const SizedBox(height: 18),
          if (repairs.isEmpty && requests.isEmpty)
            const EmptyState(
              icon: Icons.search_off,
              title: 'No matching activity',
              message:
                  'Try another search, activity type or vehicle, or clear your filters.',
            ),
        ],
        for (final repair in repairs)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.vehicle(repair.vehicleId)?.title ?? 'Your vehicle',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      repair.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      repair.providerName,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 18),
                    StatusPill(repair.status, color: const Color(0xFF08796D)),
                    const SizedBox(height: 24),
                    for (final (index, stage) in repair.stages.indexed)
                      _TimelineStep(
                        title: textOf(stage, 'title'),
                        status: textOf(stage, 'status'),
                        date: textOf(stage, 'date'),
                        last: index == repair.stages.length - 1,
                      ),
                    if (repair.estimatedCompletion.isNotEmpty) ...[
                      const Divider(),
                      const SizedBox(height: 16),
                      Text(
                        'Estimated completion: ${dateText(repair.estimatedCompletion)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      'Last updated ${dateText(repair.updatedAt)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (requests.isNotEmpty) ...[
          const SectionHeading('Your service requests'),
          for (final request in requests)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        requestProviderProfile(request)?.name ??
                            'Your provider',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        data.vehicle(request.vehicleId)?.title ??
                            'Your vehicle',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 14),
                      StatusPill(request.statusLabel),
                      const SizedBox(height: 12),
                      Text(request.description),
                      const SizedBox(height: 10),
                      Text(
                        request.deliveryLabel,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (request.preferredTime.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Requested timing: ${request.preferredTime}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      if (request.json['scheduled_at'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Scheduled: ${request.json['calendar_check'] == true ? calendarSlotLabel(textOf(request.json, 'scheduled_at'), textOf(request.json, 'calendar_time_zone')) : appointmentText(textOf(request.json, 'scheduled_at'))}',
                          ),
                        ),
                      CalendarBookingDetails(
                        controller: controller,
                        source: request.json,
                        sourceKind: 'request',
                      ),
                      if (request.events.isNotEmpty)
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text(
                            'Request updates',
                            style: TextStyle(fontSize: 14),
                          ),
                          children: [
                            for (final event in request.events)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(textOf(event, 'message')),
                                subtitle: Text(
                                  dateText(textOf(event, 'created_at')),
                                ),
                              ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      if (requestProviderProfile(request) == null)
                        const Text(
                          'Contact details for this provider are not available right now. Refresh to check again.',
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: () {
                            if (!active) return;
                            final provider = requestProviderProfile(request);
                            if (provider != null) {
                              showShopProfile(
                                context,
                                provider,
                                contactOnly: true,
                              );
                            }
                          },
                          icon: const Icon(Icons.storefront_outlined),
                          label: const Text('View provider & contact options'),
                        ),
                      if (request.canCancel)
                        TextButton(
                          onPressed: cancelling.contains(request.id)
                              ? null
                              : () => _cancel(request),
                          child: const Text('Cancel request'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Future<void> _cancel(ServiceRequest request) async {
    if (!active || !cancelling.add(request.id)) return;
    setState(() {});
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cancel this request?'),
          content: Text(
            controller.isDemo
                ? 'This cancels the request in your demo. No provider will be contacted.'
                : request.status == 'scheduled'
                ? 'Contact your provider to confirm changes to your appointment. Saving a cancellation does not confirm that the provider has received it.'
                : 'You can create a new request whenever you need help. If you already arranged a visit, contact the provider to confirm the change.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep request'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cancel request'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !active) return;
      final latest = controller.snapshot!.requests
          .where((candidate) => candidate.id == request.id)
          .firstOrNull;
      if (latest == null || !latest.canCancel) {
        showMessage(context, 'This request can no longer be cancelled.');
        return;
      }
      await controller.repository.cancelRequest(request.id);
      if (!active) return;
      await controller.refresh();
      if (mounted && active) showMessage(context, 'Cancellation saved.');
    } catch (error) {
      if (mounted && active) {
        showMessage(context, PlusController.readableError(error));
      }
    } finally {
      if (mounted) setState(() => cancelling.remove(request.id));
    }
  }
}

int _compareRecent(Json left, Json right) {
  DateTime? timestamp(Json row) =>
      DateTime.tryParse(textOf(row, 'updated_at')) ??
      DateTime.tryParse(textOf(row, 'created_at'));
  final a = timestamp(left), b = timestamp(right);
  if (a == null && b != null) return 1;
  if (a != null && b == null) return -1;
  final compared = a == null || b == null ? 0 : b.compareTo(a);
  return compared != 0
      ? compared
      : textOf(left, 'id').compareTo(textOf(right, 'id'));
}

class _TimelineStep extends StatelessWidget {
  const _TimelineStep({
    required this.title,
    required this.status,
    required this.date,
    required this.last,
  });
  final String title, status, date;
  final bool last;
  @override
  Widget build(BuildContext context) {
    final done = status == 'completed';
    final current = status == 'current';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done
                        ? const Color(0xFF08796D)
                        : current
                        ? PlusColors.blue
                        : const Color(0xFFECF0F5),
                  ),
                  child: Icon(
                    done
                        ? Icons.check
                        : current
                        ? Icons.circle
                        : Icons.circle_outlined,
                    size: current ? 10 : 15,
                    color: done || current ? Colors.white : PlusColors.muted,
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: done ? const Color(0xFF8BD2C7) : PlusColors.line,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 2, bottom: last ? 20 : 26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                      color: current || done
                          ? PlusColors.ink
                          : PlusColors.muted,
                    ),
                  ),
                  if (date.isNotEmpty)
                    Text(
                      dateText(date),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
