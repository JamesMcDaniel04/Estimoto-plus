import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../state/plus_controller.dart';

class PageBody extends StatelessWidget {
  const PageBody({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 28),
  });
  final List<Widget> children;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: padding,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
  );
}

class PageHeading extends StatelessWidget {
  const PageHeading(this.title, this.subtitle, {super.key, this.trailing});
  final String title;
  final String subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 6),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    ),
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: MediaQuery.textScalerOf(context).scale(14) > 20
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (action != null)
                TextButton(onPressed: onAction, child: Text(action!)),
            ],
          )
        : Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (action != null)
                Flexible(
                  child: TextButton(onPressed: onAction, child: Text(action!)),
                ),
            ],
          ),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.color});
  final String label;

  /// Defaults to the scheme's primary color.
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          height: 1.25,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.onAction,
  });
  final IconData icon;
  final String title, message;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(message, style: Theme.of(context).textTheme.bodySmall),
          if (action != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}

class VehiclePicker extends StatelessWidget {
  const VehiclePicker({
    super.key,
    required this.controller,
    this.label = 'Your vehicle',
  });
  final PlusController controller;
  final String label;
  @override
  Widget build(BuildContext context) {
    final vehicles = controller.snapshot?.vehicles ?? [];
    if (vehicles.isEmpty) {
      return const Text('Add a vehicle in your garage to get started.');
    }
    return DropdownButtonFormField<String>(
      key: ValueKey('${controller.selectedVehicle?.id}-${vehicles.length}'),
      initialValue: controller.selectedVehicle?.id,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.directions_car_outlined),
      ),
      items: vehicles
          .map(
            (v) => DropdownMenuItem(
              value: v.id,
              child: Text(v.title, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: (id) {
        if (id != null) controller.selectVehicle(id);
      },
    );
  }
}

class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.busy,
    required this.label,
    required this.onPressed,
    this.icon,
  });
  final bool busy;
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: 'Working',
              ),
            )
          : Icon(icon ?? Icons.check, size: 19),
      label: Text(busy ? 'Please wait…' : label),
    ),
  );
}

void showMessage(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<void> runAction(
  BuildContext context,
  PlusController controller,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    await controller.refresh();
    if (context.mounted && success != null) showMessage(context, success);
  } catch (error) {
    if (context.mounted) {
      showMessage(context, PlusController.readableError(error));
    }
  }
}

Future<void> openExternal(
  BuildContext context,
  String raw, {
  bool youtubeOnly = false,
}) async {
  final uri = Uri.tryParse(raw);
  final allowed =
      uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!youtubeOnly ||
          const [
            'www.youtube.com',
            'youtube.com',
            'youtu.be',
          ].contains(uri.host));
  if (!allowed) {
    showMessage(context, 'This link is not available.');
    return;
  }
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      showMessage(context, 'Could not open this link. Please try again.');
    }
  } catch (_) {
    if (context.mounted) {
      showMessage(context, 'Could not open this link. Please try again.');
    }
  }
}

/// Opens the customer's mail app addressed to support, never a web page.
Future<void> openSupportEmail(BuildContext context, String address) async {
  final uri = Uri(scheme: 'mailto', path: address);
  try {
    if (!await launchUrl(uri) && context.mounted) {
      showMessage(context, 'No mail app is available. Email $address.');
    }
  } catch (_) {
    if (context.mounted) {
      showMessage(context, 'No mail app is available. Email $address.');
    }
  }
}

String mileageText(int value) => value.toString().replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
  (m) => '${m[1]},',
);
String moneyText(int value) => '\$${(value / 100).toStringAsFixed(2)}';
String dateText(String raw) {
  final date = DateTime.tryParse(raw);
  if (date == null) return raw.isEmpty ? 'Not set' : raw;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}

String appointmentText(String raw) {
  final value = DateTime.tryParse(raw);
  if (value == null) return raw;
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  return '${dateText(local.toIso8601String())} at $hour:$minute ${local.hour < 12 ? 'AM' : 'PM'} ${local.timeZoneName}';
}

class FormSheet extends StatelessWidget {
  const FormSheet({super.key, required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 22),
            child,
          ],
        ),
      ),
    ),
  );
}
