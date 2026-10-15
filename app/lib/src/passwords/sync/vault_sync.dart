import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../bookmarks/bookmark_store.dart';
import '../../summary_cache.dart';
import '../../tabs/device_tabs.dart';
import '../../tabs/sessions.dart';
import '../vault.dart';
import 'sync_crypto.dart';
import 'sync_doc.dart';
import 'sync_engine.dart';
import 'sync_store.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Keeps one [Vault], and the profile's [bookmarks], in sync with the other devices: at startup, a few seconds after
/// each change, every few minutes, and when asked. The vault's synced secrets (API keys), bookmarks, this device's
/// open [tabs], page [summaries] and saved [sessions] use the vault's sync settings and a blob each.
class VaultSync extends ChangeNotifier {
  VaultSync(this.vault, {required this.onPasskeysChanged, this.bookmarks, this.tabs, this.summaries, this.sessions}) {
    vault.addListener(_onVaultChanged);
    bookmarks?.addListener(_onBookmarksChanged);
    summaries?.addListener(_onSummariesChanged);
    sessions?.addListener(_onSessionsChanged);
    tabs?.addListener(_onTabsChanged);
    _periodic = Timer.periodic(const Duration(minutes: 5), (_) => syncNow());
    if (enabled) scheduleMicrotask(syncNow);
  }

  final Vault vault;
  final BookmarkStore? bookmarks;
  final DeviceTabs? tabs;

  /// Page summaries and the questions asked about them, in a blob of their own.
  final SummaryCache? summaries;

  /// Saved tab sessions, in a blob of their own.
  final SessionStore? sessions;

  /// Called after a sync brought in or removed passkeys, with the ids that were removed.
  final void Function(Set<String> removed) onPasskeysChanged;

  late final Timer _periodic;
  Timer? _debounce;
  Timer? _tabsDebounce;
  SyncDoc? _lastSynced;
  SyncDoc? _lastSyncedSecrets;
  SyncDoc? _lastSyncedBookmarks;
  SyncDoc? _lastSyncedSummaries;
  SyncDoc? _lastSyncedSessions;
  bool _running = false;
  bool _again = false;

  bool get enabled => vault.syncSettings != null;
  bool get syncing => _running;
  SyncSettings? get settings => vault.syncSettings;
  String? get error => vault.syncSettings?.lastError;

