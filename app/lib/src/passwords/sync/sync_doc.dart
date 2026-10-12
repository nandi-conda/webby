// The synced form of a vault and how two copies of it merge. Pure Dart, so it is shared by every platform and is
// easy to test.

import 'dart:convert';

/// How long a deletion is remembered, so devices that were offline still learn about it.
const tombstoneLifetime = Duration(days: 180);

/// How long a device that stopped syncing keeps showing up under "Tabs from other devices".
const deviceLifetime = Duration(days: 30);

/// How many page summaries sync; the ones changed longest ago drop out.
const summaryLimit = 300;

/// Everything that syncs: passwords by id, passkeys by credentialId, never-save sites by origin and bookmarks by id.
///
/// Bookmarks travel in their own blob (see [SyncKeys.bookmarksBlobId]), so webby versions that predate bookmark
/// sync never see them and can't drop them; in that blob only [bookmarks] is used. Open tabs are the same, in a third
/// blob holding only [devices], page summaries in a fourth holding only [summaries], and saved sessions in a fifth
/// holding only [sessions].
///
/// Each record is a JSON map with an `updatedAt` (seconds since the epoch). A deleted item stays as a tombstone
/// `{updatedAt, deleted: true}` (passwords also keep `id`) until [tombstoneLifetime] has passed.
class SyncDoc {
  SyncDoc({
    Map<String, Map<String, Object?>>? passwords,
    Map<String, Map<String, Object?>>? passkeys,
    Map<String, Map<String, Object?>>? neverSave,
    Map<String, Map<String, Object?>>? bookmarks,
    Map<String, Map<String, Object?>>? devices,
    Map<String, Map<String, Object?>>? summaries,
    Map<String, Map<String, Object?>>? sessions,
  })  : summaries = summaries ?? {},
        sessions = sessions ?? {},
        passwords = passwords ?? {},
        passkeys = passkeys ?? {},
        neverSave = neverSave ?? {},
        bookmarks = bookmarks ?? {},
        devices = devices ?? {};

  factory SyncDoc.fromJson(Map<String, Object?> json) {
    Map<String, Map<String, Object?>> section(String name) {
      final value = json[name];
      if (value is! Map<String, Object?>) return {};
      return {
        for (final entry in value.entries)
          if (entry.value is Map<String, Object?>) entry.key: Map<String, Object?>.of(entry.value as Map<String, Object?>),
      };
    }

    return SyncDoc(
        passwords: section('passwords'),
        passkeys: section('passkeys'),
        neverSave: section('neverSave'),
        bookmarks: section('bookmarks'),
        devices: section('devices'),
        summaries: section('summaries'),
        sessions: section('sessions'));
  }

  final Map<String, Map<String, Object?>> passwords;
  final Map<String, Map<String, Object?>> passkeys;
  final Map<String, Map<String, Object?>> neverSave;

  /// Bookmarks and folders by id: `{parent, pos, title, url}` for a link, `{parent, pos, title, folder: true}` for a
  /// folder, plus `addedAt` and `updatedAt`. `parent` is a folder's id or one of the roots `bar` and `other`; `pos`
  /// orders a folder's children. A folder merged into a same-named one is a tombstone with `mergedInto`.
  final Map<String, Map<String, Object?>> bookmarks;

  /// Each device's open tabs by device id: `{name, platform, updatedAt, tabs: [{title, url}]}`. Only the device
  /// itself writes its record (refreshing `updatedAt` at least hourly), so the newest copy is always right; one not
  /// refreshed for [deviceLifetime] is dropped.
  final Map<String, Map<String, Object?>> devices;

  /// Page summaries by cache key (see SummaryCache.keyFor): `{title, url, text, at, selection?, questions?,
  /// updatedAt}`. The newest version of a page's summary, with its questions, wins; only the [summaryLimit] most
  /// recently changed are kept.
  final Map<String, Map<String, Object?>> summaries;

