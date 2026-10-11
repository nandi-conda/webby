import 'package:flatkit/flatkit.dart';
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
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TabStrip(
          tabs: const [TabLabel(title: 'One'), TabLabel(title: 'Two', loading: true)],
          active: 0,
          onSelect: (i) => events.add('select $i'),
          onClose: (i) => events.add('close $i'),
          onNew: () => events.add('new'),
        ),
      ),
    ));
    expect(find.text('One'), findsOneWidget);
    expect(find.byType(KitSpinner), findsOneWidget);

    await tester.tap(find.text('Two'));
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.tap(find.byIcon(Icons.add));
    expect(events, ['select 1', 'close 0', 'new']);
  });
}
