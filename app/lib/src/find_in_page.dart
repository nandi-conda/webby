// Find in page (Ctrl+F) when the Ladybird runtime has no native find (webby_view_find, see native/webby_ffi.h):
// a page script that searches the page's text, selects the active match and scrolls to it, and reports
// {"type":"find","current":n,"total":m} through the page-script message channel. The Nim front ends read
// [findInPageScript] from this file at compile time, so every front end runs the same JS.

import 'dart:convert';

/// Defines `window.__webbyFind` (find/next/previous/end). `__WEBBY_FIND_PREFIX__` is replaced by the view's
/// message prefix as a JSON string.
const findInPageScript = r'''
(() => {
  if (window.__webbyFind) return;
  const prefix = __WEBBY_FIND_PREFIX__;
  const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'SELECT', 'OPTION']);
  let matches = [], index = -1, query = '', caseSensitive = false;
  const highlights = (typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight === 'function');
  const report = () => {
    const msg = JSON.stringify({type: 'find', current: matches.length ? index + 1 : 0, total: matches.length});
    setTimeout(() => { try { prompt(prefix + msg); } catch (e) {} }, 0);
  };
  const visible = (el) => {
    for (let e = el; e; e = e.parentElement) {
      if (skip.has(e.tagName)) return false;
    }
    return el.getClientRects().length > 0;
  };
  const collect = () => {
    matches = [];
    if (!query || !document.body) return;
    const needle = caseSensitive ? query : query.toLowerCase();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = caseSensitive ? node.data : node.data.toLowerCase();
      if (text.indexOf(needle) < 0 || !node.parentElement || !visible(node.parentElement)) continue;
      for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length)) {
        const range = document.createRange();
        range.setStart(node, at);
        range.setEnd(node, at + needle.length);
        matches.push(range);
      }
    }
  };
  const paint = () => {
    if (highlights) {
      try {
        CSS.highlights.set('webby-find', new Highlight(...matches));
        if (index >= 0 && matches[index]) CSS.highlights.set('webby-find-active', new Highlight(matches[index]));
        else CSS.highlights.delete('webby-find-active');
        if (!document.getElementById('__webby_find_style')) {
          const style = document.createElement('style');
          style.id = '__webby_find_style';
          style.textContent = '::highlight(webby-find){background-color:#fde047;color:#000}' +
            '::highlight(webby-find-active){background-color:#f97316;color:#000}';
          (document.head || document.documentElement).appendChild(style);
        }
      } catch (e) {}
    }
    const range = matches[index];
    if (!range) return;
    const sel = window.getSelection();
    if (sel) { sel.removeAllRanges(); sel.addRange(range.cloneRange()); }
    const el = range.startContainer.parentElement;
    if (el) el.scrollIntoView({block: 'center', inline: 'nearest'});
  };
  const clear = () => {
    if (highlights) { try { CSS.highlights.delete('webby-find'); CSS.highlights.delete('webby-find-active'); } catch (e) {} }
  };
  const step = (delta) => {
    // The page may have changed since the last search.
    collect();
    if (!matches.length) { index = -1; clear(); report(); return; }
    index = ((index + delta) % matches.length + matches.length) % matches.length;
    paint();
    report();
  };
  window.__webbyFind = {
    find(q, cs) {
      query = q; caseSensitive = !!cs; index = -1;
      if (!q) { matches = []; clear(); report(); return; }
      step(1);
    },
    next() { if (query) step(1); },
    previous() { if (query) step(-1); },
    end() { query = ''; matches = []; index = -1; clear(); },
  };
})();
''';

/// The script for a view whose page-script messages start with [messagePrefix].
String findInPageScriptFor(String messagePrefix) =>
    findInPageScript.replaceFirst('__WEBBY_FIND_PREFIX__', jsonEncode(messagePrefix));

/// JS that runs one find call (after [findInPageScriptFor] has defined it): `find` with [query], or `next`,
/// `previous`, `end`.
String findInPageCall(String action, {String query = '', bool caseSensitive = false}) => action == 'find'
    ? 'window.__webbyFind && window.__webbyFind.find(${jsonEncode(query)}, $caseSensitive);'
    : 'window.__webbyFind && window.__webbyFind.$action();';
