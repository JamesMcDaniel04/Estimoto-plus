import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../theme.dart';
import 'common.dart';

/// Anonymous public media. The model accepts only published provider routes
/// reviewed local artwork and Commons files; no customer credentials are sent.
class ShopMediaThumbnail extends StatelessWidget {
  const ShopMediaThumbnail({super.key, required this.provider, this.size = 76});
  final ProviderProfile provider;
  final double size;

  Widget fallback(BuildContext context) => Semantics(
    label: 'Shop image unavailable',
    child: Center(
      key: const Key('shop-media-fallback'),
      child: Icon(
        provider.kind == 'technician'
            ? Icons.handyman_outlined
            : Icons.storefront_outlined,
        size: 28,
        color: context.plus.muted,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final media = provider.media;
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          // Artwork is authored for a fixed dark or white backdrop in either
          // mode; only the neutral photo backdrop follows the theme.
          color: media?.darkBackground == true
              ? PlusColors.ink
              : media?.kind == 'logo'
              ? Colors.white
              : context.plus.canvas,
          child: media == null
              ? fallback(context)
              : Padding(
                  padding: media.kind == 'logo'
                      ? const EdgeInsets.all(6)
                      : EdgeInsets.zero,
                  child: Image.network(
                    media.url.toString(),
                    // A recycled listing must never show its previous image.
                    key: ValueKey(media.url),
                    fit: media.kind == 'logo' ? BoxFit.contain : BoxFit.cover,
                    width: size,
                    height: size,
                    cacheWidth: 320,
                    semanticLabel: '${provider.name} ${media.kind}',
                    frameBuilder: (context, child, frame, synchronous) =>
                        frame == null ? fallback(context) : child,
                    errorBuilder: (context, error, stack) =>
                        fallback(context),
                  ),
                ),
        ),
      ),
    );
  }
}

class ShopMediaCredit extends StatelessWidget {
  const ShopMediaCredit({super.key, required this.media});
  final ProviderMedia media;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.info_outline, size: 17),
    label: Text(media.kind == 'logo' ? 'Logo credit' : 'Photo credit'),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(media.kind == 'logo' ? 'Logo credit' : 'Photo credit'),
        content: SingleChildScrollView(
          child: SelectableText(media.attribution),
        ),
        actions: [
          TextButton(
            onPressed: () => openExternal(context, media.sourceUrl.toString()),
            child: const Text('View image source'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}
