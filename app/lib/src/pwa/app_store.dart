import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'manifest.dart';

/// An installed web app: what its launcher runs and where its files are.
class InstalledApp {
  const InstalledApp({
    required this.slug,
    required this.id,
    required this.name,
    required this.startUrl,
    required this.scope,
    required this.manifestUrl,
    this.iconPath,
    this.themeColor,
    this.description = '',
  });

  /// File-name-safe key, unique per app id.
  final String slug;
  final String id;
  final String name;
  final String startUrl;
  final String scope;
  final String manifestUrl;
  final String? iconPath;
  final String? themeColor;
  final String description;

  bool inScope(Uri url) {
    final s = Uri.parse(scope);
    return sameOrigin(url, s) && url.path.startsWith(s.path);
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'startUrl': startUrl,
        'scope': scope,
        'manifestUrl': manifestUrl,
        if (iconPath != null) 'icon': iconPath,
        if (themeColor != null) 'themeColor': themeColor,
        if (description.isNotEmpty) 'description': description,
      };

  static InstalledApp? fromJson(String slug, Object? json) {
    if (json is! Map || json['id'] is! String || json['startUrl'] is! String) return null;
    return InstalledApp(
      slug: slug,
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      startUrl: json['startUrl'] as String,
      scope: json['scope'] as String? ?? json['startUrl'] as String,
      manifestUrl: json['manifestUrl'] as String? ?? '',
      iconPath: json['icon'] as String?,
      themeColor: json['themeColor'] as String?,
      description: json['description'] as String? ?? '',
    );
  }
}

/// Turns downloaded icon bytes into PNG bytes (the app does this with dart:ui); null when they can't be decoded.
typedef IconToPng = Future<Uint8List?> Function(Uint8List bytes);

/// Installed web apps: one folder per app under `${XDG_DATA_HOME:-~/.local/share}/webby/apps/` (app.json and the
/// icon) and a `<app id>.desktop` launcher in `${XDG_DATA_HOME}/applications/` that runs `webby --app=<url>`.
class AppStore extends ChangeNotifier {
  AppStore({String? dataHome, Map<String, String>? environment, String? executable})
      : _env = environment ?? Platform.environment,
        _executable = executable ?? Platform.resolvedExecutable,
        _dataHome = dataHome ?? _defaultDataHome(environment ?? Platform.environment);

  static final AppStore instance = AppStore();

  final Map<String, String> _env;
  final String _executable;
  final String _dataHome;

  static String _defaultDataHome(Map<String, String> env) {
    final xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    return '${env['HOME'] ?? '.'}/.local/share';
  }

  Directory get appsDir => Directory('$_dataHome/webby/apps');
  Directory get applicationsDir => Directory('$_dataHome/applications');
  File desktopFile(String slug) => File('${applicationsDir.path}/${appIdFor(slug)}.desktop');

  /// The app's own application id, which its window uses as Wayland app id and X11 WM_CLASS (the Flutter runner reads
  /// WEBBY_APP_ID, see conda/webby/window_icon.inc), so docks show it apart from webby, with its launcher's icon.
  static String appIdFor(String slug) => 'dev.webby.WebApp-$slug';

  /// What the app's window needs to look like the app: its id, name and icon (read by the Flutter runner).
  static Map<String, String> windowEnvironment(InstalledApp app) => {
        'WEBBY_APP_ID': appIdFor(app.slug),
        'WEBBY_APP_NAME': app.name,
        if (app.iconPath != null) 'WEBBY_APP_ICON': app.iconPath!,
      };

  /// This process's environment minus the app-window variables, so a browser window started from an app is webby.
  Map<String, String> get _browserEnvironment =>
      {for (final e in _env.entries) if (!e.key.startsWith('WEBBY_APP_')) e.key: e.value};

