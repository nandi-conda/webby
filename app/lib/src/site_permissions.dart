// Per-site permissions, the way Chrome keeps them: each site (origin) is asked once whether it may use a feature such
// as the location, and the answer is remembered until changed in the site settings panel (the address bar's tune
// icon). Requests come from the engine (see webby_view_permission_request in webby_ffi.h).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

import 'bindings.dart';
import 'incognito.dart';

enum PermissionSetting { ask, allow, block }

/// A permission sites can ask for: its engine name, how the site settings panel names it, and how the prompt words
/// the request ("example.com wants to …").
class SitePermissionKind {
  const SitePermissionKind(this.name, this.label, this.request, this.icon);

  final String name;
  final String label;
  final String request;
  final IconData icon;

  static const location = SitePermissionKind('geolocation', 'Location', 'Know your location', Icons.location_on_outlined);

  static const notifications =
      SitePermissionKind('notifications', 'Notifications', 'Show notifications', Icons.notifications_outlined);

  static const microphone = SitePermissionKind('microphone', 'Microphone', 'Use your microphones', Icons.mic_none);

  static const all = [location, microphone, notifications];

  static SitePermissionKind? named(String name) => all.where((k) => k.name == name).firstOrNull;
}

/// The remembered answers, by origin then permission name.
///
/// Stored as JSON in `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<WEBBY_PROFILE|default>/site_permissions.json`
/// (or $WEBBY_SITE_PERMISSIONS_FILE), written through a temporary file on every change.
class SitePermissionStore extends ChangeNotifier {
  SitePermissionStore(this.file) {
    _load();
  }

  static SitePermissionStore? _instance;
  static SitePermissionStore get instance => _instance ??= SitePermissionStore(defaultFile());

  static File defaultFile() {
    final env = Platform.environment;
    final override = env['WEBBY_SITE_PERMISSIONS_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final xdg = env['XDG_DATA_HOME'];
    final dataHome = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '/tmp'}/.local/share';
    final name = env['WEBBY_PROFILE'] ?? '';
    // Profile names become directory names (same rule as bookmarks and the password vault).
    final profile = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
    return File('$dataHome/webby/profiles/$profile/site_permissions.json');
  }

  final File file;
  final Map<String, Map<String, PermissionSetting>> _sites = {};

  void _load() {
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final sites = json['sites'] as Map<String, Object?>? ?? const {};
      for (final MapEntry(key: origin, value: permissions) in sites.entries) {
        if (permissions is! Map<String, Object?>) continue;
        for (final MapEntry(key: name, value: value) in permissions.entries) {
          final setting = PermissionSetting.values.where((s) => s.name == value).firstOrNull;
          if (setting != null && setting != PermissionSetting.ask) (_sites[origin] ??= {})[name] = setting;
        }
      }
    } catch (error) {
      debugPrint('webby: could not read ${file.path}: $error');
    }
  }

  void _save() {
    // An incognito window starts from the profile's answers but keeps its own changes to itself.
    if (Incognito.active) return;
    try {
      final directory = file.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final contents = const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'sites': {
          for (final MapEntry(key: origin, value: permissions) in _sites.entries)
            origin: {for (final MapEntry(key: name, value: setting) in permissions.entries) name: setting.name},
        },
      });
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(contents, flush: true);
      temp.renameSync(file.path);
    } catch (error) {
      debugPrint('webby: could not save ${file.path}: $error');
    }
  }

  PermissionSetting get(String origin, String permission) => _sites[origin]?[permission] ?? PermissionSetting.ask;

  void set(String origin, String permission, PermissionSetting setting) {
    if (get(origin, permission) == setting) return;
    if (setting == PermissionSetting.ask) {
      _sites[origin]?.remove(permission);
      if (_sites[origin]?.isEmpty ?? false) _sites.remove(origin);
    } else {
      (_sites[origin] ??= {})[permission] = setting;
    }
    _save();
    notifyListeners();
  }

  /// Forgets every answer [origin] got.
  void reset(String origin) {
    if (_sites.remove(origin) == null) return;
    _save();
    notifyListeners();
  }

  bool hasSettings(String origin) => _sites[origin]?.isNotEmpty ?? false;
}

/// The origin ("https://example.com") of [url], or null for pages without one worth keeping settings for.
String? originOf(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) return null;
  return uri.origin;
}

/// One view's permission requests: answered at once from [SitePermissionStore] or a "this time" grant, otherwise
/// left in [request] for the prompt.
class PagePermissions {
  PagePermissions._(this._request, this._respond);

  @visibleForTesting
  PagePermissions.withFunctions(this._request, this._respond);

  /// Null with a runtime that predates site permissions.
  static PagePermissions? of(WebbyBindings bindings) {
    final lib = bindings.library;
    if (!lib.providesSymbol('webby_view_permission_request')) return null;
    return PagePermissions._(
      lib.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>(
          'webby_view_permission_request'),
      lib.lookupFunction<Void Function(ViewPtr, Uint64, Int32), void Function(ViewPtr, int, int)>(
          'webby_view_permission_respond'),
    );
  }

  final Pointer<Utf8> Function(ViewPtr) _request;
  final void Function(ViewPtr, int, int) _respond;

  /// The request waiting for the user, or null.
  PermissionRequest? request;
  String _json = '';

  /// "Allow this time" answers, by "origin permission"; they last as long as the tab. The tab shares its set.
  Set<String> allowedThisTime = {};

  /// Call when the view's state changes. Returns whether [request] changed.
  bool check(ViewPtr view) {
    final previous = request;
    // Answering one request can bring up the next one at once.
    for (var json = _request(view).toDartString(); json != _json; json = _request(view).toDartString()) {
      _json = json;
      request = null;
      if (json.isEmpty) break;
      final parsed = PermissionRequest.fromJson(jsonDecode(json) as Map<String, Object?>);
      final setting = allowedThisTime.contains('${parsed.origin} ${parsed.permission}')
          ? PermissionSetting.allow
          : SitePermissionStore.instance.get(parsed.origin, parsed.permission);
      // Permissions this browser doesn't know how to ask about are refused.
      if (setting == PermissionSetting.ask && SitePermissionKind.named(parsed.permission) != null) {
        request = parsed;
        break;
      }
      _respond(view, parsed.id, setting == PermissionSetting.allow ? 1 : 0);
    }
    return !identical(previous, request);
  }

  /// Answers [request]. [remember] keeps the answer for the site; an allow without it lasts for this tab.
  void answer(ViewPtr view, {required bool allow, required bool remember}) {
    final pending = request;
    if (pending == null) return;
    if (remember) {
      SitePermissionStore.instance
          .set(pending.origin, pending.permission, allow ? PermissionSetting.allow : PermissionSetting.block);
    } else if (allow) {
      allowedThisTime.add('${pending.origin} ${pending.permission}');
    }
    _respond(view, pending.id, allow ? 1 : 0);
  }

  /// A recreated view (a discarded tab coming back) starts with nothing waiting.
  void reset() {
    request = null;
    _json = '';
  }
}

class PermissionRequest {
  const PermissionRequest({required this.id, required this.permission, required this.origin});

  factory PermissionRequest.fromJson(Map<String, Object?> json) => PermissionRequest(
        id: (json['id'] as num?)?.toInt() ?? 0,
        permission: json['permission'] as String? ?? '',
        origin: json['origin'] as String? ?? '',
      );

  final int id;
  final String permission;
  final String origin;
}
