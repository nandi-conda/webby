import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/bindings.dart';
import 'src/bookmarks/bookmark_bar.dart';
import 'src/bookmarks/bookmark_dialog.dart';
import 'src/bookmarks/bookmark_store.dart';
import 'src/bookmarks/bookmarks_page.dart';
import 'src/frame_bench.dart';
import 'src/omnibox.dart';
import 'src/passkey_dialog.dart';
import 'src/passwords/password_bar.dart';
import 'src/passwords/password_manager.dart';
import 'src/passwords/vault_page.dart';
import 'src/web_view.dart';

void main(List<String> args) {
  runApp(WebbyApp(initialUrl: args.isNotEmpty ? args.first : 'https://ladybird.org'));
}

class WebbyApp extends StatelessWidget {
  const WebbyApp({super.key, required this.initialUrl});

  final String initialUrl;

  @override
  Widget build(BuildContext context) {
    // flatkit colours: the KDE colour scheme on Plasma, otherwise light or dark with the desktop.
    return KitSystemTheme(
      builder: (context, colors) => MaterialApp(
        title: 'Webby',
        debugShowCheckedModeBanner: false,
        theme: KitTheme.material(colors),
        builder: (context, child) => Material(color: colors.background, child: child),
        home: BrowserPage(initialUrl: initialUrl),
      ),
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.initialUrl});

