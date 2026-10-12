import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A page the address bar offers while the user types (from the history).
class OmniboxSuggestion {
  const OmniboxSuggestion(this.url, this.title);

  final String url;
  final String title;
}

/// The address bar: a borderless rounded pill. While it isn't being edited it shows the page's address the way
/// Chrome does, the host in full colour and the rest dimmed, without "https://" or "www."; clicking selects the whole
/// address for typing over.
class Omnibox extends StatefulWidget {
  const Omnibox({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.url,
    required this.onSubmitted,
    this.onSiteSettings,
    this.suggest,
    this.trailing = const [],
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// The page's address, put back when editing ends without going anywhere.
  final String url;
  final ValueChanged<String> onSubmitted;

  /// The tune icon at the left opens the site's settings (permissions); null leaves it as decoration.
  final VoidCallback? onSiteSettings;

  /// Pages to offer under the pill for what has been typed so far; Up/Down pick one and Enter opens it.
  final List<OmniboxSuggestion> Function(String input)? suggest;

  /// Shown inside the pill at the right, such as the bookmark star.
  final List<Widget> trailing;

  @override
  State<Omnibox> createState() => _OmniboxState();
}

class _OmniboxState extends State<Omnibox> {
  bool _hovered = false;
  final _link = LayerLink();
  final _pill = GlobalKey();
  final _popup = OverlayPortalController();
  List<OmniboxSuggestion> _suggestions = const [];
  int _selected = -1;

  /// The text last seen while editing, so selection changes don't count as typing.
  String _seenText = '';

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
    widget.controller.addListener(_textChanged);
  }

  void _textChanged() {
    final text = widget.controller.text;
    if (!widget.focusNode.hasFocus || text == _seenText) return;
    _seenText = text;
    final suggest = widget.suggest;
    final suggestions = suggest == null || text.trim().isEmpty ? const <OmniboxSuggestion>[] : suggest(text);
    setState(() {
      _suggestions = suggestions;
      _selected = -1;
    });
    if (suggestions.isEmpty) {
      _popup.hide();
    } else {
      _popup.show();
    }
  }

  void _closeSuggestions() {
    if (_suggestions.isEmpty && !_popup.isShowing) return;
    _popup.hide();
    setState(() {
      _suggestions = const [];
      _selected = -1;
    });
  }

  void _submit(String text) {
    final picked = _selected >= 0 && _selected < _suggestions.length ? _suggestions[_selected].url : text;
    _closeSuggestions();
    widget.onSubmitted(picked);
  }

  void _open(OmniboxSuggestion suggestion) {
    _closeSuggestions();
    widget.onSubmitted(suggestion.url);
  }

  /// Up/Down move through the suggestions and Esc closes them, before the text field gets the keys.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_suggestions.isEmpty || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      // -1 is the typed text itself.
      setState(() => _selected = (_selected + 1 + step) % (_suggestions.length + 1) - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      _closeSuggestions();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(Omnibox old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
    if (old.controller != widget.controller) {
      old.controller.removeListener(_textChanged);
      widget.controller.addListener(_textChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    widget.controller.removeListener(_textChanged);
    super.dispose();
  }

  void _focusChanged() {
    final controller = widget.controller;
    _seenText = controller.text;
    if (widget.focusNode.hasFocus) {
      // Select everything after the click has placed the caret.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.focusNode.hasFocus) {
          controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
        }
      });
    } else {
      _closeSuggestions();
      if (widget.url.isNotEmpty) controller.text = widget.url;
    }
    setState(() {});
  }

  /// (host, rest) for display, or null to show [text] as it is.
  static (String, String)? _split(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) return null;
    var host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
    if (uri.hasPort) host = '$host:${uri.port}';
    final at = text.indexOf(uri.host);
    if (at < 0) return null;
    var rest = text.substring(at + uri.host.length);
    if (uri.hasPort) rest = rest.substring(':${uri.port}'.length);
    if (rest == '/') rest = '';
    return (uri.scheme == 'http' ? 'http://$host' : host, rest);
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final focused = widget.focusNode.hasFocus;
    final style = KitText.body(context);
    final text = widget.controller.text;
    final parts = focused ? null : _split(text);
    final fill = _hovered && !focused ? c.pressed : c.hover;

    final pill = MouseRegion(
      key: _pill,
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.focusNode.requestFocus,
        child: Container(
          height: 32,
          padding: const EdgeInsets.only(left: 3, right: 4),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              KitIconButton(
                Icons.tune,
                tooltip: 'View site information',
                size: 16,
                extent: 26,
                color: c.textDim,
                onPressed: widget.onSiteSettings,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      onSubmitted: _submit,
                      textInputAction: TextInputAction.go,
                      // An address, not prose: no suggestions, so keyboards don't add a space after each period.
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      smartDashesType: SmartDashesType.disabled,
                      smartQuotesType: SmartQuotesType.disabled,
                      // While the formatted address is shown on top, the field's own text is hidden.
                      style: parts == null ? style : style.copyWith(color: const Color(0x00000000)),
                      cursorColor: c.accent,
                      cursorWidth: 1.5,
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: 'Search or enter address',
                        hintStyle: style.copyWith(color: c.textDim),
                        hintFadeDuration: Duration.zero,
                      ),
                    ),
                    if (parts != null)
                      IgnorePointer(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: parts.$1,
                                style: style.copyWith(color: c.text),
                              ),
                              TextSpan(
                                text: parts.$2,
                                style: style.copyWith(color: c.textDim),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              ...widget.trailing,
            ],
          ),
        ),
      ),
    );
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _popup,
        overlayChildBuilder: _buildSuggestions,
        child: Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: pill),
      ),
    );
  }

  Widget _buildSuggestions(BuildContext context) {
    final c = KitTheme.of(context);
    final width = (_pill.currentContext?.findRenderObject() as RenderBox?)?.size.width ?? 400;
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, 4),
        // Clicking a suggestion isn't a click outside the address bar, so it keeps focus until the page loads.
        child: TextFieldTapRegion(
          child: Container(
            width: width,
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(kitRadius),
              boxShadow: [BoxShadow(color: c.shadow, blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, suggestion) in _suggestions.indexed)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _selected = index),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _open(suggestion),
                      child: Container(
                        height: 34,
                        color: index == _selected ? c.hover : null,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(Icons.history, size: 16, color: c.textDim),
                            const SizedBox(width: 10),
                            if (suggestion.title.isNotEmpty) ...[
                              Flexible(
                                child: Text(suggestion.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              Text('  -  ', style: KitText.dim(context)),
                            ],
                            Flexible(
                              child: Text(
                                suggestion.url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: KitText.body(context).copyWith(color: c.accent),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the address bar loads for [input]: the address itself when it looks like one, otherwise a Google search.
String addressToUrl(String input) {
  final text = input.trim();
  if (_looksLikeAddress(text)) return text;
  return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(text)}';
}

final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');
final _hostPort = RegExp(r'^(\[[0-9a-fA-F:.]+\]|[^\s/:?#@]+)(:\d{1,5})?$');

bool _looksLikeAddress(String text) {
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return false;
  // "https://…", "about:blank", "file:///…"; but "localhost:8080" is a host with a port, not a scheme.
  final scheme = _scheme.firstMatch(text);
  if (scheme != null && !RegExp(r'^[^:]+:\d').hasMatch(text)) {
    return text.contains('://') ||
        const {
          'about',
          'data',
          'file',
          'mailto',
          'javascript',
          'view-source',
        }.contains(scheme.group(0)!.toLowerCase().replaceAll(':', ''));
  }
  final authority = text.split(RegExp(r'[/?#]')).first;
  final match = _hostPort.firstMatch(authority.contains('@') ? authority.split('@').last : authority);
  if (match == null) return false;
  final host = match.group(1)!.toLowerCase();
  if (host == 'localhost' || host.startsWith('[')) return true;
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return true;
  // A dot-separated name ending in a letters-only TLD: "example.com", "news.ycombinator.com".
  return RegExp(r'^([a-z0-9-]+\.)+[a-z]{2,63}\.?$').hasMatch(host);
}
