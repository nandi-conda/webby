import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'incognito.dart';
import 'pwa/app_store.dart';
import 'web_view.dart';

/// JavaScript that reports right-clicks to the browser so it can show its context menu.
///
/// Ladybird fires the page's `contextmenu` event and then asks the UI for a menu, but the headless view has no menu
/// of its own. This script listens for the event and, once the page's handlers have run (and Ladybird has selected
/// the word under the pointer), sends what was clicked through prompt() with [prefix], like the password script:
///   {"type": "contextmenu", "prevented", "link", "linkText", "image", "selection", "editable", "password"}
/// `prevented` is set when the page cancelled the event to show a menu of its own.
/// It also defines `window.__webbyContextMenu.act(action, text)` to cut, paste, select all or inspect what was clicked.
String contextMenuPageScript(String prefix) => '''
(() => {
  if (window.__webbyContextMenu) return;
  const PREFIX = ${jsonEncode(prefix)};

  // Pages sometimes replace window.prompt; use a pristine one from a fresh frame if so.
  let host = window;
  const isNative = (f) => { try { return /\\[native code\\]/.test(Function.prototype.toString.call(f)); } catch (e) { return false; } };
  if (!isNative(window.prompt)) {
    try {
      const frame = document.createElement('iframe');
      frame.style.display = 'none';
      (document.body || document.documentElement).appendChild(frame);
      host = frame.contentWindow;
    } catch (e) {}
  }
  const prompt = host.prompt;
  const send = (message) => { try { prompt.call(host, PREFIX + JSON.stringify(message)); } catch (e) {} };

  const TEXT_INPUTS = ['', 'text', 'search', 'url', 'tel', 'email', 'password', 'number'];
  function editableOf(node) {
    for (let el = node; el; el = el.parentElement) {
      if (el instanceof HTMLTextAreaElement || el instanceof HTMLInputElement) {
        if (el.disabled || el.readOnly) return null;
        if (el instanceof HTMLInputElement && !TEXT_INPUTS.includes((el.getAttribute('type') || '').toLowerCase())) return null;
        return el;
      }
      if (el.isContentEditable) return el;
    }
    return null;
  }
  const hasSelectionApi = (el) => { try { return typeof el.selectionStart === 'number'; } catch (e) { return false; } };
  const hrefOf = (link) => typeof link.href === 'string' ? link.href : new URL(link.href.baseVal, document.baseURI).href;

  let target = null;
  let inspected = null;
  window.addEventListener('contextmenu', (event) => {
    const node = event.target instanceof Element ? event.target : event.target && event.target.parentElement;
    // Report after the page's own handlers (to see whether one cancelled the event) and after Ladybird has selected
    // the word under the pointer.
    setTimeout(() => {
      const link = node && node.closest('a[href], area[href]');
      const image = node && node.closest('img');
      const editable = node && editableOf(node);
      const password = editable instanceof HTMLInputElement && editable.type === 'password';
      target = editable || null;
      inspected = node;
      let selection = '';
      if (password) {
        selection = '';
      } else if (editable && hasSelectionApi(editable)) {
        selection = editable.value.substring(editable.selectionStart, editable.selectionEnd);
      } else {
        selection = String(document.getSelection() || '');
      }
      send({
        type: 'contextmenu',
        prevented: event.defaultPrevented,
        link: link ? hrefOf(link) : '',
        linkText: link ? (link.textContent || '').trim().slice(0, 200) : '',
        image: image ? (image.currentSrc || image.src || '') : '',
        selection: selection.slice(0, 1 << 20),
        editable: !!editable,
        password,
      });
    }, 0);
  }, true);

  function setValue(el, value) {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
  }
  function fireInput(el, inputType, data) {
    let event;
    try { event = new InputEvent('input', { bubbles: true, inputType, data }); } catch (e) { event = new Event('input', { bubbles: true }); }
    el.dispatchEvent(event);
  }
  // Replaces the selection in the clicked field with text ('' deletes it), the way typing would.
  function replaceSelection(el, text, inputType) {
    el.focus();
    if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
      const value = el.value;
      if (hasSelectionApi(el)) {
        const start = el.selectionStart, end = el.selectionEnd;
        setValue(el, value.slice(0, start) + text + value.slice(end));
        el.setSelectionRange(start + text.length, start + text.length);
      } else {
        setValue(el, value + text);
      }
      fireInput(el, inputType, text || null);
      return;
    }
    try {
      if (document.execCommand(text ? 'insertText' : 'delete', false, text)) return;
    } catch (e) {}
    const selection = document.getSelection();
    if (!selection || !selection.rangeCount) return;
    const range = selection.getRangeAt(0);
    range.deleteContents();
    if (text) {
      const node = document.createTextNode(text);
      range.insertNode(node);
      range.setStartAfter(node);
      range.collapse(true);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    fireInput(el, inputType, text || null);
  }

  Object.defineProperty(window, '__webbyContextMenu', {
    value: Object.freeze({
      act(action, text) {
        const el = target && target.isConnected ? target : null;
        if (action === 'cut' && el) replaceSelection(el, '', 'deleteByCut');
        else if (action === 'paste' && el && typeof text === 'string') replaceSelection(el, text, 'insertFromPaste');
        else if (action === 'inspect') {
          const eruda = window.eruda;
          if (!eruda) return;
          if (!eruda._isInit) eruda.init();
          eruda.show();
          eruda.show('elements');
          const node = inspected && inspected.isConnected ? inspected : document.body;
          try { eruda.get('elements').select(node); } catch (e) {}
        } else if (action === 'selectAll') {
          if (el && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) { el.focus(); el.select(); }
          else if (el) { el.focus(); document.getSelection().selectAllChildren(el); }
          else document.getSelection().selectAllChildren(document.body || document.documentElement);
        }
      },
    }),
  });
})();
''';

