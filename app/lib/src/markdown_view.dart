import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

/// One block of a markdown document, as [parseMarkdown] splits it.
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

/// A list item; [marker] is "•" for bullets or "3." for numbered items. [depth] counts indent levels.
class MdListItem extends MdBlock {
  const MdListItem(this.marker, this.text, {this.depth = 0});
  final String marker;
  final String text;
  final int depth;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.code);
  final String code;
}

class MdRule extends MdBlock {
  const MdRule();
}

final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _bullet = RegExp(r'^(\s*)[-*+•]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d{1,3})[.)]\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');

/// Splits [source] into blocks. It copes with half-written text, so a summary can be shown while it streams in: an
/// unclosed code fence runs to the end, and unclosed inline markers stay as they are.
List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  final paragraph = <String>[];
  final quote = <String>[];
  void flush() {
    if (paragraph.isNotEmpty) blocks.add(MdParagraph(paragraph.join(' ')));
    if (quote.isNotEmpty) blocks.add(MdQuote(quote.join(' ')));
    paragraph.clear();
    quote.clear();
  }

  final lines = source.replaceAll('\r\n', '\n').split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      flush();
      final code = <String>[];
      for (i++; i < lines.length && !lines[i].trim().startsWith('```'); i++) {
        code.add(lines[i]);
      }
      blocks.add(MdCode(code.join('\n').trimRight()));
      continue;
    }
    if (trimmed.isEmpty) {
      flush();
      continue;
    }
    final heading = _heading.firstMatch(trimmed);
    if (heading != null) {
      flush();
      blocks.add(MdHeading(heading[1]!.length, heading[2]!));
      continue;
    }
    if (_rule.hasMatch(line)) {
      flush();
      blocks.add(const MdRule());
      continue;
    }
    final bullet = _bullet.firstMatch(line);
    if (bullet != null) {
      flush();
      blocks.add(MdListItem('•', bullet[2]!, depth: _depth(bullet[1]!)));
      continue;
    }
    final numbered = _numbered.firstMatch(line);
    if (numbered != null) {
      flush();
      blocks.add(MdListItem('${numbered[2]}.', numbered[3]!, depth: _depth(numbered[1]!)));
      continue;
    }
    if (trimmed.startsWith('>')) {
      if (paragraph.isNotEmpty) flush();
      quote.add(trimmed.replaceFirst(RegExp(r'^>\s?'), ''));
      continue;
    }
    // A plain line right after a list item continues that item.
    if (paragraph.isEmpty && quote.isEmpty && blocks.isNotEmpty && blocks.last is MdListItem &&
        line.startsWith(RegExp(r'\s'))) {
      final item = blocks.removeLast() as MdListItem;
      blocks.add(MdListItem(item.marker, '${item.text} $trimmed', depth: item.depth));
      continue;
    }
    if (quote.isNotEmpty) flush();
    paragraph.add(trimmed);
  }
  flush();
  return blocks;
}

int _depth(String indent) => (indent.replaceAll('\t', '    ').length / 2).floor().clamp(0, 4);

final _inline = RegExp(r'(\*\*|__)(.+?)\1|`([^`]+)`|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)|(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?!\w)|~~(.+?)~~|\[([^\]]+)\]\(([^)\n]+)\)');

