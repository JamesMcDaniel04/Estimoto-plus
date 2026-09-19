import 'package:flutter/material.dart';
import '../plus_links.dart';
import '../domain/models.dart';
import '../state/plus_controller.dart';
import '../screens/request_sheet.dart';
import '../screens/my_shops_screen.dart';
import 'dedicated_shop_choice.dart';
import 'common.dart';
import 'workspace_widgets.dart';
import 'shop_media.dart';
import 'shop_profile.dart';
import 'google_places_attribution.dart';

String serviceModeLabel(String mode) => mode == 'mobile'
    ? 'Mobile service · provider comes to you'
    : 'Shop visit · bring your vehicle to the shop';

List<ProviderProfile> discoveryProviders(
  Json data,
  String key, {
  int limit = 30,
}) => rowsOf(data, key)
    .where((p) => p['public_visible'] != false)
    .take(limit)
    .map(ProviderProfile.fromJson)
    .toList();

class DiscoveryNotice extends StatelessWidget {
  const DiscoveryNotice(this.data, {super.key});
  final Json data;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Within 30 mi · Approximate distances',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (data['truncated'] == true)
          const Text(
            'Showing up to 30 shops, including alternatives. Refine your service to narrow results.',
          ),
        if (data['status'] == 'stale')
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Live search is unavailable. Showing saved listings; confirm current details with the shop.',
            ),
          ),
        if (data['status'] == 'unavailable')
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Live directory search is unavailable. Any nearby providers shown are a partial list.',
            ),
          ),
      ],
    ),
  );
}

class DiscoveryDetails extends StatelessWidget {
  const DiscoveryDetails(this.data, {super.key});
  final Json data;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('About these results'),
    childrenPadding: const EdgeInsets.only(bottom: 16),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Public map listings, officially checked business profiles and participating Estimoto providers. A public listing alone does not verify services. Distances are approximate straight-line distances from your ZIP center, not driving distance or mobile coverage. Confirm services and availability directly.',
      ),
      if (textOf(data, 'checked_at').isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Last checked: ${dateText(textOf(data, 'checked_at'))}'),
        ),
      for (final attribution in rowsOf(data, 'source_attributions'))
        TextButton(
          onPressed: () => openExternal(context, textOf(attribution, 'url')),
          child: Text(textOf(attribution, 'name')),
        ),
      if (data['directory_provider'] == 'google_places') ...[
        const Text(
          'Results may be suggested for your vehicle by Google Maps. Confirm the exact repair and vehicle expertise with the shop.',
        ),
        TextButton(
          onPressed: () => openExternal(context, discoveryTermsUrl),
          child: const Text('Shop search terms'),
        ),
        TextButton(
          onPressed: () => openExternal(context, discoveryPrivacyUrl),
          child: const Text('Shop search privacy'),
        ),
      ],
    ],
  );
}

class DiscoveryResults extends StatefulWidget {
  const DiscoveryResults({
    super.key,
    required this.controller,
    required this.data,
    required this.vehicleId,
    required this.postalCode,
    this.specialty,
    this.mobileOnly = false,
    this.independentSearch = false,
    this.description = '',
  });
  final PlusController controller;
  final Json data;
  final String? vehicleId, specialty;
  final String postalCode, description;
  final bool mobileOnly, independentSearch;
  @override
  State<DiscoveryResults> createState() => _DiscoveryResultsState();
}

class _DiscoveryResultsState extends WorkspaceState<DiscoveryResults> {
  @override
  PlusController get controller => widget.controller;
  List<Json> favorites = [];
  int epoch = 0;
  bool get sameSearch =>
      active &&
      controller.selectedVehicle?.id == widget.vehicleId &&
      (widget.independentSearch ||
          controller.snapshot!.profile.postalCode == widget.postalCode);
  @override
  void initState() {
    super.initState();
    loadFavorites();
  }

