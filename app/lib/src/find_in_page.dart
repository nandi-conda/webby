// Find in page (Ctrl+F) when the Ladybird runtime has no native find (webby_view_find, see native/webby_ffi.h):
// a page script that searches the page's text, selects the active match and scrolls to it, and reports
// {"type":"find","current":n,"total":m} through the page-script message channel. The Nim front ends read
// [findInPageScript] from this file at compile time, so every front end runs the same JS.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bindings.dart';
import 'web_view.dart';

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

/// libwebby's native find in page (webby_view_find*, see native/webby_ffi.h): Ladybird highlights every match.
/// Null with a runtime that predates it.
class NativeFind {
  NativeFind._(DynamicLibrary lib)
    : _find = lib.lookupFunction<Void Function(ViewPtr, Pointer<Utf8>, Int32), void Function(ViewPtr, Pointer<Utf8>, int)>(
        'webby_view_find',
      ),
      next = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_find_next'),
      previous = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_find_previous'),
      end = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_find_end'),
      current = lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_find_current'),
      total = lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_find_total');

  static NativeFind? of(WebbyBindings bindings) {
    final lib = bindings.library;
    return lib.providesSymbol('webby_view_find') && lib.providesSymbol('webby_view_find_total') ? NativeFind._(lib) : null;
  }

  final void Function(ViewPtr, Pointer<Utf8>, int) _find;
  final void Function(ViewPtr) next;
  final void Function(ViewPtr) previous;
  final void Function(ViewPtr) end;
  final int Function(ViewPtr) current;
  final int Function(ViewPtr) total;

  void find(ViewPtr view, String query, bool caseSensitive) {
    final text = query.toNativeUtf8();
    _find(view, text, caseSensitive ? 1 : 0);
    malloc.free(text);
  }
}

/// The find bar under the page: the query, "n of m", previous/next, match case and close. Enter goes to the next
/// match and Shift+Enter to the previous one; Esc closes it ([onClose]).
class FindBar extends StatefulWidget {
  const FindBar({super.key, required this.controller, required this.onClose});

  final WebbyController controller;
  final VoidCallback onClose;

  @override
  State<FindBar> createState() => FindBarState();
}

class FindBarState extends State<FindBar> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  bool _caseSensitive = false;

  /// Focuses the query with its text selected (Ctrl+F while the bar is open).
  void focus() {
    _focus.requestFocus();
    _query.selection = TextSelection(baseOffset: 0, extentOffset: _query.text.length);
  }

  /// Goes to the next (or previous) match.
  void step({bool forward = true}) {
    if (_query.text.isEmpty) return;
    forward ? widget.controller.findNext() : widget.controller.findPrevious();
  }

  void _search() => widget.controller.find(_query.text, caseSensitive: _caseSensitive);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focus();
    });
  }

  @override
  void didUpdateWidget(FindBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.endFind();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      step(forward: !HardwareKeyboard.instance.isShiftPressed);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final total = widget.controller.findTotal;
    final count = _query.text.isEmpty
        ? ''
        : total == 0
        ? 'No matches'
        : '${widget.controller.findCurrent} of $total';
    return Container(
      decoration: BoxDecoration(color: c.surface, border: Border(top: BorderSide(color: c.border))),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 260,
            child: Focus(
              onKeyEvent: _onKey,
              child: KitTextField(
                controller: _query,
                focusNode: _focus,
                hint: 'Find in page',
                prefixIcon: Icons.search,
                error: _query.text.isNotEmpty && widget.controller.findTotal == 0,
                autocorrect: false,
                onChanged: (_) => _search(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: Text(
              count,
              style: KitText.small(context, color: total == 0 && _query.text.isNotEmpty ? c.danger : c.textDim),
            ),
          ),
          KitIconButton(Icons.keyboard_arrow_up, tooltip: 'Previous match (Shift+Enter)', onPressed: () => step(forward: false)),
          KitIconButton(Icons.keyboard_arrow_down, tooltip: 'Next match (Enter)', onPressed: step),
          KitIconButton(
            Icons.text_fields,
            tooltip: 'Match case',
            color: _caseSensitive ? c.accent : null,
            onPressed: () {
              setState(() => _caseSensitive = !_caseSensitive);
              _search();
            },
          ),
          const Spacer(),
          KitIconButton(Icons.close, tooltip: 'Close (Esc)', onPressed: widget.onClose),
        ],
      ),
    );
  }
}
