import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bindings.dart';
import '../notifications.dart';
import '../passkey_dialog.dart';
import '../passwords/password_bar.dart';
import '../passwords/password_manager.dart';
import '../site_settings.dart';
import '../ui.dart';
import '../web_view.dart';
import 'app_store.dart';
import 'offline.dart';

/// An installed web app's window (`webby --app=<url>`): just the page, no browser toolbar. Pages outside the app's
/// scope get a thin strip with their origin and a way out to the browser, like other browsers' app windows.
class AppWindowPage extends StatefulWidget {
  const AppWindowPage({super.key, required this.startUrl});

  final String startUrl;

  @override
  State<AppWindowPage> createState() => _AppWindowPageState();
}

class _AppWindowPageState extends State<AppWindowPage> {
  WebbyController? _controller;
  PasswordAgent? _passwords;
  NotificationAgent? _notifications;
  Object? _startupError;
  InstalledApp? _app;
  final _pageFocus = FocusNode(debugLabel: 'page');
  Map<String, Object?>? _shownPasskeyPrompt;

  @override
  void initState() {
    super.initState();
    final start = Uri.tryParse(widget.startUrl);
    _app = start == null ? null : AppStore.instance.forUrl(start);
    try {
      _controller = WebbyController(initialUrl: widget.startUrl)..addListener(_onPageChanged);
      _passwords = PasswordAgent(_controller!);
      _notifications = NotificationAgent(_controller!);
      PasswordManager.instance.start(WebbyBindings.open());
      OfflineMonitor.start(WebbyBindings.open())?.addListener(_onOffline);
    } catch (error) {
      _startupError = error;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _pageFocus.requestFocus());
  }

  void _onOffline() => setState(() {});

  void _onPageChanged() {
    final passkeyPrompt = _controller!.webauthnPrompt;
    if (passkeyPrompt != null && !identical(passkeyPrompt, _shownPasskeyPrompt)) {
      _shownPasskeyPrompt = passkeyPrompt;
      showPasskeyDialog(context, _controller!, passkeyPrompt);
    }
    setState(() {});
  }

  /// Whether [url] belongs to the app: its installed scope, else the start URL's origin.
  bool _inScope(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || url.isEmpty) return true;
    if (_app != null) return _app!.inScope(uri);
    final start = Uri.tryParse(widget.startUrl);
    return start == null || (uri.scheme == start.scheme && uri.host == start.host && uri.port == start.port);
  }

  static bool _isAppShortcut(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f5) return true;
    if (keyboard.isAltPressed && (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight)) return true;
    return keyboard.isControlPressed && !keyboard.isAltPressed && key == LogicalKeyboardKey.keyR;
  }

  @override
  void dispose() {
    OfflineMonitor.instance?.removeListener(_onOffline);
    _passwords?.dispose();
    _notifications?.dispose();
    _controller?.dispose();
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

    final outside = !_inScope(controller.url);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f5): controller.reload,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): controller.reload,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): controller.goBack,
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): controller.goForward,
      },
      child: Material(
        color: c.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (outside)
              Container(
                color: c.surface,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Row(
                  children: [
                    KitIconButton(
                      Icons.arrow_back,
                      tooltip: 'Back to ${_app?.name ?? 'the app'}',
                      size: 16,
                      extent: 26,
                      onPressed: controller.canGoBack ? controller.goBack : null,
                    ),
                    const SizedBox(width: 6),
                    Icon(Uri.tryParse(controller.url)?.isScheme('https') == true ? Icons.lock_outline : Icons.info_outline,
                        size: 14, color: c.textDim),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        Uri.tryParse(controller.url)?.host ?? controller.url,
                        overflow: TextOverflow.ellipsis,
                        style: KitText.small(context, color: c.textDim),
                      ),
                    ),
                    KitIconButton(
                      Icons.open_in_browser,
                      tooltip: 'Open in Webby',
                      size: 16,
                      extent: 26,
                      onPressed: () => AppStore.instance.openInBrowser(controller.url),
                    ),
                  ],
                ),
              ),
            if (OfflineMonitor.instance?.offline ?? false)
              const KitBanner(message: 'Offline: showing the copy saved when you last opened this.', icon: Icons.cloud_off),
            SizedBox(
              height: 2,
              child: controller.isLoading
                  ? LinearProgressIndicator(minHeight: 2, color: c.accent, backgroundColor: c.border)
                  : null,
            ),
            if (_passwords != null) PasswordBar(agent: _passwords!),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: WebbyView(controller: controller, focusNode: _pageFocus, isBrowserShortcut: _isAppShortcut),
                  ),
                  PermissionBubble(controller: controller),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