  /// A file-name-safe key for an app id: its host plus a short hash of the whole id.
  static String slugFor(String id) {
    final uri = Uri.tryParse(id);
    final host = (uri?.host ?? '').replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-');
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(id)) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return '${host.isEmpty ? 'app' : host}-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  List<InstalledApp> get apps {
    if (!appsDir.existsSync()) return const [];
    final apps = <InstalledApp>[];
    for (final dir in appsDir.listSync().whereType<Directory>()) {
      final file = File('${dir.path}/app.json');
      if (!file.existsSync()) continue;
      try {
        final app = InstalledApp.fromJson(dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty), jsonDecode(file.readAsStringSync()));
        if (app != null) apps.add(app);
      } catch (_) {}
    }
    apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return apps;
  }

  InstalledApp? byId(String id) {
    final slug = slugFor(id);
    for (final app in apps) {
      if (app.slug == slug) return app;
    }
    return null;
  }

  /// The installed app whose start URL is [url] (how `--app=<url>` finds its scope), else one whose scope has it.
  InstalledApp? forUrl(Uri url) {
    final all = apps;
    for (final app in all) {
      if (app.startUrl == url.toString()) return app;
    }
    InstalledApp? best;
    for (final app in all) {
      if (app.inScope(url) && (best == null || app.scope.length > best.scope.length)) best = app;
    }
    return best;
  }

  /// The command that starts webby: the conda `bin/webby` wrapper when there is one, else this executable with the
  /// Ladybird prefix it was started with.
  List<String> get launchCommand {
    final exe = File(_executable);
    final wrapper = File('${exe.parent.parent.parent.path}/bin/webby');
    if (exe.parent.path.endsWith('/lib/webby') && wrapper.existsSync()) return [wrapper.path];
    final prefix = _env['WEBBY_LADYBIRD_PREFIX'];
    return [
      if (prefix != null && prefix.isNotEmpty) ...['env', 'WEBBY_LADYBIRD_PREFIX=$prefix'],
      _executable,
    ];
  }

  /// Starts [app] in its own window.
  Future<void> launch(InstalledApp app) => Process.start(
        launchCommand.first,
        [...launchCommand.skip(1), '--app=${app.startUrl}'],
        environment: {..._browserEnvironment, ...windowEnvironment(app)},
        includeParentEnvironment: false,
        mode: ProcessStartMode.detached,
      );

  /// Opens [url] in a normal browser window.
  Future<void> openInBrowser(String url) => Process.start(
        launchCommand.first,
        [...launchCommand.skip(1), url],
        environment: _browserEnvironment,
        includeParentEnvironment: false,
        mode: ProcessStartMode.detached,
      );

  /// Installs [manifest] as [name]: saves its icon (as PNG, or SVG as is) and writes the launcher.
  Future<InstalledApp> install(
    WebAppManifest manifest, {
    String? name,
    required IconToPng iconToPng,
    Future<(Uint8List, String)?> Function(Uri url)? download,
  }) async {
    final id = manifest.id.toString();
    final slug = slugFor(id);
    final dir = Directory('${appsDir.path}/$slug');
    await dir.create(recursive: true);

    String? iconPath;
    final icon = manifest.bestIcon;
    if (icon != null) {
      try {
        final fetched = await (download ?? _download)(icon.src);
        if (fetched != null) {
          final (bytes, contentType) = fetched;
          final svg = icon.isSvg || contentType.contains('svg');
          final out = svg ? bytes : await iconToPng(bytes);
          if (out != null) {
            final file = File('${dir.path}/icon.${svg ? 'svg' : 'png'}');
            await file.writeAsBytes(out);
            iconPath = file.path;
          }
        }
      } catch (_) {
        // No icon: the launcher falls back to webby's own.
      }
    }

    final app = InstalledApp(
      slug: slug,
      id: id,
      name: (name ?? '').trim().isNotEmpty ? name!.trim() : manifest.title,
      startUrl: manifest.startUrl.toString(),
      scope: manifest.scope.toString(),
      manifestUrl: manifest.manifestUrl.toString(),
      iconPath: iconPath,
      themeColor: manifest.themeColor,
      description: manifest.description,
    );
    await File('${dir.path}/app.json').writeAsString(const JsonEncoder.withIndent('  ').convert(app.toJson()));
    await _writeDesktopFile(app, manifest.description);
    notifyListeners();
    return app;
  }

  Future<void> uninstall(InstalledApp app) async {
    // Launchers from before app ids were webby-app-<slug>.desktop.
    for (final launcher in [desktopFile(app.slug), File('${applicationsDir.path}/webby-app-${app.slug}.desktop')]) {
      if (launcher.existsSync()) await launcher.delete();
    }
    final dir = Directory('${appsDir.path}/${app.slug}');
    if (dir.existsSync()) await dir.delete(recursive: true);
    _refreshDesktopDatabase();
    notifyListeners();
  }

  /// The launcher for [app] (Desktop Entry spec 1.5).
  String desktopEntry(InstalledApp app, [String description = '']) {
    final command = launchCommand;
    final exec = [
      'env',
      for (final e in windowEnvironment(app).entries) '${e.key}=${e.value}',
      ...(command.first == 'env' ? command.skip(1) : command),
      '--app=${app.startUrl}',
    ].map(_quoteExecArg).join(' ');
    return [
      '[Desktop Entry]',
      'Type=Application',
      'Version=1.5',
      'Name=${_escape(app.name)}',
      if (description.isNotEmpty) 'Comment=${_escape(description)}',
      'Exec=$exec',
      'Icon=${app.iconPath ?? 'dev.webby.webby'}',
      'Terminal=false',
      'Categories=Network;WebApps;',
      'StartupNotify=true',
      'StartupWMClass=${appIdFor(app.slug)}',
      'X-Webby-App-Id=${_escape(app.id)}',
      '',
    ].join('\n');
  }

  Future<void> _writeDesktopFile(InstalledApp app, String description) async {
    await applicationsDir.create(recursive: true);
    final file = desktopFile(app.slug);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(desktopEntry(app, description));
    try {
      await Process.run('chmod', ['755', tmp.path]);
    } catch (_) {}
    await tmp.rename(file.path);
    final old = File('${applicationsDir.path}/webby-app-${app.slug}.desktop');
    if (old.existsSync()) await old.delete();
    _refreshDesktopDatabase();
  }

  /// Rewrites every installed app's launcher, so launchers follow webby's install path and launcher format.
  Future<void> refreshLaunchers() async {
    for (final app in apps) {
      try {
        await _writeDesktopFile(app, app.description);
      } catch (_) {}
    }
  }

  void _refreshDesktopDatabase() {
    // Most desktops watch the folder anyway; this just makes it quicker where the tool exists.
    Process.run('update-desktop-database', [applicationsDir.path]).catchError((_) => ProcessResult(0, 0, '', ''));
  }

  static String _escape(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('\n', '\\n').replaceAll('\r', '\\r').replaceAll('\t', '\\t');

  /// Quotes one Exec argument: reserved characters need double quotes, and `%` is doubled since it starts field codes.
  static String _quoteExecArg(String arg) {
    var a = arg.replaceAll('%', '%%');
    if (RegExp(r'''[\s"'\\><~|&;$*?#()`]''').hasMatch(a)) {
      a = '"${a.replaceAllMapped(RegExp(r'[\\"`$]'), (m) => '\\${m[0]}')}"';
    }
    // The spec's string escaping turns each backslash into two once more.
    return a.replaceAll('\\', '\\\\');
  }

  static Future<(Uint8List, String)?> _download(Uri url) async {
    if (url.isScheme('data')) {
      final data = UriData.fromUri(url);
      return (data.contentAsBytes(), data.mimeType);
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'webby');
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > 4 << 20) return null;
      }
      return (builder.takeBytes(), response.headers.contentType?.mimeType ?? '');
    } finally {
      client.close(force: true);
    }
  }
}
