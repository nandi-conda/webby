// One round of sync: read the server's copy, merge, write back if it changed.

import 'sync_doc.dart';
import 'sync_store.dart';

class SyncOutcome {
  const SyncOutcome(this.doc, this.etag);

  /// The merged state; the server now has the same.
  final SyncDoc doc;
  final String? etag;
}

/// Merges [local] with the server's copy and makes the server hold the result. Retries when another device writes
/// in between. Throws [SyncStoreError], `SyncDecryptError` or `BadSyncCode` for the user to see.
Future<SyncOutcome> syncOnce(SyncSettings settings, SyncDoc local, {BlobStore? store, int? now}) async {
  final keys = await settings.key.derive();
  final blobs = store ?? settings.store(keys);
  for (var attempt = 0; attempt < 5; attempt++) {
    final remote = await blobs.read();
    final remoteDoc = remote == null ? SyncDoc() : await keys.open(remote.bytes);
    final merged =
        mergeDocs(local, remoteDoc, now: now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (remote != null && merged == remoteDoc) return SyncOutcome(merged, remote.etag);
    try {
      final etag = await blobs.write(await keys.seal(merged), ifMatch: remote == null ? null : (remote.etag ?? '*'));
      return SyncOutcome(merged, etag);
    } on SyncConflict {
      continue;
    }
  }
  throw const SyncStoreError('Other devices kept syncing at the same moment; try again.');
}