  @override
  void didUpdateWidget(covariant DiscoveryResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vehicleId != widget.vehicleId) {
      favorites = [];
      loadFavorites();
    }
  }

  Future<void> loadFavorites() async {
    final run = ++epoch, vehicle = widget.vehicleId;
    if (vehicle == null || !sameSearch) return;
    try {
      final value = await controller.repository.listDiscoveryFavorites(vehicle);
      if (!sameSearch || run != epoch) return;
      setState(() {
        favorites = value;
        error = null;
      });
    } catch (e) {
      if (sameSearch && run == epoch) {
        setState(
          () => error =
              'Saved shop preferences could not be loaded. Refresh the directory to try again.',
        );
      }
    }
  }

  Future<void> save(ProviderProfile provider) async {
    if (!sameSearch || busy || widget.vehicleId == null) return;
    final run = epoch;
    await perform(() async {
      final saved = await chooseDedicatedShop(
        context,
        controller,
        source: provider.source,
        sourceId: provider.sourceId,
        vehicleId: widget.vehicleId!,
        aliases: rowsOf(provider.json, 'favorite_references'),
      );
      if (saved && sameSearch && run == epoch) await loadFavorites();
    });
  }

  Future<void> saveContact(ProviderProfile provider) async {
    if (!sameSearch || provider.source == 'google_places') return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ShopEditor(
          controller: controller,
          initialContact: {
            'name': provider.name,
            'email': textOf(provider.json, 'email'),
            'phone': provider.phone,
            'address': provider.displayAddress,
            'website': textOf(provider.json, 'website'),
            'vehicle_id': widget.vehicleId,
            'notes': textOf(provider.json, 'source_url').isEmpty
                ? ''
                : 'Public listing: ${textOf(provider.json, 'source_url')}',
          },
        ),
      ),
    );
    if (!mounted || !sameSearch) return;
    openMyShops(context, controller, initialSummary: widget.description);
  }

  @override
  Widget build(BuildContext context) {
    if (!current) return const SizedBox.shrink();
    if (!sameSearch) {
      return const Text(
        'Your vehicle or service ZIP changed. Search again for current shop options.',
      );
    }
    final providers = discoveryProviders(widget.data, 'providers');
    final alternatives = discoveryProviders(
      widget.data,
      'shop_visit_alternatives',
      limit: 30 - providers.length,
    );
    Widget card(ProviderProfile provider, bool alternative) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DiscoveryProviderCard(
        provider: provider,
        vehicleMake: controller.snapshot!.vehicle(widget.vehicleId ?? '')?.make,
        favorites: favorites
            .where(
              (f) =>
                  (f['source'] == provider.source &&
                      f['source_id'] == provider.sourceId) ||
                  rowsOf(provider.json, 'favorite_references').any(
                    (alias) =>
                        alias['vehicle_id'] == widget.vehicleId &&
                        alias['specialty'] == f['specialty'] &&
                        alias['source'] == f['source'] &&
                        alias['source_id'] == f['source_id'],
                  ),
            )
            .map((f) => specialtyLabel(textOf(f, 'specialty')))
            .toList(),
        onSave: widget.vehicleId == null || busy ? null : () => save(provider),
        onSaveContact:
            provider.independent && provider.source != 'google_places'
            ? () => saveContact(provider)
            : null,
        onRequest:
            provider.requestModes.isEmpty ||
                controller.snapshot!.profile.postalCode != widget.postalCode
            ? null
            : () {
                if (!sameSearch) return;
                requestProvider(
                  context,
                  controller,
                  provider,
                  specialty: widget.specialty,
                  description: widget.description,
                  searchedVehicleId: widget.vehicleId,
                  searchedPostalCode: widget.postalCode,
                  serviceMode: alternative
                      ? 'shop_visit'
                      : widget.mobileOnly
                      ? 'mobile'
                      : null,
                );
              },
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DiscoveryNotice(widget.data),
        if (error != null) WorkspaceError(error!),
        if (providers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              widget.mobileOnly
                  ? 'No mobile provider lists coverage for this ZIP in these results. You can consider a shop visit below.'
                  : widget.data['status'] == 'ready'
                  ? 'No matching listings were returned. Try another service or check your saved ZIP.'
                  : 'Refresh the directory to check nearby options again.',
            ),
          ),
        for (final provider in providers) card(provider, false),
        if (alternatives.isNotEmpty) ...[
          const SectionHeading('Nearby shops you can visit'),
          const Text(
            'These are shop-visit alternatives. They do not list mobile coverage for this search.',
          ),
          for (final provider in alternatives) card(provider, true),
        ],
        DiscoveryDetails(widget.data),
      ],
    );
  }
}

