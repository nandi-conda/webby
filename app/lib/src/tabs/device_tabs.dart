// This device's open tabs as other devices see them, and the tabs other devices published: "Tabs from other devices".

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../passwords/sync/sync_doc.dart';

int Function() deviceTabsClock = () => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A device republishes its record at least this often, so the others can tell it's still around.
const _heartbeat = Duration(hours: 1);

/// At most this many tabs are published, and titles and URLs are cut to keep the blob small.
const _maxTabs = 200;
const _maxTitle = 300;
const _maxUrl = 4096;

/// One open tab: what another device shows and opens.
@immutable
class DeviceTab {
  const DeviceTab(this.title, this.url);

  final String title;
  final String url;

  static DeviceTab? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    final title = json['title'];
    return DeviceTab(title is String ? title : '', url);
  }

  Map<String, Object?> toJson() => {'title': title, 'url': url};

  @override
  bool operator ==(Object other) => other is DeviceTab && other.title == title && other.url == url;

  @override
  int get hashCode => Object.hash(title, url);
}

/// Another device and the tabs it had open when it last synced.
class RemoteDevice {
  RemoteDevice({required this.id, required this.name, required this.platform, required this.seenAt, required this.tabs});

  final String id;
  final String name;
  final String platform;

  /// Seconds since the epoch when the device last published its tabs.
  final int seenAt;
  final List<DeviceTab> tabs;
}

/// Whether [url] is worth showing on another device: not blank pages, and nothing only this device can open.
bool isShareableUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return const {'http', 'https', 'ftp', 'file'}.contains(uri.scheme) && (uri.scheme == 'file' || uri.host.isNotEmpty);
}

/// The profile's device identity and open tabs for sync.
///
/// The device id, its name and whether it shares its tabs are kept in
/// `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<WEBBY_PROFILE|default>/device.json` (or $WEBBY_DEVICE_FILE).
/// Other devices' tabs live only in memory and come from the sync server.
class DeviceTabs extends ChangeNotifier {
  DeviceTabs(this.file) {
    _load();
  }

  static DeviceTabs? _instance;

  static DeviceTabs get instance => _instance ??= DeviceTabs(defaultFile());

  static File defaultFile() {
    final env = Platform.environment;
    final override = env['WEBBY_DEVICE_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final xdg = env['XDG_DATA_HOME'];
    final dataHome = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '/tmp'}/.local/share';
    final name = env['WEBBY_PROFILE'] ?? '';
    final profile = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
    return File('$dataHome/webby/profiles/$profile/device.json');
  }

  final File file;
  late String deviceId;
  late String _name;
  bool _share = true;
  List<DeviceTab> _tabs = const [];

  /// What this device last put on the server, so it isn't rewritten until something changes (or the heartbeat).
  Map<String, Object?>? _published;

  Map<String, Map<String, Object?>> _remote = {};

  String get name => _name;
  set name(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == _name) return;
    _name = trimmed;
    _save();
    notifyListeners();
  }

  /// Whether other devices see this device's tabs. Off, this device still sees theirs.
  bool get share => _share;
  set share(bool value) {
    if (value == _share) return;
    _share = value;
    _save();
    notifyListeners();
  }

  /// This device's open tabs, in tab-strip order.
  List<DeviceTab> get tabs => _tabs;

  /// Called by the browser whenever its tabs change; tabs that make no sense elsewhere are left out.
  void setTabs(Iterable<DeviceTab> tabs) {
    final shareable = [
      for (final tab in tabs)
        if (isShareableUrl(tab.url))
          DeviceTab(_cut(tab.title, _maxTitle), _cut(tab.url, _maxUrl)),
    ].take(_maxTabs).toList();
    if (listEquals(shareable, _tabs)) return;
    _tabs = shareable;
    notifyListeners();
  }

  static String _cut(String text, int max) => text.length <= max ? text : text.substring(0, max);

  /// The other devices, most recently seen first.
  List<RemoteDevice> get devices {
    final list = <RemoteDevice>[
      for (final entry in _remote.entries)
        if (entry.key != deviceId && !isDeleted(entry.value))
          RemoteDevice(
            id: entry.key,
            name: (entry.value['name'] as String?) ?? 'Unnamed device',
            platform: (entry.value['platform'] as String?) ?? '',
            seenAt: updatedAtOf(entry.value),
            tabs: [
              for (final tab in (entry.value['tabs'] as List?) ?? const []) DeviceTab.fromJson(tab),
            ].whereType<DeviceTab>().toList(),
          ),
    ];
    return list..sort((a, b) => b.seenAt.compareTo(a.seenAt));
  }

  Map<String, Object?> _record(int updatedAt) => _share
      ? {
          'name': _name,
          'platform': Platform.operatingSystem,
          'updatedAt': updatedAt,
          'tabs': [for (final tab in _tabs) tab.toJson()],
        }
      : {'updatedAt': updatedAt, 'deleted': true};

  static String _withoutTime(Map<String, Object?> record) =>
      SyncDoc(devices: {'': {...record}..remove('updatedAt')}).canonical();

  /// Whether this device's record needs writing: it changed, or it's due for the heartbeat.
  bool get needsPublish {
    final published = _published;
    if (published == null) return true;
    if (_withoutTime(_record(0)) != _withoutTime(published)) return true;
    return !isDeleted(published) && deviceTabsClock() - updatedAtOf(published) >= _heartbeat.inSeconds;
  }

  /// What this device contributes to the tabs blob: its own record, refreshed if [needsPublish].
  SyncDoc toSyncDoc() {
    // Always newer than what the server holds for this device, even if another device's clock is ahead.
    final record = needsPublish
        ? _record(max(deviceTabsClock(), _published == null ? 0 : updatedAtOf(_published!) + 1))
        : _published!;
    return SyncDoc(devices: {deviceId: record});
  }

  /// Takes in the merged tabs blob. Returns whether this device's own record on the server differs from what it
  /// would publish (another device removed it, or this device's clock is behind), so it should sync again.
  bool applySyncDoc(SyncDoc doc) {
    final mine = doc.devices[deviceId];
    _published = mine;
    final others = {...doc.devices}..remove(deviceId);
    final changed = SyncDoc(devices: others) != SyncDoc(devices: _remote);
    _remote = others;
    if (changed) notifyListeners();
    return needsPublish;
  }

  /// Forgets what was synced (sync turned off or re-keyed).
  void reset() {
    _published = null;
    if (_remote.isEmpty) return;
    _remote = {};
    notifyListeners();
  }

  void _load() {
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final id = json['id'];
      final name = json['name'];
      if (id is String && id.isNotEmpty) {
        deviceId = id;
        _name = name is String && name.trim().isNotEmpty ? name : _defaultName();
        _share = json['share'] as bool? ?? true;
        return;
      }
    } catch (_) {}
    final random = Random.secure();
    deviceId = List<int>.generate(16, (_) => random.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _name = _defaultName();
    _save();
  }

  static String _defaultName() {
    if (Platform.isAndroid) return 'Android phone';
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty && host != 'localhost') return host;
    } catch (_) {}
    return switch (Platform.operatingSystem) { 'linux' => 'Linux computer', final os => os };
  }

  void _save() {
    try {
      final directory = file.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({'id': deviceId, 'name': _name, 'share': _share}));
      temp.renameSync(file.path);
    } catch (error) {
      debugPrint('webby: could not save ${file.path}: $error');
    }
  }
}
