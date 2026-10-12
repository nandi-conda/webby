import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/android.dart';
import 'src/bindings.dart';
import 'src/bookmarks/bookmark_bar.dart';
import 'src/bookmarks/bookmark_dialog.dart';
import 'src/bookmarks/bookmark_store.dart';
import 'src/bookmarks/bookmarks_page.dart';
import 'src/color_scheme.dart';
import 'src/frame_bench.dart';
import 'src/history/history_page.dart';
import 'src/history/history_store.dart';
import 'src/incognito.dart';
import 'src/notifications.dart';
import 'src/omnibox.dart';
import 'src/page_dialogs.dart';
import 'src/passkey_dialog.dart';
import 'src/passwords/password_bar.dart';
import 'src/passwords/password_manager.dart';
import 'src/passwords/vault_page.dart';
import 'src/pwa/app_store.dart';
import 'src/pwa/app_window.dart';
import 'src/pwa/install_dialog.dart';
import 'src/pwa/offline.dart';
import 'src/pwa/pwa_agent.dart';
import 'src/site_data.dart';
import 'src/site_settings.dart';
import 'src/tab_strip.dart';
import 'src/tabs/device_tabs.dart';
import 'src/tabs/device_tabs_page.dart';
import 'src/tabs/sessions.dart';
import 'src/tabs/sessions_page.dart';
import 'src/web_view.dart';

Future<void> main(List<String> args) async {
  // `--app=<url>` opens an installed web app in its own window (what the app launchers run).
  final app = args.where((a) => a.startsWith('--app=')).map((a) => a.substring(6)).firstOrNull;
  final urls = args.where((a) => !a.startsWith('--')).toList();
  // `--incognito` makes this process an incognito window: its own Ladybird that keeps nothing (see Incognito).
  if (app == null && args.contains(Incognito.flag) && !Platform.isAndroid) Incognito.enable();
  var initialUrl = app ?? (urls.isNotEmpty ? urls.first : (Incognito.active ? 'about:blank' : 'https://ladybird.org'));
  if (Platform.isAndroid) {
    WidgetsFlutterBinding.ensureInitialized();
    await AndroidHost.prepare();
    initialUrl = await AndroidHost.initialUrl() ?? initialUrl;
  }
  // Desktop launchers for installed web apps; Android has none.
  if (app == null && !Incognito.active && !Platform.isAndroid) AppStore.instance.refreshLaunchers().ignore();
  runApp(WebbyApp(initialUrl: initialUrl, appMode: app != null));
}

class WebbyApp extends StatelessWidget {
  const WebbyApp({super.key, required this.initialUrl, this.appMode = false});

  final String initialUrl;
  final bool appMode;

  @override
  Widget build(BuildContext context) {
    // flatkit colours: the KDE colour scheme on Plasma, otherwise light or dark with the desktop.
    return KitSystemTheme(
      builder: (context, systemColors) {
        // Incognito windows always use their own dark colours.
        final colors = Incognito.active ? Incognito.colors : systemColors;
        // Pages follow the same light or dark choice as the UI (prefers-color-scheme).
        PageColorScheme.brightness.value = colors.brightness;
        return MaterialApp(
          title: Incognito.active ? 'Webby (Incognito)' : 'Webby',
          debugShowCheckedModeBanner: false,
          theme: KitTheme.material(colors),
          builder: (context, child) => Material(color: colors.background, child: child),
          home: appMode ? AppWindowPage(startUrl: initialUrl) : BrowserPage(initialUrl: initialUrl),
        );
      },
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.initialUrl});

  final String initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

/// One tab: its own Ladybird view, password agent and keyboard focus.
class _BrowserTab {
  _BrowserTab(String url) : this.withController(WebbyController(initialUrl: url));

  _BrowserTab.withController(this.controller) {
    passwords = PasswordAgent(controller);
    pwa = PwaAgent(controller);
  }

