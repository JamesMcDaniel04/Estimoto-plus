import 'package:flutter/material.dart';
import '../build_info.dart';
import '../data/repository.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../widgets/common.dart';
import 'garage_forms.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller, this.onExit});
  final PlusController controller;
  final VoidCallback? onExit;

  static Future<void> open(
    BuildContext context,
    PlusController controller, {
    VoidCallback? onExit,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SettingsScreen(controller: controller, onExit: onExit),
    ),
  );

  static Future<void> confirmExit(
    BuildContext context,
    PlusController controller,
    VoidCallback? onExit,
  ) async {
    final owner = controller.snapshot?.profile.id;
    if (owner == null ||
        !controller.isCurrentCustomer(owner) ||
        onExit == null) {
      return;
    }
    final demo = controller.isDemo;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(demo ? 'Leave the demo?' : 'Sign out?'),
        content: Text(
          demo
              ? 'Demo changes are not kept once you leave.'
              : 'Your saved details stay in your account. Sign in again with your email to return.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(demo ? 'Leave demo' : 'Sign out'),
          ),
        ],
      ),
    );
    if (leave == true &&
        context.mounted &&
        controller.isCurrentCustomer(owner)) {
      onExit();
    }
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final PlusController controller;
  String? owner;
  bool exiting = false;
  bool get current =>
      identical(widget.controller, controller) &&
      owner != null &&
      controller.isCurrentCustomer(owner!);
  @override
  void initState() {
    super.initState();
    controller = widget.controller;
    owner = controller.snapshot?.profile.id;
    controller.addListener(changed);
  }

  void changed() {
    if (mounted) {
      owner ??= controller.snapshot?.profile.id;
      setState(() {});
    }
  }

  @override
  void dispose() {
    controller.removeListener(changed);
    super.dispose();
  }

  Future<void> exit() async {
    if (!current || exiting) return;
    setState(() => exiting = true);
    await SettingsScreen.confirmExit(context, controller, widget.onExit);
    if (mounted && current) setState(() => exiting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!current) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: Text('Sign in to view your settings.')),
      );
    }
    final snapshot = controller.snapshot!;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: PageBody(
          children: [
            const SectionHeading('Account'),
            Text('Signed in as', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(snapshot.profile.email, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              controller.isDemo
                  ? 'Demo session · sample data that resets when you leave.'
                  : 'This email identifies your account and is used for sign-in. It cannot be changed here. Signing in with a different address opens a separate account.',
              style: theme.textTheme.bodySmall,
            ),
            const SectionHeading('Profile'),
            Text(
              'Shops see these details only when you choose to share a request. Clearing them does not recall information already shared.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ProfileForm(
              key: ValueKey(snapshot.profile.id),
              controller: controller,
              inline: true,
              onSaved: () {
                if (mounted && current) showMessage(context, 'Profile saved');
              },
            ),
            const SectionHeading('App preferences'),
            const Text(
              'Choose the vehicle, estimate type and page used when you open the app. These choices are saved to your account.',
            ),
            const SizedBox(height: 12),
            _AppPreferences(controller: controller),
            const SectionHeading('Privacy'),
            _InsightsPreference(controller: controller),
            const SectionHeading('Connections'),
            const Card(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.hub_outlined),
                      title: Text('Nango'),
                      subtitle: Text('Google Calendar · Not configured'),
                    ),
                    Divider(indent: 16, endIndent: 16),
                    ListTile(
                      leading: Icon(
                        Icons.mail_outline,
                        color: Color(0xFFEA4335),
                      ),
                      title: Text('Gmail'),
                      subtitle: Text(
                        'Car-service appointments, estimates and receipts\nNot configured',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.onExit != null) ...[
              const SectionHeading('Session'),
              OutlinedButton.icon(
                onPressed: exiting ? null : exit,
                icon: const Icon(Icons.logout, size: 19),
                label: Text(controller.isDemo ? 'Leave demo' : 'Sign out'),
              ),
            ],
            const SectionHeading('About'),
            Text(PlusBuildInfo.label, style: theme.textTheme.bodyMedium),
            if (PlusBuildInfo.sourceSha.isNotEmpty)
              Text(
                'Source ${PlusBuildInfo.sourceSha.substring(0, PlusBuildInfo.sourceSha.length < 7 ? PlusBuildInfo.sourceSha.length : 7)}',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class _AppPreferences extends StatefulWidget {
  const _AppPreferences({required this.controller});
  final PlusController controller;
  @override
  State<_AppPreferences> createState() => _AppPreferencesState();
}

class _AppPreferencesState extends State<_AppPreferences> {
  late final PlusController controller;
  late final String owner;
  late AppSettings baseline;
  String? vehicle;
  String discipline = 'pdr', home = 'garage';
  bool busy = false, conflict = false, confirming = false;
  String? error;
  bool get active =>
      mounted &&
      identical(controller, widget.controller) &&
      controller.isCurrentCustomer(owner);
  bool get dirty =>
      vehicle != baseline.defaultVehicleId ||
      discipline != baseline.defaultEstimateDiscipline ||
      home != baseline.homeTab;
  bool get changedElsewhere =>
      controller.snapshot!.settings.revision != baseline.revision;
  @override
  void initState() {
    super.initState();
    controller = widget.controller;
    owner = controller.snapshot!.profile.id;
    sync();
    controller.addListener(changed);
  }

  void sync() {
    baseline = controller.snapshot!.settings;
    vehicle = baseline.defaultVehicleId;
    discipline = baseline.defaultEstimateDiscipline;
    home = baseline.homeTab;
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
    controller.removeListener(changed);
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
      await controller.reloadAppSettings();
      if (active) setState(sync);
    } catch (e) {
      if (active) setState(() => error = PlusController.readableError(e));
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (!active || busy || conflict || changedElsewhere) return;
    final body = <String, dynamic>{
      'default_vehicle_id': vehicle,
      'default_estimate_discipline': discipline,
      'home_tab': home,
    };
    final revision = baseline.revision;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await controller.saveAppSettings(body, expectedRevision: revision);
      if (!mounted || !active) return;
      setState(sync);
      showMessage(context, 'App preferences saved');
    } catch (e) {
      if (active) {
        setState(() {
          error = PlusController.readableError(e);
          conflict = e is PlusApiException && e.statusCode == 409;
        });
      }
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  Future<void> reset() async {
    if (!active || busy) return;
    final revision = controller.snapshot!.settings.revision;
    setState(() {
      busy = true;
      confirming = true;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset app preferences?'),
        content: const Text(
          'Use the first available vehicle, PDR estimates and the Garage start page. Your profile, privacy choice and saved records stay unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep preferences'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset preferences'),
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
      await controller.resetAppSettings(expectedRevision: revision);
      if (!mounted || !active) return;
      setState(sync);
      showMessage(context, 'App preferences reset');
    } catch (e) {
      if (active) {
        setState(() {
          error = PlusController.readableError(e);
          conflict = e is PlusApiException && e.statusCode == 409;
        });
      }
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  Widget dropdown(
    String key,
    String label,
    String value,
    Map<String, String> options,
    ValueChanged<String> change,
  ) => DropdownButtonFormField<String>(
    key: ValueKey('$key-$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final entry in options.entries)
        DropdownMenuItem(
          value: entry.key,
          child: Text(entry.value, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: busy
        ? null
        : (next) {
            if (!active || busy || next == null) return;
            setState(() => change(next));
          },
  );
  @override
  Widget build(BuildContext context) {
    if (!active) return const SizedBox.shrink();
    final vehicles = controller.snapshot!.vehicles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        dropdown(
          'default-vehicle',
          'Default vehicle',
          vehicle ?? '',
          {
            '': 'First available vehicle',
            for (final item in vehicles) item.id: item.title,
            if (vehicle != null && !vehicles.any((v) => v.id == vehicle))
              vehicle!: 'Saved vehicle no longer available',
          },
          (value) => vehicle = value.isEmpty ? null : value,
        ),
        const SizedBox(height: 16),
        dropdown(
          'default-discipline',
          'Default estimate type',
          discipline,
          const {'pdr': 'PDR', 'collision': 'Collision'},
          (value) => discipline = value,
        ),
        const SizedBox(height: 16),
        dropdown('home-tab', 'Start page', home, const {
          'garage': 'Garage',
          'estimates': 'Estimates',
          'repairs': 'Repairs',
          'find_help': 'Find help',
        }, (value) => home = value),
        const SizedBox(height: 20),
        if (changedElsewhere || conflict)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Your saved app preferences changed. Reload them before saving again. Your unfinished choices are still shown.',
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
          label: 'Save app preferences',
          onPressed: busy || changedElsewhere || conflict ? null : save,
        ),
        if (dirty || changedElsewhere || conflict)
          TextButton(
            onPressed: busy ? null : reload,
            child: Text(
              conflict
                  ? 'Reload saved preferences'
                  : 'Discard preference changes',
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: busy ? null : reset,
          child: const Text('Reset app preferences'),
        ),
      ],
    );
  }
}

class _InsightsPreference extends StatefulWidget {
  const _InsightsPreference({required this.controller});
  final PlusController controller;
  @override
  State<_InsightsPreference> createState() => _InsightsPreferenceState();
}

class _InsightsPreferenceState extends State<_InsightsPreference> {
  late final PlusController controller;
  late final String owner;
  bool loading = false, busy = false;
  bool? share, pending;
  String? error;
  bool get active =>
      mounted &&
      identical(widget.controller, controller) &&
      controller.isCurrentCustomer(owner);
  @override
  void initState() {
    super.initState();
    controller = widget.controller;
    owner = controller.snapshot!.profile.id;
    load();
  }

  Future<void> load() async {
    if (!active || busy || loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await controller.repository.getKnowledgePreferences(
        isCurrent: () => active,
      );
      if (!mounted || !active) return;
      final saved = readChoice(value);
      setState(() {
        share = saved;
        pending = null;
      });
    } catch (e) {
      if (active) setState(() => error = PlusController.readableError(e));
    } finally {
      if (active) setState(() => loading = false);
    }
  }

  bool readChoice(Json value) {
    final choice = value['share_aggregate_insights'];
    if (choice is! bool) {
      throw const PlusApiException(
        'We could not read your saved privacy choice. Reload to try again.',
      );
    }
    return choice;
  }

  Future<void> save(bool selected) async {
    if (!active ||
        busy ||
        loading ||
        share == null ||
        (pending != null && pending != selected)) {
      return;
    }
    setState(() {
      busy = true;
      pending = selected;
      error = null;
    });
    try {
      final value = await controller.repository.saveKnowledgePreferencesScoped({
        'share_aggregate_insights': selected,
      }, isCurrent: () => active);
      if (!mounted || !active) return;
      final saved = readChoice(value);
      setState(() {
        share = saved;
        pending = null;
      });
      controller.historyChanged();
      showMessage(context, 'Privacy preference saved');
    } catch (e) {
      if (active) setState(() => error = PlusController.readableError(e));
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (loading) const LinearProgressIndicator(),
      if (share != null)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          key: const Key('settings-insights-consent'),
          title: const Text('Help improve repair insights'),
          value: share!,
          onChanged: busy || loading || pending != null ? null : save,
        ),
      if (share == null)
        const Text(
          'Load your saved insights-sharing choice before changing it.',
        ),
      const Text(
        'Optionally share grouped service needs, requests and parts-source trends. Contact details, VIN, insurance and free-text notes are excluded. You can turn this off at any time; your personal history will still work.',
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (pending != null) ...[
        const SizedBox(height: 12),
        Text(
          'Your change to turn insights sharing ${pending! ? 'on' : 'off'} has not been confirmed. Retry or reload the saved choice.',
        ),
        OutlinedButton(
          onPressed: busy ? null : () => save(pending!),
          child: const Text('Retry privacy change'),
        ),
      ],
      TextButton(
        onPressed: busy || loading ? null : load,
        child: const Text('Reload privacy preference'),
      ),
    ],
  );
}
