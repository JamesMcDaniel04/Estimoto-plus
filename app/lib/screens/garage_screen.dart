import 'calendar_screen.dart';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/vehicle_photo.dart';
import 'vehicle_photo_screen.dart';
import 'garage_forms.dart';
import 'estimate_forms.dart';
import 'my_shops_screen.dart';
import 'history_screen.dart';
import 'vehicle_value_screen.dart';
import 'settings_screen.dart';
import '../services/reminder_status.dart';
import '../widgets/workspace_widgets.dart';

class GarageScreen extends StatefulWidget {
  const GarageScreen({super.key, required this.controller, this.onExit});
  final PlusController controller;
  final VoidCallback? onExit;

  @override
  State<GarageScreen> createState() => _GarageScreenState();
}

class _GarageScreenState extends WorkspaceState<GarageScreen> {
  @override
  PlusController get controller => widget.controller;

  Future<void> _setCompleted(ServiceReminder reminder, bool completed) async {
    if (!active || busy) return;
    final saved = controller.snapshot?.reminders
        .where((row) => row.id == reminder.id)
        .firstOrNull;
    if (saved == null || saved.completed == completed) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => busy = true);
    try {
      if (completed) {
        await controller.repository.completeReminder(reminder.id);
      } else {
        await controller.repository.reopenReminder(reminder.id);
      }
      if (!active) return;
      await controller.refresh();
      if (!active) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(completed ? 'Reminder completed' : 'Reminder reopened'),
          duration: const Duration(seconds: 6),
          persist: false,
          action: completed
              ? SnackBarAction(
                  label: 'Undo',
                  onPressed: () => _setCompleted(reminder, false),
                )
              : null,
        ),
      );
    } catch (e) {
      if (active) {
        messenger.showSnackBar(
          SnackBar(content: Text(PlusController.readableError(e))),
        );
      }
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!current) return const SizedBox.shrink();
    final data = controller.snapshot!;
    final vehicle = controller.selectedVehicle;
    final now = DateTime.now();
    final scoped = data.reminders.where(
      (r) => vehicle != null && r.vehicleId == vehicle.id,
    );
    final reminders = sortReminders(
      scoped.where((r) => !r.completed),
      now: now,
      mileage: vehicle?.mileage ?? 0,
    );
    final completed = sortReminders(
      scoped.where((r) => r.completed),
      now: now,
      mileage: vehicle?.mileage ?? 0,
    );
    return PageBody(
      children: [
        PageHeading(
          'Hi, ${data.profile.firstName}.',
          'Your cars. Your care. All together.',
          trailing: IconButton.filledTonal(
            tooltip: 'Your profile',
            onPressed: () =>
                SettingsScreen.open(context, controller, onExit: widget.onExit),
            icon: const Icon(Icons.person_outline),
          ),
        ),
        if (vehicle == null)
          EmptyState(
            icon: Icons.directions_car_outlined,
            title: 'Make room for your first car',
            message:
                'Save your vehicle once to start estimates, find help and keep its history together.',
            action: 'Add a vehicle',
            onAction: () => editVehicle(context, controller),
          )
        else ...[
          if (data.vehicles.length > 1) ...[
            VehiclePicker(controller: controller),
            const SizedBox(height: 16),
          ],
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            decoration: BoxDecoration(
              color: PlusColors.navy,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        vehicle.nickname.isEmpty
                            ? 'In your garage'
                            : vehicle.nickname,
                        style: const TextStyle(
                          color: Color(0xFFC5DAED),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit vehicle',
                      onPressed: () =>
                          editVehicle(context, controller, vehicle: vehicle),
                      icon: const Icon(
                        Icons.edit_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                Text(
                  '${vehicle.make} ${vehicle.model}',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.6,
                    color: Colors.white,
                  ),
                ),
                Text(
                  '${vehicle.year}',
                  style: const TextStyle(
                    color: Color(0xFFC5DAED),
                    fontSize: 16,
                  ),
                ),
                VehiclePhotoPanel(
                  key: ValueKey('${data.profile.id}:${vehicle.id}'),
                  controller: controller,
                  vehicle: vehicle,
                  onEdit: () =>
                      openVehiclePhoto(context, controller, vehicle.id),
                ),
                Row(
                  children: [
                    const Icon(
                      Icons.speed_outlined,
                      size: 18,
                      color: Color(0xFF73E1D5),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${mileageText(vehicle.mileage)} miles',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.verified_user_outlined,
                      size: 18,
                      color: Color(0xFF73E1D5),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _QuickAction(
                  icon: Icons.add_a_photo_outlined,
                  title: 'Get an estimate',
                  subtitle: 'PDR or collision',
                  onTap: () => newEstimate(context, controller),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _QuickAction(
                  icon: Icons.near_me_outlined,
                  title: 'Find local help',
                  subtitle: 'Shops & mobile techs',
                  onTap: () => controller.selectTab(4),
                ),
              ),
            ],
          ),
        ],
        SectionHeading(
          'Coming up',
          action: 'Add reminder',
          onAction: vehicle == null || busy
              ? null
              : () => addReminder(context, controller),
        ),
        if (reminders.isEmpty)
          const EmptyState(
            icon: Icons.event_available_outlined,
            title: 'Nothing on your list',
            message:
                'Add a reminder when your next service is due. Your garage will keep it here.',
          )
        else
          Card(
            child: Column(
              children: [
                for (final reminder in reminders)
                  _reminderRow(reminder, now, vehicle!.mileage),
              ],
            ),
          ),
        if (completed.isNotEmpty)
          Card(
            child: ExpansionTile(
              key: ValueKey('completed-reminders-${vehicle!.id}'),
              title: Text('Completed reminders (${completed.length})'),
              subtitle: const Text('Reopen, edit or delete a past reminder'),
              children: [
                for (final reminder in completed)
                  _reminderRow(reminder, now, vehicle.mileage),
              ],
            ),
          ),
        SectionHeading('A little help goes a long way'),
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => controller.selectTab(2),
          child: Ink(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F1F8),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.support_agent,
                  size: 32,
                  color: PlusColors.navy,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ask Estibot',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Understand a repair or connect with the right technician.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: PlusColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: PlusColors.navy),
              ],
            ),
          ),
        ),
        SectionHeading(
          'Your garage',
          action: 'Add vehicle',
          onAction: () => editVehicle(context, controller),
        ),
        for (final car in data.vehicles)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ListTile(
                leading: const Icon(
                  Icons.directions_car_outlined,
                  color: PlusColors.blue,
                ),
                title: Text(car.title),
                subtitle: Text('${mileageText(car.mileage)} miles'),
                trailing: Icon(
                  car.id == vehicle?.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: PlusColors.blue,
                ),
                onTap: () => controller.selectVehicle(car.id),
              ),
            ),
          ),
        const SectionHeading('Make it yours'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(
                  Icons.storefront_outlined,
                  color: PlusColors.blue,
                ),
                title: const Text('My shops'),
                subtitle: const Text('Saved contacts and scheduling requests'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openMyShops(context, controller),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.calendar_month_outlined,
                  color: PlusColors.blue,
                ),
                title: const Text('Calendar'),
                subtitle: const Text(
                  'Availability and confirmed appointment copies',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openCalendar(context, controller),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.price_check_outlined,
                  color: PlusColors.blue,
                ),
                title: const Text('Vehicle value'),
                subtitle: const Text(
                  'Market estimates and your documented care',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: controller.selectedVehicle == null
                    ? null
                    : () => openVehicleValue(context, controller),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.history_outlined,
                  color: PlusColors.blue,
                ),
                title: const Text('Service history & receipts'),
                subtitle: const Text(
                  'Past repairs, maintenance, modifications and costs',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openVehicleHistory(context, controller),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _reminderRow(ServiceReminder reminder, DateTime now, int mileage) {
    final status = ReminderStatus.forReminder(
      reminder,
      now: now,
      mileage: mileage,
    );
    final color = reminder.completed
        ? PlusColors.muted
        : switch (status.urgency) {
            ReminderUrgency.overdue => const Color(0xFFAF3F24),
            ReminderUrgency.dueNow => PlusColors.blue,
            ReminderUrgency.upcoming => const Color(0xFF08796D),
          };
    return ListTile(
      key: ValueKey('reminder-${reminder.id}'),
      onTap: busy
          ? null
          : () => addReminder(context, controller, reminder: reminder),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: Text(
        reminder.title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reminder.completed ? 'Completed' : status.label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              reminder.completed
                  ? [
                      if (reminder.dueDate.isNotEmpty)
                        dateText(reminder.dueDate),
                      if (reminder.dueMileage != null)
                        '${mileageText(reminder.dueMileage!)} miles',
                    ].join(' or ')
                  : status.detail,
            ),
          ],
        ),
      ),
      trailing: IconButton(
        tooltip: reminder.completed
            ? 'Reopen reminder'
            : 'Mark reminder complete',
        icon: Icon(
          reminder.completed ? Icons.undo : Icons.check_circle_outline,
          color: color,
        ),
        onPressed: busy
            ? null
            : () => _setCompleted(reminder, !reminder.completed),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: PlusColors.blue, size: 26),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
}