/// Inline markdown in [text] (bold, italic, code, strikethrough, links shown as their text) as spans over [base].
/// Links to `#words` are anchors into the page: with [onAnchor] they are clickable and call it with the words.
List<InlineSpan> markdownSpans(String text, TextStyle base,
    {required Color codeBackground, Color? linkColor, void Function(String words)? onAnchor}) {
  final spans = <InlineSpan>[];
  var at = 0;
  for (final match in _inline.allMatches(text)) {
    if (match.start > at) spans.add(TextSpan(text: text.substring(at, match.start)));
    if (match[2] != null) {
      spans.add(TextSpan(
        children: markdownSpans(match[2]!, base, codeBackground: codeBackground, linkColor: linkColor, onAnchor: onAnchor),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ));
    } else if (match[3] != null) {
      spans.add(TextSpan(
        text: match[3],
        style: TextStyle(fontFamily: 'monospace', fontSize: (base.fontSize ?? 14) * 0.92, backgroundColor: codeBackground),
      ));
    } else if (match[4] != null || match[5] != null) {
      spans.add(TextSpan(
        children: markdownSpans(match[4] ?? match[5]!, base, codeBackground: codeBackground, linkColor: linkColor, onAnchor: onAnchor),
        style: const TextStyle(fontStyle: FontStyle.italic),
      ));
    } else if (match[6] != null) {
      spans.add(TextSpan(text: match[6], style: const TextStyle(decoration: TextDecoration.lineThrough)));
    } else if (match[7] != null) {
      final target = match[8]!.trim();
      final words = target.startsWith('#') ? _anchorWords(target.substring(1)) : '';
      final style = TextStyle(color: linkColor, decoration: TextDecoration.underline);
      if (words.isEmpty) {
        spans.add(TextSpan(text: match[7], style: style));
      } else if (onAnchor != null) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          // Kept out of the panel's text selection, whose I-beam would otherwise win over the hand cursor, and
          // padded so the small § is easy to hit.
          child: SelectionContainer.disabled(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              opaque: true,
              child: Tooltip(
                message: 'Go to “$words”',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onAnchor(words),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    child: Text(match[7]!, style: base.merge(style).copyWith(decoration: TextDecoration.none)),
                  ),
                ),
              ),
            ),
          ),
        ));
      }
    }
    at = match.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}

/// The page words an anchor link (`[§](#words)`) points at, with URL escapes and stray quotes undone.
String _anchorWords(String target) {
  final words = target.replaceAllMapped(RegExp(r'(%[0-9A-Fa-f]{2})+'), (m) {
    try {
      return Uri.decodeComponent(m[0]!);
    } catch (_) {
      return m[0]!;
    }
  });
  return words.replaceAll(RegExp(r'^[\s"“”‘’]+|[\s"“”‘’]+$'), '').replaceAll(RegExp(r'\s+'), ' ');
}

/// Renders markdown with flatkit colours. Wrap it in a [SelectionArea] to make the text selectable. Anchor links
/// (`[§](#words)`) call [onAnchor] when clicked and are left out without it.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.source, {super.key, this.onAnchor});

  final String source;
  final void Function(String words)? onAnchor;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final body = KitText.body(context).copyWith(height: 1.45);
    final codeBackground = c.hover;
    Widget rich(String text, TextStyle style) => Text.rich(
      TextSpan(style: style, children: markdownSpans(text, style, codeBackground: codeBackground, linkColor: c.accent, onAnchor: onAnchor)),
    );

    final children = <Widget>[];
    MdBlock? previous;
    for (final block in parseMarkdown(source)) {
      final gap = switch ((previous, block)) {
        (null, _) => 0.0,
        (MdListItem(), MdListItem()) => 3.0,
        (_, MdHeading()) => 14.0,
        _ => 8.0,
      };
      if (gap > 0) children.add(SizedBox(height: gap));
      previous = block;
      switch (block) {
        case MdHeading(:final level, :final text):
          final size = (body.fontSize ?? 14) * switch (level) { 1 => 1.35, 2 => 1.2, 3 => 1.08, _ => 1.0 };
          children.add(rich(text, body.copyWith(fontSize: size, fontWeight: FontWeight.w700, height: 1.3)));
        case MdParagraph(:final text):
          children.add(rich(text, body));
        case MdListItem(:final marker, :final text, :final depth):
          children.add(Padding(
            padding: EdgeInsets.only(left: 4.0 + depth * 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: marker == '•' ? 14 : 22,
                  child: Text(marker, style: body.copyWith(color: c.textDim)),
                ),
                Expanded(child: rich(text, body)),
              ],
            ),
          ));
        case MdQuote(:final text):
          children.add(Container(
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: c.border, width: 3))),
            child: rich(text, body.copyWith(color: c.textDim)),
          ));
        case MdCode(:final code):
          children.add(Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: codeBackground, borderRadius: BorderRadius.circular(kitRadius)),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(code, style: body.copyWith(fontFamily: 'monospace', fontSize: (body.fontSize ?? 14) * 0.92)),
            ),
          ));
        case MdRule():
          children.add(Container(height: 1, color: c.border));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