/// JavaScript that runs one of the script's actions ('cut', 'paste' with [text], 'selectAll', 'inspect') on what was
/// clicked.
String contextMenuActionScript(String action, [String? text]) =>
    'window.__webbyContextMenu && window.__webbyContextMenu.act(${jsonEncode(action)}, ${jsonEncode(text)});';

String? _eruda;

/// JavaScript that opens the eruda dev tools (bundled in assets/eruda) in the page, on the Elements panel with the
/// right-clicked element selected. eruda is loaded into the page the first time.
Future<String> inspectScript() async {
  final eruda = _eruda ??= await rootBundle.loadString('assets/eruda/eruda.js');
  return inspectScriptWith(eruda);
}

/// [inspectScript] with eruda's source given.
String inspectScriptWith(String erudaSource) => '''
(() => {
  if (!window.eruda) {
    // eruda is a UMD bundle: hide any AMD/CommonJS loader the page has so it lands on window.eruda. It throws on pages
    // without storage (opaque origins); there is nothing to inspect with then.
    try {
      (function (define, module, exports) {
$erudaSource
      }).call(window);
    } catch (e) {
      return;
    }
  }
  if (window.__webbyContextMenu) {
    window.__webbyContextMenu.act('inspect');
  } else if (window.eruda) {
    if (!window.eruda._isInit) window.eruda.init();
    window.eruda.show();
    window.eruda.show('elements');
  }
})();
''';

/// What the user right-clicked, as [contextMenuPageScript] reports it.
class ContextMenuTarget {
  const ContextMenuTarget({
    this.prevented = false,
    this.link = '',
    this.linkText = '',
    this.image = '',
    this.selection = '',
    this.editable = false,
    this.password = false,
  });

  /// Parses a page message; null if it isn't a context menu report.
  static ContextMenuTarget? fromMessage(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, Object?> || decoded['type'] != 'contextmenu') return null;
    String string(String key) => decoded is Map<String, Object?> && decoded[key] is String ? decoded[key] as String : '';
    return ContextMenuTarget(
      prevented: decoded['prevented'] == true,
      link: _webUrl(string('link')),
      linkText: string('linkText'),
      image: _webUrl(string('image')),
      selection: string('selection'),
      editable: decoded['editable'] == true,
      password: decoded['password'] == true,
    );
  }

  /// Only offer links the browser would follow; `javascript:` and the like are dropped.
  static String _webUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    return const {'http', 'https', 'file', 'data', 'about'}.contains(uri.scheme) ? url : '';
  }

  final bool prevented;
  final String link;
  final String linkText;
  final String image;
  final String selection;
  final bool editable;
  final bool password;
}

/// One row of the context menu; a null [id] is a divider.
class ContextMenuEntry {
  const ContextMenuEntry(this.id, this.label, {this.enabled = true});
  const ContextMenuEntry.divider()
      : id = null,
        label = '',
        enabled = false;

  final String? id;
  final String label;
  final bool enabled;
}