  /// Saved tab sessions by id: `{name, savedAt, active, tabs: [{title, url}], updatedAt}`. A rename or a tab taken
  /// out rewrites the whole record, and the newest version wins.
  final Map<String, Map<String, Object?>> sessions;

  Map<String, Object?> toJson() => {
        'version': 1,
        'passwords': _sorted(passwords),
        'passkeys': _sorted(passkeys),
        'neverSave': _sorted(neverSave),
        if (bookmarks.isNotEmpty) 'bookmarks': _sorted(bookmarks),
        if (devices.isNotEmpty) 'devices': _sorted(devices),
        if (summaries.isNotEmpty) 'summaries': _sorted(summaries),
        if (sessions.isNotEmpty) 'sessions': _sorted(sessions),
      };

  /// A stable encoding: equal documents encode to equal strings.
  String canonical() => jsonEncode(_canonicalValue(toJson()));

  @override
  bool operator ==(Object other) => other is SyncDoc && other.canonical() == canonical();

  @override
  int get hashCode => canonical().hashCode;

  static Map<String, Object?> _sorted(Map<String, Map<String, Object?>> section) =>
      {for (final key in section.keys.toList()..sort()) key: section[key]};
}

Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final key in keys) key: _canonicalValue(value[key])};
  }
  if (value is List) return [for (final item in value) _canonicalValue(item)];
  return value;
}

int updatedAtOf(Map<String, Object?> record) {
  final value = record['updatedAt'];
  return value is int ? value : (value is num ? value.toInt() : 0);
}

bool isDeleted(Map<String, Object?> record) => record['deleted'] == true;

/// Which of two versions of one item wins: the newer one; at the same time a deletion; then the larger encoding, so
/// every device picks the same one.
Map<String, Object?> newer(Map<String, Object?> a, Map<String, Object?> b) {
  final byTime = updatedAtOf(a).compareTo(updatedAtOf(b));
  if (byTime != 0) return byTime > 0 ? a : b;
  if (isDeleted(a) != isDeleted(b)) return isDeleted(a) ? a : b;
  final ea = jsonEncode(_canonicalValue(a));
  final eb = jsonEncode(_canonicalValue(b));
  return ea.compareTo(eb) >= 0 ? a : b;
}

Map<String, Map<String, Object?>> _mergeSection(
    Map<String, Map<String, Object?>> a, Map<String, Map<String, Object?>> b, int expireBefore) {
  final merged = <String, Map<String, Object?>>{};
  for (final key in {...a.keys, ...b.keys}) {
    final x = a[key];
    final y = b[key];
    final winner = x == null ? y! : (y == null ? x : newer(x, y));
    if (isDeleted(winner) && updatedAtOf(winner) < expireBefore) continue;
    merged[key] = Map<String, Object?>.of(winner);
  }
  return merged;
}

/// Merges two copies of the synced vault. The result is the same whichever order they're given in.
///
/// [now] is in seconds since the epoch; tombstones older than [tombstoneLifetime] are dropped.
SyncDoc mergeDocs(SyncDoc a, SyncDoc b, {required int now}) {
  final expireBefore = now - tombstoneLifetime.inSeconds;
  final passwords = _mergeSection(a.passwords, b.passwords, expireBefore);

  // The same site and username saved separately on two devices: keep the newest, delete the rest.
  final byAccount = <String, List<String>>{};
  for (final entry in passwords.entries) {
    if (isDeleted(entry.value)) continue;
    final account = jsonEncode([entry.value['origin'], entry.value['username']]);
    byAccount.putIfAbsent(account, () => []).add(entry.key);
  }
  for (final ids in byAccount.values.where((ids) => ids.length > 1)) {
    final keep = ids.map((id) => passwords[id]!).reduce(newer);
    for (final id in ids) {
      final record = passwords[id]!;
      if (identical(record, keep)) continue;
      passwords[id] = {'id': id, 'updatedAt': updatedAtOf(record), 'deleted': true};
    }
  }

  return SyncDoc(
    passwords: passwords,
    passkeys: _mergeSection(a.passkeys, b.passkeys, expireBefore),
    neverSave: _mergeSection(a.neverSave, b.neverSave, expireBefore),
    bookmarks: _repairBookmarks(_mergeSection(a.bookmarks, b.bookmarks, expireBefore)),
    devices: _mergeSection(a.devices, b.devices, expireBefore)
      ..removeWhere((_, record) => !isDeleted(record) && updatedAtOf(record) < now - deviceLifetime.inSeconds),
    summaries: _trimSummaries(_mergeSection(a.summaries, b.summaries, expireBefore)),
    sessions: _mergeSection(a.sessions, b.sessions, expireBefore),
  );
}

