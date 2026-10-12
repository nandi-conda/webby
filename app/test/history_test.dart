import 'dart:io';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/history/history_page.dart';
import 'package:webby/src/history/history_store.dart';
import 'package:webby/src/incognito.dart';
import 'package:webby/src/omnibox.dart';

void main() {
  late Directory dir;
  late File file;
  var now = DateTime(2026, 10, 12, 15, 30).millisecondsSinceEpoch;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('webby-history');
    file = File('${dir.path}/profile/history.jsonl');
    now = DateTime(2026, 10, 12, 15, 30).millisecondsSinceEpoch;
    historyClock = () => now;
  });

  tearDown(() {
    Incognito.active = false;
    dir.deleteSync(recursive: true);
  });

  group('store', () {
    test('records visits with their titles and reads them back', () {
      final store = HistoryStore(file);
      final visit = store.record('https://ladybird.org/', '')!;
      now += 1000;
      store.setTitle(visit, 'Ladybird');
      store.record('https://example.com/a', 'A');
      expect(store.record('about:blank', ''), isNull);
      expect(store.record('data:text/html,hi', ''), isNull);

      final again = HistoryStore(file);
      expect([for (final e in again.entries) (e.url, e.title)], [
        ('https://example.com/a', 'A'),
        ('https://ladybird.org/', 'Ladybird'),
      ]);
    });

    test('incognito windows record nothing', () {
      Incognito.active = true;
      final store = HistoryStore(file);
      expect(store.record('https://ladybird.org/', 'Ladybird'), isNull);
      expect(file.existsSync(), isFalse);
    });

    test('remove and clear rewrite the file, keeping visits other windows added', () {
      final store = HistoryStore(file);
      final old = store.record('https://old.example/', 'Old')!;
      now += Duration.millisecondsPerDay;
      store.record('https://new.example/', 'New');
      // Another window appends a visit.
      now += 1000;
      HistoryStore(file).record('https://other.example/', 'Other');

      store.remove([old]);
      expect(file.readAsStringSync(), isNot(contains('old.example')));
      expect([for (final e in HistoryStore(file).entries) e.url], ['https://other.example/', 'https://new.example/']);

      store.clear(since: DateTime.fromMillisecondsSinceEpoch(now));
      expect([for (final e in HistoryStore(file).entries) e.url], ['https://new.example/']);
      store.clear();
      expect(HistoryStore(file).length, 0);
      expect(file.readAsStringSync(), isEmpty);
    });

    test('drops visits older than 90 days', () {
      final store = HistoryStore(file);
      store.record('https://ancient.example/', '');
      now += const Duration(days: 91).inMilliseconds;
      store.record('https://recent.example/', '');
      expect([for (final e in HistoryStore(file).entries) e.url], ['https://recent.example/']);
    });

    test('search matches every word in the title or address', () {
      final store = HistoryStore(file)
        ..record('https://news.ycombinator.com/', 'Hacker News')
        ..record('https://ladybird.org/news', 'Ladybird news');
      expect([for (final e in store.search('ladybird NEWS')) e.title], ['Ladybird news']);
      expect(store.search('news').length, 2);
      expect(store.search('').length, 2);
    });

    test('suggestions put typed-prefix sites first, then frequent pages, one per address', () {
      final store = HistoryStore(file);
      for (var i = 0; i < 5; i++) {
        store.record('https://example.com/github-notes', 'Notes about GitHub');
      }
      store.record('https://github.com/nandi-conda/webby', 'webby');
      store.record('https://github.com/', 'GitHub');
      final urls = [for (final s in store.suggest('git')) s.url];
      expect(urls, ['https://github.com/', 'https://github.com/nandi-conda/webby', 'https://example.com/github-notes']);
      expect(store.suggest('github.com/nandi').single.title, 'webby');
      expect(store.suggest('   '), isEmpty);
    });
  });

  test('day headings', () {
    final now = DateTime(2026, 10, 12, 9);
    expect(historyDayLabel(DateTime(2026, 10, 12, 1), now), 'Today - Monday, October 12, 2026');
    expect(historyDayLabel(DateTime(2026, 10, 11, 23), now), 'Yesterday - Sunday, October 11, 2026');
    expect(historyDayLabel(DateTime(2026, 9, 30), now), 'Wednesday, September 30, 2026');
  });

  group('ui', () {
    testWidgets('history page groups by day, deletes and opens', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = HistoryStore(file);
      now = DateTime.now().millisecondsSinceEpoch;
      store.record('https://ladybird.org/', 'Ladybird');
      now -= Duration.millisecondsPerDay;
      store.record('https://example.com/', 'Example');
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => opened = await Navigator.of(context)
                  .push<String>(MaterialPageRoute(builder: (_) => HistoryPage(store: store))),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Today - '), findsOneWidget);
      expect(find.textContaining('Yesterday - '), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'examp');
      await tester.pump();
      expect(find.text('Ladybird'), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(find.text('Example'), findsNothing);
      expect(HistoryStore(file).length, 1);

      await tester.tap(find.text('Ladybird'));
      await tester.pumpAndSettle();
      expect(opened, 'https://ladybird.org/');
    });

    testWidgets('clear history dialog clears all time', (tester) async {
      final store = HistoryStore(file)..record('https://ladybird.org/', 'Ladybird');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showClearHistoryDialog(context, store: store),
              child: const Text('clear'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('clear'));
      await tester.pumpAndSettle();
      expect(find.text('All time'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(store.length, 0);
    });

    testWidgets('address bar suggests from history; arrows pick, Enter opens', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = HistoryStore(file)
        ..record('https://github.com/', 'GitHub')
        ..record('https://gitlab.com/', 'GitLab');
      final address = TextEditingController();
      final focus = FocusNode();
      final submitted = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: KitTheme(
              colors: KitColors.light,
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: 600,
                  child: Omnibox(
                  controller: address,
                  focusNode: focus,
                  url: '',
                  onSubmitted: submitted.add,
                  suggest: (input) => [for (final s in store.suggest(input)) OmniboxSuggestion(s.url, s.title)],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'git');
      await tester.pump();
      expect(find.text('https://github.com/'), findsOneWidget);
      expect(find.text('https://gitlab.com/'), findsOneWidget);

      // Typed text first; Enter without picking goes where it was typed.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(submitted.single, store.suggest('git')[1].url);
      expect(find.text('https://github.com/'), findsNothing);

      await tester.enterText(find.byType(TextField), 'gitl');
      await tester.pump();
      await tester.tap(find.text('https://gitlab.com/'));
      await tester.pump();
      expect(submitted, hasLength(2));
      expect(submitted.last, 'https://gitlab.com/');

      await tester.enterText(find.byType(TextField), 'gith');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('https://github.com/'), findsNothing);
    });
  });
}
