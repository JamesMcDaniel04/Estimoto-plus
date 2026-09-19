import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../widgets/common.dart';

/// Everything a shop or the app has told the customer, newest first.
///
/// Opening the screen marks the feed read so the badge clears; a notice
/// still shows as new until the list is left. Tapping a notice jumps to the
/// tab where the underlying record lives.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.controller});
  final PlusController controller;

  static Future<void> open(BuildContext context, PlusController controller) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ActivityScreen(controller: controller),
        ),
      );

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<Json>? notices;
  Set<String> unreadOnOpen = {};
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final feed = await widget.controller.repository.listNotifications();
      final rows = rowsOf(feed, 'notifications');
      if (!mounted) return;
      setState(() {
        notices = rows;
        unreadOnOpen = rows
            .where((n) => n['read_at'] == null)
            .map((n) => n['id'] as String)
            .toSet();
        error = null;
      });
      if (unreadOnOpen.isNotEmpty) {
        await widget.controller.markNotificationsRead(all: true);
      }
    } catch (e) {
      if (mounted) setState(() => error = PlusController.readableError(e));
    }
  }

  static const _tabs = {
    'estimate': 1,
    'request': 3,
    'reminder': 0,
    'outreach': 0,
  };

  static IconData _icon(String kind) => switch (kind) {
    'estimate_ready' => Icons.receipt_long_outlined,
    'estimate_failed' => Icons.error_outline,
    'reminder_due' => Icons.alarm_outlined,
    'shop_confirmed' => Icons.event_available_outlined,
    'request_declined' || 'request_cancelled' => Icons.block_outlined,
    'request_scheduled' => Icons.event_outlined,
    'request_completed' => Icons.task_alt_outlined,
    _ => Icons.handshake_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = notices;
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: SafeArea(
        top: false,
        child: rows == null
            ? Center(
                child: error == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: EmptyState(
                          icon: Icons.cloud_off_outlined,
                          title: 'Activity is unavailable',
                          message: error!,
                          action: 'Try again',
                          onAction: _load,
                        ),
                      ),
              )
            : rows.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: EmptyState(
                  icon: Icons.notifications_none_outlined,
                  title: 'Nothing yet',
                  message:
                      'Shop replies, ready estimates, confirmed times and due reminders show up here.',
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final notice = rows[index];
                  final id = notice['id'] as String? ?? '';
                  final fresh = unreadOnOpen.contains(id);
                  final kind = textOf(notice, 'kind');
                  final tab = _tabs[textOf(notice, 'source_kind')];
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        _icon(kind),
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(
                        textOf(notice, 'title'),
                        style: fresh
                            ? const TextStyle(fontWeight: FontWeight.w700)
                            : null,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (textOf(notice, 'body').isNotEmpty)
                            Text(textOf(notice, 'body')),
                          Text(
                            relativeTime(textOf(notice, 'created_at')),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      trailing: fresh
                          ? Semantics(
                              label: 'New',
                              child: Icon(
                                Icons.circle,
                                size: 10,
                                color: theme.colorScheme.primary,
                              ),
                            )
                          : null,
                      onTap: tab == null
                          ? null
                          : () {
                              widget.controller.selectTab(tab);
                              Navigator.of(context).pop();
                            },
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// "Just now", "3 h ago", "2 d ago" or the date for anything older.
String relativeTime(String raw, {DateTime? now}) {
  final stamp = DateTime.tryParse(raw)?.toLocal();
  if (stamp == null) return '';
  final difference = (now ?? DateTime.now()).difference(stamp);
  if (difference.inMinutes < 1) return 'Just now';
  if (difference.inHours < 1) return '${difference.inMinutes} min ago';
  if (difference.inDays < 1) return '${difference.inHours} h ago';
  if (difference.inDays < 7) return '${difference.inDays} d ago';
  return dateText(raw.substring(0, 10));
}
