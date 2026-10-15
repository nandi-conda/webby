// The window's open tabs, kept on disk as they change so they come back, asleep until selected, at the next start
// (also after Android kills the app in the background or for an update).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../incognito.dart';
import 'device_tabs.dart';
import 'sessions.dart';

/// The open tabs and which one was in front, in
/// `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<WEBBY_PROFILE|default>/open_tabs.json` (or $WEBBY_OPEN_TABS_FILE).
/// Incognito windows never save them.
class OpenTabsStore {
  OpenTabsStore(this.file);

  static OpenTabsStore? _instance;

  static OpenTabsStore get instance => _instance ??= OpenTabsStore(defaultFile());

  static OpenTabsStore? _pinned;

  /// pinned_tabs.json next to open_tabs.json: desktop's pinned tabs from before it kept all the open tabs, read once
  /// when open_tabs.json is missing.
  static OpenTabsStore get pinned =>
      _pinned ??= OpenTabsStore(File('${SessionStore.defaultFile().parent.path}/pinned_tabs.json'));

  static File defaultFile() {
    final override = Platform.environment['WEBBY_OPEN_TABS_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    return File('${SessionStore.defaultFile().parent.path}/open_tabs.json');
  }

  final File file;
  Timer? _pending;
  String _written = '';

  /// The tabs last saved, with the index of the front one and how many at the start are pinned, or null when there
  /// are none.
  ({List<DeviceTab> tabs, int active, int pinned})? read() {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final tabs = [
        for (final entry in json['tabs'] as List<Object?>? ?? const [])
          if (DeviceTab.fromJson(entry) case final tab? when isSessionUrl(tab.url)) tab,
      ];
      if (tabs.isEmpty) return null;
      final active = (json['active'] as int? ?? 0).clamp(0, tabs.length - 1);
      final pinned = (json['pinned'] as int? ?? 0).clamp(0, tabs.length);
      return (tabs: tabs, active: active, pinned: pinned);
    } catch (_) {
      return null;
    }
  }

  /// Saves [tabs] a moment later, so a burst of page changes is written once.
  void save(List<DeviceTab> tabs, int active, {int pinned = 0}) {
    if (Incognito.active) return;
    _pending?.cancel();
    _pending = Timer(const Duration(seconds: 1), () => _write(tabs, active, pinned));
  }

  /// Writes what [save] is holding back now (e.g. as the app goes into the background).
  void flush(List<DeviceTab> tabs, int active, {int pinned = 0}) {
    if (Incognito.active) return;
    _pending?.cancel();
    _pending = null;
    _write(tabs, active, pinned);
  }

  /// [pinned] counts the pinned tabs at the start of [tabs].
  void _write(List<DeviceTab> tabs, int active, int pinned) {
    final kept = <DeviceTab>[];
    var front = 0;
    var keptPinned = 0;
    for (final (i, tab) in tabs.indexed) {
      if (!isSessionUrl(tab.url)) continue;
      if (i <= active) front = kept.length;
      if (i < pinned) keptPinned++;
      kept.add(tab);
    }
    final contents = jsonEncode({
      'version': 1,
      'active': front,
      'pinned': keptPinned,
      'tabs': [for (final tab in kept) tab.toJson()],
    });
    if (contents == _written) return;
    try {
      final directory = file.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(contents, flush: true);
      temp.renameSync(file.path);
      _written = contents;
    } catch (error) {
      debugPrint('webby: could not save ${file.path}: $error');
    }
  }
}
