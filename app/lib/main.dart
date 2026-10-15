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
import 'src/find_in_page.dart';
import 'src/frame_bench.dart';
import 'src/history/history_page.dart';
import 'src/history/history_store.dart';
import 'src/home_page.dart';
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
import 'src/route_guard.dart';
import 'src/side_panel.dart';
import 'src/site_data.dart';
import 'src/site_settings.dart';
import 'src/summarize.dart';
import 'src/tab_strip.dart';
import 'src/tabs/device_tabs.dart';
import 'src/tabs/device_tabs_page.dart';
import 'src/tabs/new_tab_requests.dart';
import 'src/tabs/open_tabs.dart';
import 'src/tabs/sessions.dart';
import 'src/tabs/sessions_page.dart';
import 'src/tabs/tab_layout.dart';
import 'src/web_view.dart';

Future<void> main(List<String> args) async {
  // `--app=<url>` opens an installed web app in its own window (what the app launchers run).
  final app = args.where((a) => a.startsWith('--app=')).map((a) => a.substring(6)).firstOrNull;
  final urls = args.where((a) => !a.startsWith('--')).toList();
  // `--incognito` makes this process an incognito window: its own Ladybird that keeps nothing (see Incognito).
  if (app == null && args.contains(Incognito.flag) && !Platform.isAndroid) Incognito.enable();
  var initialUrl = app ?? (urls.isNotEmpty ? urls.first : 'about:blank');
  String? launchUrl;
  if (Platform.isAndroid) {
    WidgetsFlutterBinding.ensureInitialized();
    await AndroidHost.prepare();
    launchUrl = await AndroidHost.initialUrl();
    initialUrl = launchUrl ?? initialUrl;
  }
  // Desktop launchers for installed web apps; Android has none.
  if (app == null && !Incognito.active && !Platform.isAndroid) AppStore.instance.refreshLaunchers().ignore();
  WidgetsFlutterBinding.ensureInitialized();
  PlatformRouteGuard.install();
  runApp(WebbyApp(
    initialUrl: initialUrl,
    moreUrls: app == null && urls.length > 1 ? urls.sublist(1) : const [],
    launchUrl: launchUrl,
    appMode: app != null,
  ));
}

class WebbyApp extends StatelessWidget {
  const WebbyApp({super.key, required this.initialUrl, this.moreUrls = const [], this.launchUrl, this.appMode = false});

  final String initialUrl;
  final List<String> moreUrls;
  final String? launchUrl;
  final bool appMode;

  @override
  Widget build(BuildContext context) {
    // flatkit's neutral greys with a blue accent, light or dark with the desktop. The KDE colour
    // scheme stays off: Breeze's blue-grey with Plasma's (often wallpaper-picked) accent looked off.
    return KitSystemTheme(
      followKde: false,
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
          home: appMode ? AppWindowPage(startUrl: initialUrl) : BrowserPage(initialUrl: initialUrl, moreUrls: moreUrls, launchUrl: launchUrl),
        );
      },
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.initialUrl, this.moreUrls = const [], this.launchUrl});

  final String initialUrl;

  /// Further addresses from the command line, opened as background tabs after [initialUrl].
  final List<String> moreUrls;

  /// The link the app was opened with on Android, which opens in front of the restored tabs.
  final String? launchUrl;

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
  NewTabRequests? newTabs;
  final focus = FocusNode(debugLabel: 'page');
  Map<String, Object?>? shownPasskeyPrompt;
  PageDialog? shownDialog;
  /// When the tab last went into the background (null while it is the active tab).
  DateTime? hiddenSince;
  /// Pinned tabs sit small at the start of the strip, survive "Close other tabs" and come back at the next start.
  bool pinned = false;
  /// The page address last recorded in the history for this tab, and its visit (null when it isn't recorded).
  String recordedUrl = '';
  HistoryEntry? visit;

  void dispose() {
    passwords.dispose();
    pwa.dispose();
    notifications?.dispose();
    newTabs?.dispose();
    controller.dispose();
    focus.dispose();
  }
}

const _blankUrl = 'about:blank';