/// The rows to show for [target] (null when the page didn't report the click, e.g. Shift+right-click or a page the
/// script can't run in): link, image and text rows first, then navigation.
List<ContextMenuEntry> contextMenuEntries(
  ContextMenuTarget? target, {
  required bool canGoBack,
  required bool canGoForward,
  required bool canOpenInNewTab,
  required bool clipboardHasText,
  bool canOpenIncognito = false,
}) {
  final groups = <List<ContextMenuEntry>>[];
  if (target != null && target.link.isNotEmpty) {
    groups.add([
      if (canOpenInNewTab) const ContextMenuEntry('openLinkInNewTab', 'Open link in new tab'),
      if (canOpenIncognito) const ContextMenuEntry('openLinkIncognito', 'Open link in incognito window'),
      const ContextMenuEntry('openLink', 'Open link'),
      const ContextMenuEntry('copyLink', 'Copy link address'),
      if (target.linkText.isNotEmpty) const ContextMenuEntry('copyLinkText', 'Copy link text'),
    ]);
  }
  if (target != null && target.image.isNotEmpty) {
    groups.add([
      ContextMenuEntry(canOpenInNewTab ? 'openImageInNewTab' : 'openImage',
          canOpenInNewTab ? 'Open image in new tab' : 'Open image'),
      const ContextMenuEntry('saveImage', 'Save image to Downloads'),
      const ContextMenuEntry('copyImageAddress', 'Copy image address'),
    ]);
  }
  if (target != null && target.editable) {
    final hasSelection = target.selection.isNotEmpty;
    groups.add([
      ContextMenuEntry('cut', 'Cut', enabled: hasSelection && !target.password),
      ContextMenuEntry('copy', 'Copy', enabled: hasSelection && !target.password),
      ContextMenuEntry('paste', 'Paste', enabled: clipboardHasText),
      const ContextMenuEntry('selectAll', 'Select all'),
    ]);
  } else if (target != null && target.selection.trim().isNotEmpty) {
    groups.add([
      const ContextMenuEntry('copy', 'Copy'),
      ContextMenuEntry('search', 'Search the web for “${_ellipsize(target.selection.trim(), 30)}”'),
    ]);
  }
  final onPage = target == null || (target.link.isEmpty && target.image.isEmpty && !target.editable);
  if (onPage) {
    groups.add([
      ContextMenuEntry('back', 'Back', enabled: canGoBack),
      ContextMenuEntry('forward', 'Forward', enabled: canGoForward),
      const ContextMenuEntry('reload', 'Reload'),
    ]);
    groups.add([
      const ContextMenuEntry('selectAll', 'Select all'),
      const ContextMenuEntry('copyPageAddress', 'Copy page address'),
    ]);
  }
  groups.add([const ContextMenuEntry('inspect', 'Inspect')]);
  return [
    for (final (index, group) in groups.indexed) ...[
      if (index > 0) const ContextMenuEntry.divider(),
      ...group,
    ],
  ];
}

String _ellipsize(String text, int max) {
  final oneLine = text.replaceAll(RegExp(r'\s+'), ' ');
  return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
}

/// Runs [contextMenuPageScript] in a [WebbyController]'s pages and reports right-clicks to [onRequest].
class ContextMenuAgent {
  ContextMenuAgent(this.controller, {required this.onRequest}) {
    controller.addListener(_onPageChanged);
    _messages = controller.pageMessages.listen(_onMessage);
    _onPageChanged();
  }

  final WebbyController controller;
  final void Function(ContextMenuTarget target) onRequest;
  late final StreamSubscription<String> _messages;
  String _scriptedUrl = '';
  bool _wasLoading = false;

  void _onPageChanged() {
    // Once per load, and again when the URL changes without one; the script skips pages that already have it.
    final loadFinished = _wasLoading && !controller.isLoading;
    _wasLoading = controller.isLoading;
    if (controller.url == _scriptedUrl && !loadFinished) return;
    _scriptedUrl = controller.url;
    if (controller.isAttached && controller.url.isNotEmpty && controller.messagePrefix.isNotEmpty) {
      controller.runPageScript(contextMenuPageScript(controller.messagePrefix));
    }
  }

  void _onMessage(String text) {
    final target = ContextMenuTarget.fromMessage(text);
    if (target != null) onRequest(target);
  }

  void dispose() {
    controller.removeListener(_onPageChanged);
    _messages.cancel();
  }
}

/// The context menu for [target] as flatkit menu rows. Picking a row carries it out, then calls [afterAction].
Future<List<KitMenuEntry>> contextMenuItems(
  BuildContext context, {
  required WebbyController controller,
  required ContextMenuTarget? target,
  void Function(String url)? onOpenInNewTab,
  VoidCallback? afterAction,
}) async {
  final clipboardHasText = target?.editable == true && await Clipboard.hasStrings();
  final entries = contextMenuEntries(
    target,
    canGoBack: controller.canGoBack,
    canGoForward: controller.canGoForward,
    canOpenInNewTab: onOpenInNewTab != null,
    clipboardHasText: clipboardHasText,
    // From a normal browser window on the desktop (an incognito window is its own process; see Incognito).
    canOpenIncognito: onOpenInNewTab != null && !Incognito.active && !Platform.isAndroid,
  );
  return [
    for (final entry in entries)
      if (entry.id == null)
        const KitMenuDivider()
      else
        KitMenuItem(
          entry.label,
          onSelected: !entry.enabled
              ? null
              : () async {
                  await runContextMenuAction(context, entry.id!,
                      controller: controller, target: target, onOpenInNewTab: onOpenInNewTab);
                  afterAction?.call();
                },
        ),
  ];
}

