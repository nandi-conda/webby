import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/bindings.dart';
import 'src/bookmarks/bookmark_bar.dart';
import 'src/bookmarks/bookmark_dialog.dart';
import 'src/bookmarks/bookmark_store.dart';
import 'src/bookmarks/bookmarks_page.dart';
import 'src/frame_bench.dart';
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
    return MaterialApp(
      title: 'Webby',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: BrowserPage(initialUrl: initialUrl),
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
    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText('Could not start Ladybird:\n\n$_startupError'),
          ),
        ),
      );
    }

    final bookmarked = BookmarkStore.instance.bookmarkFor(controller.url) != null;
    return CallbackShortcuts(
      bindings: {for (final entry in _shortcuts.entries) entry.key: () => _runShortcut(entry.value)},
      child: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: controller.canGoBack ? controller.goBack : null,
                    ),
                    IconButton(
                      tooltip: 'Forward',
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: controller.canGoForward ? controller.goForward : null,
                    ),
                    IconButton(
                      tooltip: controller.isLoading ? 'Stop' : 'Reload',
                      icon: Icon(controller.isLoading ? Icons.close : Icons.refresh),
                      onPressed: controller.isLoading ? controller.stop : controller.reload,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _address,
                        focusNode: _addressFocus,
                        onSubmitted: _go,
                        textInputAction: TextInputAction.go,
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          hintText: 'Search or enter address',
                          prefixIcon: const Icon(Icons.public, size: 18),
                          suffixIcon: IconButton(
                            tooltip: bookmarked ? 'Edit bookmark (Ctrl+D)' : 'Bookmark this page (Ctrl+D)',
                            icon: Icon(bookmarked ? Icons.star : Icons.star_border, size: 20),
                            onPressed: controller.url.isEmpty ? null : _bookmarkPage,
                          ),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    PopupMenuButton<String>(
                      tooltip: 'Bookmarks',
                      icon: const Icon(Icons.bookmarks_outlined),
                      onSelected: _runShortcut,
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: 'bookmark', child: Text('Bookmark this page    Ctrl+D')),
                        CheckedPopupMenuItem(
                          value: 'bar',
                          checked: BookmarkStore.instance.showBar,
                          child: const Text('Show bookmarks bar    Ctrl+Shift+B'),
                        ),
                        const PopupMenuItem(value: 'manager', child: Text('Bookmark manager    Ctrl+Shift+O')),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Passwords and passkeys',
                      icon: const Icon(Icons.key),
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VaultPage())),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: 2,
              child: controller.isLoading ? const LinearProgressIndicator() : null,
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
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Text(controller.hoveredLink, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
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
