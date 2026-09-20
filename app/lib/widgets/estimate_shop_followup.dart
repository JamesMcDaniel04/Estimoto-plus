import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import 'shop_profile.dart';

class EstimateShopFollowUp extends StatelessWidget {
  const EstimateShopFollowUp({
    super.key,
    required this.controller,
    required this.estimate,
  });

  final PlusController controller;
  final CustomerEstimate estimate;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    if (snapshot == null || estimate.status == 'draft') {
      return const SizedBox.shrink();
    }
    final owner = snapshot.profile.id;
    final providerId = textOf(estimate.json, 'provider_id');
    // A saved name is display text, never authority to select another shop.
    final provider = providerId.isEmpty
        ? null
        : snapshot.providers
              .where((p) => p.id == providerId && !p.independent)
              .firstOrNull;
    final name = provider?.name ?? estimate.providerName;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your estimating shop',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (name.isNotEmpty) ...[const SizedBox(height: 10), Text(name)],
            const SizedBox(height: 10),
            if (provider == null)
              const Text(
                'Contact details for this shop are not available right now. Refresh your estimate to check again.',
              )
            else ...[
              Text(switch (estimate.status) {
                'ready' =>
                  'Review the quoted amount with your shop and confirm the next steps directly.',
                'approved' =>
                  'Contact your shop to confirm repair arrangements and timing.',
                _ =>
                  'For questions about delivery or review, contact the shop you selected.',
              }),
              if (provider.phone.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                SelectableText(provider.phone),
              ],
              if (provider.displayAddress.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(provider.displayAddress),
              ],
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () {
                  if (controller.isCurrentCustomer(owner)) {
                    showShopProfile(context, provider, contactOnly: true);
                  }
                },
                icon: const Icon(Icons.storefront_outlined),
                label: const Text('View shop & contact options'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
