import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/bookmarks/bookmark_bar.dart';
import 'package:webby/src/bookmarks/bookmark_dialog.dart';
import 'package:webby/src/bookmarks/bookmark_html.dart';
import 'package:webby/src/bookmarks/bookmark_store.dart';
import 'package:webby/src/bookmarks/bookmarks_page.dart';

void main() {
  late Directory temp;
  late File file;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webby-bookmarks');
    file = File('${temp.path}/profiles/default/bookmarks.json');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  group('store', () {
    test('adds, persists and reloads', () {
      final store = BookmarkStore(file);
      final folder = store.addFolder('Reading');
      store.add(title: 'Ladybird', url: 'https://ladybird.org/');
      store.add(title: 'Example', url: 'https://example.com/', parent: folder);
      store.showBar = false;

      final reloaded = BookmarkStore(file);
      expect(reloaded.showBar, isFalse);
      expect(reloaded.bar.children!.single.url, 'https://ladybird.org/');
      final reading = reloaded.other.children!.single;
      expect(reading.isFolder, isTrue);
      expect(reading.children!.single.title, 'Example');
      expect(reloaded.bookmarkFor('https://example.com/')?.title, 'Example');
      expect(reloaded.bookmarkFor('https://nope.example/'), isNull);
      expect(jsonDecode(file.readAsStringSync())['version'], 1);
    });

    test('moves, refuses to nest a folder in itself, reorders and removes', () {
      final store = BookmarkStore(file);
      final a = store.addFolder('A');
      final b = store.addFolder('B', parent: a);
      final link = store.add(title: 'x', url: 'https://x.example/');
      store.update(link, parent: b, title: 'X');
      expect(store.parentOf(link), same(b));
      expect(link.title, 'X');

      store.update(a, parent: b);
      expect(store.parentOf(a), same(store.other));

      store.add(title: 'one', url: 'https://1.example/');
      store.add(title: 'two', url: 'https://2.example/');
      store.reorder(store.bar, 1, 0);
      expect(store.bar.children!.map((n) => n.title), ['two', 'one']);

      store.remove(a);
      expect(store.find(link.id), isNull);
      expect(BookmarkStore(file).other.children, isEmpty);
    });

    test('sets aside a corrupt file', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{not json');
      final store = BookmarkStore(file);
      expect(store.loadError, isNotNull);
      expect(store.bar.children, isEmpty);
      expect(file.parent.listSync().whereType<File>().any((f) => f.path.contains('.corrupt-')), isTrue);
    });
  });

  group('html', () {
    test('round-trips through bookmarks.html', () {
      final store = BookmarkStore(file);
      store.add(title: 'Tom & "Jerry" <3', url: 'https://example.com/?a=1&b=2');
      final folder = store.addFolder('Docs');
      store.add(title: 'Dart', url: 'https://dart.dev/', parent: folder);

      final parsed = parseBookmarksHtml(exportBookmarksHtml(store));
      expect(parsed.toolbar.single.title, 'Tom & "Jerry" <3');
      expect(parsed.toolbar.single.url, 'https://example.com/?a=1&b=2');
      expect(parsed.other.single.title, 'Docs');
      expect(parsed.other.single.children!.single.url, 'https://dart.dev/');

      final target = BookmarkStore(File('${temp.path}/other.json'));
      expect(target.import(toBar: parsed.toolbar, toOther: parsed.other), 2);
      expect(target.bar.children!.single.url, 'https://example.com/?a=1&b=2');
      final imported = target.other.children!.single;
      expect(imported.title, 'Imported');
      expect(imported.children!.single.children!.single.title, 'Dart');
      // Importing again doesn't duplicate what's already on the bar.
      expect(target.import(toBar: parsed.toolbar, toOther: const []), 0);
    });

    test('reads a Firefox export', () {
      const html = '''<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks Menu</H1>
<DL><p>
    <DT><A HREF="place:type=6&sort=14&maxResults=10" ADD_DATE="1">Recent Tags</A>
    <DT><H3 ADD_DATE="1600000000" LAST_MODIFIED="1600000001">Mozilla Firefox</H3>
    <DL><p>
        <DT><A HREF="https://support.mozilla.org/" ADD_DATE="1600000000" ICON="data:image/png;base64,AAA=">Get Help</A>
    </DL><p>
    <DT><H3 ADD_DATE="1600000000" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3>
    <DL><p>
        <DT><A HREF="https://www.mozilla.org/about/" ADD_DATE="1600000000">About Us &#38; more</A>
    </DL><p>
</DL>''';
      final parsed = parseBookmarksHtml(html);
      expect(parsed.linkCount, 2);
      expect(parsed.toolbar.single.title, 'About Us & more');
      expect(parsed.other.single.title, 'Mozilla Firefox');
      expect(parsed.other.single.children!.single.addedAt, 1600000000);
    });
  });

  group('ui', () {
    testWidgets('star flow adds a bookmark that shows on the bar and opens', (tester) async {
      final store = BookmarkStore(file);
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  BookmarkBar(store: store, onOpen: (url) => opened = url),
                  TextButton(
                    onPressed: () =>
                        bookmarkPage(context, url: 'https://ladybird.org/', title: 'Ladybird', store: store),
                    child: const Text('star'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('Ctrl+D'), findsOneWidget);

      await tester.tap(find.text('star'));
      await tester.pumpAndSettle();
      expect(find.text('Bookmark added'), findsOneWidget);
      // The first field is the name.
      await tester.enterText(find.byType(TextField).first, 'LB');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(store.bookmarkFor('https://ladybird.org/')?.title, 'LB');
      await tester.tap(find.text('LB'));
      expect(opened, 'https://ladybird.org/');

      // Starring it again edits the same bookmark; Remove deletes it.
      await tester.tap(find.text('star'));
      await tester.pumpAndSettle();
      expect(find.text('Edit bookmark'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(store.bar.children, isEmpty);
    });

    testWidgets('bar opens bookmarks in new tabs from the right-click menu and middle-click', (tester) async {
      final store = BookmarkStore(file);
      store.add(title: 'Ladybird', url: 'https://ladybird.org/');
      final folder = store.addFolder('Docs', parent: store.bar);
      store.add(title: 'Dart', url: 'https://dart.dev/', parent: folder);
      store.add(title: 'Flutter', url: 'https://flutter.dev/', parent: folder);
      final opened = <String>[];
      final newTabs = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookmarkBar(store: store, onOpen: opened.add, onOpenInNewTab: newTabs.add),
          ),
        ),
      );

      await tester.tap(find.text('Ladybird'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in new tab'));
      await tester.pumpAndSettle();
      expect(newTabs, ['https://ladybird.org/']);

      await tester.tap(find.text('Ladybird'), buttons: kMiddleMouseButton);
      await tester.pumpAndSettle();
      expect(newTabs, ['https://ladybird.org/', 'https://ladybird.org/']);
      expect(opened, isEmpty);

      // A folder offers all its links; they're added last first so the tabs end up in folder order.
      newTabs.clear();
      await tester.tap(find.text('Docs'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open all 2 in new tabs'));
      await tester.pumpAndSettle();
      expect(newTabs, ['https://flutter.dev/', 'https://dart.dev/']);
    });

    testWidgets('bar grows with a large system font so labels are not clipped', (tester) async {
      final store = BookmarkStore(file);
      store.add(title: 'Ladybird', url: 'https://ladybird.org/');
      Widget app() => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800), textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: Column(children: [BookmarkBar(store: store, onOpen: (_) {}), const Expanded(child: SizedBox())]),
          ),
        ),
      );
      await tester.pumpWidget(app());
      final bar = tester.getRect(find.byType(BookmarkBar));
      expect(bar.height, greaterThan(30));
      final label = tester.getRect(find.text('Ladybird'));
      expect(label.top, greaterThanOrEqualTo(bar.top));
      expect(label.bottom, lessThanOrEqualTo(bar.bottom));

      // The empty-state hint wraps on a phone-width screen; the bar grows to fit it.
      store.remove(store.bar.children!.single);
      await tester.pump();
      final empty = tester.getRect(find.byType(BookmarkBar));
      final hint = tester.getRect(find.textContaining('Ctrl+D'));
      expect(hint.bottom, lessThanOrEqualTo(empty.bottom));
    });

    testWidgets('manager browses folders, deletes and opens', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = BookmarkStore(file);
      final folder = store.addFolder('Docs');
      store.add(title: 'Dart', url: 'https://dart.dev/', parent: folder);
      store.add(title: 'Flutter', url: 'https://flutter.dev/', parent: folder);

      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await Navigator.of(
                context,
              ).push<String>(MaterialPageRoute(builder: (_) => BookmarksPage(store: store))),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No bookmarks yet'), findsOneWidget);
      await tester.tap(find.text('Docs').first);
      await tester.pumpAndSettle();
      expect(find.text('https://flutter.dev/'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      expect(store.bookmarkFor('https://dart.dev/'), isNull);

      await tester.enterText(find.widgetWithText(TextField, 'Search bookmarks'), 'flut');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flutter'));
      await tester.pumpAndSettle();
      expect(result, 'https://flutter.dev/');
    });
  });
}