/// Carries out the context menu row [id] (see [contextMenuEntries]) for [target].
Future<void> runContextMenuAction(
  BuildContext context,
  String id, {
  required WebbyController controller,
  required ContextMenuTarget? target,
  void Function(String url)? onOpenInNewTab,
}) async {
  final t = target ?? const ContextMenuTarget();
  void openInNewTab(String url) => onOpenInNewTab != null ? onOpenInNewTab(url) : controller.load(url);
  switch (id) {
    case 'openLinkInNewTab':
      openInNewTab(t.link);
    case 'openLinkIncognito':
      await AppStore.instance.openIncognito(t.link);
    case 'openLink':
      controller.load(t.link);
    case 'copyLink':
      await Clipboard.setData(ClipboardData(text: t.link));
    case 'copyLinkText':
      await Clipboard.setData(ClipboardData(text: t.linkText));
    case 'openImageInNewTab':
      openInNewTab(t.image);
    case 'openImage':
      controller.load(t.image);
    case 'copyImageAddress':
      await Clipboard.setData(ClipboardData(text: t.image));
    case 'saveImage':
      final message = await saveImageToDownloads(t.image);
      if (context.mounted) showKitToast(context, message, duration: const Duration(seconds: 4));
    case 'copy':
      await Clipboard.setData(ClipboardData(text: t.selection));
    case 'cut':
      await Clipboard.setData(ClipboardData(text: t.selection));
      controller.runJavaScript(contextMenuActionScript('cut'));
    case 'paste':
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.isNotEmpty) controller.runJavaScript(contextMenuActionScript('paste', text));
    case 'selectAll':
      controller.runJavaScript(contextMenuActionScript('selectAll'));
    case 'inspect':
      controller.runJavaScript(await inspectScript());
    case 'search':
      openInNewTab(t.selection.trim());
    case 'back':
      controller.goBack();
    case 'forward':
      controller.goForward();
    case 'reload':
      controller.reload();
    case 'copyPageAddress':
      await Clipboard.setData(ClipboardData(text: controller.url));
  }
}

/// Downloads [url] (http(s) or data:) into ~/Downloads (or $XDG_DOWNLOAD_DIR) and says where it went.
Future<String> saveImageToDownloads(String url, {Directory? directory}) async {
  try {
    final uri = Uri.parse(url);
    List<int> bytes;
    String? mimeType;
    if (uri.scheme == 'data') {
      final data = uri.data!;
      bytes = data.contentAsBytes();
      mimeType = data.mimeType;
    } else if (uri.scheme == 'http' || uri.scheme == 'https') {
      final client = HttpClient()..userAgent = 'webby';
      try {
        final response = await (await client.getUrl(uri)).close();
        if (response.statusCode != 200) return 'Could not save the image (HTTP ${response.statusCode})';
        mimeType = response.headers.contentType?.mimeType;
        bytes = [for (final chunk in await response.toList()) ...chunk];
      } finally {
        client.close();
      }
    } else if (uri.scheme == 'file') {
      bytes = await File.fromUri(uri).readAsBytes();
    } else {
      return 'Can’t save images from ${uri.scheme}: addresses';
    }
    final dir = directory ?? downloadsDirectory();
    await dir.create(recursive: true);
    final file = _freeFile(dir, imageFileName(uri, mimeType));
    await file.writeAsBytes(bytes, flush: true);
    return 'Saved ${file.path}';
  } catch (e) {
    return 'Could not save the image: $e';
  }
}

Directory downloadsDirectory() {
  final env = Platform.environment;
  final home = env['HOME'] ?? '.';
  final xdg = env['XDG_DOWNLOAD_DIR'];
  return Directory(xdg != null && xdg.isNotEmpty ? xdg : '$home/Downloads');
}

/// A file name for an image at [uri]: its last path segment, with an extension from [mimeType] if it has none.
String imageFileName(Uri uri, String? mimeType) {
  var name = uri.scheme == 'data' || uri.pathSegments.isEmpty ? '' : uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
  name = name.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_');
  if (name.isEmpty || name.startsWith('.')) name = 'image$name';
  if (!name.contains('.')) {
    const extensions = {
      'image/png': 'png',
      'image/jpeg': 'jpg',
      'image/gif': 'gif',
      'image/webp': 'webp',
      'image/svg+xml': 'svg',
      'image/avif': 'avif',
      'image/bmp': 'bmp',
      'image/x-icon': 'ico',
    };
    final extension = extensions[mimeType];
    if (extension != null) name = '$name.$extension';
  }
  return name;
}

File _freeFile(Directory dir, String name) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';
  var file = File('${dir.path}/$name');
  for (var i = 1; file.existsSync(); i++) {
    file = File('${dir.path}/$stem ($i)$extension');
  }
  return file;
}
