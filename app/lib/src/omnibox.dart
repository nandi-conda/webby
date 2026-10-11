import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

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
    this.trailing = const [],
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// The page's address, put back when editing ends without going anywhere.
  final String url;
  final ValueChanged<String> onSubmitted;

  /// Shown inside the pill at the right, such as the bookmark star.
  final List<Widget> trailing;

  @override
  State<Omnibox> createState() => _OmniboxState();
}

class _OmniboxState extends State<Omnibox> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(Omnibox old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    super.dispose();
  }

  void _focusChanged() {
    final controller = widget.controller;
    if (widget.focusNode.hasFocus) {
      // Select everything after the click has placed the caret.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.focusNode.hasFocus) {
          controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
        }
      });
    } else if (widget.url.isNotEmpty) {
      controller.text = widget.url;
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

    return MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.focusNode.requestFocus,
        child: Container(
          height: 32,
          padding: const EdgeInsets.only(left: 12, right: 4),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              Icon(Icons.tune, size: 16, color: c.textDim),
              const SizedBox(width: 10),
              Expanded(
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      onSubmitted: widget.onSubmitted,
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