class _BrowserPageState extends State<BrowserPage> with WidgetsBindingObserver {
  final _tabs = <_BrowserTab>[];
  int _active = 0;
  /// Closed tabs, most recent last, for Ctrl+Shift+T and the "Recently closed" menus.
  final _closedTabs = <DeviceTab>[];
  Object? _startupError;
  final _address = TextEditingController();
  final _addressFocus = FocusNode(debugLabel: 'address');
  String _shownUrl = '';
  Timer? _discardTimer;
  /// Saves the tabs as a session when the window is closed (see [_onExitRequested]).
  AppLifecycleListener? _exitListener;

  /// Background tabs hidden this long lose their page (and its WebContent process) until they're shown again: 30
  /// minutes, 5 on Android, where a phone has little RAM to spare. WEBBY_DISCARD_MINUTES overrides it; 0 never
  /// discards on age (low memory still does).
  static final Duration? _discardAfter = () {
    final minutes =
        int.tryParse(Platform.environment['WEBBY_DISCARD_MINUTES'] ?? '') ?? (Platform.isAndroid ? 5 : 30);
    return minutes > 0 ? Duration(minutes: minutes) : null;
  }();

  _BrowserTab? get _tab => _tabs.isEmpty ? null : _tabs[_active];
  WebbyController? get _controller => _tab?.controller;

  @override
  void initState() {
    super.initState();
    try {
      _openStartTabs();
      final tab = _tab!;
      _address.text = tab.controller.url.isNotEmpty ? tab.controller.url : widget.initialUrl;
      PasswordManager.instance.start(WebbyBindings.open());
      // Offline mode serves pages from the disk cache, which incognito windows don't have.
      if (!Incognito.active) OfflineMonitor.start(WebbyBindings.open())?.addListener(_onBookmarksChanged);
      maybeStartBench(tab.controller);
      BookmarkStore.instance.addListener(_onBookmarksChanged);
      _discardTimer = Timer.periodic(const Duration(minutes: 1), (_) => _discardIdleTabs());
      if (Platform.isAndroid) {
        AndroidHost.onOpenUrl(_openFromOtherApp);
        AndroidHost.onMemoryPressure(_onMemoryPressure);
      }
      WidgetsBinding.instance.addObserver(this);
      if (_restoresTabs) {
        _lifecycle = AppLifecycleListener(
            onHide: () => OpenTabsStore.instance.flush(_sessionTabs(), _active, pinned: _pinnedCount));
      }
      if (!Incognito.active && !Platform.isAndroid) _exitListener = AppLifecycleListener(onExitRequested: _onExitRequested);
    } catch (error) {
      _startupError = error;
    }
  }

  /// The open tabs are kept as they change and come back at the next start, asleep until selected (Android also
  /// stops apps whenever it likes, in the background or for updates). Incognito windows keep nothing.
  static final bool _restoresTabs = !Incognito.active;
  AppLifecycleListener? _lifecycle;

