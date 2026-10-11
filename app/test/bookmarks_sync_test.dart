import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/bookmarks/bookmark_store.dart';
import 'package:webby/src/passwords/sync/sync_crypto.dart';
import 'package:webby/src/passwords/sync/sync_doc.dart';
import 'package:webby/src/passwords/sync/sync_engine.dart';
import 'package:webby/src/passwords/sync/sync_store.dart';

import 'passwords/sync_test.dart' show MemoryStore;

/// The tree as text: `title` for a link, `title[...]` for a folder.
String tree(BookmarkStore store) {
  String node(Bookmark b) => b.isFolder ? '${b.title}[${b.children!.map(node).join(', ')}]' : b.title;
  return 'bar[${store.bar.children!.map(node).join(', ')}] other[${store.other.children!.map(node).join(', ')}]';
}

void main() {
  late Directory temp;
  late MemoryStore server;
  late SyncSettings settings;
  var clock = 1000000;
  var files = 0;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webby-bookmark-sync');
    server = MemoryStore();
    settings = SyncSettings(code: SyncKey.generate().code);
    bookmarkClock = () => clock;
  });
  tearDown(() => temp.deleteSync(recursive: true));

  BookmarkStore device() => BookmarkStore(File('${temp.path}/${files++}/bookmarks.json'));

  /// What VaultSync does for bookmarks.
  Future<void> sync(BookmarkStore store) async {
    clock++;
    final outcome = await syncOnce(settings, store.toSyncDoc(), store: server, now: clock, blob: SyncBlob.bookmarks);
    store.applySyncDoc(mergeDocs(store.toSyncDoc(), outcome.doc, now: clock));
  }

  Future<void> syncAll(List<BookmarkStore> stores) async {
    for (var round = 0; round < 2; round++) {
      for (final store in stores) {
        await sync(store);
      }
    }
  }

  test('a new device gets the tree in order, and it persists', () async {
    final desktop = device();
    final news = desktop.addFolder('News', parent: desktop.bar);
    desktop.add(title: 'Ladybird', url: 'https://ladybird.org/');
    desktop.add(title: 'HN', url: 'https://news.ycombinator.com/', parent: news);
    desktop.add(title: 'Docs', url: 'https://docs.example/', parent: desktop.other);
    desktop.reorder(desktop.bar, 1, 0);
    final phone = device();
    await syncAll([desktop, phone]);
    expect(tree(phone), 'bar[Ladybird, News[HN]] other[Docs]');
    expect(tree(phone), tree(desktop));
    expect(tree(BookmarkStore(phone.file)), tree(phone));
  });

  test('edits on both sides merge item by item', () async {
    final desktop = device();
    final a = desktop.add(title: 'A', url: 'https://a.example/');
    final b = desktop.add(title: 'B', url: 'https://b.example/');
    desktop.add(title: 'C', url: 'https://c.example/');
    final phone = device();
    await syncAll([desktop, phone]);

    clock += 10;
    desktop.remove(b);
    desktop.update(a, title: 'A renamed');
    phone.reorder(phone.bar, 2, 0);
    phone.add(title: 'D', url: 'https://d.example/');
    await syncAll([desktop, phone]);
    expect(tree(desktop), 'bar[C, A renamed, D] other[]');
    expect(tree(phone), tree(desktop));
  });

  test('two devices that imported the same bookmarks do not double them', () async {
    final desktop = device();
    final phone = device();
    for (final store in [desktop, phone]) {
      final work = store.addFolder('Work', parent: store.bar);
      store.add(title: 'Mail', url: 'https://mail.example/', parent: work);
      store.add(title: 'Ladybird', url: 'https://ladybird.org/');
    }
    phone.add(title: 'Wiki', url: 'https://wiki.example/', parent: phone.bar.children!.first);
    await syncAll([desktop, phone]);
    expect(tree(desktop), 'bar[Work[Mail, Wiki], Ladybird] other[]');
    expect(tree(phone), tree(desktop));
  });

  test('a bookmark added to a folder deleted elsewhere moves to Other bookmarks', () async {
    final desktop = device();
    desktop.addFolder('Old', parent: desktop.bar);
    final phone = device();
    await syncAll([desktop, phone]);

    clock += 10;
    desktop.remove(desktop.bar.children!.single);
    phone.add(title: 'Keep me', url: 'https://keep.example/', parent: phone.bar.children!.single);
    await syncAll([desktop, phone]);
    expect(tree(desktop), 'bar[] other[Keep me]');
    expect(tree(phone), tree(desktop));
  });

  test('folders moved into each other on two devices do not vanish', () async {
    final desktop = device();
    desktop.addFolder('X');
    desktop.addFolder('Y');
    final phone = device();
    await syncAll([desktop, phone]);

    clock += 10;
    desktop.update(desktop.other.children![0], parent: desktop.other.children![1]);
    phone.update(phone.other.children![1], parent: phone.other.children![0]);
    await syncAll([desktop, phone]);
    expect(tree(phone), tree(desktop));
    expect(desktop.folders.map((f) => f.$1.title), containsAll(['X', 'Y']));
  });

  test('lots of reordering keeps positions apart', () {
    final store = device();
    for (var i = 0; i < 5; i++) {
      store.add(title: '$i', url: 'https://$i.example/');
    }
    for (var i = 0; i < 80; i++) {
      store.reorder(store.bar, 4, 1);
    }
    final positions = store.bar.children!.map((b) => b.pos).toList();
    expect(positions, [...positions]..sort());
    expect(positions.toSet().length, positions.length);
  });

  test('a bookmarks file from before sync keeps its order', () {
    final file = File('${temp.path}/old/bookmarks.json')..createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({
      'version': 1,
      'showBar': true,
      'roots': {
        'bar': {
          'id': 'bar',
          'title': 'Bookmarks bar',
          'children': [
            {'id': 'z', 'title': 'Z', 'url': 'https://z.example/', 'addedAt': 5},
            {'id': 'a', 'title': 'A', 'url': 'https://a.example/', 'addedAt': 6},
          ],
        },
        'other': {'id': 'other', 'title': 'Other bookmarks', 'children': []},
      },
    }));
    final store = BookmarkStore(file);
    final copy = device()..applySyncDoc(store.toSyncDoc());
    expect(tree(copy), 'bar[Z, A] other[]');
  });

  test('bookmarks live in their own blob', () async {
    final keys = await settings.key.derive();
    expect(keys.bookmarksBlobId, isNot(keys.blobId));
    expect(keys.bookmarksBlobId.length, 64);
    // Older webby versions read only the passwords blob, and an empty bookmarks section isn't written there.
    expect(SyncDoc().toJson().containsKey('bookmarks'), isFalse);
  });
}
