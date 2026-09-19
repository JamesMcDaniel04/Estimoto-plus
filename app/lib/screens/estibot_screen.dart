import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/discovery_results.dart';
import '../widgets/workspace_widgets.dart';
import 'my_shops_screen.dart';
import 'history_screen.dart';
import 'calendar_screen.dart';

class EstibotScreen extends StatefulWidget {
  const EstibotScreen({super.key, required this.controller});
  final PlusController controller;
  @override
  State<EstibotScreen> createState() => _EstibotScreenState();
}

class _EstibotScreenState extends WorkspaceState<EstibotScreen> {
  @override
  PlusController get controller => widget.controller;
  final message = TextEditingController();
  final scroll = ScrollController();
  @override
  void dispose() {
    message.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> clearConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear this conversation?'),
        content: const Text(
          'Messages are only kept on this screen. Your garage, estimates and requests are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true && active) widget.controller.clearConversation();
  }

  Future<void> send([String? prompt]) async {
    if (!active) return;
    final value = prompt ?? message.text;
    if (value.trim().isEmpty || widget.controller.asking) return;
    message.clear();
    await widget.controller.ask(value);
    if (active && scroll.hasClients) {
      await scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!current) return unavailable;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            controller: scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PageHeading(
                      'A little clarity.\nThe right connection.',
                      'Understand estimates, plan routine care, find repair help, or schedule with your saved shop.',
                      trailing: widget.controller.messages.isEmpty
                          ? null
                          : PopupMenuButton<String>(
                              tooltip: 'Conversation options',
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'clear',
                                  child: Text('Clear conversation'),
                                ),
                              ],
                              onSelected: (_) => clearConversation(),
                            ),
                    ),
                    VehiclePicker(controller: widget.controller),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () =>
                              openMyShops(context, widget.controller),
                          icon: const Icon(Icons.storefront_outlined),
                          label: const Text('My shops & scheduling'),
                        ),
                        TextButton.icon(
                          onPressed: () =>
                              openCalendar(context, widget.controller),
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: const Text('Calendar'),
                        ),
                        TextButton.icon(
                          onPressed: () =>
                              openVehicleHistory(context, widget.controller),
                          icon: const Icon(Icons.history_outlined),
                          label: const Text('Service history'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('schedule-around-calendar'),
                      onPressed: () => openMyShops(context, widget.controller),
                      icon: const Icon(Icons.event_available_outlined),
                      label: const Text('Schedule around my calendar'),
                    ),
                    const SizedBox(height: 20),
                    if (widget.controller.messages.isEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: context.plus.card,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              backgroundColor: context.plus.successSoft,
                              child: Icon(
                                Icons.support_agent,
                                color: context.plus.success,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'What would you like help with?',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Choose a topic below. I can explain estimate terms and routine care, help find a technician, or prepare a scheduling request. I cannot diagnose vehicle problems.',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      for (final prompt in [
                        'Find mobile dent repair',
                        'Help me understand an estimate',
                        'How do I check tire pressure?',
                        'Help me schedule service with my shop',
                        'What is in my car’s service history?',
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: () => send(prompt),
                              style: OutlinedButton.styleFrom(
                                alignment: Alignment.centerLeft,
                                backgroundColor: context.plus.card,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Text(prompt),
                              ),
                            ),
                          ),
                        ),
                    ],
                    for (final entry in widget.controller.messages)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: Column(
                          crossAxisAlignment: entry.isUser
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            Align(
                              alignment: entry.isUser
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.all(17),
                                decoration: BoxDecoration(
                                  color: entry.isUser
                                      ? context.plus.navyCard
                                      : context.plus.card,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Text(
                                  entry.text,
                                  style: TextStyle(
                                    color: entry.isUser
                                        ? context.plus.onNavy
                                        : context.plus.ink,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ),
                            if (!entry.isUser) ...[
                              if (entry.answer!.intent == 'unmatched')
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: ActionChip(
                                    avatar: const Icon(
                                      Icons.near_me_outlined,
                                      size: 18,
                                    ),
                                    label: const Text(
                                      'Find a technician for this',
                                    ),
                                    onPressed: () =>
                                        widget.controller.selectTab(4),
                                  ),
                                ),
                              if (entry.answer!.intent == 'shop_outreach')
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: OutlinedButton.icon(
                                    onPressed: () => openMyShops(
                                      context,
                                      widget.controller,
                                      initialSummary:
                                          widget.controller.messages
                                              .where((e) => e.isUser)
                                              .lastOrNull
                                              ?.text ??
                                          '',
                                    ),
                                    icon: const Icon(Icons.event_outlined),
                                    label: const Text(
                                      'Review a scheduling request',
                                    ),
                                  ),
                                ),
                              if (entry.answer!.providers.isNotEmpty ||
                                  entry.answer!.discovery != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: DiscoveryResults(
                                    key: ObjectKey(entry),
                                    controller: widget.controller,
                                    vehicleId: entry.vehicleId,
                                    postalCode: entry.postalCode,
                                    specialty: entry.answer!.specialty,
                                    mobileOnly: entry.mobileOnly,
                                    description: entry.prompt,
                                    data: {
                                      ...?entry.answer!.discovery,
                                      'providers': entry.answer!.providers
                                          .where(
                                            (p) =>
                                                !entry.mobileOnly ||
                                                p.requestModes.contains(
                                                  'mobile',
                                                ),
                                          )
                                          .map((p) => p.json)
                                          .toList(),
                                      'shop_visit_alternatives':
                                          entry.mobileOnly
                                          ? entry.answer!.providers
                                                .where(
                                                  (p) => !p.requestModes
                                                      .contains('mobile'),
                                                )
                                                .map((p) => p.json)
                                                .toList()
                                          : <Json>[],
                                    },
                                  ),
                                ),
                              for (final video in entry.answer!.videos)
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: OutlinedButton.icon(
                                    onPressed: () => openExternal(
                                      context,
                                      textOf(video, 'url'),
                                      youtubeOnly: true,
                                    ),
                                    icon: const Icon(Icons.play_circle_outline),
                                    label: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(textOf(video, 'title')),
                                        Text(
                                          textOf(video, 'source'),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    if (widget.controller.asking)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Expanded(child: Text('Estibot is thinking…')),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Container(
          color: context.plus.card,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('assistant-message'),
                  controller: message,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => send(),
                  decoration: const InputDecoration(
                    hintText: 'Ask about estimates, care, or finding help…',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                key: const Key('assistant-send'),
                tooltip: 'Send message',
                onPressed: widget.controller.asking ? null : send,
                icon: const Icon(Icons.arrow_upward),
                style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