/// Keeps the [summaryLimit] most recently changed summaries (and the tombstones), the same ones on every device.
Map<String, Map<String, Object?>> _trimSummaries(Map<String, Map<String, Object?>> records) {
  final live = records.keys.where((key) => !isDeleted(records[key]!)).toList()
    ..sort((a, b) {
      final byTime = updatedAtOf(records[b]!).compareTo(updatedAtOf(records[a]!));
      return byTime != 0 ? byTime : a.compareTo(b);
    });
  for (final key in live.skip(summaryLimit)) {
    records.remove(key);
  }
  return records;
}

/// The two bookmark roots every device has; they never appear as records.
const bookmarkRoots = {'bar', 'other'};

/// Makes merged bookmarks a tree again, the same way on every device: a bookmark whose folder was deleted elsewhere
/// moves to Other bookmarks, a loop of folders (each moved into the other on different devices) is cut, and two
/// devices' copies of the same folder or link collapse into one (the first sync of two devices that both imported
/// the same bookmarks shouldn't double them).
Map<String, Map<String, Object?>> _repairBookmarks(Map<String, Map<String, Object?>> records) {
  bool isFolder(Map<String, Object?> record) => record['folder'] == true;
  final ids = records.keys.toList()..sort();

  // Where a bookmark really lives: past folders merged into others, and Other bookmarks when its folder is gone.
  String resolve(Object? parent) {
    final seen = <String>{};
    while (parent is String && !bookmarkRoots.contains(parent) && seen.add(parent)) {
      final record = records[parent];
      if (record == null) return 'other';
      if (!isDeleted(record)) return isFolder(record) ? parent : 'other';
      parent = record['mergedInto'];
    }
    return parent is String && bookmarkRoots.contains(parent) ? parent : 'other';
  }

  void setParent(String id, String parent) => records[id] = {...records[id]!, 'parent': parent};

  for (var changed = true; changed;) {
    changed = false;
    for (final id in ids) {
      final record = records[id]!;
      if (isDeleted(record)) continue;
      final parent = resolve(record['parent']);
      if (parent != record['parent']) setParent(id, parent);
    }
    for (final id in ids) {
      if (isDeleted(records[id]!)) continue;
      final seen = <String>{};
      for (var at = id; !bookmarkRoots.contains(at);) {
        if (!seen.add(at)) {
          setParent(at, 'other');
          break;
        }
        at = records[at]!['parent'] as String;
      }
    }
    for (final (folders, key) in [(true, 'title'), (false, 'url')]) {
      final groups = <String, List<String>>{};
      for (final id in ids) {
        final record = records[id]!;
        if (isDeleted(record) || isFolder(record) != folders) continue;
        groups.putIfAbsent(jsonEncode([record['parent'], record[key]]), () => []).add(id);
      }
      for (final group in groups.values.where((group) => group.length > 1)) {
        final keep = group.map((id) => records[id]!).reduce(newer);
        final keepId = group.firstWhere((id) => identical(records[id], keep));
        for (final id in group.where((id) => id != keepId)) {
          records[id] = {'updatedAt': updatedAtOf(records[id]!), 'deleted': true, if (folders) 'mergedInto': keepId};
        }
        // Children of the folders just merged away need re-homing; go round again.
        if (folders) changed = true;
      }
      if (changed) break;
    }
  }
  return records;
}
