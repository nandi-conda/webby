import 'dart:convert';

/// One entry of a manifest's `icons`.
class ManifestIcon {
  const ManifestIcon({required this.src, this.sizes = const [], this.type = '', this.purpose = 'any'});

  final Uri src;

  /// Edge lengths from `sizes` (`48x48 96x96` → [48, 96]); 0 stands for `any` (a scalable icon).
  final List<int> sizes;
  final String type;
  final String purpose;

  bool get isSvg => type.contains('svg') || src.path.toLowerCase().endsWith('.svg');
  bool get isPng => type.contains('png') || src.path.toLowerCase().endsWith('.png');
  int get largest => sizes.isEmpty ? 0 : sizes.reduce((a, b) => a > b ? a : b);
}

/// The parts of a web app manifest (https://www.w3.org/TR/appmanifest/) webby uses, with URLs resolved.
class WebAppManifest {
  const WebAppManifest({
    required this.manifestUrl,
    required this.id,
    required this.name,
    required this.startUrl,
    required this.scope,
    this.shortName = '',
    this.description = '',
    this.display = 'browser',
    this.themeColor,
    this.backgroundColor,
    this.icons = const [],
    this.categories = const [],
  });

  final Uri manifestUrl;

  /// The app's identity (`id`, else the start URL), as the spec defines it.
  final Uri id;
  final String name;
  final String shortName;
  final String description;
  final Uri startUrl;
  final Uri scope;
  final String display;
  final String? themeColor;
  final String? backgroundColor;
  final List<ManifestIcon> icons;
  final List<String> categories;

  /// What to call the app: [name], else [shortName].
  String get title => name.isNotEmpty ? name : shortName;

  /// Whether [url] belongs to the app (same origin and under [scope]'s path).
  bool inScope(Uri url) => sameOrigin(url, scope) && url.path.startsWith(scope.path);

  /// The icon to use for a desktop launcher: PNG over SVG over anything else, `any` purpose over `maskable`, then the
  /// one closest to 256 px (bigger beats smaller).
  ManifestIcon? get bestIcon {
    if (icons.isEmpty) return null;
    int score(ManifestIcon icon) {
      var s = 0;
      if (icon.isPng) {
        s += 4000;
      } else if (icon.isSvg) {
        s += 3000;
      }
      if (icon.purpose.split(RegExp(r'\s+')).contains('any')) s += 2000;
      final size = icon.isSvg ? 256 : icon.largest;
      s += size >= 256 ? 1000 - (size - 256).clamp(0, 999) ~/ 4 : size * 2;
      return s;
    }

    return (icons.toList()..sort((a, b) => score(b) - score(a))).first;
  }

  /// Parses [text], the manifest fetched from [manifestUrl] for the page at [documentUrl]. Returns null when it isn't
  /// a JSON object or names no app.
  static WebAppManifest? parse(String text, {required Uri manifestUrl, required Uri documentUrl}) {
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (json is! Map<String, Object?>) return null;

    String str(String key) => json is Map && json[key] is String ? (json[key] as String).trim() : '';
    Uri? resolve(String value) {
      if (value.isEmpty) return null;
      try {
        return manifestUrl.resolve(value);
      } on FormatException {
        return null;
      }
    }

    final name = str('name');
    final shortName = str('short_name');
    if (name.isEmpty && shortName.isEmpty) return null;

    // start_url must be same-origin with the document, else the document's URL is used.
    var startUrl = resolve(str('start_url'));
    if (startUrl == null || !sameOrigin(startUrl, documentUrl)) startUrl = documentUrl;
    startUrl = startUrl.removeFragment();

    // scope must contain start_url, else it's start_url's directory.
    final defaultScope = startUrl.resolve('.').replace(query: '');
    var scope = resolve(str('scope'));
    if (scope == null || !sameOrigin(scope, startUrl) || !startUrl.path.startsWith(scope.path)) scope = defaultScope;
    scope = Uri(scheme: scope.scheme, host: scope.host, port: scope.port, path: scope.path);

    var id = startUrl;
    final idValue = str('id');
    if (idValue.isNotEmpty) {
      final resolved = Uri.tryParse(idValue) == null ? null : startUrl.resolve(idValue).removeFragment();
      if (resolved != null && sameOrigin(resolved, startUrl)) id = resolved;
    }

    final icons = <ManifestIcon>[];
    if (json['icons'] case final List<Object?> list) {
      for (final entry in list) {
        if (entry is! Map || entry['src'] is! String) continue;
        final src = resolve(entry['src'] as String);
        if (src == null || !(src.isScheme('http') || src.isScheme('https') || src.isScheme('data'))) continue;
        final sizes = <int>[];
        for (final size in (entry['sizes'] is String ? entry['sizes'] as String : '').split(RegExp(r'\s+'))) {
          if (size.toLowerCase() == 'any') {
            sizes.add(0);
          } else if (RegExp(r'^(\d+)[xX](\d+)$').firstMatch(size) case final m?) {
            sizes.add(int.parse(m.group(1)!));
          }
        }
        icons.add(ManifestIcon(
          src: src,
          sizes: sizes,
          type: entry['type'] is String ? (entry['type'] as String).toLowerCase() : '',
          purpose: entry['purpose'] is String ? (entry['purpose'] as String).toLowerCase() : 'any',
        ));
      }
    }

    return WebAppManifest(
      manifestUrl: manifestUrl,
      id: id,
      name: name,
      shortName: shortName,
      description: str('description'),
      startUrl: startUrl,
      scope: scope,
      display: str('display').isEmpty ? 'browser' : str('display'),
      themeColor: str('theme_color').isEmpty ? null : str('theme_color'),
      backgroundColor: str('background_color').isEmpty ? null : str('background_color'),
      icons: icons,
      categories: [
        if (json['categories'] case final List<Object?> list)
          for (final c in list)
            if (c is String) c,
      ],
    );
  }
}

bool sameOrigin(Uri a, Uri b) => a.scheme == b.scheme && a.host == b.host && a.port == b.port;