  void _openStartTabs() {
    // Desktop kept only the pinned tabs (pinned_tabs.json) before it kept all of them.
    final saved = !_restoresTabs
        ? null
        : OpenTabsStore.instance.read() ?? (Platform.isAndroid ? null : OpenTabsStore.pinned.read());
    if (saved == null) {
      _active = _tabs.length;
      _addTab(widget.initialUrl);
      // More addresses on the command line open as background tabs.
      for (final url in widget.moreUrls) {
        _addTab(url).controller.visible = false;
      }
      _syncVisibility();
      return;
    }
    // Only the front tab loads now; the others wait until they're selected.
    for (final (i, tab) in saved.tabs.indexed) {
      _insertTab(_BrowserTab.withController(WebbyController.unloaded(tab.url, title: tab.title))..pinned = i < saved.pinned);
    }
    _active = saved.active;
    // Addresses webby was started with open as new tabs after the restored ones, the first in front.
    final launch = Platform.isAndroid
        ? [?widget.launchUrl]
        : [if (widget.initialUrl != _blankUrl) widget.initialUrl, ...widget.moreUrls];
    for (final (i, url) in launch.indexed) {
      final tab = _addTab(url);
      if (i == 0) {
        _active = _tabs.length - 1;
      } else {
        tab.controller.visible = false;
      }
    }
    _syncVisibility();
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
    // window.open(..., 'noopener') gets a tab of its own, with its own WebContent (see new_tab_requests.dart).
    // Blank tabs show webby's start page (incognito windows keep their own blank page).
    if (!Incognito.active) {
      tab.controller.pageScripts.add(() => tab.controller.url == _blankUrl ? homePageScript(homePageData()) : '');
    }
    tab.newTabs = NewTabRequests(tab.controller, onOpen: (url) {
      if (!mounted || !_tabs.contains(tab)) return;
      final opened = _addTab(url, at: _tabs.indexOf(tab) + 1);
      _selectTab(_tabs.indexOf(opened));
    });
    // Pinned tabs stay together at the start; an unpinned tab opened among them goes just after them.
    final pinnedCount = _pinnedCount;
    final index = at ?? _tabs.length;
    _tabs.insert(tab.pinned ? index.clamp(0, pinnedCount) : index.clamp(pinnedCount, _tabs.length), tab);
    _publishTabs();
    return tab;
  }

  int get _pinnedCount => _tabs.takeWhile((t) => t.pinned).length;

  /// Pins tab [index] (moving it to the end of the pinned tabs) or unpins it (moving it just after them).
  void _togglePinned(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final active = _tab;
    final tab = _tabs.removeAt(index);
    tab.pinned = !tab.pinned;
    _tabs.insert(_pinnedCount, tab);
    setState(() => _active = _tabs.indexOf(active!));
    _publishTabs();
  }

