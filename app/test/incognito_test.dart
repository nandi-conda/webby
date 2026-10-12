import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/context_menu.dart';
import 'package:webby/src/incognito.dart';

void main() {
  group('Incognito.ladybirdArgs', () {
    test('adds the forgetful engine flags', () {
      expect(Incognito.ladybirdArgs(''), '--temporary-profile --disable-sql-database --disable-http-disk-cache');
    });

    test('keeps other flags and drops any profile choice', () {
      expect(
        Incognito.ladybirdArgs('--disable-sandbox --profile work  --profile-path=/x --force-new-process --dot'),
        '--disable-sandbox --dot --temporary-profile --disable-sql-database --disable-http-disk-cache',
      );
    });

    test('does not repeat flags that are already there', () {
      expect(Incognito.ladybirdArgs('--disable-http-disk-cache'),
          '--temporary-profile --disable-sql-database --disable-http-disk-cache');
    });
  });

  test('context menu offers an incognito window for links only when asked', () {
    const link = ContextMenuTarget(link: 'https://example.com/');
    List<String?> ids({required bool incognito}) => contextMenuEntries(link,
            canGoBack: false,
            canGoForward: false,
            canOpenInNewTab: true,
            clipboardHasText: false,
            canOpenIncognito: incognito)
        .map((e) => e.id)
        .toList();
    expect(ids(incognito: true), contains('openLinkIncognito'));
    expect(ids(incognito: false), isNot(contains('openLinkIncognito')));
  });

  testWidgets('incognito badge and new-tab page lay out', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: KitTheme.material(Incognito.colors),
      home: const Material(child: Column(children: [IncognitoBadge(), Expanded(child: IncognitoNewTab())])),
    ));
    expect(find.text('Incognito'), findsOneWidget);
    expect(find.text("You've gone incognito"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
