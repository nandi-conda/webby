// Small site icons (favicons) for lists of saved pages.

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

/// The favicon of [url]'s site, fetched as a PNG from Google's favicon service by host name
/// (the way OneTab shows its lists). A letter tile stands in while it loads or when there is none.
class SiteIcon extends StatelessWidget {
  const SiteIcon(this.url, {super.key, this.size = 16});

  final String url;
  final double size;

  /// Off in widget tests, which have no network.
  static bool fetch = true;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(url);
    final host = uri == null || !(uri.isScheme('http') || uri.isScheme('https')) ? '' : uri.host;
    final fallback = _LetterTile(host: host, size: size);
    if (!fetch || host.isEmpty) return fallback;
    return Image.network(
      'https://www.google.com/s2/favicons?domain=${Uri.encodeComponent(host)}&sz=${(size * 2).round()}',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, sync) => frame == null ? fallback : child,
      errorBuilder: (context, error, stack) => fallback,
    );
  }
}

class _LetterTile extends StatelessWidget {
  const _LetterTile({required this.host, required this.size});

  final String host;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final name = host.startsWith('www.') ? host.substring(4) : host;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.hover, borderRadius: BorderRadius.circular(3)),
      child: name.isEmpty
          ? Icon(Icons.public, size: size * 0.75, color: c.textDim)
          : Text(
              name[0].toUpperCase(),
              style: TextStyle(fontSize: size * 0.62, height: 1, fontWeight: FontWeight.w600, color: c.textDim),
            ),
    );
  }
}
