import 'dart:io';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/bookmarks/bookmark_store.dart';
import 'package:webby/src/bookmarks/bookmarks_page.dart';
import 'package:webby/src/history/history_page.dart';
import 'package:webby/src/history/history_store.dart';
import 'package:webby/src/side_panel.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('webby-side-panel'));
  tearDown(() => temp.deleteSync(recursive: true));

  Widget app(Widget child) => KitTheme(
    colors: KitColors.light,
    child: MaterialApp(
      home: Material(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [const Expanded(child: SizedBox()), SizedBox(width: 400, child: child)],
        ),
      ),
    ),
  );

  testWidgets('a page in the sidebar hands back what it opens and closes with its back button', (tester) async {
    final store = BookmarkStore(File('${temp.path}/bookmarks.json'));
    final folder = store.addFolder('Reading');
    store.add(title: 'Ladybird', url: 'https://ladybird.org/');
    store.add(title: 'Example', url: 'https://example.com/', parent: folder);
    final opened = <Object>[];
    var closed = false;
    await tester.pumpWidget(app(SidePanel(
      page: (_) => BookmarksPage(store: store),
      onResult: opened.add,
      onClose: () => closed = true,
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Search bookmarks'), findsOneWidget);

    await tester.tap(find.text('Ladybird'));
    await tester.pumpAndSettle();
    expect(opened, ['https://ladybird.org/']);
    // The page comes back, so the sidebar stays open.
    expect(find.text('Ladybird'), findsOneWidget);
    expect(closed, isFalse);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('history fits the sidebar and opens pages from it', (tester) async {
    final store = HistoryStore(File('${temp.path}/history.jsonl'));
    store.record('https://example.com/a', 'A page with a fairly long title that has to be cut off somewhere');
    final opened = <Object>[];
    await tester.pumpWidget(app(SidePanel(
      page: (_) => HistoryPage(store: store),
      onResult: opened.add,
      onClose: () {},
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.textContaining('A page with'));
    await tester.pumpAndSettle();
    expect(opened, ['https://example.com/a']);
  });
}
