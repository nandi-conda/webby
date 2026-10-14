// window.open(url, '_blank', 'noopener') as a fresh tab. Ladybird gives every window a page opens a view on the
// opener's own WebContent process, so a busy page (Pulseboard, a Flutter app running in LibJS) also has to load and
// paint every article it opens, and those tabs stayed blank. A noopener window has nothing to share with its opener,
// so the page script asks the browser to open the address in a tab of its own instead, which gets its own process.

import 'dart:async';
import 'dart:convert';

import '../web_view.dart';

/// JavaScript that wraps `window.open` so that a user-initiated `_blank` window with `noopener` or `noreferrer` goes
/// to the browser as `{"type": "openTab", "url"}` through the page-message channel (see passwords/page_script.dart)
/// and returns null, as such a window.open does anyway. Everything else goes to the engine's own window.open. Plain
/// clicks on `<a target=_blank>` links go the same way.
String newTabPageScript(String prefix) => '''
(() => {
  if (window.__webbyOpen) return;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  const open = window.open;
  if (typeof open !== 'function') return;
  window.__webbyOpen = true;
  const send = (message) => { try { prompt.call(window, PREFIX + JSON.stringify(message)); return true; } catch (e) { return false; } };
  const wrapped = function (url, target, features) {
    try {
      const name = target === undefined || target === null || target === '' ? '_blank' : String(target);
      const words = String(features === undefined || features === null ? '' : features).toLowerCase().split(/[\\s,]+/);
      const detached = words.some((w) => w === 'noopener' || w === 'noreferrer' || w === 'noopener=1' || w === 'noreferrer=1');
      const activated = !navigator.userActivation || navigator.userActivation.isActive;
      if (name.toLowerCase() === '_blank' && detached && activated && url !== undefined && url !== null && url !== '') {
        const href = new URL(String(url), document.baseURI).href;
        if (/^https?:/i.test(href) && send({ type: 'openTab', url: href })) return null;
      }
    } catch (e) {}
    return open.apply(this, arguments);
  };
  try { Object.defineProperty(wrapped, 'toString', { value: () => open.toString(), configurable: true }); } catch (e) {}
  window.open = wrapped;
  // A plain click on <a target=_blank> (noopener unless rel=opener) would open the same shared window; the page's
  // own handlers run first, and a click they took over is left alone.
  window.addEventListener('click', (event) => {
    try {
      if (event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
      const link = event.target && event.target.closest ? event.target.closest('a[href], area[href]') : null;
      if (!link || String(link.target).toLowerCase() !== '_blank' || link.hasAttribute('download')) return;
      if (/(^|\\s)opener(\\s|\$)/i.test(link.rel || '')) return;
      if (!/^https?:/i.test(link.href)) return;
      if (send({ type: 'openTab', url: link.href })) event.preventDefault();
    } catch (e) {}
  });
})();
''';

/// Runs [newTabPageScript] in a [WebbyController]'s pages and hands the addresses they open to [onOpen].
class NewTabRequests {
  NewTabRequests(this.controller, {required this.onOpen}) {
    controller.pageScripts.add(_script);
    _messages = controller.pageMessages.listen(_onMessage);
  }

  final WebbyController controller;
  final void Function(String url) onOpen;
  late final StreamSubscription<String> _messages;

  String _script() => controller.messagePrefix.isEmpty ? '' : newTabPageScript(controller.messagePrefix);

  void _onMessage(String text) {
    if (!text.startsWith('{"type":"openTab"')) return;
    final Object? message;
    try {
      message = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (message is! Map) return;
    final url = message['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) onOpen(url as String);
  }

  void dispose() {
    controller.pageScripts.remove(_script);
    _messages.cancel();
  }
}
