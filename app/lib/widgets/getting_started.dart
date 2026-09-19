import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';

/// Three-step checklist for a new garage, shown until every step is done or
/// the customer dismisses it. Dismissal is remembered per account on this
/// device so a returning customer is not nagged.
class GettingStartedCard extends StatefulWidget {
  const GettingStartedCard({
    super.key,
    required this.controller,
    required this.onAddVehicle,
    required this.onEditProfile,
    required this.onStartEstimate,
  });
  final PlusController controller;
  final VoidCallback onAddVehicle, onEditProfile, onStartEstimate;

  static const storeName = 'getting_started_dismissed';

  static bool profileComplete(PlusSnapshot snapshot) =>
      snapshot.profile.name.trim().isNotEmpty &&
      snapshot.profile.postalCode.trim().isNotEmpty;
  static bool hasVehicle(PlusSnapshot snapshot) => snapshot.vehicles.isNotEmpty;
  static bool hasActivity(PlusSnapshot snapshot) =>
      snapshot.estimates.isNotEmpty || snapshot.requests.isNotEmpty;
  static bool complete(PlusSnapshot snapshot) =>
      profileComplete(snapshot) &&
      hasVehicle(snapshot) &&
      hasActivity(snapshot);

  @override
  State<GettingStartedCard> createState() => _GettingStartedCardState();
}

class _GettingStartedCardState extends State<GettingStartedCard> {
  bool? dismissed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.controller.snapshot?.profile.id;
    final value = id == null
        ? null
        : await widget.controller.localStore.read(
            id,
            GettingStartedCard.storeName,
          );
    if (mounted) setState(() => dismissed = value == 'true');
  }

  Future<void> _dismiss() async {
    setState(() => dismissed = true);
    final id = widget.controller.snapshot?.profile.id;
    if (id != null) {
      await widget.controller.localStore.write(
        id,
        GettingStartedCard.storeName,
        'true',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.controller.snapshot;
    if (snapshot == null ||
        dismissed != false ||
        GettingStartedCard.complete(snapshot)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final steps = [
      (
        'Add your first vehicle',
        'Year, make and model is enough to begin.',
        GettingStartedCard.hasVehicle(snapshot),
        widget.onAddVehicle,
      ),
      (
        'Complete your profile',
        'Your name and ZIP code let shops near you reply.',
        GettingStartedCard.profileComplete(snapshot),
        widget.onEditProfile,
      ),
      (
        'Start an estimate or request',
        'Photograph damage for a PDR or collision estimate, or ask a shop for help.',
        GettingStartedCard.hasActivity(snapshot),
        widget.onStartEstimate,
      ),
    ];
    final done = steps.where((step) => step.$3).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Getting started · $done of ${steps.length}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Hide getting started',
                  onPressed: _dismiss,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
            for (final step in steps)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  step.$3 ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: step.$3
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  step.$1,
                  style: step.$3
                      ? TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : null,
                ),
                subtitle: step.$3 ? null : Text(step.$2),
                trailing: step.$3
                    ? null
                    : const Icon(Icons.chevron_right, size: 20),
                onTap: step.$3 ? null : step.$4,
              ),
          ],
        ),
      ),
    );
  }
}
