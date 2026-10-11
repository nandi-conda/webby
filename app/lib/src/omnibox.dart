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
                          TextSpan(children: [
                            TextSpan(text: parts.$1, style: style.copyWith(color: c.text)),
                            TextSpan(text: parts.$2, style: style.copyWith(color: c.textDim)),
                          ]),
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
