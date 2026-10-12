// Where the tabs go: a strip across the top, or a list down the left side.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// The profile's tab layout, in
/// `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<WEBBY_PROFILE|default>/tabs.json` (or $WEBBY_TABS_FILE).
/// Incognito windows read it and may change it too: it's a preference, not browsing data.
class TabLayout extends ChangeNotifier {
  TabLayout(this.file) {
    _load();
  }

  static TabLayout? _instance;

  static TabLayout get instance => _instance ??= TabLayout(defaultFile());

  static File defaultFile() {
    final env = Platform.environment;
    final override = env['WEBBY_TABS_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final xdg = env['XDG_DATA_HOME'];
    final dataHome = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '/tmp'}/.local/share';
    final name = env['WEBBY_PROFILE'] ?? '';
    final profile = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
    return File('$dataHome/webby/profiles/$profile/tabs.json');
  }

  final File file;
  bool _vertical = false;

  /// Whether the tabs are listed down the left side instead of across the top.
  bool get vertical => _vertical;
  set vertical(bool value) {
    if (value == _vertical) return;
    _vertical = value;
    _save();
    notifyListeners();
  }

  void _load() {
    try {
      if (!file.existsSync()) return;
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map<String, Object?>) _vertical = json['vertical'] as bool? ?? false;
    } catch (_) {
      // An unreadable file just means the default layout; the next change rewrites it.
    }
  }

  void _save() {
    try {
      final directory = file.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(jsonEncode({'version': 1, 'vertical': _vertical}), flush: true);
      temp.renameSync(file.path);
    } on FileSystemException catch (error) {
      debugPrint('webby: could not save ${file.path}: $error');
    }
  }
}
