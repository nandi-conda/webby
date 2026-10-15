import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/bookmarks/bookmark_store.dart';
import 'package:webby/src/passwords/sync/sync_doc.dart';
import 'package:webby/src/passwords/sync/sync_engine.dart';
import 'package:webby/src/passwords/sync/sync_store.dart';
import 'package:webby/src/passwords/sync/sync_crypto.dart';
import 'package:webby/src/passwords/sync/vault_sync.dart';
import 'package:webby/src/passwords/vault.dart';
import 'package:webby/src/summary_cache.dart';
import 'package:webby/src/tabs/device_tabs.dart';
import 'package:webby/src/tabs/sessions.dart';

// Needs a running sync-server and a throwaway vault:
//   WEBBY_VAULT_KEYRING=0 WEBBY_VAULT_FILE=/tmp/v/vault.json WEBBY_SYNC_TEST_SERVER=http://127.0.0.1:8080 flutter test
void main() {
  final server = Platform.environment['WEBBY_SYNC_TEST_SERVER'];
  test('vault + VaultSync against a local server, with a simulated phone', () async {
    final vault = await Vault.open();
    vault.savePassword('https://a.example', 'v', 'desk-pw');
    final doomed = vault.savePassword('https://b.example', 'w', 'gone-soon');
    vault.setNeverSave('https://never.example', true);
    await vault.setPasskeys([
      {'credentialId': 'pk1', 'rpId': 'a.example', 'userName': 'v', 'privateKey': 'x', 'createdAt': 100},
    ]);
    final bookmarksDir = Directory.systemTemp.createTempSync('webby-vault-sync');
    final bookmarks = BookmarkStore(File('${bookmarksDir.path}/bookmarks.json'));
    bookmarks.add(title: 'Ladybird', url: 'https://ladybird.org/');
    final tabs = DeviceTabs(File('${bookmarksDir.path}/device.json'))
      ..setTabs([const DeviceTab('Ladybird', 'https://ladybird.org/')]);
    final summaries = SummaryCache(File('${bookmarksDir.path}/summaries.json'))
      ..store('https://ladybird.org/', const CachedSummary(title: 'Ladybird', url: 'https://ladybird.org/', text: '- browser', at: 1));
    final sessions = SessionStore(File('${bookmarksDir.path}/sessions.json'))
      ..save([const DeviceTab('Ladybird', 'https://ladybird.org/')], name: 'Desk');
    await vault.setSecret('deepseek-api-key', 'sk-synced-key');
    await vault.setSecret('device-only', 'sk-stays-here', sync: false);
    var removedPasskeys = <String>{};
    final sync = VaultSync(vault,
        onPasskeysChanged: (removed) => removedPasskeys = removed, bookmarks: bookmarks, tabs: tabs, summaries: summaries,
        sessions: sessions);
    final settings = SyncSettings(code: SyncKey.generate().code, server: server!);
    await sync.enable(settings);
    expect(sync.error, isNull);
    expect(vault.syncSettings!.lastSync, isNotNull);
    final serverBookmarks = await syncOnce(settings, SyncDoc(), blob: SyncBlob.bookmarks);
    expect(serverBookmarks.doc.bookmarks.values.single['url'], 'https://ladybird.org/');
    expect((await syncOnce(settings, SyncDoc())).doc.bookmarks, isEmpty);
    final serverSummaries = await syncOnce(settings, SyncDoc(), blob: SyncBlob.summaries);
    expect(serverSummaries.doc.summaries['https://ladybird.org/']!['text'], '- browser');
    // Secrets travel only in their own blob, and device-only ones not at all.
    expect(serverSummaries.doc.toJson().toString() + (await syncOnce(settings, SyncDoc())).doc.toJson().toString(),
        allOf(isNot(contains('sk-synced')), isNot(contains('sk-stays'))));
    final serverSecrets = await syncOnce(settings, SyncDoc(), blob: SyncBlob.secrets);
    expect(serverSecrets.doc.secrets.keys, ['deepseek-api-key']);
    expect(serverSecrets.doc.secrets['deepseek-api-key']!['value'], 'sk-synced-key');
    final serverSessions = await syncOnce(settings, SyncDoc(), blob: SyncBlob.sessions);
    expect(serverSessions.doc.sessions.values.single['name'], 'Desk');
    final serverTabs = await syncOnce(settings, SyncDoc(), blob: SyncBlob.tabs);
    expect(serverTabs.doc.devices[tabs.deviceId]!['tabs'], [
      {'title': 'Ladybird', 'url': 'https://ladybird.org/'}
    ]);

    // The "phone": syncs its own doc, deletes the desktop's b.example password and pk1, adds one of its own.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 5;
    final phoneView = await syncOnce(settings, SyncDoc());
    final phone = SyncDoc.fromJson(phoneView.doc.toJson());
    phone.passwords[doomed.id] = {'id': doomed.id, 'updatedAt': now, 'deleted': true};
    phone.passkeys['pk1'] = {'updatedAt': now, 'deleted': true};
    phone.passkeys['pk2'] = {'credentialId': 'pk2', 'rpId': 'c.example', 'userName': 'p', 'createdAt': now};
    phone.passwords['phone1'] = {
      'id': 'phone1', 'origin': 'https://c.example', 'username': 'p', 'password': 'phone-pw', 'createdAt': now,
      'updatedAt': now
    };
    await syncOnce(settings, phone);

    await sync.syncNow();
    expect(sync.error, isNull);
    expect(vault.passwords.map((p) => p.origin), unorderedEquals(['https://a.example', 'https://c.example']));
    expect(vault.passkeys.map((p) => p['credentialId']), ['pk2']);
    expect(vault.passkeys.single.containsKey('updatedAt'), isFalse);
    expect(removedPasskeys, {'pk1'});
    expect(vault.isNeverSave('https://never.example'), isTrue);

    // A bookmark from the phone arrives.
    final phoneBookmarks = SyncDoc.fromJson(serverBookmarks.doc.toJson());
    phoneBookmarks.bookmarks['ph1'] = {
      'parent': 'other', 'pos': 1.0, 'title': 'Phone', 'url': 'https://phone.example/', 'addedAt': now, 'updatedAt': now
    };
    await syncOnce(settings, phoneBookmarks, blob: SyncBlob.bookmarks);
    // The phone's tabs arrive too.
    await syncOnce(
        settings,
        SyncDoc(devices: {
          'phone': {
            'name': 'Phone', 'platform': 'android', 'updatedAt': now,
            'tabs': [{'title': 'News', 'url': 'https://news.example/'}]
          }
        }),
        blob: SyncBlob.tabs);
    // And a summary with a question asked on the phone.
    await syncOnce(
        settings,
        SyncDoc(summaries: {
          'https://news.example/': {
            'title': 'News', 'url': 'https://news.example/', 'text': '- news', 'at': 5, 'updatedAt': now,
            'questions': [{'q': 'who?', 'a': 'them'}]
          }
        }),
        blob: SyncBlob.summaries);
    final phoneSessions = SyncDoc.fromJson(serverSessions.doc.toJson());
    phoneSessions.sessions.values.single['name'] = 'Renamed on phone';
    phoneSessions.sessions.values.single['updatedAt'] = now;
    phoneSessions.sessions['phone-s'] = {
      'name': 'Phone',
      'savedAt': now,
      'active': 0,
      'tabs': [
        {'title': 'News', 'url': 'https://news.example/'}
      ],
      'updatedAt': now,
    };
    await syncOnce(settings, phoneSessions, blob: SyncBlob.sessions);
    // The phone replaces the key, and tries to set the desktop's device-only one.
    await syncOnce(
        settings,
        SyncDoc(secrets: {
          'deepseek-api-key': {'value': 'sk-from-phone', 'updatedAt': now},
          'device-only': {'value': 'sk-phone-copy', 'updatedAt': now},
        }),
        blob: SyncBlob.secrets);
    await sync.syncNow();
    expect(vault.secret('deepseek-api-key'), 'sk-from-phone');
    expect(vault.secret('device-only'), 'sk-stays-here');
    expect(vault.secretSyncs('device-only'), isFalse);
    expect([for (final s in sessions.sessions) s.name], ['Phone', 'Renamed on phone']);
    expect(summaries.lookup('https://news.example/')!.questions.single.answer, 'them');
    expect(summaries.lookup('https://ladybird.org/')!.text, '- browser');
    expect(bookmarks.other.children!.single.title, 'Phone');
    expect(tabs.devices.single.name, 'Phone');
    expect(tabs.devices.single.tabs.single.url, 'https://news.example/');

    // Local delete propagates.
    vault.setNeverSave('https://never.example', false);
    await sync.syncNow();
    final serverView = await syncOnce(settings, SyncDoc());
    expect(isDeleted(serverView.doc.neverSave['https://never.example']!), isTrue);

    // The phone removes the key: gone here too. Then a new key set here goes back up.
    await syncOnce(
        settings,
        SyncDoc(secrets: {
          'deepseek-api-key': {'updatedAt': now + 1, 'deleted': true}
        }),
        blob: SyncBlob.secrets);
    await sync.syncNow();
    expect(vault.secret('deepseek-api-key'), isNull);
    // Clocks: the tombstone is from "now + 1", so let the local set be newer.
    await Future<void>.delayed(const Duration(seconds: 8));
    await vault.setSecret('deepseek-api-key', 'sk-newer-here');
    await sync.syncNow();
    expect((await syncOnce(settings, SyncDoc(), blob: SyncBlob.secrets)).doc.secrets['deepseek-api-key']!['value'],
        'sk-newer-here');
    // Unticking sync keeps the key here and stops it being taken from or sent to the server.
    await vault.setSecret('deepseek-api-key', 'sk-newer-here', sync: false);
    expect(vault.secretSyncs('deepseek-api-key'), isFalse);
    expect(vault.secretsSyncDoc().secrets, isEmpty);

    // Reopen from disk: settings and tombstones persisted.
    await vault.flush();
    final again = await Vault.open();
    expect(again.syncSettings!.code, settings.code);
    expect(again.toSyncDoc(), vault.toSyncDoc());
    expect(again.secretSyncs('deepseek-api-key'), isFalse);
    expect(again.secret('device-only'), 'sk-stays-here');

    await sync.disable(erase: true);
    expect(vault.syncSettings, isNull);
    expect(await settings.store(await settings.key.derive()).read(), isNull);
    expect(await settings.store(await settings.key.derive(), blob: SyncBlob.bookmarks).read(), isNull);
    expect(await settings.store(await settings.key.derive(), blob: SyncBlob.tabs).read(), isNull);
    expect(await settings.store(await settings.key.derive(), blob: SyncBlob.summaries).read(), isNull);
    expect(await settings.store(await settings.key.derive(), blob: SyncBlob.sessions).read(), isNull);
    expect(await settings.store(await settings.key.derive(), blob: SyncBlob.secrets).read(), isNull);
    expect(tabs.devices, isEmpty);
    sync.dispose();
    bookmarksDir.deleteSync(recursive: true);
  }, skip: server == null || Platform.environment['WEBBY_VAULT_FILE'] == null ? 'needs a sync server' : false);
}
