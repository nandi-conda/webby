import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/passwords/sync/sync_doc.dart';
import 'package:webby/src/passwords/sync/sync_engine.dart';
import 'package:webby/src/passwords/sync/sync_store.dart';
import 'package:webby/src/passwords/sync/sync_crypto.dart';
import 'package:webby/src/passwords/sync/vault_sync.dart';
import 'package:webby/src/passwords/vault.dart';

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
    var removedPasskeys = <String>{};
    final sync = VaultSync(vault, onPasskeysChanged: (removed) => removedPasskeys = removed);
    final settings = SyncSettings(code: SyncKey.generate().code, server: server!);
    await sync.enable(settings);
    expect(sync.error, isNull);
    expect(vault.syncSettings!.lastSync, isNotNull);

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

    // Local delete propagates.
    vault.setNeverSave('https://never.example', false);
    await sync.syncNow();
    final serverView = await syncOnce(settings, SyncDoc());
    expect(isDeleted(serverView.doc.neverSave['https://never.example']!), isTrue);

    // Reopen from disk: settings and tombstones persisted.
    await vault.flush();
    final again = await Vault.open();
    expect(again.syncSettings!.code, settings.code);
    expect(again.toSyncDoc(), vault.toSyncDoc());

    await sync.disable(erase: true);
    expect(vault.syncSettings, isNull);
    expect(await settings.store(await settings.key.derive()).read(), isNull);
    sync.dispose();
  }, skip: server == null || Platform.environment['WEBBY_VAULT_FILE'] == null ? 'needs a sync server' : false);
}