  final String initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  WebbyController? _controller;
  PasswordAgent? _passwords;
  Object? _startupError;
  final _address = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'address');
  final _pageFocus = FocusNode(debugLabel: 'page');
  String _shownUrl = '';
  Map<String, Object?>? _shownPasskeyPrompt;

  @override
  void initState() {
    super.initState();
    try {
      _controller = WebbyController(initialUrl: widget.initialUrl)..addListener(_onPageChanged);
      _address.text = widget.initialUrl;
      _passwords = PasswordAgent(_controller!);
      PasswordManager.instance.start(WebbyBindings.open());
      maybeStartBench(_controller!);
      BookmarkStore.instance.addListener(_onBookmarksChanged);
    } catch (error) {
      _startupError = error;
    }
  }

  void _onPageChanged() {
    final controller = _controller!;
    // Don't clobber what the user is typing.
    if (controller.url != _shownUrl && !_addressFocus.hasFocus) {
      _shownUrl = controller.url;
      _address.text = controller.url;
    }
    final passkeyPrompt = controller.webauthnPrompt;
    if (passkeyPrompt != null && !identical(passkeyPrompt, _shownPasskeyPrompt)) {
      _shownPasskeyPrompt = passkeyPrompt;
      showPasskeyDialog(context, controller, passkeyPrompt);
    }
    setState(() {});
  }

  void _onBookmarksChanged() => setState(() {});

  void _bookmarkPage() {
    final controller = _controller;
    if (controller == null || controller.url.isEmpty) return;
    bookmarkPage(context, url: controller.url, title: controller.title);
  }

  Future<void> _openBookmarks() async {
    final url = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const BookmarksPage()));
    if (url != null) _go(url);
  }

  void _toggleBookmarkBar() => BookmarkStore.instance.showBar = !BookmarkStore.instance.showBar;

  static const _shortcuts = <ShortcutActivator, String>{
    SingleActivator(LogicalKeyboardKey.keyD, control: true): 'bookmark',
    SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true): 'bar',
    SingleActivator(LogicalKeyboardKey.keyO, control: true, shift: true): 'manager',
  };

  /// Whether [event] is one of [_shortcuts]' keys (down, repeat or up), so the page doesn't get it.
  static bool _isBrowserShortcut(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyD) return !keyboard.isShiftPressed;
    return keyboard.isShiftPressed && (key == LogicalKeyboardKey.keyB || key == LogicalKeyboardKey.keyO);
  }

  void _runShortcut(String name) {
    switch (name) {
      case 'bookmark':
        _bookmarkPage();
      case 'bar':
        _toggleBookmarkBar();
      case 'manager':
        _openBookmarks();
    }
  }

  void _go(String input) {
    final text = input.trim();
    if (text.isEmpty) return;
    _controller?.load(text);
    _pageFocus.requestFocus();
  }

  @override
  void dispose() {
    BookmarkStore.instance.removeListener(_onBookmarksChanged);
    _passwords?.dispose();
    _controller?.dispose();
    _address.dispose();
    _addressFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final controller = _controller;
    if (controller == null) {
      return Material(
        color: c.background,
        child: Center(
          child: KitPanel(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(20),
            child: SelectableText('Could not start Ladybird:\n\n$_startupError'),
          ),
        ),
      );
    }

    final bookmarked = BookmarkStore.instance.bookmarkFor(controller.url) != null;
    return CallbackShortcuts(
      bindings: {for (final entry in _shortcuts.entries) entry.key: () => _runShortcut(entry.value)},
      child: Material(
        color: c.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: c.surface,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Row(
                children: [
                  KitIconButton(
                    Icons.arrow_back,
                    tooltip: 'Back',
                    onPressed: controller.canGoBack ? controller.goBack : null,
                  ),
                  KitIconButton(
                    Icons.arrow_forward,
                    tooltip: 'Forward',
                    onPressed: controller.canGoForward ? controller.goForward : null,
                  ),
                  KitIconButton(
                    controller.isLoading ? Icons.close : Icons.refresh,
                    tooltip: controller.isLoading ? 'Stop' : 'Reload',
                    onPressed: controller.isLoading ? controller.stop : controller.reload,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Omnibox(
                      controller: _address,
                      focusNode: _addressFocus,
                      url: controller.url,
                      onSubmitted: _go,
                      trailing: [
                        KitIconButton(
                          bookmarked ? Icons.star : Icons.star_border,
                          tooltip: bookmarked ? 'Edit bookmark (Ctrl+D)' : 'Bookmark this page (Ctrl+D)',
                          color: bookmarked ? c.accent : null,
                          size: 16,
                          extent: 26,
                          onPressed: controller.url.isEmpty ? null : _bookmarkPage,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  KitMenu(
                    minWidth: 260,
                    items: () => [
                      KitMenuItem('Bookmark this page', shortcut: 'Ctrl+D', onSelected: _bookmarkPage),
                      KitMenuItem(
                        'Show bookmarks bar',
                        shortcut: 'Ctrl+Shift+B',
                        checked: BookmarkStore.instance.showBar,
                        onSelected: _toggleBookmarkBar,
                      ),
                      const KitMenuDivider(),
                      KitMenuItem('Bookmark manager', shortcut: 'Ctrl+Shift+O', onSelected: _openBookmarks),
                    ],
                    builder: (context, toggle, open) =>
                        KitIconButton(Icons.bookmarks_outlined, tooltip: 'Bookmarks', onPressed: toggle),
                  ),
                  KitIconButton(
                    Icons.key,
                    tooltip: 'Passwords and passkeys',
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VaultPage())),
                  ),
                ],
              ),
            ),
            // The loading line doubles as the toolbar's bottom border.
            SizedBox(
              height: 2,
              child: controller.isLoading
                  ? LinearProgressIndicator(minHeight: 2, color: c.accent, backgroundColor: c.border)
                  : Align(alignment: Alignment.topCenter, child: Container(height: 1, color: c.border)),
            ),
            BookmarkBar(onOpen: _go),
            if (_passwords != null) PasswordBar(agent: _passwords!),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: WebbyView(controller: controller, focusNode: _pageFocus, isBrowserShortcut: _isBrowserShortcut),
                  ),
                  if (controller.hoveredLink.isNotEmpty)
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 600),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: c.surface,
                          border: Border(top: BorderSide(color: c.border), right: BorderSide(color: c.border)),
                          borderRadius: const BorderRadius.only(topRight: Radius.circular(kitRadius)),
                        ),
                        child: Text(
                          controller.hoveredLink,
                          overflow: TextOverflow.ellipsis,
                          style: KitText.small(context, color: c.textDim),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