  void _onVaultChanged() {
    if (!enabled || _running) return;
    if (_lastSynced != null &&
        vault.toSyncDoc() == _lastSynced &&
        _lastSyncedSecrets != null &&
        vault.secretsSyncDoc() == _lastSyncedSecrets) {
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), syncNow);
  }

  void _onBookmarksChanged() {
    if (!enabled || _running) return;
    if (_lastSyncedBookmarks != null && bookmarks!.toSyncDoc() == _lastSyncedBookmarks) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), syncNow);
  }

  void _onSummariesChanged() {
    if (!enabled || _running) return;
    if (_lastSyncedSummaries != null && summaries!.toSyncDoc() == _lastSyncedSummaries) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), syncNow);
  }

  void _onSessionsChanged() {
    if (!enabled || _running) return;
    if (_lastSyncedSessions != null && sessions!.toSyncDoc() == _lastSyncedSessions) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), syncNow);
  }

  void _onTabsChanged() {
    if (!enabled || _running || !tabs!.needsPublish) return;
    // Tabs change with every page load; publish once browsing settles rather than on each one.
    _tabsDebounce?.cancel();
    _tabsDebounce = Timer(const Duration(seconds: 10), syncNow);
  }

  /// Starts syncing this device with the sync key and storage in [settings].
  Future<void> enable(SyncSettings settings) async {
    SyncKey.fromCode(settings.code);
    _lastSynced = null;
    _lastSyncedSecrets = null;
    _lastSyncedBookmarks = null;
    _lastSyncedSummaries = null;
    _lastSyncedSessions = null;
    tabs?.reset();
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
      await settings.store(keys, blob: SyncBlob.bookmarks).delete();
      await settings.store(keys, blob: SyncBlob.tabs).delete();
      await settings.store(keys, blob: SyncBlob.summaries).delete();
      await settings.store(keys, blob: SyncBlob.sessions).delete();
      await settings.store(keys, blob: SyncBlob.secrets).delete();
    }
    _debounce?.cancel();
    _tabsDebounce?.cancel();
    _lastSynced = null;
    _lastSyncedSecrets = null;
    _lastSyncedBookmarks = null;
    _lastSyncedSummaries = null;
    _lastSyncedSessions = null;
    tabs?.reset();
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
    _tabsDebounce?.cancel();
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
      await _syncSecrets(settings);
      if (bookmarks != null) await _syncBookmarks(settings, bookmarks!);
      if (tabs != null) await _syncTabs(settings, tabs!);
      if (summaries != null) await _syncSummaries(settings, summaries!);
      if (sessions != null) await _syncSessions(settings, sessions!);
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

  Future<void> _syncSecrets(SyncSettings settings) async {
    final outcome = await syncOnce(settings, vault.secretsSyncDoc(), blob: SyncBlob.secrets);
    if (vault.syncSettings?.code != settings.code) return;
    final merged = mergeDocs(vault.secretsSyncDoc(), outcome.doc, now: _now());
    _lastSyncedSecrets = outcome.doc;
    vault.applySecretsSyncDoc(merged);
    if (merged != outcome.doc) _again = true;
  }

  Future<void> _syncBookmarks(SyncSettings settings, BookmarkStore bookmarks) async {
    final outcome = await syncOnce(settings, bookmarks.toSyncDoc(), blob: SyncBlob.bookmarks);
    if (vault.syncSettings?.code != settings.code) return;
    final merged = mergeDocs(bookmarks.toSyncDoc(), outcome.doc, now: _now());
    _lastSyncedBookmarks = outcome.doc;
    bookmarks.applySyncDoc(merged);
    if (merged != outcome.doc) _again = true;
  }

  Future<void> _syncSummaries(SyncSettings settings, SummaryCache summaries) async {
    final outcome = await syncOnce(settings, summaries.toSyncDoc(), blob: SyncBlob.summaries);
    if (vault.syncSettings?.code != settings.code) return;
    final merged = mergeDocs(summaries.toSyncDoc(), outcome.doc, now: _now());
    _lastSyncedSummaries = outcome.doc;
    summaries.applySyncDoc(merged);
    if (merged != outcome.doc) _again = true;
  }

  Future<void> _syncSessions(SyncSettings settings, SessionStore sessions) async {
    final outcome = await syncOnce(settings, sessions.toSyncDoc(), blob: SyncBlob.sessions);
    if (vault.syncSettings?.code != settings.code) return;
    final merged = mergeDocs(sessions.toSyncDoc(), outcome.doc, now: _now());
    _lastSyncedSessions = outcome.doc;
    sessions.applySyncDoc(merged);
    if (merged != outcome.doc) _again = true;
  }

  Future<void> _syncTabs(SyncSettings settings, DeviceTabs tabs) async {
    final outcome = await syncOnce(settings, tabs.toSyncDoc(), blob: SyncBlob.tabs);
    if (vault.syncSettings?.code != settings.code) return;
    // Tabs that changed during the round, or this device's record lost to another device's, go up next round.
    if (tabs.applySyncDoc(outcome.doc)) _again = true;
  }

  @override
  void dispose() {
    vault.removeListener(_onVaultChanged);
    bookmarks?.removeListener(_onBookmarksChanged);
    summaries?.removeListener(_onSummariesChanged);
    sessions?.removeListener(_onSessionsChanged);
    tabs?.removeListener(_onTabsChanged);
    _periodic.cancel();
    _debounce?.cancel();
    _tabsDebounce?.cancel();
    super.dispose();
  }
}