class DiscoveryProviderCard extends StatelessWidget {
  const DiscoveryProviderCard({
    super.key,
    required this.provider,
    this.onRequest,
    this.onSave,
    this.onSaveContact,
    this.vehicleMake,
    this.favorites = const [],
  });
  final ProviderProfile provider;
  final VoidCallback? onRequest, onSave, onSaveContact;
  final String? vehicleMake;
  final List<String> favorites;
  Future<void> openProfile(BuildContext context) async {
    final action = await showShopProfile(
      context,
      provider,
      canRequest: onRequest != null,
      canSave: onSave != null,
      canSaveContact: onSaveContact != null,
      favorites: favorites,
    );
    if (!context.mounted) return;
    switch (action) {
      case ShopProfileAction.request:
        onRequest?.call();
      case ShopProfileAction.save:
        onSave?.call();
      case ShopProfileAction.saveContact:
        onSaveContact?.call();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final match = provider.json['vehicle_match'] as Map? ?? {};
    final listedMake =
        match['status'] == 'listed_make' &&
        const [
          'service:vehicle:brand',
          'official_website',
        ].contains(match['basis']) &&
        vehicleMake != null &&
        '${match['make']}'.toLowerCase() == vehicleMake!.toLowerCase();
    final suggestedMake =
        provider.source == 'google_places' &&
        match['status'] == 'search_relevance' &&
        vehicleMake != null &&
        '${match['make']}'.toLowerCase() == vehicleMake!.toLowerCase();
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(provider.name, style: Theme.of(context).textTheme.titleMedium),
        if (provider.distanceMiles != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'About ${provider.distanceMiles!.toStringAsFixed(1)} mi from your ZIP center',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            provider.independent
                ? provider.json['verification'] is Map &&
                          provider.json['verification']['status'] ==
                              'contact_confirmed'
                      ? 'Business contact details checked'
                      : provider.source == 'google_places'
                      ? 'Independent repair listing'
                      : 'Independent listing · OpenStreetMap'
                : 'Participating Estimoto provider',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        hint: 'Open shop profile',
        child: InkWell(
          key: ValueKey('shop-card-${provider.id}'),
          onTap: () => openProfile(context),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final largeText =
                        MediaQuery.textScalerOf(context).scale(17) > 23;
                    if (largeText && constraints.maxWidth < 340) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ShopMediaThumbnail(provider: provider, size: 64),
                          const SizedBox(height: 10),
                          identity,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ShopMediaThumbnail(provider: provider),
                        const SizedBox(width: 12),
                        Expanded(child: identity),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right, semanticLabel: null),
                      ],
                    );
                  },
                ),
                if (provider.displayAddress.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      provider.displayAddress,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (provider.specialties.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final service in provider.specialties)
                          StatusPill(specialtyLabel(service)),
                      ],
                    ),
                  ),
                if (listedMake)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'Listed support for ${match['make']} · confirm with the shop',
                    ),
                  ),
                if (suggestedMake)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'Suggested for your ${match['make']} · confirm services with the shop',
                    ),
                  ),
                if (provider.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(provider.description),
                  ),
                GooglePlacesAttribution(provider),
                if (provider.requestModes.contains('mobile'))
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'Lists mobile service for this ZIP · availability requires confirmation',
                    ),
                  ),
                if (favorites.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Your dedicated shop: ${favorites.join(', ')}'),
                  ),
                if (!provider.independent &&
                    provider.requestModes.isNotEmpty &&
                    onRequest != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: ValueKey('shop-request-${provider.id}'),
                        onPressed: onRequest,
                        icon: const Icon(Icons.handshake_outlined),
                        label: const Text('Request help'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
