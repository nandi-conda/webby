// Saved sessions: sets of tabs kept by name to reopen later (on quit, or "Close all tabs and save as session").

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../incognito.dart';
import 'device_tabs.dart';

/// A saved set of tabs.
class SavedSession {
  SavedSession({required this.id, required this.name, required this.savedAt, required this.tabs, this.active = 0});

  static SavedSession? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final tabs = [
      for (final tab in (json['tabs'] as List<Object?>? ?? const [])) ?DeviceTab.fromJson(tab),
    ];
    if (tabs.isEmpty) return null;
    final active = json['active'] as int? ?? 0;
    return SavedSession(
      id: id,
      name: json['name'] as String? ?? '',
      savedAt: json['savedAt'] as int? ?? 0,
      tabs: tabs,
      active: active.clamp(0, tabs.length - 1),
    );
  }

  final String id;
  String name;

  /// Seconds since the epoch.
  final int savedAt;
  final List<DeviceTab> tabs;

  /// The tab that was in front, which comes back in front.
  final int active;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'savedAt': savedAt,
    'active': active,
    'tabs': [for (final tab in tabs) tab.toJson()],
  };
}

/// Whether [url] is worth keeping in a session (not a blank tab).
bool isSessionUrl(String url) => url.isNotEmpty && url != 'about:blank';

/// The profile's saved sessions, in
/// `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<WEBBY_PROFILE|default>/sessions.json` (or $WEBBY_SESSIONS_FILE).
/// Incognito windows never save one.
class SessionStore extends ChangeNotifier {
  SessionStore(this.file) {
    _load();
  }

  static SessionStore? _instance;

  static SessionStore get instance => _instance ??= SessionStore(defaultFile());

  static File defaultFile() {
    final env = Platform.environment;
    final override = env['WEBBY_SESSIONS_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final xdg = env['XDG_DATA_HOME'];
    final dataHome = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '/tmp'}/.local/share';
    final name = env['WEBBY_PROFILE'] ?? '';
    final profile = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
    return File('$dataHome/webby/profiles/$profile/sessions.json');
  }

  final File file;
  final List<SavedSession> _sessions = [];
  bool _askOnQuit = true;
  int _idCounter = 0;

  /// Why the file couldn't be read (it was set aside), or null.
  String? loadError;

  /// Newest first.
  List<SavedSession> get sessions => List.unmodifiable(_sessions);

  /// Whether closing the window asks to save its tabs as a session.
  bool get askOnQuit => _askOnQuit;
  set askOnQuit(bool value) {
    if (value == _askOnQuit) return;
    _askOnQuit = value;
    _changed();
  }

  void _load() {
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      _askOnQuit = json['askOnQuit'] as bool? ?? true;
      for (final entry in (json['sessions'] as List<Object?>? ?? const [])) {
        final session = SavedSession.fromJson(entry);
        if (session != null) _sessions.add(session);
      }
      _sessions.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    } catch (error) {
      // Keep the unreadable file for the user rather than overwriting it on the next save.
      final aside = '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      try {
        file.renameSync(aside);
      } catch (_) {}
      loadError = 'Could not read ${file.path} ($error); it was moved to $aside.';
      _sessions.clear();
    }
  }

  void _save() {
    if (Incognito.active) return;
    final directory = file.parent;
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final contents = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'askOnQuit': _askOnQuit,
      'sessions': [for (final session in _sessions) session.toJson()],
    });
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(contents, flush: true);
    temp.renameSync(file.path);
  }

  void _changed() {
    _save();
    notifyListeners();
  }

  /// Saves [tabs] (blank ones left out) as a session called [name], or a name from the date when it's empty.
  /// [active] is the index in [tabs] of the tab in front. Returns null when there's nothing to save, or in incognito.
  SavedSession? save(List<DeviceTab> tabs, {String? name, int active = 0, DateTime? now}) {
    if (Incognito.active) return null;
    final kept = <DeviceTab>[];
    var keptActive = 0;
    for (final (i, tab) in tabs.indexed) {
      if (!isSessionUrl(tab.url)) continue;
      if (i <= active) keptActive = kept.length;
      kept.add(tab);
    }
    if (kept.isEmpty) return null;
    final time = now ?? DateTime.now();
    final trimmed = name?.trim() ?? '';
    final session = SavedSession(
      id: '${time.microsecondsSinceEpoch.toRadixString(36)}${(_idCounter++).toRadixString(36)}',
      name: trimmed.isEmpty ? defaultSessionName(time) : trimmed,
      savedAt: time.millisecondsSinceEpoch ~/ 1000,
      tabs: kept,
      active: keptActive,
    );
    _sessions.insert(0, session);
    _changed();
    return session;
  }

  void rename(SavedSession session, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == session.name || !_sessions.contains(session)) return;
    session.name = trimmed;
    _changed();
  }

  /// Takes the tab at [index] out of [session] and returns it; the session goes when its last tab does.
  DeviceTab? removeTab(SavedSession session, int index) {
    if (!_sessions.contains(session) || index < 0 || index >= session.tabs.length) return null;
    final tab = session.tabs.removeAt(index);
    if (session.tabs.isEmpty) _sessions.remove(session);
    _changed();
    return tab;
  }

  /// Puts [tab] back at [index] in [session] (undo), bringing the session back if it had gone.
  void restoreTab(SavedSession session, DeviceTab tab, int index) {
    session.tabs.insert(index.clamp(0, session.tabs.length), tab);
    if (!_sessions.contains(session)) {
      restoreDeleted(session);
    } else {
      _changed();
    }
  }

  void delete(SavedSession session) {
    if (_sessions.remove(session)) _changed();
  }

  /// Puts back a session that was just deleted (undo).
  void restoreDeleted(SavedSession session) {
    if (_sessions.contains(session)) return;
    _sessions
      ..add(session)
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    _changed();
  }

  void deleteAll() {
    if (_sessions.isEmpty) return;
    _sessions.clear();
    _changed();
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Oct 12, 14:05": the name a session gets when the user doesn't give one.
String defaultSessionName(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_months[time.month - 1]} ${time.day}, ${two(time.hour)}:${two(time.minute)}';
}
