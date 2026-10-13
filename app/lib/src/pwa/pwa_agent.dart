import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../web_view.dart';
import 'app_store.dart';
import 'manifest.dart';

/// JavaScript that reports the page's `<link rel="manifest">` as `{"type": "manifest", "href": ...}` through the
/// browser's page-message channel (see passwords/page_script.dart), and again if the link changes later.
String manifestPageScript(String prefix) => '''
(() => {
  if (window.__webbyManifest) return;
  window.__webbyManifest = true;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  let last = null;
  const report = () => {
    const link = document.querySelector('link[rel~="manifest"][href]');
    const href = link ? link.href : '';
    if (href === last) return;
    last = href;
    try { prompt.call(window, PREFIX + JSON.stringify({ type: 'manifest', href })); } catch (e) {}
  };
  report();
  try { new MutationObserver(report).observe(document.head || document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel'] }); } catch (e) {}
})();
''';

/// Watches one [WebbyController] for an installable web app manifest.
class PwaAgent extends ChangeNotifier {
  PwaAgent(this.controller, {AppStore? store, Future<String?> Function(Uri url)? fetch})
      : store = store ?? AppStore.instance,
        _fetch = fetch ?? _fetchManifest {
    controller.addListener(_onPageChanged);
    _messages = controller.pageMessages.listen(_onMessage);
    this.store.addListener(notifyListeners);
  }

  final WebbyController controller;
  final AppStore store;
  final Future<String?> Function(Uri url) _fetch;
  late final StreamSubscription<String> _messages;

  /// The current page's manifest, when it has one that names an app.
  WebAppManifest? manifest;

  String _scriptedUrl = '';
  bool _wasLoading = false;
  String _href = '';
  int _generation = 0;

  /// The installed app for [manifest], if it's installed.
  InstalledApp? get installed => manifest == null ? null : store.byId(manifest!.id.toString());

  void _onPageChanged() {
    final loadFinished = _wasLoading && !controller.isLoading;
    _wasLoading = controller.isLoading;
    if (controller.url == _scriptedUrl && !loadFinished) return;
    if (controller.url != _scriptedUrl && manifest != null && !_sameDocumentApp(controller.url)) {
      manifest = null;
      _href = '';
      notifyListeners();
    }
    _scriptedUrl = controller.url;
    final url = Uri.tryParse(controller.url);
    if (url != null && (url.isScheme('http') || url.isScheme('https')) && controller.isAttached && controller.messagePrefix.isNotEmpty) {
      controller.runPageScript(manifestPageScript(controller.messagePrefix));
    }
  }

  bool _sameDocumentApp(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && manifest != null && manifest!.inScope(uri);
  }

  void _onMessage(String text) {
    Map<String, Object?> message;
    try {
      message = jsonDecode(text) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    if (message['type'] != 'manifest') return;
    final href = message['href'] as String? ?? '';
    if (href == _href && manifest != null) return;
    _href = href;
    _load(href, controller.url);
  }

  Future<void> _load(String href, String documentUrl) async {
    final generation = ++_generation;
    WebAppManifest? found;
    final manifestUrl = Uri.tryParse(href);
    final document = Uri.tryParse(documentUrl);
    if (href.isNotEmpty && manifestUrl != null && document != null &&
        (manifestUrl.isScheme('http') || manifestUrl.isScheme('https'))) {
      try {
        final text = await _fetch(manifestUrl);
        if (text != null) found = WebAppManifest.parse(text, manifestUrl: manifestUrl, documentUrl: document);
      } catch (_) {}
    }
    if (generation != _generation) return;
    manifest = found;
    notifyListeners();
  }

  static Future<String?> _fetchManifest(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'webby');
      request.headers.set(HttpHeaders.acceptHeader, 'application/manifest+json, application/json;q=0.9, */*;q=0.1');
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 1 << 20) return null;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onPageChanged);
    store.removeListener(notifyListeners);
    _messages.cancel();
    super.dispose();
  }
}
