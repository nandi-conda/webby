import 'package:flatkit/flatkit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/tab_strip.dart';

void main() {
  test('tabTitle prefers the page title, then the URL, then "New tab"', () {
    expect(tabTitle(' Example ', 'https://example.com/'), 'Example');
    expect(tabTitle('', 'https://example.com/a'), 'example.com/a');
    expect(tabTitle('', ''), 'New tab');
    expect(tabTitle('', 'about:blank'), 'New tab');
  });

  testWidgets('selects, closes and opens tabs', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TabStrip(
            tabs: const [
              TabLabel(title: 'One'),
              TabLabel(title: 'Two', loading: true),
            ],
            active: 0,
            onSelect: (i) => events.add('select $i'),
            onClose: (i) => events.add('close $i'),
            onNew: () => events.add('new'),
          ),
        ),
      ),
    );
    expect(find.text('One'), findsOneWidget);
    expect(find.byType(KitSpinner), findsOneWidget);

    await tester.tap(find.text('Two'));
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.tap(find.byIcon(Icons.add));
    expect(events, ['select 1', 'close 0', 'new']);
  });

  testWidgets('right-click opens the menu for a tab or for the empty strip', (tester) async {
    final opened = <int?>[];
    final picked = <String>[];
    Widget strip({bool vertical = false}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 800,
            height: 400,
            // Laid out like the browser does: the vertical list sits in a row beside the page.
            child: Flex(
              direction: vertical ? Axis.horizontal : Axis.vertical,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TabStrip(
                  tabs: const [
                    TabLabel(title: 'One'),
                    TabLabel(title: 'Two'),
                  ],
                  active: 0,
                  vertical: vertical,
                  onSelect: (_) {},
                  onClose: (_) {},
                  onNew: () {},
                  menuItems: (tab) {
                    opened.add(tab);
                    return [KitMenuItem('Vertical tabs', checked: vertical, onSelected: () => picked.add('toggle'))];
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(strip());
    await tester.tap(find.text('Two'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(opened.last, 1);
    await tester.tap(find.text('Vertical tabs'));
    await tester.pumpAndSettle();
    expect(picked, ['toggle']);

    await tester.tapAt(const Offset(700, 15), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(opened.last, isNull);
    expect(find.text('Vertical tabs'), findsOneWidget);
    await tester.tapAt(const Offset(700, 300));
    await tester.pumpAndSettle();

    // A long press is the touch screen's right-click.
    await tester.longPress(find.text('One'));
    await tester.pumpAndSettle();
    expect(opened.last, 0);
    expect(find.text('Vertical tabs'), findsOneWidget);

    // The vertical list is a fixed-width column.
    await tester.pumpWidget(strip(vertical: true));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TabStrip)).width, TabStrip.verticalWidth);
  });

  testWidgets('double-clicking empty strip space opens a new tab', (tester) async {
    for (final vertical in [false, true]) {
      var opened = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: Flex(
              direction: vertical ? Axis.horizontal : Axis.vertical,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TabStrip(
                  tabs: const [TabLabel(title: 'One')],
                  active: 0,
                  vertical: vertical,
                  onSelect: (_) {},
                  onClose: (_) {},
                  onNew: () => opened++,
                ),
              ],
            ),
          ),
        ),
      ));
      final at = vertical ? const Offset(100, 350) : const Offset(700, 15);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(opened, 1, reason: vertical ? 'vertical' : 'horizontal');
    }
  });

  testWidgets('on a narrow screen many tabs keep readable widths and scroll to the active one', (tester) async {
    Widget strip(int active) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: TabStrip(
                  tabs: [for (var i = 0; i < 6; i++) TabLabel(title: 'Tab $i')],
                  active: active,
                  onSelect: (_) {},
                  onClose: (_) {},
                  onNew: () {},
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(strip(0));
    expect(tester.getSize(find.ancestor(of: find.text('Tab 0'), matching: find.byType(KitTooltip))).width, 120);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('Tab 5'), findsNothing);

    await tester.pumpWidget(strip(5));
    await tester.pumpAndSettle();
    expect(find.text('Tab 5'), findsOneWidget);
    expect(tester.getRect(find.text('Tab 5')).right, lessThanOrEqualTo(400 - 36));
  });

  testWidgets('pinned tabs are small, show the site letter and have no close button', (tester) async {
    for (final vertical in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 400,
              child: Flex(
                direction: vertical ? Axis.horizontal : Axis.vertical,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TabStrip(
                    tabs: const [
                      TabLabel(title: 'Mail', url: 'https://www.mail.example/', pinned: true),
                      TabLabel(title: 'One'),
                    ],
                    active: 1,
                    vertical: vertical,
                    onSelect: (_) {},
                    onClose: (_) {},
                    onNew: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('M'), findsOneWidget);
      expect(find.text('Mail'), findsNothing);
      expect(find.text('One'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    }
  });

  test('tabInitial uses the site, else the title', () {
    expect(tabInitial('Mail', 'https://www.mail.example/'), 'M');
    expect(tabInitial('docs', 'about:blank'), 'D');
    expect(tabInitial('', ''), '');
  });
}
