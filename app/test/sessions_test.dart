import 'dart:io';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/site_icon.dart';
import 'package:webby/src/tabs/device_tabs.dart';
import 'package:webby/src/tabs/sessions.dart';
import 'package:webby/src/tabs/sessions_page.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('webby-sessions'));
  tearDown(() => temp.deleteSync(recursive: true));

  File file() => File('${temp.path}/profile/sessions.json');

  const tabs = [
    DeviceTab('', 'about:blank'),
    DeviceTab('Ladybird', 'https://ladybird.org/'),
    DeviceTab('', ''),
    DeviceTab('Example', 'https://example.com/'),
  ];

  test('saves non-blank tabs and keeps the front tab', () {
    final store = SessionStore(file());
    final session = store.save(tabs, name: '  Work ', active: 3, now: DateTime(2026, 10, 12, 9, 5))!;
    expect(session.name, 'Work');
    expect([for (final t in session.tabs) t.url], ['https://ladybird.org/', 'https://example.com/']);
    expect(session.active, 1);

    final reloaded = SessionStore(file());
    expect(reloaded.sessions.single.name, 'Work');
    expect(reloaded.sessions.single.active, 1);
    expect(reloaded.sessions.single.tabs.first.title, 'Ladybird');
  });

  test('an empty name gets one from the date; nothing to save gives null', () {
    final store = SessionStore(file());
    expect(store.save(tabs, now: DateTime(2026, 10, 12, 9, 5))!.name, 'Oct 12, 09:05');
    expect(store.save(const [DeviceTab('', 'about:blank')]), isNull);
    expect(store.sessions, hasLength(1));
  });

  test('rename, delete, undo, delete all and the ask-on-quit setting persist', () {
    final store = SessionStore(file());
    final a = store.save(tabs, name: 'a', now: DateTime(2026, 1, 1))!;
    final b = store.save(tabs, name: 'b', now: DateTime(2026, 1, 2))!;
    expect([for (final s in store.sessions) s.name], ['b', 'a']);
    store.rename(a, 'renamed');
    store.delete(b);
    expect([for (final s in SessionStore(file()).sessions) s.name], ['renamed']);
    store.restoreDeleted(b);
    expect([for (final s in SessionStore(file()).sessions) s.name], ['b', 'renamed']);
    store.askOnQuit = false;
    store.deleteAll();
    final reloaded = SessionStore(file());
    expect(reloaded.sessions, isEmpty);
    expect(reloaded.askOnQuit, isFalse);
  });

  test('a corrupt file is set aside', () {
    file()
      ..createSync(recursive: true)
      ..writeAsStringSync('{nope');
    final store = SessionStore(file());
    expect(store.loadError, isNotNull);
    expect(store.sessions, isEmpty);
  });

  Widget app(Widget child) => KitTheme(
    colors: KitColors.light,
    child: MaterialApp(home: Material(child: child)),
  );

  testWidgets('sessions panel restores, deletes with undo', (tester) async {
    SiteIcon.fetch = false;
    final store = SessionStore(file());
    store.save(tabs, name: 'Morning', active: 3);
    SessionOpen? opened;
    var closed = false;
    await tester.pumpWidget(app(SessionsPanel(
      store: store,
      onOpen: (open) => opened = open,
      onClose: () => closed = true,
    )));
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('2 tabs'), findsOneWidget);

    expect(find.text('Ladybird'), findsOneWidget);
    expect(find.textContaining('Created '), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(store.sessions, isEmpty);
    expect(find.text('Deleted "Morning"'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(store.sessions, hasLength(1));

    await tester.tap(find.text('Restore all'));
    await tester.pumpAndSettle();
    expect(opened!.urls, ['https://ladybird.org/', 'https://example.com/']);
    expect(opened!.active, 1);
    await tester.tap(find.byIcon(Icons.close).first);
    expect(closed, isTrue);
  });

  testWidgets('sessions panel opens and removes single tabs', (tester) async {
    SiteIcon.fetch = false;
    final store = SessionStore(file());
    store.save(tabs, name: 'Morning', active: 3);
    SessionOpen? opened;
    var closed = false;
    await tester.pumpWidget(app(SessionsPanel(
      store: store,
      onOpen: (open) => opened = open,
      onClose: () => closed = true,
    )));

    await tester.tap(find.byIcon(Icons.close).at(1));
    await tester.pump();
    expect(store.sessions.single.tabs.map((t) => t.url), ['https://example.com/']);
    expect(find.text('Removed "Ladybird"'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(store.sessions.single.tabs.map((t) => t.url), ['https://ladybird.org/', 'https://example.com/']);

    // Removing the last tab takes the session with it.
    store.removeTab(store.sessions.single, 0);
    final last = store.sessions.single;
    store.removeTab(last, 0);
    expect(store.sessions, isEmpty);
    store.restoreTab(last, const DeviceTab('Ladybird', 'https://ladybird.org/'), 0);
    expect(store.sessions.single.tabs, hasLength(1));
    await tester.pump();

    await tester.tap(find.text('Ladybird'));
    await tester.pumpAndSettle();
    expect(opened!.urls, ['https://ladybird.org/']);
    expect(closed, isFalse);
  });

  testWidgets('quit prompt returns the choice and can stop asking', (tester) async {
    final store = SessionStore(file());
    (QuitChoice, String)? result;
    await tester.pumpWidget(app(Builder(
      builder: (context) => KitButton('quit', onPressed: () async {
        result = await askSaveOnQuit(context, tabCount: 2, store: store);
      }),
    )));
    await tester.tap(find.text('quit'));
    await tester.pumpAndSettle();
    expect(find.text('Save open tabs as a session?'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'Evening');
    await tester.tap(find.text('Don\'t ask again'));
    await tester.pump();
    await tester.tap(find.text('Save and close'));
    await tester.pumpAndSettle();
    expect(result, (QuitChoice.save, 'Evening'));
    expect(store.askOnQuit, isFalse);
  });
}
