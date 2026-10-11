// The synced form of a vault and how two copies of it merge. Pure Dart, so it is shared by every platform and is
// easy to test.

import 'dart:convert';

/// How long a deletion is remembered, so devices that were offline still learn about it.
const tombstoneLifetime = Duration(days: 180);

/// Everything that syncs: passwords by id, passkeys by credentialId and never-save sites by origin.
///
/// Each record is a JSON map with an `updatedAt` (seconds since the epoch). A deleted item stays as a tombstone
/// `{updatedAt, deleted: true}` (passwords also keep `id`) until [tombstoneLifetime] has passed.
class SyncDoc {
  SyncDoc({
    Map<String, Map<String, Object?>>? passwords,
    Map<String, Map<String, Object?>>? passkeys,
    Map<String, Map<String, Object?>>? neverSave,
  })  : passwords = passwords ?? {},
        passkeys = passkeys ?? {},
        neverSave = neverSave ?? {};

  factory SyncDoc.fromJson(Map<String, Object?> json) {
    Map<String, Map<String, Object?>> section(String name) {
      final value = json[name];
      if (value is! Map<String, Object?>) return {};
      return {
        for (final entry in value.entries)
          if (entry.value is Map<String, Object?>) entry.key: Map<String, Object?>.of(entry.value as Map<String, Object?>),
      };
    }

    return SyncDoc(passwords: section('passwords'), passkeys: section('passkeys'), neverSave: section('neverSave'));
  }

  final Map<String, Map<String, Object?>> passwords;
  final Map<String, Map<String, Object?>> passkeys;
  final Map<String, Map<String, Object?>> neverSave;

  Map<String, Object?> toJson() => {
        'version': 1,
        'passwords': _sorted(passwords),
        'passkeys': _sorted(passkeys),
        'neverSave': _sorted(neverSave),
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
  );
}
