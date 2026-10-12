import 'dart:io';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/passwords/sync/sync_doc.dart';
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

  test('rename, delete, undo and delete all persist', () {
    final store = SessionStore(file());
    final a = store.save(tabs, name: 'a', now: DateTime(2026, 1, 1))!;
    final b = store.save(tabs, name: 'b', now: DateTime(2026, 1, 2))!;
    expect([for (final s in store.sessions) s.name], ['b', 'a']);
    store.rename(a, 'renamed');
    store.delete(b);
    expect([for (final s in SessionStore(file()).sessions) s.name], ['renamed']);
    store.restoreDeleted(b);
    expect([for (final s in SessionStore(file()).sessions) s.name], ['b', 'renamed']);
    store.deleteAll();
    final reloaded = SessionStore(file());
    expect(reloaded.sessions, isEmpty);
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

  test('sessions sync: two devices merge saves, renames and deletes', () {
    final desk = SessionStore(File('${temp.path}/desk/sessions.json'));
    final phone = SessionStore(File('${temp.path}/phone/sessions.json'));
    final work = desk.save(tabs, name: 'Work', active: 3, now: DateTime(2026, 1, 1))!;
    final old = desk.save(tabs, name: 'Old', now: DateTime(2026, 1, 2))!;
    phone.save(const [DeviceTab('News', 'https://news.example/')], name: 'Reading', now: DateTime(2026, 1, 3));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    void sync() {
      final merged = mergeDocs(desk.toSyncDoc(), phone.toSyncDoc(), now: now);
      desk.applySyncDoc(merged);
      phone.applySyncDoc(merged);
    }

    sync();
    expect([for (final s in phone.sessions) s.name], ['Reading', 'Old', 'Work']);
    expect(phone.sessions.last.active, 1);
    expect(desk.applySyncDoc(mergeDocs(desk.toSyncDoc(), phone.toSyncDoc(), now: now)), isFalse);

    // The phone renames Work, the desk deletes Old: both reach the other device and survive a reload.
    phone.rename(phone.sessions.firstWhere((s) => s.id == work.id), 'Work stuff');
    desk.delete(old);
    sync();
    expect([for (final s in desk.sessions) s.name], ['Reading', 'Work stuff']);
    expect(identical(desk.sessions.last, work), isTrue, reason: 'updated in place so Undo still finds it');
    expect([for (final s in SessionStore(File('${temp.path}/phone/sessions.json')).sessions) s.name],
        ['Reading', 'Work stuff']);
    expect(isDeleted(SessionStore(File('${temp.path}/phone/sessions.json')).toSyncDoc().sessions[old.id]!), isTrue);

    // Undo of the delete wins over the tombstone; removing a tab syncs too.
    desk.restoreDeleted(old);
    desk.removeTab(work, 0);
    sync();
    expect([for (final s in phone.sessions) s.name], ['Reading', 'Old', 'Work stuff']);
    expect(phone.sessions.last.tabs.single.url, 'https://example.com/');
    expect(phone.sessions.last.active, 0);

    phone.deleteAll();
    sync();
    expect(desk.sessions, isEmpty);
  });
}
