import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/context_menu.dart';

List<String?> ids(List<ContextMenuEntry> entries) => [for (final e in entries) e.id];

List<ContextMenuEntry> entries(ContextMenuTarget? target, {bool newTab = true, bool clipboard = true}) =>
    contextMenuEntries(target,
        canGoBack: true, canGoForward: false, canOpenInNewTab: newTab, clipboardHasText: clipboard);

void main() {
  group('ContextMenuTarget.fromMessage', () {
    test('parses a report', () {
      final target = ContextMenuTarget.fromMessage(jsonEncode({
        'type': 'contextmenu',
        'prevented': false,
        'link': 'https://example.com/a',
        'linkText': 'A',
        'image': 'https://example.com/i.png',
        'selection': 'hello',
        'editable': false,
        'password': false,
      }))!;
      expect(target.link, 'https://example.com/a');
      expect(target.linkText, 'A');
      expect(target.image, 'https://example.com/i.png');
      expect(target.selection, 'hello');
      expect(target.prevented, isFalse);
    });

    test('ignores other page messages and junk', () {
      expect(ContextMenuTarget.fromMessage('{"type":"submit","username":"a","password":"b"}'), isNull);
      expect(ContextMenuTarget.fromMessage('not json'), isNull);
      expect(ContextMenuTarget.fromMessage('[1]'), isNull);
    });

    test('drops javascript: links', () {
      final target = ContextMenuTarget.fromMessage('{"type":"contextmenu","link":"javascript:alert(1)"}')!;
      expect(target.link, isEmpty);
    });
  });

  group('contextMenuEntries', () {
    test('page menu without a report', () {
      final list = entries(null);
      expect(ids(list), ['back', 'forward', 'reload', null, 'selectAll', 'copyPageAddress', null, 'inspect']);
      expect(list.firstWhere((e) => e.id == 'forward').enabled, isFalse);
    });

    test('link menu offers a new tab only when there are tabs', () {
      const link = ContextMenuTarget(link: 'https://example.com', linkText: 'Example');
      expect(ids(entries(link)), ['openLinkInNewTab', 'openLink', 'copyLink', 'copyLinkText', null, 'inspect']);
      expect(ids(entries(link, newTab: false)), ['openLink', 'copyLink', 'copyLinkText', null, 'inspect']);
    });

    test('linked image shows both groups', () {
      const target = ContextMenuTarget(link: 'https://example.com', image: 'https://example.com/i.png');
      expect(ids(entries(target)),
          ['openLinkInNewTab', 'openLink', 'copyLink', null, 'openImageInNewTab', 'saveImage', 'copyImageAddress', null, 'inspect']);
    });

    test('text field', () {
      final list = entries(const ContextMenuTarget(editable: true, selection: 'abc'));
      expect(ids(list), ['cut', 'copy', 'paste', 'selectAll', null, 'inspect']);
      expect(list.where((e) => e.id != null).every((e) => e.enabled), isTrue);
      final empty = entries(const ContextMenuTarget(editable: true), clipboard: false);
      expect([for (final e in empty) e.enabled], [false, false, false, true, false, true]);
    });

    test('password field never offers cut or copy', () {
      final list = entries(const ContextMenuTarget(editable: true, password: true, selection: 'x'));
      expect(list.firstWhere((e) => e.id == 'cut').enabled, isFalse);
      expect(list.firstWhere((e) => e.id == 'copy').enabled, isFalse);
    });

    test('selected text adds copy and search above the page rows', () {
      final list = entries(const ContextMenuTarget(selection: 'a fairly long piece of selected page text'));
      expect(ids(list).take(3), ['copy', 'search', null]);
      expect(list[1].label, 'Search the web for “a fairly long piece of selecte…”');
    });
  });

  test('page script embeds the prefix and defines the action hook', () {
    final script = contextMenuPageScript('\u0001p:');
    expect(script, contains(jsonEncode('\u0001p:')));
    expect(script, contains('__webbyContextMenu'));
    expect(script, contains(r'/\[native code\]/'));
    expect(contextMenuActionScript('paste', 'a"b'),
        'window.__webbyContextMenu && window.__webbyContextMenu.act("paste", "a\\"b");');
  });

  test('inspect script loads eruda once, hiding AMD loaders, then inspects the clicked element', () {
    final script = inspectScriptWith('/* eruda */');
    expect(script, contains('if (!window.eruda)'));
    expect(script, contains('(function (define, module, exports) {\n/* eruda */\n'));
    expect(script, contains("window.__webbyContextMenu.act('inspect')"));
  });

  group('saving images', () {
    test('file names', () {
      expect(imageFileName(Uri.parse('https://x.org/a/b/cat.png?s=1'), 'image/png'), 'cat.png');
      expect(imageFileName(Uri.parse('https://x.org/photo'), 'image/jpeg'), 'photo.jpg');
      expect(imageFileName(Uri.parse('https://x.org/'), 'image/webp'), 'image.webp');
      expect(imageFileName(Uri.parse('data:image/gif;base64,R0lGOD'), 'image/gif'), 'image.gif');
    });

    test('data: image goes to the directory without overwriting', () async {
      final dir = await Directory.systemTemp.createTemp('webby-ctx');
      addTearDown(() => dir.delete(recursive: true));
      final url = 'data:image/png;base64,${base64Encode([1, 2, 3])}';
      expect(await saveImageToDownloads(url, directory: dir), 'Saved ${dir.path}/image.png');
      expect(await saveImageToDownloads(url, directory: dir), 'Saved ${dir.path}/image (1).png');
      expect(File('${dir.path}/image (1).png').readAsBytesSync(), [1, 2, 3]);
    });
  });
}
