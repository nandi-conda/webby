import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'bindings.dart';
import 'incognito.dart';

/// Ad and tracker blocking ("Block ads" in the ⋮ menu), on by default.
///
/// The engine is Ladybird's own content blocker (Brave's adblock engine: network rules and element hiding), fed
/// EasyList and EasyPrivacy, which Ladybird downloads into the profile's ContentBlocking/Lists and refreshes daily.
/// It is off in a fresh Ladybird profile, so before Ladybird starts [prepareEngine] writes the switch into the
/// profile's Settings.json. Runtimes with webby_set_content_blocking (native/webby_ffi.h) also switch it while
/// running; older ones pick a change up at the next start.
///
/// The choice lives in `<data>/webby/profiles/<profile>/content_blocking.json` ({"enabled": bool}), shared with the
/// Nim front ends (nim/src/features/adblock/store.nim).
class ContentBlocking {
  ContentBlocking._();

  /// Whether blocking is on, for the menu's check mark.
  static final enabled = ValueNotifier<bool>(_readEnabled());

  /// Whether the running engine follows [setEnabled] at once (else it applies at the next start).
  static bool get appliesLive => _setLive != null;

  static void Function(int)? _setLiveCache;
  static bool _looked = false;
  static void Function(int)? get _setLive {
    if (_looked) return _setLiveCache;
    _looked = true;
    final lib = WebbyBindings.open().library;
    if (lib.providesSymbol('webby_set_content_blocking')) {
      _setLiveCache = lib.lookupFunction<Void Function(Int32), void Function(int)>('webby_set_content_blocking');
    }
    return _setLiveCache;
  }

  static void setEnabled(bool on) {
    if (enabled.value == on) return;
    enabled.value = on;
    // Incognito windows follow the normal profile's choice but don't change it.
    if (!Incognito.active) {
      try {
        _prefFile.parent.createSync(recursive: true);
        _prefFile.writeAsStringSync(jsonEncode({'enabled': on}));
      } on FileSystemException catch (e) {
        debugPrint('webby: could not save content_blocking.json: $e');
      }
    }
    _setLive?.call(on ? 1 : 0);
  }

  /// Writes the switch into Ladybird's Settings.json. Runs right before webby_init.
  static void prepareEngine() {
    final settings = ladybirdSettingsFile(_words(_env('WEBBY_LADYBIRD_ARGS')));
    if (settings == null) return;
    writeLadybirdSettings(settings, enabled.value, updateLists: !Incognito.active);
  }

  /// Settings.json of the Ladybird profile [args] select, or null for a temporary profile (it has no fixed path).
  static File? ladybirdSettingsFile(List<String> args) {
    final dir = ladybirdProfileDirs(args);
    return dir == null ? null : File('${dir.config}/Settings.json');
  }

  /// The config and data directories of the Ladybird profile [args] select (LibWebView/Profile.cpp).
  static ({String config, String data})? ladybirdProfileDirs(List<String> args) {
    if (Platform.isAndroid) {
      // Android uses Ladybird's legacy layout under $XDG_CONFIG_HOME / $XDG_DATA_HOME (LadybirdRuntime.kt).
      return (config: '${_configHome()}/Ladybird', data: '${_dataHome()}/Ladybird');
    }
    var name = 'default';
    String? path;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      final next = i + 1 < args.length ? args[i + 1] : '';
      if (a == '--temporary-profile' || a == '--force-new-process') return null;
      if (a == '--profile-path') path = next;
      if (a.startsWith('--profile-path=')) path = a.substring('--profile-path='.length);
      if (a == '--profile') name = next;
      if (a.startsWith('--profile=')) name = a.substring('--profile='.length);
    }
    if (path != null) return (config: '$path/config', data: '$path/data');
    return (
      config: '${_configHome()}/Ladybird/Profiles/$name',
      data: '${_dataHome()}/Ladybird/Profiles/$name',
    );
  }

  /// Sets the content blocker (and its EasyList and EasyPrivacy lists) on or off in [file], keeping everything else.
  /// [updateLists] lets Ladybird download and refresh the lists.
  static void writeLadybirdSettings(File file, bool on, {required bool updateLists}) {
    Map<String, dynamic> json = {};
    String? before;
    try {
      before = file.readAsStringSync();
      final decoded = jsonDecode(before);
      if (decoded is Map<String, dynamic>) json = decoded;
    } on Object {
      // Missing or unreadable: Ladybird fills in its defaults around what we write.
    }
    Map<String, dynamic> object(Map<String, dynamic> parent, String key) =>
        parent[key] is Map<String, dynamic> ? parent[key] as Map<String, dynamic> : (parent[key] = <String, dynamic>{});
    final blockers = object(json, 'contentBlockers');
    blockers['enabled'] = on;
    final lists = object(blockers, 'builtInLists');
    lists['easyList'] = true;
    lists['easyPrivacy'] = true;
    final features = object(object(json, 'backgroundNetworking'), 'features');
    features['contentBlockerSubscriptionUpdates'] = updateLists;
    final after = const JsonEncoder.withIndent('    ').convert(json);
    if (after == before) return;
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.webby-tmp');
      tmp.writeAsStringSync(after);
      tmp.renameSync(file.path);
    } on FileSystemException catch (e) {
      debugPrint('webby: could not write ${file.path}: $e');
    }
  }

  /// The normal profile's downloaded lists, for incognito windows (which don't download their own).
  static List<File> downloadedLists() {
    final dirs = ladybirdProfileDirs(Incognito.active ? Incognito.originalArgs : _words(_env('WEBBY_LADYBIRD_ARGS')));
    if (dirs == null) return const [];
    return [
      for (final id in ['easyList', 'easyPrivacy'])
        if (File('${dirs.data}/ContentBlocking/Lists/$id.txt') case final f when f.existsSync()) f,
    ];
  }

  static List<String> _words(String s) => s.split(' ').where((w) => w.isNotEmpty).toList();

  static bool _readEnabled() {
    try {
      final json = jsonDecode(_prefFile.readAsStringSync());
      if (json is Map && json['enabled'] is bool) return json['enabled'] as bool;
    } on Object {
      // No choice made yet.
    }
    return true;
  }

  static File get _prefFile => File('${_dataHome()}/webby/profiles/${_profileName()}/content_blocking.json');

  static String _profileName() {
    final name = _env('WEBBY_PROFILE');
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
  }

  static String _home() => _env('HOME').isEmpty ? '/tmp' : _env('HOME');
  static String _dataHome() => _env('XDG_DATA_HOME').isEmpty ? '${_home()}/.local/share' : _env('XDG_DATA_HOME');
  static String _configHome() => _env('XDG_CONFIG_HOME').isEmpty ? '${_home()}/.config' : _env('XDG_CONFIG_HOME');

  /// The live environment: Android's LadybirdRuntime sets the XDG variables with setenv after Dart may have read
  /// Platform.environment, and Incognito.enable() changes WEBBY_LADYBIRD_ARGS the same way.
  static String _env(String name) {
    final key = name.toNativeUtf8();
    try {
      final getenv = DynamicLibrary.process()
          .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('getenv');
      final value = getenv(key);
      return value == nullptr ? '' : value.toDartString();
    } finally {
      malloc.free(key);
    }
  }
}
