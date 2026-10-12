import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/markdown_view.dart';

String plain(List<InlineSpan> spans) => spans.map((s) => s.toPlainText()).join();

void main() {
  test('splits blocks', () {
    final blocks = parseMarkdown('### Topic\nIntro line\ncontinues.\n\n- one\n  more\n* two\n1. first\n> quoted\n---\n```\ncode\n');
    expect(blocks.map((b) => b.runtimeType.toString()), [
      'MdHeading', 'MdParagraph', 'MdListItem', 'MdListItem', 'MdListItem', 'MdQuote', 'MdRule', 'MdCode',
    ]);
    expect((blocks[1] as MdParagraph).text, 'Intro line continues.');
    expect((blocks[2] as MdListItem).text, 'one more');
    expect((blocks[4] as MdListItem).marker, '1.');
    expect((blocks.last as MdCode).code, 'code');
  });

  test('inline styles, and half-streamed markers stay literal', () {
    const base = TextStyle(fontSize: 14);
    final spans = markdownSpans('a **bold** `x` *it* [link](https://e.com) **open', base, codeBackground: Colors.grey);
    expect(plain(spans), 'a bold x it link **open');
    expect((spans[1] as TextSpan).style!.fontWeight, FontWeight.w700);
    expect(plain(markdownSpans('snake_case_name and 2*3*4', base, codeBackground: Colors.grey)), 'snake_case_name and 2*3*4');
  });

  testWidgets('renders', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: const KitTheme(
        colors: KitColors.light,
        child: Material(child: MarkdownView('## Head\n- **a** item\n\nText')),
      ),
    ));
    expect(find.textContaining('Head'), findsOneWidget);
    expect(find.textContaining('a item'), findsOneWidget);
  });

  testWidgets('anchor links jump into the page, and are left out without a handler', (tester) async {
    final jumps = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: KitTheme(
        colors: KitColors.light,
        child: Material(child: MarkdownView('- Point [§](#The Early Years%20of “X”)', onAnchor: jumps.add)),
      ),
    ));
    await tester.tap(find.text('§'));
    expect(jumps, ['The Early Years of “X']);
    const base = TextStyle(fontSize: 14);
    expect(plain(markdownSpans('Point [§](#some words)', base, codeBackground: Colors.grey)), 'Point ');
  });
}
