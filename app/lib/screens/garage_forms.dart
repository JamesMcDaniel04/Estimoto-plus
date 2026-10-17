import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../data/repository.dart';
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
  late final PlusController boundController;
  late final String owner;
  late CustomerProfile baseline;
  bool busy = false, conflict = false, confirming = false;
  String? error;
  String preference = 'email';
  final form = GlobalKey<FormState>();
  bool get active =>
      mounted &&
      identical(widget.controller, boundController) &&
      boundController.isCurrentCustomer(owner);
  bool get dirty =>
      name.text != baseline.name ||
      phone.text != baseline.phone ||
      postal.text != baseline.postalCode ||
      preference != textOf(baseline.json, 'contact_preference', 'email');
  bool get changedElsewhere {
    final saved = boundController.snapshot!.profile;
    return saved.revision != baseline.revision ||
        saved.name != baseline.name ||
        saved.phone != baseline.phone ||
        saved.postalCode != baseline.postalCode ||
        textOf(saved.json, 'contact_preference', 'email') !=
            textOf(baseline.json, 'contact_preference', 'email');
  }

  @override
  void initState() {
    super.initState();
    boundController = widget.controller;
    owner = boundController.snapshot!.profile.id;
    baseline = boundController.snapshot!.profile;
    name = TextEditingController(text: baseline.name);
    phone = TextEditingController(text: baseline.phone);
    postal = TextEditingController(text: baseline.postalCode);
    preference = textOf(baseline.json, 'contact_preference', 'email');
    boundController.addListener(changed);
  }

  void sync() {
    baseline = boundController.snapshot!.profile;
    name.text = baseline.name;
    phone.text = baseline.phone;
    postal.text = baseline.postalCode;
    preference = textOf(baseline.json, 'contact_preference', 'email');
    conflict = false;
    error = null;
  }

  void changed() {
    if (!mounted) return;
    if (active && !busy && !dirty) sync();
    setState(() {});
  }

  @override
  void dispose() {
    boundController.removeListener(changed);
    name.dispose();
    phone.dispose();
    postal.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    if (!active || busy) return;
    if (!conflict) {
      setState(sync);
      return;
    }
    setState(() => busy = true);
    try {
      await boundController.reloadProfileSettings();
      if (active) setState(sync);
    } catch (e) {
      if (active) setState(() => error = PlusController.readableError(e));
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (!active ||
        busy ||
        conflict ||
        changedElsewhere ||
        !form.currentState!.validate()) {
      return;
    }
    final body = <String, dynamic>{
      'name': name.text.trim(),
      'phone': phone.text.trim(),
      'postal_code': postal.text.trim(),
      'contact_preference': preference,
    };
    final revision = baseline.revision;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await boundController.saveProfileSettings(
        body,
        expectedRevision: revision,
      );
      if (!mounted || !active) return;
      setState(() {
        sync();
        busy = false;
      });
      if (widget.inline) {
        widget.onSaved?.call();
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      if (!mounted || !active) return;
      setState(() {
        error = PlusController.readableError(e);
        conflict = e is PlusApiException && e.statusCode == 409;
        busy = false;
      });
    }
  }

  Future<void> clear() async {
    if (!active || busy) return;
    final revision = boundController.snapshot!.profile.revision;
    // Lock while the dialog is open, including captured callbacks.
    setState(() {
      busy = true;
      confirming = true;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear profile details?'),
        content: const Text(
          'Remove your name, phone and service ZIP, and return preferred contact to email. Your sign-in email, vehicles, estimates and history stay in your account. Details already shared with a shop are not recalled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep details'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear details'),
          ),
        ],
      ),
    );
    if (!mounted || !active) return;
    setState(() => confirming = false);
    if (confirmed != true) {
      setState(() => busy = false);
      return;
    }
    try {
      await boundController.clearProfileSettings(expectedRevision: revision);
      if (!mounted || !active) return;
      setState(() {
        sync();
        busy = false;
      });
      showMessage(context, 'Profile details cleared');
    } catch (e) {
      if (!mounted || !active) return;
      setState(() {
        error = PlusController.readableError(e);
        conflict = e is PlusApiException && e.statusCode == 409;
        busy = false;
      });
    }
  }

  String? validatePhone(String? value) {
    final input = value?.trim() ?? '';
    if (input.isEmpty) {
      return preference == 'phone'
          ? 'Add a phone number or choose email.'
          : null;
    }
    final digits = input.replaceAll(RegExp(r'\D'), '');
    return RegExp(r'^\+?[0-9 ().-]+$').hasMatch(input) &&
            digits.length >= 7 &&
            digits.length <= 15
        ? null
        : 'Enter a valid phone number with 7–15 digits.';
  }

  @override
  Widget build(BuildContext context) {
    if (!active) return const SizedBox.shrink();
    final changed = changedElsewhere;
    final fields = Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.inline) ...[
            Text(baseline.email),
            const SizedBox(height: 20),
          ],
          TextFormField(
            controller: name,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'Name',
              helperText: 'Optional',
            ),
            maxLength: 200,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: phone,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: 'Phone (optional)',
              suffixIcon: phone.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear phone',
                      icon: const Icon(Icons.clear),
                      onPressed: busy
                          ? null
                          : () {
                              phone.clear();
                              setState(() {});
                            },
                    ),
            ),
            keyboardType: TextInputType.phone,
            maxLength: 50,
            validator: validatePhone,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: postal,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'ZIP code',
              helperText: 'Optional · needed to request service',
            ),
            keyboardType: TextInputType.number,
            maxLength: 10,
            validator: (value) {
              final zip = value?.trim() ?? '';
              return zip.isEmpty || RegExp(r'^\d{5}(-\d{4})?$').hasMatch(zip)
                  ? null
                  : 'Enter a five-digit ZIP code';
            },
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('contact-$preference'),
            initialValue: preference,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Preferred contact'),
            items: const [
              DropdownMenuItem(value: 'email', child: Text('Email')),
              DropdownMenuItem(value: 'phone', child: Text('Phone')),
            ],
            onChanged: busy
                ? null
                : (value) {
                    if (!active || busy) return;
                    setState(() => preference = value ?? 'email');
                  },
          ),
          const SizedBox(height: 20),
          if (changed || conflict)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Your saved profile changed. Reload the saved details before saving again. Your unfinished edits are still shown.',
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
          BusyButton(
            busy: busy && !confirming,
            label: 'Save profile',
            onPressed: busy || changed || conflict ? null : save,
          ),
          if (dirty || changed || conflict)
            TextButton(
              onPressed: busy ? null : reload,
              child: Text(
                conflict ? 'Reload saved profile' : 'Discard profile changes',
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : clear,
            icon: const Icon(Icons.person_remove_outlined),
            label: const Text('Clear profile details'),
          ),
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
