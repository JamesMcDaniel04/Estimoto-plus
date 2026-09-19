import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../build_info.dart';
import '../domain/models.dart';
import '../plus_links.dart';
import '../services/account_export.dart';
import '../state/plus_controller.dart';
import '../widgets/common.dart';
import 'calendar_screen.dart';
import 'garage_forms.dart';

/// Account, profile, session, data, legal and version in one place.
///
/// Email is read-only because it is the sign-in identity. Profile fields
/// reuse [ProfileForm] so validation lives in one widget. Signing out
/// always asks first; the exit itself belongs to the caller. Deleting the
/// account requires a typed confirmation and, once the server confirms,
/// hands control to [onAccountDeleted] so the launcher can end the session.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.onExit,
    this.onAccountDeleted,
    this.saveExport = saveAccountExport,
  });
  final PlusController controller;
  final VoidCallback? onExit;
  final VoidCallback? onAccountDeleted;

  /// Platform hand-off for a finished export; tests substitute a fake.
  final Future<String?> Function(String json) saveExport;

  static Future<void> open(
    BuildContext context,
    PlusController controller, {
    VoidCallback? onExit,
    VoidCallback? onAccountDeleted,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SettingsScreen(
        controller: controller,
        onExit: onExit,
        onAccountDeleted: onAccountDeleted,
      ),
    ),
  );

  Future<void> _confirmExit(BuildContext context) async {
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
    if (leave == true) onExit?.call();
  }

  Future<void> _exportData(BuildContext context) async {
    final Json data;
    try {
      data = await controller.exportAccount();
    } catch (error) {
      if (context.mounted) {
        showMessage(context, PlusController.readableError(error));
      }
      return;
    }
    final json = const JsonEncoder.withIndent('  ').convert(data);
    final saved = await saveExport(json);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your data is ready'),
        content: Text(
          '${saved ?? 'The file could not be saved on this device.'}\n\n'
          'You can also copy the JSON to paste it anywhere you like.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: json));
              if (context.mounted) {
                Navigator.pop(context);
                showMessage(context, 'Copied to the clipboard');
              }
            },
            child: const Text('Copy JSON'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    if (controller.isDemo) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('This is the demo'),
          content: const Text(
            'The demo has no account to delete. Leaving it discards the sample data. '
            'Signed-in customers can permanently delete their account and data from this screen.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Leave demo'),
            ),
          ],
        ),
      );
      if (leave == true) onExit?.call();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _DeleteAccountDialog(email: controller.snapshot!.profile.email),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final result = await controller.deleteAccount();
      if (!context.mounted) return;
      final signInRemoved = result['sign_in_removed'] == true;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Account deleted'),
          content: Text(
            signInRemoved
                ? 'Your vehicles, estimates, history, photos and receipts have been permanently removed.'
                : 'Your vehicles, estimates, history, photos and receipts have been permanently removed. '
                      'Signing in again with the same email starts a new, empty account.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      onAccountDeleted?.call();
    } catch (error) {
      if (context.mounted) {
        showMessage(context, PlusController.readableError(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot;
      if (snapshot == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: const Center(child: Text('Sign in to view your settings.')),
        );
      }
      final theme = Theme.of(context);
      final demo = controller.isDemo;
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
                demo
                    ? 'Demo session · sample data that resets when you leave.'
                    : 'To change your email, sign in with the new address. Your email is how shops reach you and how you sign in.',
                style: theme.textTheme.bodySmall,
              ),
              const SectionHeading('Notifications'),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.mark_email_unread_outlined),
                  title: const Text('Email me about updates'),
                  subtitle: const Text(
                    'Shop replies, ready estimates, confirmed times and due reminders. Activity in the app is always kept.',
                  ),
                  value: snapshot.profile.emailUpdates,
                  onChanged: (value) => runAction(
                    context,
                    controller,
                    () => controller.repository.setEmailUpdates(value),
                    success: value ? 'Email updates on' : 'Email updates off',
                  ),
                ),
              ),
              const SectionHeading('Connections'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      _CalendarConnectionTile(controller: controller),
                      const Divider(indent: 16, endIndent: 16),
                      const ListTile(
                        enabled: false,
                        leading: Icon(
                          Icons.mail_outline,
                          color: Color(0xFFEA4335),
                        ),
                        title: Text('Gmail'),
                        subtitle: Text(
                          'Car-service appointments, estimates and receipts\nComing soon · not available in this version',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SectionHeading('Profile'),
              Text(
                'Shops see these details only when you choose to share a request.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              ProfileForm(
                key: ValueKey(snapshot.profile.id),
                controller: controller,
                inline: true,
                onSaved: () => showMessage(context, 'Profile saved'),
              ),
              if (onExit != null) ...[
                const SectionHeading('Session'),
                OutlinedButton.icon(
                  onPressed: () => _confirmExit(context),
                  icon: const Icon(Icons.logout, size: 19),
                  label: Text(demo ? 'Leave demo' : 'Sign out'),
                ),
              ],
              const SectionHeading('Your data'),
              Text(
                'Download a copy of everything in your account as a JSON file: profile, vehicles, estimates, requests, service history, shops and reminders.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _exportData(context),
                icon: const Icon(Icons.download_outlined, size: 19),
                label: const Text('Download my data'),
              ),
              const SectionHeading('Legal & support'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.privacy_tip_outlined),
                      title: const Text('Privacy policy'),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => openExternal(context, privacyPolicyUrl),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.gavel_outlined),
                      title: const Text('Terms of use'),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => openExternal(context, termsOfUseUrl),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.code_outlined),
                      title: const Text('Open-source licenses'),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: 'Estimoto +',
                        applicationVersion: PlusBuildInfo.label,
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.support_agent_outlined),
                      title: const Text('Contact support'),
                      subtitle: const Text(supportEmail),
                      onTap: () => openSupportEmail(context, supportEmail),
                    ),
                  ],
                ),
              ),
              const SectionHeading('Delete account'),
              Text(
                'Permanently removes your profile, vehicles, estimates and photos, requests, service history and receipts, saved shops and reminders. Open shop requests are cancelled first. This cannot be undone.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(color: theme.colorScheme.error),
                ),
                onPressed: () => _confirmDelete(context),
                icon: const Icon(Icons.delete_forever_outlined, size: 19),
                label: const Text('Delete my account'),
              ),
              const SectionHeading('About'),
              Text(PlusBuildInfo.label, style: theme.textTheme.bodyMedium),
              if (PlusBuildInfo.sourceSha.isNotEmpty)
                Text(
                  'Source ${PlusBuildInfo.sourceSha.substring(0, 7)}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Google Calendar through Nango: shows the real connection state and opens
/// the calendar screen, instead of a label that could never be tapped.
class _CalendarConnectionTile extends StatelessWidget {
  const _CalendarConnectionTile({required this.controller});
  final PlusController controller;

  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: controller.repository.getCalendarStatus(),
    builder: (context, snapshot) {
      final data = snapshot.data;
      final status = data == null ? 'loading' : textOf(data, 'status');
      final configured = data?['configured'] == true;
      final subtitle = switch (status) {
        'loading' => 'Google Calendar · Checking…',
        'connected' => 'Google Calendar · Connected',
        'connecting' => 'Google Calendar · Finish connecting',
        'reconnect_required' => 'Google Calendar · Reconnect needed',
        'unavailable' => 'Google Calendar · Not available in this version',
        _ => 'Google Calendar · Not connected',
      };
      return ListTile(
        leading: Icon(
          Icons.calendar_month_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: const Text('Nango'),
        subtitle: Text(subtitle),
        trailing: configured ? const Icon(Icons.chevron_right) : null,
        enabled: status != 'loading',
        onTap: configured ? () => openCalendar(context, controller) : null,
      );
    },
  );
}

/// Typed confirmation keeps a stray tap from erasing an account.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.email});
  final String email;
  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  static const phrase = 'DELETE';
  final input = TextEditingController();
  bool get matches => input.text.trim().toUpperCase() == phrase;

  @override
  void initState() {
    super.initState();
    input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Delete your account?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Everything saved for ${widget.email} will be erased and cannot be recovered. '
          'Download your data first if you want to keep a copy.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: input,
          autofocus: true,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Type $phrase to confirm',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Keep my account'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
        onPressed: matches ? () => Navigator.pop(context, true) : null,
        child: const Text('Delete permanently'),
      ),
    ],
  );
}
