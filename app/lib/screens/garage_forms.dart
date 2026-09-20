import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../widgets/common.dart';

Future<void> editVehicle(
  BuildContext context,
  PlusController controller, {
  Vehicle? vehicle,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _VehicleForm(controller: controller, vehicle: vehicle),
);
Future<void> editProfile(BuildContext context, PlusController controller) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ProfileForm(controller: controller),
    );
Future<void> addReminder(
  BuildContext context,
  PlusController controller, {
  ServiceReminder? reminder,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _ReminderForm(controller: controller, reminder: reminder),
);

class _VehicleForm extends StatefulWidget {
  const _VehicleForm({required this.controller, this.vehicle});
  final PlusController controller;
  final Vehicle? vehicle;
  @override
  State<_VehicleForm> createState() => _VehicleFormState();
}

class _VehicleFormState extends State<_VehicleForm> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    fields = {
      for (final key in [
        'nickname',
        'year',
        'make',
        'model',
        'vin',
        'mileage',
        'insurer',
        'policy_number',
      ])
        key: TextEditingController(
          text:
              widget.vehicle?.json[key]?.toString() ??
              (key == 'year' ? DateTime.now().year.toString() : ''),
        ),
    };
  }

  @override
  void dispose() {
    for (final value in fields.values) {
      value.dispose();
    }
    super.dispose();
  }

  String? validate(String key, String? value) {
    final text = value?.trim() ?? '';
    if (['make', 'model'].contains(key) && text.isEmpty) {
      return 'This field is required';
    }
    if (key == 'year' &&
        (int.tryParse(text) == null ||
            int.parse(text) < 1886 ||
            int.parse(text) > DateTime.now().year + 1)) {
      return 'Enter a valid model year';
    }
    if (key == 'mileage' &&
        text.isNotEmpty &&
        (int.tryParse(text) == null ||
            int.parse(text) < 0 ||
            int.parse(text) > 3000000)) {
      return 'Enter a valid mileage';
    }
    if (key == 'vin' &&
        text.isNotEmpty &&
        !RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(text.toUpperCase())) {
      return 'Enter a 17-character VIN';
    }
    return null;
  }

  Future<void> save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final body = <String, dynamic>{
        for (final entry in fields.entries) entry.key: entry.value.text.trim(),
      };
      body['year'] = int.parse(fields['year']!.text.trim());
      body['mileage'] = int.tryParse(fields['mileage']!.text.trim()) ?? 0;
      body['vin'] = fields['vin']!.text.trim().toUpperCase();
      await widget.controller.saveVehicle(body, id: widget.vehicle?.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = PlusController.readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FormSheet(
    title: widget.vehicle == null ? 'Add your vehicle' : 'Edit your vehicle',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Save it once. Use it for estimates, repair requests and reminders.',
          ),
          const SizedBox(height: 18),
          for (final entry in {
            'nickname': 'Nickname (optional)',
            'year': 'Year',
            'make': 'Make',
            'model': 'Model',
            'vin': 'VIN (optional)',
            'mileage': 'Current mileage',
            'insurer': 'Insurance company (optional)',
            'policy_number': 'Policy number (optional)',
          }.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: TextFormField(
                controller: fields[entry.key],
                enabled: !busy,
                decoration: InputDecoration(labelText: entry.value),
                keyboardType: ['year', 'mileage'].contains(entry.key)
                    ? TextInputType.number
                    : TextInputType.text,
                textCapitalization: entry.key == 'vin'
                    ? TextCapitalization.characters
                    : TextCapitalization.words,
                maxLength: entry.key == 'vin'
                    ? 17
                    : (entry.key == 'year' ? 4 : 100),
                validator: (v) => validate(entry.key, v),
                buildCounter:
                    (
                      _, {
                      required currentLength,
                      required isFocused,
                      required maxLength,
                    }) => null,
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          BusyButton(busy: busy, label: 'Save vehicle', onPressed: save),
          if (widget.vehicle != null)
            Center(
              child: TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          await widget.controller.repository.deleteVehicle(
                            widget.vehicle!.id,
                          );
                          await widget.controller.refresh();
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (mounted) {
                            setState(() {
                              busy = false;
                              error = PlusController.readableError(e);
                            });
                          }
                        }
                      },
                child: const Text('Remove from garage'),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Name, phone, ZIP and contact preference for the signed-in customer.
///
/// As a bottom sheet (the default) it closes itself after saving. With
/// [inline] it renders bare fields for a host page and reports success
/// through [onSaved] instead of popping the route.
class ProfileForm extends StatefulWidget {
  const ProfileForm({
    super.key,
    required this.controller,
    this.inline = false,
    this.onSaved,
  });
  final PlusController controller;
  final bool inline;
  final VoidCallback? onSaved;
  @override
  State<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<ProfileForm> {
  late final TextEditingController name, phone, postal;
  bool busy = false;
  String? error;
  String preference = 'email';
  final form = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    final p = widget.controller.snapshot!.profile;
    name = TextEditingController(text: p.name);
    phone = TextEditingController(text: p.phone);
    postal = TextEditingController(text: p.postalCode);
    preference = textOf(p.json, 'contact_preference', 'email');
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    postal.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.repository.saveProfile({
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'postal_code': postal.text.trim(),
        'contact_preference': preference,
      });
      await widget.controller.refresh();
      if (!mounted) return;
      if (widget.inline) {
        setState(() => busy = false);
        widget.onSaved?.call();
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = PlusController.readableError(e);
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.inline) ...[
            Text(widget.controller.snapshot!.profile.email),
            const SizedBox(height: 20),
          ],
          TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Name'),
            maxLength: 120,
            validator: (v) =>
                (v?.trim().isEmpty ?? true) ? 'Enter your name' : null,
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: phone,
            builder: (context, _) => TextFormField(
              controller: phone,
              decoration: InputDecoration(
                labelText: 'Phone (optional)',
                suffixIcon: phone.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear phone',
                        icon: const Icon(Icons.clear),
                        onPressed: busy ? null : phone.clear,
                      ),
              ),
              keyboardType: TextInputType.phone,
              maxLength: 30,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: postal,
            decoration: const InputDecoration(labelText: 'ZIP code'),
            keyboardType: TextInputType.number,
            maxLength: 5,
            validator: (v) => RegExp(r'^\d{5}$').hasMatch(v?.trim() ?? '')
                ? null
                : 'Enter a five-digit ZIP code',
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: preference,
            decoration: const InputDecoration(labelText: 'Preferred contact'),
            items: const [
              DropdownMenuItem(value: 'email', child: Text('Email')),
              DropdownMenuItem(value: 'phone', child: Text('Phone')),
            ],
            onChanged: (value) => preference = value ?? 'email',
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
          BusyButton(busy: busy, label: 'Save profile', onPressed: save),
        ],
      ),
    );
    return widget.inline
        ? fields
        : FormSheet(title: 'Your profile', child: fields);
  }
}