  final WebbyController controller;
  late final PasswordAgent passwords;
  late final PwaAgent pwa;
  /// Set when the tab joins the window, which its notifications bring forward.
  NotificationAgent? notifications;
  final focus = FocusNode(debugLabel: 'page');
  Map<String, Object?>? shownPasskeyPrompt;
  PageDialog? shownDialog;
  /// When the tab last went into the background (null while it is the active tab).
  DateTime? hiddenSince;
  /// The page address last recorded in the history for this tab, and its visit (null when it isn't recorded).
  String recordedUrl = '';
  HistoryEntry? visit;

  void dispose() {
    passwords.dispose();
    pwa.dispose();
    notifications?.dispose();
    controller.dispose();
    focus.dispose();
  }
}

const _blankUrl = 'about:blank';

class _BrowserPageState extends State<BrowserPage> {
  final _tabs = <_BrowserTab>[];
  int _active = 0;
  /// URLs of closed tabs, most recent last, for Ctrl+Shift+T.
  final _closedUrls = <String>[];
  Object? _startupError;
  final _address = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'address');
  String _shownUrl = '';
  Timer? _discardTimer;
  /// Asks to save the tabs as a session when the window is closed (see [_onExitRequested]).
  AppLifecycleListener? _exitListener;
  bool _askingToQuit = false;

  /// Background tabs hidden this long lose their page (and its WebContent process) until they're shown again.
  /// WEBBY_DISCARD_MINUTES overrides it; 0 never discards on age (low memory still does).
  static final Duration? _discardAfter = () {
    final minutes = int.tryParse(Platform.environment['WEBBY_DISCARD_MINUTES'] ?? '') ?? 30;
    return minutes > 0 ? Duration(minutes: minutes) : null;
  }();

  _BrowserTab? get _tab => _tabs.isEmpty ? null : _tabs[_active];
  WebbyController? get _controller => _tab?.controller;

  @override
  void initState() {
    super.initState();
    try {
      final tab = _addTab(widget.initialUrl);
      _address.text = widget.initialUrl;
      PasswordManager.instance.start(WebbyBindings.open());
      // Offline mode serves pages from the disk cache, which incognito windows don't have.
      if (!Incognito.active) OfflineMonitor.start(WebbyBindings.open())?.addListener(_onBookmarksChanged);
      maybeStartBench(tab.controller);
      BookmarkStore.instance.addListener(_onBookmarksChanged);
      _discardTimer = Timer.periodic(const Duration(minutes: 1), (_) => _discardIdleTabs());
      if (Platform.isAndroid) AndroidHost.onOpenUrl(_go);
      if (!Incognito.active && !Platform.isAndroid) _exitListener = AppLifecycleListener(onExitRequested: _onExitRequested);
    } catch (error) {
      _startupError = error;
    }
  }

  _BrowserTab _addTab(String url, {int? at}) => _insertTab(_BrowserTab(url), at: at);

  _BrowserTab _insertTab(_BrowserTab tab, {int? at}) {
    tab.controller.addListener(() => _onPageChanged(tab));
    tab.notifications = NotificationAgent(tab.controller, onClick: () {
      if (mounted && _tabs.contains(tab)) _selectTab(_tabs.indexOf(tab));
    });
    // Links with target=_blank and window.open() open a tab next to their opener and switch to it.
    tab.controller.onNewView = (controller) {
      final index = _tabs.indexOf(tab);
      final opened = _insertTab(_BrowserTab.withController(controller), at: index < 0 ? null : index + 1);
      _selectTab(_tabs.indexOf(opened));
    };
    _tabs.insert(at ?? _tabs.length, tab);
    _publishTabs();
    return tab;
  }

