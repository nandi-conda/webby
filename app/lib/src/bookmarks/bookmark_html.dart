import 'bookmark_store.dart';

/// Reads and writes the Netscape bookmark file format (bookmarks.html) that Firefox, Chrome and Safari all export.

String _escape(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _unescape(String text) => text.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (m) {
  final entity = m[1]!;
  if (entity.startsWith('#x') || entity.startsWith('#X')) {
    return String.fromCharCode(int.tryParse(entity.substring(2), radix: 16) ?? 0xfffd);
  }
  if (entity.startsWith('#')) return String.fromCharCode(int.tryParse(entity.substring(1)) ?? 0xfffd);
  return const {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' '}[entity.toLowerCase()] ?? m[0]!;
});

/// The bookmarks bar becomes the toolbar folder; Other bookmarks' contents go at the top level, as Chrome does.
String exportBookmarksHtml(BookmarkStore store) {
  final out = StringBuffer()
    ..writeln('<!DOCTYPE NETSCAPE-Bookmark-file-1>')
    ..writeln('<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->')
    ..writeln('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
    ..writeln('<TITLE>Bookmarks</TITLE>')
    ..writeln('<H1>Bookmarks</H1>')
    ..writeln('<DL><p>');

  void write(Bookmark node, int depth, {bool toolbar = false}) {
    final indent = '    ' * depth;
    if (node.isFolder) {
      final flag = toolbar ? ' PERSONAL_TOOLBAR_FOLDER="true"' : '';
      out
        ..writeln('$indent<DT><H3 ADD_DATE="${node.addedAt}"$flag>${_escape(node.title)}</H3>')
        ..writeln('$indent<DL><p>');
      for (final child in node.children!) {
        write(child, depth + 1);
      }
      out.writeln('$indent</DL><p>');
    } else {
      out.writeln('$indent<DT><A HREF="${_escape(node.url!)}" ADD_DATE="${node.addedAt}">${_escape(node.title)}</A>');
    }
  }

  write(store.bar, 1, toolbar: true);
  for (final child in store.other.children!) {
    write(child, 1);
  }
  out.writeln('</DL><p>');
  return out.toString();
}

/// What a bookmarks.html holds: the toolbar folder's contents and everything else.
class ParsedBookmarks {
  final List<Bookmark> toolbar = [];
  final List<Bookmark> other = [];
  int get linkCount => [...toolbar, ...other].expand((n) => n.descendants).where((n) => !n.isFolder).length;
}

/// Parses a Netscape bookmark file. It is tag soup rather than HTML, so this only looks at `<DL>`, `<H3>` and `<A>`.
ParsedBookmarks parseBookmarksHtml(String html) {
  final result = ParsedBookmarks();
  final top = Bookmark.folder(id: '', title: '');
  final toolbar = Bookmark.folder(id: '', title: '');
  final attributePattern = RegExp(r'''([A-Za-z_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
  Map<String, String> attributes(String text) => {
    for (final m in attributePattern.allMatches(text)) m[1]!.toUpperCase(): _unescape(m[2] ?? m[3] ?? ''),
  };
  String textUntil(String closing, int from) {
    final match = RegExp(closing, caseSensitive: false).allMatches(html, from).firstOrNull;
    final end = match?.start ?? -1;
    return _unescape(
      (end < 0 ? html.substring(from) : html.substring(from, end)).replaceAll(RegExp(r'<[^>]*>'), ''),
    ).trim();
  }

  final stack = <Bookmark>[top];
  Bookmark? pending;
  var serial = 0;
  for (final m in RegExp(r'<(/?)(dl|h3|a)\b([^>]*)>', caseSensitive: false).allMatches(html)) {
    final closing = m[1]!.isNotEmpty;
    final tag = m[2]!.toLowerCase();
    if (tag == 'dl') {
      if (closing) {
        if (stack.length > 1) stack.removeLast();
      } else {
        stack.add(pending ?? stack.last);
        pending = null;
      }
    } else if (!closing && tag == 'h3') {
      final attrs = attributes(m[3]!);
      final title = textUntil('</h3', m.end);
      final isToolbar = attrs['PERSONAL_TOOLBAR_FOLDER'] == 'true';
      if (isToolbar) {
        pending = toolbar;
      } else {
        pending = Bookmark.folder(id: '${serial++}', title: title, addedAt: int.tryParse(attrs['ADD_DATE'] ?? ''));
        stack.last.children!.add(pending);
      }
    } else if (!closing && tag == 'a') {
      final attrs = attributes(m[3]!);
      final url = attrs['HREF'] ?? '';
      // Firefox's "place:" entries are saved searches, not pages.
      if (url.isEmpty || url.startsWith('place:')) continue;
      stack.last.children!.add(
        Bookmark.link(
          id: '${serial++}',
          title: textUntil('</a', m.end),
          url: url,
          addedAt: int.tryParse(attrs['ADD_DATE'] ?? ''),
        ),
      );
    }
  }
  result.toolbar.addAll(toolbar.children!);
  result.other.addAll(top.children!);
  return result;
}
