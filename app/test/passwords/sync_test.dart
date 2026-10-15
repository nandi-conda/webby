import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/passwords/sync/sync_crypto.dart';
import 'package:webby/src/passwords/sync/sync_doc.dart';
import 'package:webby/src/passwords/sync/sync_engine.dart';
import 'package:webby/src/passwords/sync/sync_store.dart';

Map<String, Object?> pw(String id, String user, String pass, int at, {String origin = 'https://a.example'}) =>
    {'id': id, 'origin': origin, 'username': user, 'password': pass, 'createdAt': at, 'updatedAt': at};

/// An in-memory [BlobStore] that behaves like the server.
class MemoryStore implements BlobStore {
  List<int>? bytes;
  int version = 0;
  void Function()? beforeWrite;

  @override
  Future<StoredBlob?> read() async => bytes == null ? null : StoredBlob(bytes!, '"$version"');

  @override
  Future<String?> write(List<int> data, {String? ifMatch}) async {
    beforeWrite?.call();
    final current = bytes == null ? null : '"$version"';
    if (ifMatch == null ? current != null : (ifMatch != '*' && ifMatch != current)) throw const SyncConflict();
    bytes = data;
    version++;
    return '"$version"';
  }

  @override
  Future<void> delete() async => bytes = null;
}

