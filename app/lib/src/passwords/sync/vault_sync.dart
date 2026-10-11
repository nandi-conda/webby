import 'dart:async';

import 'package:flutter/foundation.dart';

import '../vault.dart';
import 'sync_crypto.dart';
import 'sync_doc.dart';
import 'sync_engine.dart';
import 'sync_store.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Keeps one [Vault] in sync with the other devices: at startup, a few seconds after each change, every few minutes,
/// and when asked.
class VaultSync extends ChangeNotifier {
  VaultSync(this.vault, {required this.onPasskeysChanged}) {
    vault.addListener(_onVaultChanged);
    _periodic = Timer.periodic(const Duration(minutes: 5), (_) => syncNow());
    if (enabled) scheduleMicrotask(syncNow);
  }

  final Vault vault;

  /// Called after a sync brought in or removed passkeys, with the ids that were removed.
  final void Function(Set<String> removed) onPasskeysChanged;

  late final Timer _periodic;
  Timer? _debounce;
  SyncDoc? _lastSynced;
  bool _running = false;
  bool _again = false;

  bool get enabled => vault.syncSettings != null;
  bool get syncing => _running;
  SyncSettings? get settings => vault.syncSettings;
  String? get error => vault.syncSettings?.lastError;

  void _onVaultChanged() {
    if (!enabled || _running) return;
    if (_lastSynced != null && vault.toSyncDoc() == _lastSynced) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), syncNow);
  }

  /// Starts syncing this device with the sync key and storage in [settings].
  Future<void> enable(SyncSettings settings) async {
    SyncKey.fromCode(settings.code);
    _lastSynced = null;
    await vault.setSyncSettings(settings);
    await syncNow();
  }

  /// Stops syncing here. With [erase], also deletes the server's copy, which stops every device syncing.
  Future<void> disable({bool erase = false}) async {
    final settings = vault.syncSettings;
    if (settings == null) return;
    if (erase) {
      final keys = await settings.key.derive();
      await settings.store(keys).delete();
    }
    _debounce?.cancel();
    _lastSynced = null;
    await vault.setSyncSettings(null);
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (_running) {
      _again = true;
      return;
    }
    final settings = vault.syncSettings;
    if (settings == null) return;
    _running = true;
    _debounce?.cancel();
    notifyListeners();
    try {
      final outcome = await syncOnce(settings, vault.toSyncDoc());
      if (vault.syncSettings?.code != settings.code) return; // Turned off or re-keyed meanwhile.
      // The vault may have changed while we were talking to the server; keep those changes too.
      final merged = mergeDocs(vault.toSyncDoc(), outcome.doc, now: _now());
      final before = {for (final passkey in vault.passkeys) passkey['credentialId'] as String?};
      _lastSynced = outcome.doc;
      final passkeysChanged = vault.applySyncDoc(merged);
      await vault.setSyncSettings(settings.copyWith(etag: outcome.etag, lastSync: _now(), clearError: true));
      if (passkeysChanged) {
        final after = {for (final passkey in vault.passkeys) passkey['credentialId'] as String?};
        onPasskeysChanged(before.difference(after).whereType<String>().toSet());
      }
      if (merged != outcome.doc) _again = true;
    } catch (error) {
      debugPrint('webby: sync failed: $error');
      if (vault.syncSettings?.code == settings.code) {
        await vault.setSyncSettings(vault.syncSettings!.copyWith(lastError: '$error'));
      }
    } finally {
      _running = false;
      notifyListeners();
      if (_again) {
        _again = false;
        unawaited(syncNow());
      }
    }
  }

  @override
  void dispose() {
    vault.removeListener(_onVaultChanged);
    _periodic.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