class _ReminderForm extends StatefulWidget {
  const _ReminderForm({required this.controller, this.reminder});
  final PlusController controller;
  final ServiceReminder? reminder;
  @override
  State<_ReminderForm> createState() => _ReminderFormState();
}

class _ReminderFormState extends State<_ReminderForm> {
  final title = TextEditingController();
  final mileage = TextEditingController();
  DateTime? date;
  String? error;
  bool busy = false;
  bool get editing => widget.reminder != null;
  @override
  void initState() {
    super.initState();
    final r = widget.reminder;
    if (r != null) {
      title.text = r.title;
      if (r.dueMileage != null) mileage.text = r.dueMileage.toString();
      if (r.dueDate.isNotEmpty) date = DateTime.tryParse(r.dueDate);
    }
  }

  Future<void> remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this reminder?'),
        content: const Text('You can add it again any time.'),
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
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.controller.repository.deleteReminder(widget.reminder!.id);
      await widget.controller.refresh();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = PlusController.readableError(e);
          busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    title.dispose();
    mileage.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    final miles = int.tryParse(mileage.text.trim());
    if (title.text.trim().isEmpty ||
        (date == null && miles == null) ||
        (mileage.text.trim().isNotEmpty &&
            (miles == null || miles < 0 || miles > 5000000))) {
      setState(() => error = 'Add a title and a valid date or mileage.');
      return;
    }
    if (!editing && widget.controller.selectedVehicle == null) {
      setState(() => error = 'Choose a vehicle first.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final body = <String, dynamic>{
        'vehicle_id':
            widget.reminder?.vehicleId ?? widget.controller.selectedVehicle!.id,
        'title': title.text.trim(),
        'due_date': date?.toIso8601String().substring(0, 10),
        'due_mileage': miles,
      };
      if (editing) {
        await widget.controller.repository.updateReminder(
          widget.reminder!.id,
          body,
        );
      } else {
        await widget.controller.repository.addReminder(body);
      }
      await widget.controller.refresh();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = PlusController.readableError(e);
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => FormSheet(
    title: editing ? 'Edit reminder' : 'Add a reminder',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!editing) ...[
          VehiclePicker(controller: widget.controller),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: title,
          enabled: !busy,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'What needs attention?'),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      final initial =
                          date ?? DateTime.now().add(const Duration(days: 30));
                      final first = DateTime(1950);
                      final last = DateTime.now().add(
                        const Duration(days: 3650),
                      );
                      final value = await showDatePicker(
                        context: context,
                        initialDate: initial,
                        firstDate: initial.isBefore(first) ? initial : first,
                        lastDate: initial.isAfter(last) ? initial : last,
                      );
                      if (value != null && mounted) {
                        setState(() => date = value);
                      }
                    },
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text(
                date == null
                    ? 'Choose a date'
                    : dateText(date!.toIso8601String()),
              ),
            ),
            if (date != null)
              IconButton(
                tooltip: 'Clear reminder date',
                onPressed: busy ? null : () => setState(() => date = null),
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: mileage,
          enabled: !busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Or due at mileage'),
        ),
        const SizedBox(height: 12),
        const Text(
          'Use the service interval in your owner’s manual or your shop’s recommendation.',
        ),
        const SizedBox(height: 18),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        BusyButton(busy: busy, label: 'Save reminder', onPressed: save),
        if (editing)
          Center(
            child: TextButton(
              onPressed: busy ? null : remove,
              child: const Text('Delete reminder'),
            ),
          ),
      ],
    ),
  );
}