  void _newTab([String url = _blankUrl]) {
    if (_tabs.isEmpty) return;
    final tab = _addTab(url, at: _active + 1);
    _selectTab(_tabs.indexOf(tab));
  }

  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    if (_findTab == tab) _findTab = null;
    final url = tab.controller.url;
    if (url.isNotEmpty && url != _blankUrl) {
      _closedTabs.add(DeviceTab(tabTitle(tab.controller.title, url), url));
      if (_closedTabs.length > 25) _closedTabs.removeAt(0);
    }
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
    if (_restoresTabs) OpenTabsStore.instance.save(_sessionTabs(), _active, pinned: _pinnedCount);
  }

  /// Opens a new incognito window (a separate process; desktop only).
  void _openIncognito() {
    if (Platform.isAndroid) return;
    AppStore.instance.openIncognito().catchError((Object error) {
      if (mounted) showKitToast(context, 'Could not open an incognito window: $error');
    });
  }

  void _openDeviceTabs() => _showPanel(_Panel.deviceTabs);

  void _openDeviceTabUrls(List<String> urls) {
    if (urls.isEmpty) return;
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

  /// Closing the window keeps its tabs as a session, without asking. Incognito windows never save one, and a window
  /// with only blank tabs saves nothing ([SessionStore.save] skips those).
  Future<AppExitResponse> _onExitRequested() async {
    if (!Incognito.active) SessionStore.instance.save(_sessionTabs(), active: _active);
    if (_restoresTabs) OpenTabsStore.instance.flush(_sessionTabs(), _active, pinned: _pinnedCount);
    return AppExitResponse.exit;
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

  /// Closes every tab but the pinned ones, leaving one blank tab after them (like closing the last tab).
  void _closeAllTabs() {
    final old = _tabs.where((t) => !t.pinned).toList();
    _tabs.removeWhere(old.contains);
    _active = _tabs.length;
    _addTab(_blankUrl);
    for (final t in old) {
      t.dispose();
    }
    _selectTab(_active, force: true);
  }

  /// The sidebar that's showing, if any. The toolbar buttons open their screens here rather than over the page.
  _Panel? _panel;

  void _showPanel(_Panel panel) => setState(() => _panel = panel);

  void _togglePanel(_Panel panel) => setState(() => _panel = _panel == panel ? null : panel);

  void _closePanel() => setState(() => _panel = null);

  /// The sessions sidebar, kept as one widget instance so the window's rebuilds (every page notification, many per
  /// second while a page loads) don't rebuild it too; it updates from [SessionStore] on its own. Rebuilding it on
  /// every one of them made its corner flicker on desktop during loads.
  SessionsPanel? _sessions;

  Widget _sessionsPanel({required bool wide}) {
    final sessions = _sessions;
    if (sessions != null && sessions.wide == wide) return sessions;
    return _sessions = SessionsPanel(
      wide: wide,
      onOpen: _restoreSession,
      onClose: _closePanel,
      onSaveOpenTabs: _saveSession,
      onCloseAllAndSave: _closeAllAndSaveSession,
    );
  }

  void _closeAllAndSaveSession() => _saveSession(closeAll: true);

  /// The sidebar: beside the page on wide windows, under it on narrow ones (phones).
  Widget _sidePanel(_Panel panel, {required bool wide}) => switch (panel) {
    _Panel.sessions => _sessionsPanel(wide: wide),
    _Panel.bookmarks => SidePanel(
      key: const ValueKey(_Panel.bookmarks),
      wide: wide,
      page: (_) => const BookmarksPage(),
      onClose: _closePanel,
      onResult: (url) => _go(url as String),
    ),
    _Panel.history => SidePanel(
      key: const ValueKey(_Panel.history),
      wide: wide,
      page: (_) => HistoryPage(onOpenInNewTab: _openInBackgroundTab),
      onClose: _closePanel,
      onResult: (url) => _openHistoryUrl(url as String),
    ),
    _Panel.deviceTabs => SidePanel(
      key: const ValueKey(_Panel.deviceTabs),
      wide: wide,
      page: (_) => const DeviceTabsPage(),
      onClose: _closePanel,
      onResult: (urls) => _openDeviceTabUrls((urls as List).cast<String>()),
    ),
    _Panel.passwords => SidePanel(
      key: const ValueKey(_Panel.passwords),
      wide: wide,
      page: (_) => const VaultPage(),
      onClose: _closePanel,
    ),
  };

  /// Opens a saved session's tabs next to the current one.
  void _restoreSession(SessionOpen open) {
    if (open.urls.isEmpty) return;
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
      // Pinned tabs may have pushed it further along.
      at = _tabs.indexOf(tab) + 1;
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
    final after = _discardAfter;
    final low = _lowOnMemory();
    _discardHiddenTabs((hidden) => (after != null && hidden >= after) || (low && hidden >= const Duration(minutes: 1)));
  }

  /// Discards the background tabs for which [discard] says yes, given how long each has been hidden.
  void _discardHiddenTabs(bool Function(Duration hidden) discard) {
    final now = DateTime.now();
    final candidates = _tabs
        .where((t) =>
            t != _tab &&
            !t.pinned &&
            t.hiddenSince != null &&
            !t.controller.isDiscarded &&
            t.controller.isAttached &&
            t.controller.webauthnPrompt == null)
        .toList()
      ..sort((a, b) => a.hiddenSince!.compareTo(b.hiddenSince!));
    var changed = false;
    for (final t in candidates) {
      if (discard(now.difference(t.hiddenSince!))) {
        t.controller.discard();
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  /// The system is short of memory. [level] is Android's onTrimMemory level (ComponentCallbacks2): 20 means the
  /// app was just put away, 40 and up that it sits in the background where Android may kill it, 15 that the device
  /// is critically low while the app runs. Pages collect their garbage; unless the app was only put away, background
  /// tabs lose their pages too (all of them when it's serious, else those hidden for a minute or more).
  void _onMemoryPressure(int level) {
    WebbyController.collectAllGarbage();
    if (level == 20) return;
    final everyTab = level >= 40 || level == 15;
    _discardHiddenTabs((hidden) => everyTab || hidden >= const Duration(minutes: 1));
  }

  @override
  void didHaveMemoryPressure() => _onMemoryPressure(15);

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
    if (_closedTabs.isNotEmpty) _newTab(_closedTabs.removeLast().url);
  }

  /// Menu rows for the last few closed tabs, newest first; picking one reopens it.
  List<KitMenuEntry> _recentlyClosedItems() {
    if (_closedTabs.isEmpty) return const [];
    String short(String title) => title.length > 50 ? '${title.substring(0, 49)}…' : title;
    return [
      const KitMenuDivider(),
      const KitMenuItem('Recently closed', onSelected: null),
      for (final closed in _closedTabs.reversed.take(10))
        KitMenuItem('   ${short(closed.title)}', onSelected: () {
          _closedTabs.remove(closed);
          _newTab(closed.url);
        }),
    ];
  }

  /// Opens a copy of tab [index] next to it and switches to it.
  void _duplicateTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final url = _tabs[index].controller.url;
    final copy = _addTab(url.isEmpty ? _blankUrl : url, at: index + 1);
    _selectTab(_tabs.indexOf(copy));
  }

  /// Closes every tab but [index] (or only those after it, with [toTheRight]).
  void _closeOtherTabs(int index, {bool toTheRight = false}) {
    if (index < 0 || index >= _tabs.length) return;
    final keep = _tabs[index];
    for (var i = _tabs.length - 1; i >= 0; i--) {
      if (_tabs[i] != keep && !_tabs[i].pinned && (!toTheRight || i > index)) _closeTab(i);
    }
    _selectTab(_tabs.indexOf(keep), force: true);
  }

  /// The tab strip's right-click menu, for tab [index], or for no tab (null) on the strip's empty space.
  List<KitMenuEntry> _tabMenuItems(int? index) {
    final layout = TabLayout.instance;
    return [
      KitMenuItem('New tab', shortcut: 'Ctrl+T', onSelected: _newTab),
      if (index != null) ...[
        const KitMenuDivider(),
        KitMenuItem('Reload', onSelected: () => _tabs[index].controller.reload()),
        KitMenuItem('Duplicate', onSelected: () => _duplicateTab(index)),
        KitMenuItem(_tabs[index].pinned ? 'Unpin tab' : 'Pin tab', onSelected: () => _togglePinned(index)),
        const KitMenuDivider(),
        KitMenuItem('Close', shortcut: index == _active ? 'Ctrl+W' : null, onSelected: () => _closeTab(index)),
        KitMenuItem('Close other tabs',
            onSelected: _tabs.indexed.any((e) => e.$1 != index && !e.$2.pinned) ? () => _closeOtherTabs(index) : null),
        KitMenuItem(layout.vertical ? 'Close tabs below' : 'Close tabs to the right',
            onSelected: _tabs.skip(index + 1).any((t) => !t.pinned)
                ? () => _closeOtherTabs(index, toTheRight: true)
                : null),
      ],
      const KitMenuDivider(),
      KitMenuItem('Reopen closed tab', shortcut: 'Ctrl+Shift+T',
          onSelected: _closedTabs.isEmpty ? null : _reopenClosedTab),
      ..._recentlyClosedItems(),
      if (!Platform.isAndroid) ...[
        const KitMenuDivider(),
        KitMenuItem(
          'Vertical tabs',
          checked: layout.vertical,
          onSelected: () => setState(() => layout.vertical = !layout.vertical),
        ),
      ],
    ];
  }

  void _selectTab(int index, {bool force = false}) {
    if (index < 0 || index >= _tabs.length || (index == _active && !force)) return;
    setState(() {
      _active = index;
      if (_findTab != null && _findTab != _tabs[index]) _findTab = null;
    });
    _syncVisibility();
    if (_restoresTabs) OpenTabsStore.instance.save(_sessionTabs(), _active, pinned: _pinnedCount);
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

  void _openHistory() => _showPanel(_Panel.history);

  void _openHistoryUrl(String url) {
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

  void _openBookmarks() => _showPanel(_Panel.bookmarks);

  Future<void> _clearBrowsingData() async {
    final data = SiteData.of(WebbyBindings.open());
    if (data == null) {
      showKitToast(context, 'This Ladybird runtime is too old to clear browsing data');
      return;
    }
    if (await showClearBrowsingData(context, data) && mounted) showKitToast(context, 'Browsing data cleared');
  }

  /// The tab whose find bar shows (null when it is closed); the bar closes when another tab comes forward.
  _BrowserTab? _findTab;
  final _findBar = GlobalKey<FindBarState>();

  void _openFind() {
    final tab = _tab;
    if (tab == null) return;
    if (_findTab == tab) {
      _findBar.currentState?.focus();
      return;
    }
    setState(() => _findTab = tab);
  }

  void _closeFind() {
    final tab = _findTab;
    if (tab == null) return;
    setState(() => _findTab = null);
    if (_tab == tab) tab.focus.requestFocus();
  }

  void _findStep({required bool forward}) {
    final bar = _findBar.currentState;
    if (_findTab != _tab || bar == null) {
      _openFind();
    } else {
      bar.step(forward: forward);
    }
  }

  void _toggleBookmarkBar() => BookmarkStore.instance.showBar = !BookmarkStore.instance.showBar;

  static const _shortcuts = <ShortcutActivator, String>{
    SingleActivator(LogicalKeyboardKey.keyD, control: true): 'bookmark',
    SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true): 'bar',
    SingleActivator(LogicalKeyboardKey.keyO, control: true, shift: true): 'manager',
    SingleActivator(LogicalKeyboardKey.keyH, control: true): 'history',
    SingleActivator(LogicalKeyboardKey.keyF, control: true): 'find',
    SingleActivator(LogicalKeyboardKey.keyG, control: true): 'findNext',
    SingleActivator(LogicalKeyboardKey.keyG, control: true, shift: true): 'findPrevious',
    SingleActivator(LogicalKeyboardKey.f3): 'findNext',
    SingleActivator(LogicalKeyboardKey.f3, shift: true): 'findPrevious',
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
    if (event.logicalKey == LogicalKeyboardKey.f3 && !keyboard.isControlPressed && !keyboard.isAltPressed) return true;
    if (!keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyT || key == LogicalKeyboardKey.tab || key == LogicalKeyboardKey.keyG) return true;
    if (key == LogicalKeyboardKey.keyD ||
        key == LogicalKeyboardKey.keyH ||
        key == LogicalKeyboardKey.keyF ||
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
      case 'find':
        _openFind();
      case 'findNext':
        _findStep(forward: true);
      case 'findPrevious':
        _findStep(forward: false);
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

  /// A link another app opened while webby runs: it gets a tab of its own (a blank current tab takes it), like
  /// links opened from other apps in other browsers, so the page the user was on stays put.
  void _openFromOtherApp(String url) {
    final current = _controller?.url;
    if (current == null || current.isEmpty || current == _blankUrl) {
      _go(url);
    } else {
      _newTab(addressToUrl(url.trim()));
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
    WidgetsBinding.instance.removeObserver(this);
    _discardTimer?.cancel();
    _exitListener?.dispose();
    _lifecycle?.dispose();
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
    // Android's screen is too narrow for a tab list beside the page.
    final vertical = TabLayout.instance.vertical && !Platform.isAndroid;
    final size = MediaQuery.sizeOf(context);
    // Incognito windows have no sessions, synced tabs or password vault.
    final panel = Incognito.active && _privatePanels.contains(_panel) ? null : _panel;
    final panelWide = size.width >= 720;
    final tabStrip = TabStrip(
      tabs: [
        for (final t in _tabs)
          TabLabel(
            title: tabTitle(t.controller.title, t.controller.url),
            loading: t.controller.isLoading,
            pinned: t.pinned,
            url: t.controller.url,
          ),
      ],
      active: _active,
      vertical: vertical,
      onSelect: _selectTab,
      onClose: _closeTab,
      onNew: _newTab,
      menuItems: _tabMenuItems,
    );
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
            if (!vertical) tabStrip,
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
                  // The buttons below each toggle a sidebar.
                  KitIconButton(
                    panel == _Panel.bookmarks ? Icons.bookmarks : Icons.bookmarks_outlined,
                    tooltip: 'Bookmarks (Ctrl+Shift+O)',
                    onPressed: () => _togglePanel(_Panel.bookmarks),
                  ),
                  // Sessions: save the open tabs and restore saved sets.
                  if (!Incognito.active)
                    KitIconButton(
                      panel == _Panel.sessions ? Icons.layers : Icons.layers_outlined,
                      tooltip: 'Sessions',
                      onPressed: () => _togglePanel(_Panel.sessions),
                    ),
                  // Summarize: its sidebar belongs to the tab.
                  ListenableBuilder(
                    listenable: SummaryJob.of(controller),
                    builder: (context, _) {
                      final job = SummaryJob.of(controller);
                      return KitIconButton(
                        job.open ? Icons.summarize : Icons.summarize_outlined,
                        tooltip: 'Summarize this page',
                        onPressed: job.open
                            ? job.close
                            : controller.url.isEmpty
                            ? null
                            : () => summarizePage(context, controller),
                      );
                    },
                  ),
                  // The vault belongs to the normal windows; incognito ones only fill from it.
                  if (!Incognito.active)
                    KitIconButton(
                      panel == _Panel.passwords ? Icons.key : Icons.key_outlined,
                      tooltip: 'Passwords and passkeys',
                      onPressed: () => _togglePanel(_Panel.passwords),
                    ),
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
                      KitMenuItem('Find in page…', shortcut: 'Ctrl+F', onSelected: _openFind),
                      ..._recentlyClosedItems(),
                      if (!Incognito.active) ...[
                        const KitMenuDivider(),
                        KitMenuItem('Tabs from other devices', onSelected: _openDeviceTabs),
                      ],
                      if (!Platform.isAndroid) ...[
                        const KitMenuDivider(),
                        KitMenuItem('New incognito window', shortcut: 'Ctrl+Shift+N', onSelected: _openIncognito),
                      ],
                      const KitMenuDivider(),
                      KitMenuItem('Summarize this page', onSelected: () => summarizePage(context, controller)),
                      if (!Incognito.active)
                        KitMenuItem('Summarize settings…', onSelected: () => showSummarizeSettings(context)),
                      const KitMenuDivider(),
                      KitMenuItem('Clear browsing data…', shortcut: 'Ctrl+Shift+Del', onSelected: _clearBrowsingData),
                    ],
                    builder: (context, toggle, open) => KitIconButton(Icons.more_vert, tooltip: 'More', onPressed: toggle),
                  ),
                ],
              ),
            ),
            // The loading line doubles as the toolbar's bottom border.
            SizedBox(
              height: 2,
              child: controller.isLoading
                  // Its own layer, so the animation doesn't repaint the rest of the window every frame of a load.
                  ? RepaintBoundary(
                      child: LinearProgressIndicator(minHeight: 2, color: c.accent, backgroundColor: c.border),
                    )
                  : Align(alignment: Alignment.topCenter, child: Container(height: 1, color: c.border)),
            ),
            Expanded(
              child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              if (vertical) tabStrip,
              Expanded(
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
            BookmarkBar(onOpen: _go, onOpenInNewTab: _openInBackgroundTab),
            PasswordBar(key: ObjectKey(tab), agent: tab.passwords),
            Expanded(
              // An open summary sits beside the page (below it on narrow windows), which shrinks the page.
              child: SummaryLayout(
                key: ObjectKey(tab),
                controller: controller,
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
                  if (controller.hoveredLink.isNotEmpty && !controller.pointerIsTouch)
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
            ),
            if (_findTab == tab)
              FindBar(key: _findBar, controller: controller, onClose: _closeFind),
            // The sidebar sits under the page on narrow windows.
            if (panel != null && !panelWide) SizedBox(height: size.height * 0.5, child: _sidePanel(panel, wide: false)),
              ],
              ),
              ),
              if (panel != null && panelWide)
                SizedBox(width: panel == _Panel.sessions ? 360 : 400, child: _sidePanel(panel, wide: true)),
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

/// The sidebars the toolbar opens.
enum _Panel { sessions, bookmarks, history, deviceTabs, passwords }

/// Sidebars an incognito window doesn't have.
const _privatePanels = {_Panel.sessions, _Panel.deviceTabs, _Panel.passwords};
