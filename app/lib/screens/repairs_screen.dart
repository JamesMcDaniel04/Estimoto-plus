import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'request_sheet.dart';
import '../widgets/history_cost_summary.dart';
import '../services/calendar_time.dart';
import '../widgets/calendar_booking_details.dart';

class RepairsScreen extends StatelessWidget {
  const RepairsScreen({super.key, required this.controller});
  final PlusController controller;
  @override
  Widget build(BuildContext context) {
    final data = controller.snapshot!;
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
        for (final repair in data.repairs)
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
                    StatusPill(repair.status, color: context.plus.success),
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
        if (data.requests.isNotEmpty) ...[
          const SectionHeading('Your service requests'),
          for (final request in data.requests.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.provider(request.providerId)?.name ??
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
                      if (request.canCancel)
                        TextButton(
                          onPressed: () => _cancel(context, request),
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

  Future<void> _cancel(BuildContext context, ServiceRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this request?'),
        content: const Text(
          'You can create a new request whenever you need help.',
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
    if (confirmed == true && context.mounted) {
      await runAction(context, controller, () async {
        await controller.repository.cancelRequest(request.id);
      }, success: 'Request cancelled.');
    }
  }
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
    final palette = context.plus;
    final scheme = Theme.of(context).colorScheme;
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
                        ? palette.success
                        : current
                        ? scheme.primary
                        : palette.soft,
                  ),
                  child: Icon(
                    done
                        ? Icons.check
                        : current
                        ? Icons.circle
                        : Icons.circle_outlined,
                    size: current ? 10 : 15,
                    color: done
                        ? palette.onSuccess
                        : current
                        ? scheme.onPrimary
                        : palette.muted,
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: done ? palette.successLine : palette.line,
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
                      color: current || done ? palette.ink : palette.muted,
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