  void _newTab([String url = _blankUrl]) {
    if (_tabs.isEmpty) return;
    final tab = _addTab(url, at: _active + 1);
    _selectTab(_tabs.indexOf(tab));
  }

  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    final url = tab.controller.url;
    if (url.isNotEmpty && url != _blankUrl) _closedUrls.add(url);
    // Closing the last tab leaves a blank one rather than an empty window.
    if (_tabs.length == 1) _addTab(_blankUrl);
    _tabs.removeAt(index);
    if (_active > index || _active >= _tabs.length) _active = (_active - 1).clamp(0, _tabs.length - 1);
    tab.dispose();
    _selectTab(_active, force: true);
    _publishTabs();
  }

  /// Lets the user's other devices see this window's tabs (see [DeviceTabs]).
  /// Incognito tabs are never shared.
  void _publishTabs() {
    if (Incognito.active) return;
    DeviceTabs.instance.setTabs([for (final t in _tabs) DeviceTab(t.controller.title, t.controller.url)]);
  }

  /// Opens a new incognito window (a separate process; desktop only).
  void _openIncognito() {
    if (Platform.isAndroid) return;
    AppStore.instance.openIncognito().catchError((Object error) {
      if (mounted) showKitToast(context, 'Could not open an incognito window: $error');
    });
  }

  Future<void> _openDeviceTabs() async {
    final urls = await Navigator.of(context).push<List<String>>(MaterialPageRoute(builder: (_) => const DeviceTabsPage()));
    if (urls == null || urls.isEmpty || !mounted) return;
    // Like opening a bookmark: reuse a blank tab, otherwise open new ones.
    final blank = _controller?.url.isEmpty != false || _controller?.url == _blankUrl;
    for (final (i, url) in urls.indexed) {
      if (i == 0 && blank) {
        _go(url);
      } else {
        _newTab(url);
      }
    }
  }

  /// The open tabs as a session would keep them.
  List<DeviceTab> _sessionTabs() => [for (final t in _tabs) DeviceTab(t.controller.title, t.controller.url)];

  int get _sessionTabCount => _tabs.where((t) => isSessionUrl(t.controller.url)).length;

  /// Closing the window asks whether to keep its tabs as a session. Incognito windows never save one.
  Future<AppExitResponse> _onExitRequested() async {
    final store = SessionStore.instance;
    final count = _sessionTabCount;
    if (Incognito.active || !store.askOnQuit || count == 0 || !mounted) return AppExitResponse.exit;
    // The question is already up; another click on the window's close button doesn't stack a second one.
    if (_askingToQuit) return AppExitResponse.cancel;
    _askingToQuit = true;
    try {
      final (choice, name) = await askSaveOnQuit(context, tabCount: count, store: store);
      if (choice == QuitChoice.cancel) return AppExitResponse.cancel;
      if (choice == QuitChoice.save) store.save(_sessionTabs(), name: name, active: _active);
      return AppExitResponse.exit;
    } finally {
      _askingToQuit = false;
    }
  }

  /// Asks for a name and saves the open tabs as a session. Returns whether one was saved.
  Future<bool> _saveSession({bool closeAll = false}) async {
    final count = _sessionTabCount;
    if (Incognito.active) return false;
    if (count == 0) {
      showKitToast(context, 'There are no open pages to save');
      return false;
    }
    final name = await askSessionName(
      context,
      title: closeAll ? 'Close all tabs and save as session' : 'Save open tabs as session',
      initial: defaultSessionName(DateTime.now()),
      action: closeAll ? 'Save and close tabs' : 'Save',
      message: 'The $count open tab${count == 1 ? '' : 's'} can be restored later from Sessions.',
    );
    if (name == null || !mounted) return false;
    final session = SessionStore.instance.save(_sessionTabs(), name: name, active: _active);
    if (session == null) return false;
    if (closeAll) _closeAllTabs();
    if (mounted) showKitToast(context, 'Saved session "${session.name}"');
    return true;
  }

  /// Closes every tab, leaving one blank tab (like closing the last tab).
  void _closeAllTabs() {
    final old = List.of(_tabs);
    _tabs.clear();
    _active = 0;
    _addTab(_blankUrl);
    for (final t in old) {
      t.dispose();
    }
    _selectTab(0, force: true);
  }

  Future<void> _openSessions() async {
    final open = await Navigator.of(context).push<SessionOpen>(
      MaterialPageRoute(builder: (_) => SessionsPage(onSaveOpenTabs: Incognito.active ? null : _saveSession)),
    );
    if (open == null || open.urls.isEmpty || !mounted) return;
    // A blank current tab takes the first page; the rest open in the background and the session's front tab is shown.
    final blank = _controller?.url.isEmpty != false || _controller?.url == _blankUrl;
    var at = blank ? _active : _active + 1;
    _BrowserTab? front;
    for (final (i, url) in open.urls.indexed) {
      final _BrowserTab tab;
      if (i == 0 && blank) {
        tab = _tab!;
        tab.controller.load(url);
      } else {
        tab = _addTab(url, at: at);
        tab.controller.visible = false;
      }
      at++;
      if (i == open.active) front = tab;
    }
    setState(() {});
    final index = _tabs.indexOf(front ?? _tab!);
    _selectTab(index, force: true);
  }

  /// Opens [url] in a new tab next to the current one without switching to it, like a middle-clicked link.
  void _openInBackgroundTab(String url) {
    if (_tabs.isEmpty) return;
    setState(() => _addTab(url, at: _active + 1).controller.visible = false);
    _syncVisibility();
  }

  /// Only the active tab's page renders; the others are told they're hidden and stop making frames.
  void _syncVisibility() {
    final now = DateTime.now();
    for (final t in _tabs) {
      final active = t == _tab;
      if (active) {
        t.hiddenSince = null;
      } else {
        t.hiddenSince ??= now;
      }
      t.controller.visible = active;
    }
  }

  /// Discards background tabs that have been hidden for [_discardAfter], or, when the system is short of memory,
  /// the longest-hidden ones first until it isn't.
  void _discardIdleTabs() {
    final now = DateTime.now();
    final candidates = _tabs
        .where((t) =>
            t != _tab &&
            t.hiddenSince != null &&
            !t.controller.isDiscarded &&
            t.controller.isAttached &&
            t.controller.webauthnPrompt == null)
        .toList()
      ..sort((a, b) => a.hiddenSince!.compareTo(b.hiddenSince!));
    var changed = false;
    final after = _discardAfter;
    for (final t in candidates) {
      final hidden = now.difference(t.hiddenSince!);
      if ((after != null && hidden >= after) ||
          (hidden >= const Duration(minutes: 1) && _lowOnMemory())) {
        t.controller.discard();
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  /// Whether less than a tenth of RAM is available (Linux /proc/meminfo).
  static bool _lowOnMemory() {
    try {
      int? total, available;
      for (final line in File('/proc/meminfo').readAsLinesSync()) {
        final kb = int.tryParse(line.split(RegExp(r'\s+')).elementAtOrNull(1) ?? '');
        if (line.startsWith('MemTotal:')) total = kb;
        if (line.startsWith('MemAvailable:')) available = kb;
      }
      return total != null && available != null && available * 10 < total;
    } on FileSystemException {
      return false;
    }
  }

  void _reopenClosedTab() {
    if (_closedUrls.isNotEmpty) _newTab(_closedUrls.removeLast());
  }

  void _selectTab(int index, {bool force = false}) {
    if (index < 0 || index >= _tabs.length || (index == _active && !force)) return;
    setState(() => _active = index);
    _syncVisibility();
    final tab = _tabs[index];
    final url = tab.controller.url;
    _shownUrl = url;
    _address.text = url == _blankUrl ? '' : url;
    final blank = url.isEmpty || url == _blankUrl;
    // A new tab starts in the address bar; otherwise the page gets the keys.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tab != tab) return;
      if (blank) {
        _addressFocus.requestFocus();
        _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length);
      } else {
        tab.focus.requestFocus();
      }
    });
    _showPasskeyPrompt(tab);
    _showPageDialog(tab);
  }

  void _cycleTab(int delta) => _selectTab((_active + delta) % _tabs.length);

  void _onPageChanged(_BrowserTab tab) {
    if (!_tabs.contains(tab)) return;
    final controller = tab.controller;
    if (controller.closeRequested) {
      // window.close() from the page; let the notification finish before the controller goes away.
      scheduleMicrotask(() => _closeTab(_tabs.indexOf(tab)));
      return;
    }
    _publishTabs();
    _recordHistory(tab);
    // Don't clobber what the user is typing.
    if (tab == _tab && controller.url != _shownUrl && !_addressFocus.hasFocus) {
      _shownUrl = controller.url;
      _address.text = controller.url == _blankUrl ? '' : controller.url;
    }
    _showPageDialog(tab);
    final passkeyPrompt = controller.webauthnPrompt;
    if (passkeyPrompt != null && !identical(passkeyPrompt, tab.shownPasskeyPrompt)) {
      // A site in a background tab asking for a passkey brings its tab forward.
      if (tab == _tab) {
        _showPasskeyPrompt(tab);
      } else {
        _selectTab(_tabs.indexOf(tab));
      }
    }
    setState(() {});
  }

  /// Each new page address a tab shows is a visit in the history; its title is filled in when it arrives.
  void _recordHistory(_BrowserTab tab) {
    final controller = tab.controller;
    final url = controller.url;
    if (url.isEmpty) return;
    if (url != tab.recordedUrl) {
      tab.recordedUrl = url;
      tab.visit = HistoryStore.instance.record(url, controller.title);
    } else if (tab.visit != null && controller.title.isNotEmpty) {
      HistoryStore.instance.setTitle(tab.visit!, controller.title);
    }
  }

  Future<void> _openHistory() async {
    final url = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => HistoryPage(onOpenInNewTab: _openInBackgroundTab)));
    if (url == null || !mounted) return;
    // History opens pages in a new tab, reusing a blank one.
    final blank = _controller?.url.isEmpty != false || _controller?.url == _blankUrl;
    if (blank) {
      _go(url);
    } else {
      _newTab(url);
    }
  }

  /// A page's alert/confirm/prompt shows while its tab is the active one, like Chrome's.
  void _showPageDialog(_BrowserTab tab) {
    final dialog = tab.controller.dialog;
    if (dialog == null || tab != _tab || identical(dialog, tab.shownDialog)) return;
    tab.shownDialog = dialog;
    showPageDialog(context, tab.controller, dialog);
  }

  void _showPasskeyPrompt(_BrowserTab tab) {
    final prompt = tab.controller.webauthnPrompt;
    if (prompt == null || identical(prompt, tab.shownPasskeyPrompt)) return;
    tab.shownPasskeyPrompt = prompt;
    showPasskeyDialog(context, tab.controller, prompt);
  }

  void _onBookmarksChanged() => setState(() {});

  void _bookmarkPage() {
    final controller = _controller;
    if (Incognito.active || controller == null || controller.url.isEmpty) return;
    bookmarkPage(context, url: controller.url, title: controller.title);
  }

  Future<void> _openBookmarks() async {
    final url = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const BookmarksPage()));
    if (url != null) _go(url);
  }

  Future<void> _clearBrowsingData() async {
    final data = SiteData.of(WebbyBindings.open());
    if (data == null) {
      showKitToast(context, 'This Ladybird runtime is too old to clear browsing data');
      return;
    }
    if (await showClearBrowsingData(context, data) && mounted) showKitToast(context, 'Browsing data cleared');
  }

  void _toggleBookmarkBar() => BookmarkStore.instance.showBar = !BookmarkStore.instance.showBar;

  static const _shortcuts = <ShortcutActivator, String>{
    SingleActivator(LogicalKeyboardKey.keyD, control: true): 'bookmark',
    SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true): 'bar',
    SingleActivator(LogicalKeyboardKey.keyO, control: true, shift: true): 'manager',
    SingleActivator(LogicalKeyboardKey.keyH, control: true): 'history',
    SingleActivator(LogicalKeyboardKey.keyT, control: true): 'newTab',
    SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true): 'reopenTab',
    SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): 'incognito',
    SingleActivator(LogicalKeyboardKey.delete, control: true, shift: true): 'clearData',
    SingleActivator(LogicalKeyboardKey.keyW, control: true): 'closeTab',
    SingleActivator(LogicalKeyboardKey.tab, control: true): 'nextTab',
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): 'previousTab',
    SingleActivator(LogicalKeyboardKey.pageDown, control: true): 'nextTab',
    SingleActivator(LogicalKeyboardKey.pageUp, control: true): 'previousTab',
    SingleActivator(LogicalKeyboardKey.digit1, control: true): 'tab1',
    SingleActivator(LogicalKeyboardKey.digit2, control: true): 'tab2',
    SingleActivator(LogicalKeyboardKey.digit3, control: true): 'tab3',
    SingleActivator(LogicalKeyboardKey.digit4, control: true): 'tab4',
    SingleActivator(LogicalKeyboardKey.digit5, control: true): 'tab5',
    SingleActivator(LogicalKeyboardKey.digit6, control: true): 'tab6',
    SingleActivator(LogicalKeyboardKey.digit7, control: true): 'tab7',
    SingleActivator(LogicalKeyboardKey.digit8, control: true): 'tab8',
    SingleActivator(LogicalKeyboardKey.digit9, control: true): 'lastTab',
  };

  static final _tabDigits = {
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  };

  /// Whether [event] is one of [_shortcuts]' keys (down, repeat or up), so the page doesn't get it.
  static bool _isBrowserShortcut(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyT || key == LogicalKeyboardKey.tab) return true;
    if (key == LogicalKeyboardKey.keyD ||
        key == LogicalKeyboardKey.keyH ||
        key == LogicalKeyboardKey.keyW ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.pageDown ||
        _tabDigits.contains(key)) {
      return !keyboard.isShiftPressed;
    }
    return keyboard.isShiftPressed &&
        (key == LogicalKeyboardKey.keyB ||
            key == LogicalKeyboardKey.keyO ||
            key == LogicalKeyboardKey.keyN ||
            key == LogicalKeyboardKey.delete);
  }

  void _runShortcut(String name) {
    switch (name) {
      case 'bookmark':
        _bookmarkPage();
      case 'bar':
        _toggleBookmarkBar();
      case 'manager':
        _openBookmarks();
      case 'history':
        _openHistory();
      case 'newTab':
        _newTab();
      case 'reopenTab':
        _reopenClosedTab();
      case 'incognito':
        _openIncognito();
      case 'clearData':
        _clearBrowsingData();
      case 'closeTab':
        _closeTab(_active);
      case 'nextTab':
        _cycleTab(1);
      case 'previousTab':
        _cycleTab(-1);
      case 'lastTab':
        _selectTab(_tabs.length - 1);
      default:
        if (name.startsWith('tab')) _selectTab(int.parse(name.substring(3)) - 1);
    }
  }

  void _go(String input) {
    final text = input.trim();
    final tab = _tab;
    if (text.isEmpty || tab == null) return;
    tab.controller.load(addressToUrl(text));
    tab.focus.requestFocus();
  }

  @override
  void dispose() {
    _discardTimer?.cancel();
    _exitListener?.dispose();
    BookmarkStore.instance.removeListener(_onBookmarksChanged);
    OfflineMonitor.instance?.removeListener(_onBookmarksChanged);
    for (final tab in _tabs) {
      tab.dispose();
    }
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final tab = _tab;
    if (tab == null) {
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

    final controller = tab.controller;
    final bookmarked = BookmarkStore.instance.bookmarkFor(controller.url) != null;
    // The system back button/gesture goes back in the page's history first.
    return PopScope(
      canPop: !controller.canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) controller.goBack();
      },
      child: CallbackShortcuts(
      bindings: {for (final entry in _shortcuts.entries) entry.key: () => _runShortcut(entry.value)},
      child: Material(
        color: c.background,
        // Make room for the on-screen keyboard so it doesn't cover the page (SafeArea only covers system bars).
        child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabStrip(
              tabs: [
                for (final t in _tabs)
                  TabLabel(title: tabTitle(t.controller.title, t.controller.url), loading: t.controller.isLoading),
              ],
              active: _active,
              onSelect: _selectTab,
              onClose: _closeTab,
              onNew: _newTab,
            ),
            Container(
              color: c.surface,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Row(
                children: [
                  if (Incognito.active) ...[const IncognitoBadge(), const SizedBox(width: 4)],
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
                      suggest: (input) => [
                        for (final page in HistoryStore.instance.suggest(input))
                          OmniboxSuggestion(page.url, page.title),
                      ],
                      onSiteSettings: () => showSiteSettings(context, controller),
                      trailing: [
                        if (OfflineMonitor.instance?.offline ?? false)
                          KitTooltip(
                            message: 'Offline: pages come from the copies saved when you last opened them',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 5),
                              child: Icon(Icons.cloud_off, size: 16, color: c.textDim),
                            ),
                          ),
                        // Incognito windows don't install apps or bookmark pages.
                        if (!Incognito.active) ...[
                          InstallAppButton(agent: tab.pwa),
                          KitIconButton(
                            bookmarked ? Icons.star : Icons.star_border,
                            tooltip: bookmarked ? 'Edit bookmark (Ctrl+D)' : 'Bookmark this page (Ctrl+D)',
                            color: bookmarked ? c.accent : null,
                            size: 16,
                            extent: 26,
                            onPressed: controller.url.isEmpty ? null : _bookmarkPage,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  KitMenu(
                    minWidth: 260,
                    items: () => [
                      if (!Incognito.active)
                        KitMenuItem('Bookmark this page', shortcut: 'Ctrl+D', onSelected: _bookmarkPage),
                      KitMenuItem(
                        'Show bookmarks bar',
                        shortcut: 'Ctrl+Shift+B',
                        checked: BookmarkStore.instance.showBar,
                        onSelected: _toggleBookmarkBar,
                      ),
                      const KitMenuDivider(),
                      KitMenuItem('Bookmark manager', shortcut: 'Ctrl+Shift+O', onSelected: _openBookmarks),
                      KitMenuItem('History', shortcut: 'Ctrl+H', onSelected: _openHistory),
                      if (!Incognito.active) ...[
                        const KitMenuDivider(),
                        KitMenuItem('Tabs from other devices', onSelected: _openDeviceTabs),
                        const KitMenuDivider(),
                        KitMenuItem('Sessions', onSelected: _openSessions),
                        KitMenuItem('Save open tabs as session', onSelected: _saveSession),
                        KitMenuItem('Close all tabs and save as session',
                            onSelected: () => _saveSession(closeAll: true)),
                      ],
                      if (!Platform.isAndroid) ...[
                        const KitMenuDivider(),
                        KitMenuItem('New incognito window', shortcut: 'Ctrl+Shift+N', onSelected: _openIncognito),
                      ],
                      const KitMenuDivider(),
                      KitMenuItem('Clear browsing data…', shortcut: 'Ctrl+Shift+Del', onSelected: _clearBrowsingData),
                    ],
                    builder: (context, toggle, open) =>
                        KitIconButton(Icons.bookmarks_outlined, tooltip: 'Bookmarks', onPressed: toggle),
                  ),
                  // The vault belongs to the normal windows; incognito ones only fill from it.
                  if (!Incognito.active)
                    KitIconButton(
                      Icons.key,
                      tooltip: 'Passwords and passkeys',
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VaultPage())),
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
            BookmarkBar(onOpen: _go, onOpenInNewTab: _openInBackgroundTab),
            PasswordBar(key: ObjectKey(tab), agent: tab.passwords),
            Expanded(
              child: Stack(
                children: [
                  // Every tab's view stays laid out (so its Ladybird view keeps its size); only the active one shows.
                  Positioned.fill(
                    child: IndexedStack(
                      index: _active,
                      sizing: StackFit.expand,
                      children: [
                        for (final t in _tabs)
                          WebbyView(
                            key: ObjectKey(t),
                            controller: t.controller,
                            focusNode: t.focus,
                            isBrowserShortcut: _isBrowserShortcut,
                            onOpenInNewTab: _openInBackgroundTab,
                          ),
                      ],
                    ),
                  ),
                  if (Incognito.active && (controller.url.isEmpty || controller.url == _blankUrl))
                    const Positioned.fill(child: IncognitoNewTab()),
                  PermissionBubble(key: ObjectKey(tab), controller: controller),
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
        ),
      ),
      ),
    );
  }
}