void main() {
  const now = 1000;

  group('merge', () {
    test('newest edit wins and the order of arguments does not matter', () {
      final a = SyncDoc(passwords: {'1': pw('1', 'v', 'old', 10), '2': pw('2', 'w', 'only-a', 5)});
      final b = SyncDoc(passwords: {'1': pw('1', 'v', 'new', 20), '3': pw('3', 'x', 'only-b', 7)});
      final ab = mergeDocs(a, b, now: now);
      expect(ab, mergeDocs(b, a, now: now));
      expect(ab.passwords['1']!['password'], 'new');
      expect(ab.passwords.keys, unorderedEquals(['1', '2', '3']));
    });

    test('a deletion beats an older edit, a newer edit beats a deletion', () {
      final tomb = {'id': '1', 'updatedAt': 15, 'deleted': true};
      expect(isDeleted(mergeDocs(SyncDoc(passwords: {'1': pw('1', 'v', 'p', 10)}), SyncDoc(passwords: {'1': tomb}),
              now: now)
          .passwords['1']!), isTrue);
      expect(isDeleted(mergeDocs(SyncDoc(passwords: {'1': pw('1', 'v', 'p', 20)}), SyncDoc(passwords: {'1': tomb}),
              now: now)
          .passwords['1']!), isFalse);
    });

    test('ties are settled the same way everywhere, deletions first', () {
      final x = SyncDoc(passwords: {'1': pw('1', 'v', 'aaa', 10)});
      final y = SyncDoc(passwords: {'1': pw('1', 'v', 'bbb', 10)});
      expect(mergeDocs(x, y, now: now), mergeDocs(y, x, now: now));
      final tomb = SyncDoc(passwords: {'1': {'id': '1', 'updatedAt': 10, 'deleted': true}});
      expect(isDeleted(mergeDocs(x, tomb, now: now).passwords['1']!), isTrue);
    });

    test('the same account saved on two devices collapses to the newest', () {
      final a = SyncDoc(passwords: {'1': pw('1', 'v', 'first', 10)});
      final b = SyncDoc(passwords: {'2': pw('2', 'v', 'second', 12)});
      final merged = mergeDocs(a, b, now: now);
      expect(merged.passwords['2']!['password'], 'second');
      expect(isDeleted(merged.passwords['1']!), isTrue);
      // Merging again with either side changes nothing.
      expect(mergeDocs(merged, a, now: now), merged);
      expect(mergeDocs(b, merged, now: now), merged);
    });

    test('old tombstones are dropped', () {
      final old = now - tombstoneLifetime.inSeconds - 1;
      final doc = SyncDoc(neverSave: {'https://x': {'updatedAt': old, 'deleted': true}, 'https://y': {'updatedAt': old}});
      expect(mergeDocs(doc, SyncDoc(), now: now).neverSave.keys, ['https://y']);
    });

    test('passkeys and never-save sites merge by key', () {
      final a = SyncDoc(passkeys: {'c1': {'credentialId': 'c1', 'updatedAt': 1}}, neverSave: {'https://x': {'updatedAt': 3}});
      final b = SyncDoc(passkeys: {'c2': {'credentialId': 'c2', 'updatedAt': 2}});
      final merged = mergeDocs(a, b, now: now);
      expect(merged.passkeys.keys, unorderedEquals(['c1', 'c2']));
      expect(merged.neverSave.keys, ['https://x']);
    });
  });

  test('secrets: newest wins, deletions win over older values, either order', () {
    final a = SyncDoc(secrets: {
      'k': {'value': 'old', 'updatedAt': 10},
      'gone': {'value': 'x', 'updatedAt': 10},
    });
    final b = SyncDoc(secrets: {
      'k': {'value': 'new', 'updatedAt': 20},
      'gone': {'updatedAt': 15, 'deleted': true},
    });
    final merged = mergeDocs(a, b, now: 100);
    expect(merged, mergeDocs(b, a, now: 100));
    expect(merged.secrets['k']!['value'], 'new');
    expect(isDeleted(merged.secrets['gone']!), isTrue);
    expect(SyncDoc.fromJson(merged.toJson()), merged);
  });

  group('sync code', () {
    test('round-trips and tolerates sloppy typing', () {
      final key = SyncKey.generate();
      final code = key.code;
      expect(code, startsWith('webby1-'));
      expect(SyncKey.fromCode(code).bytes, key.bytes);
      expect(SyncKey.fromCode(' ${code.toLowerCase().replaceAll('-', ' ')} ').bytes, key.bytes);
    });

    test('catches typos', () {
      final code = SyncKey.generate().code;
      final i = code.length - 3;
      final typo = code.substring(0, i) + (code[i] == 'A' ? 'B' : 'A') + code.substring(i + 1);
      expect(() => SyncKey.fromCode(typo), throwsA(isA<BadSyncCode>()));
      expect(() => SyncKey.fromCode(code.substring(0, code.length - 2)), throwsA(isA<BadSyncCode>()));
    });

    test('pairing links carry the server when it is not the default', () {
      final code = SyncKey.generate().code;
      expect(SyncSettings.fromPairing(SyncSettings(code: code).pairingLink).server, defaultSyncServer);
      final custom = SyncSettings.fromPairing(SyncSettings(code: code, server: 'https://sync.example').pairingLink);
      expect(custom.server, 'https://sync.example');
      expect(custom.code, code);
      final dav = SyncSettings.fromPairing(
          SyncSettings(code: code, backend: SyncBackend.webdav, server: 'https://dav.example/f').pairingLink);
      expect(dav.backend, SyncBackend.webdav);
      expect(SyncSettings.fromPairing(code).code, code);
    });
  });

  test('encryption round-trips and other keys cannot read it', () async {
    final keys = await SyncKey.generate().derive();
    final doc = SyncDoc(passwords: {'1': pw('1', 'v', 'secret', 1)});
    final sealed = await keys.seal(doc);
    expect(String.fromCharCodes(sealed), isNot(contains('secret')));
    expect(await keys.open(sealed), doc);
    final other = await SyncKey.generate().derive();
    expect(() => other.open(sealed), throwsA(isA<SyncDecryptError>()));
    expect(keys.blobId, hasLength(64));
  });

  group('syncOnce', () {
    test('two devices converge, including when they race', () async {
      final code = SyncKey.generate().code;
      final settings = SyncSettings(code: code);
      final store = MemoryStore();

      final desktop = SyncDoc(passwords: {'1': pw('1', 'v', 'desk', 10)});
      final phone = SyncDoc(passwords: {'2': pw('2', 'w', 'phone', 11, origin: 'https://b.example')});

      final first = await syncOnce(settings, desktop, store: store, now: now);
      expect(first.doc.passwords.keys, ['1']);

      // The desktop writes again just before the phone's write lands: the phone must retry and keep both changes.
      var raced = false;
      store.beforeWrite = () {
        if (raced) return;
        raced = true;
        store.version++;
        store.bytes = List.of(store.bytes!);
      };
      final second = await syncOnce(settings, phone, store: store, now: now);
      expect(second.doc.passwords.keys, unorderedEquals(['1', '2']));
      store.beforeWrite = null;

      final back = await syncOnce(settings, first.doc, store: store, now: now);
      expect(back.doc, second.doc);
    });

    test('does not write when nothing changed', () async {
      final settings = SyncSettings(code: SyncKey.generate().code);
      final store = MemoryStore();
      final doc = SyncDoc(passwords: {'1': pw('1', 'v', 'p', 1)});
      await syncOnce(settings, doc, store: store, now: now);
      final version = store.version;
      await syncOnce(settings, doc, store: store, now: now);
      expect(store.version, version);
    });

    // Run against a real server with WEBBY_SYNC_TEST_SERVER=http://127.0.0.1:8080 (see sync-server/).
    final server = Platform.environment['WEBBY_SYNC_TEST_SERVER'];
    test('works against the webby-sync server', () async {
      final settings = SyncSettings(code: SyncKey.generate().code, server: server!);
      final a = await syncOnce(settings, SyncDoc(passwords: {'1': pw('1', 'v', 'p', 1)}), now: now);
      final b = await syncOnce(settings, SyncDoc(passwords: {'2': pw('2', 'w', 'q', 2)}), now: now);
      expect(b.doc.passwords.keys, unorderedEquals(['1', '2']));
      expect(b.etag, isNot(a.etag));
      final keys = await settings.key.derive();
      await settings.store(keys).delete();
      expect(await settings.store(keys).read(), isNull);
    }, skip: server == null ? 'set WEBBY_SYNC_TEST_SERVER' : false);
  });
}
