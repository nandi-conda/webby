import 'package:flatkit/flatkit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// What the tab strip shows for one tab.
class TabLabel {
  const TabLabel({required this.title, this.loading = false});

  final String title;
  final bool loading;
}

/// The text for a tab: the page title, else the URL without its scheme, else "New tab".
String tabTitle(String title, String url) {
  if (title.trim().isNotEmpty) return title.trim();
  if (url.isEmpty || url == 'about:blank') return 'New tab';
  return url.replaceFirst(RegExp(r'^[a-z]+://'), '');
}

/// The tabs with close buttons and a "new tab" button: a row across the top, or with [vertical] a list down the
/// left side. Middle-click closes a tab; right-click (long-press on touch screens) opens [menuItems] for that tab, or for
/// no tab (null) on empty space.
class TabStrip extends StatefulWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    this.vertical = false,
    this.menuItems,
  });

  final List<TabLabel> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNew;
  final bool vertical;
  final List<KitMenuEntry> Function(int? tab)? menuItems;

  /// How wide the vertical tab list is.
  static const verticalWidth = 220.0;

  @override
  State<TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<TabStrip> {
  static const _minTabWidth = 120.0;
  static const _newTabWidth = 36.0;
  final _scroll = ScrollController();
  int _scrolledTo = -1;

  /// Brings the active tab into view in a scrolling strip when it changes (a new tab, a link opened from elsewhere).
  void _scrollToActive() {
    if (_scrolledTo == widget.active) return;
    _scrolledTo = widget.active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final start = widget.active * _minTabWidth;
      final end = start + _minTabWidth;
      double? target;
      if (start < position.pixels) {
        target = start;
      } else if (end > position.pixels + position.viewportDimension) {
        target = end - position.viewportDimension;
      }
      if (target != null) {
        _scroll.animateTo(target.clamp(0, position.maxScrollExtent),
            duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Where the menu opens (the right-click point) and which tab it's for.
  Offset _menuAt = Offset.zero;
  int? _menuTab;
  VoidCallback? _toggleMenu;
  bool _menuOpen = false;

  void _openMenu(Offset at, int? tab) {
    if (widget.menuItems == null) return;
    final wasOpen = _menuOpen;
    setState(() {
      _menuAt = at;
      _menuTab = tab;
    });
    // Close the open menu first, then open it again at the new point once the anchor has moved.
    if (wasOpen) _toggleMenu?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_menuOpen) _toggleMenu?.call();
    });
  }

  Widget _tab(int i) => _Tab(
        label: widget.tabs[i],
        selected: i == widget.active,
        vertical: widget.vertical,
        onSelect: () => widget.onSelect(i),
        onClose: () => widget.onClose(i),
        onMenu: (at) => _openMenu(at, i),
      );

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final newTab = KitIconButton.compact(Icons.add, tooltip: 'New tab (Ctrl+T)', onPressed: widget.onNew);
    // Double-clicking the strip's empty space opens a new tab. Only the empty space listens, so a tab's own
    // clicks aren't held back waiting to see whether a second click follows.
    final empty = GestureDetector(behavior: HitTestBehavior.opaque, onDoubleTap: widget.onNew);
    final Widget strip;
    if (widget.vertical) {
      strip = Container(
        width: TabStrip.verticalWidth,
        decoration: BoxDecoration(color: c.background, border: Border(right: BorderSide(color: c.border))),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.only(top: 4),
              sliver: SliverList.list(
                children: [
                  for (var i = 0; i < widget.tabs.length; i++) SizedBox(height: 32, child: _tab(i)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(padding: const EdgeInsets.only(left: 6), child: newTab),
                  ),
                ],
              ),
            ),
            // The space under the list, down to the bottom.
            SliverFillRemaining(hasScrollBody: false, child: empty),
          ],
        ),
      );
    } else {
      strip = Container(
        height: 34,
        padding: const EdgeInsets.only(left: 4, top: 4),
        decoration: BoxDecoration(color: c.background, border: Border(bottom: BorderSide(color: c.border))),
        // The empty space sits behind the row, so it takes whatever the tabs and the button don't cover.
        child: LayoutBuilder(builder: (context, constraints) {
          // Tabs share the width down to [_minTabWidth]; past that (a phone with a handful of tabs) they keep that
          // width and the row scrolls, with the new-tab button staying at the end.
          final count = widget.tabs.length;
          final room = constraints.maxWidth - _newTabWidth;
          if (count * _minTabWidth <= room) {
            _scrolledTo = -1;
            return Stack(
              children: [
                Positioned.fill(child: empty),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < count; i++)
                      Flexible(
                        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: _tab(i)),
                      ),
                    Center(child: newTab),
                    const Spacer(),
                  ],
                ),
              ],
            );
          }
          _scrollToActive();
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  itemExtent: _minTabWidth,
                  itemCount: count,
                  itemBuilder: (context, i) => _tab(i),
                ),
              ),
              SizedBox(width: _newTabWidth, child: Center(child: newTab)),
            ],
          );
        }),
      );
    }
    final items = widget.menuItems;
    if (items == null) return strip;
    return Stack(
      children: [
        // Right-clicks on a tab are taken by the tab; the rest of the strip gets the menu without a tab.
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: (details) => _openMenu(details.localPosition, null),
          onLongPressStart: (details) => _openMenu(details.localPosition, null),
          child: strip,
        ),
        Positioned(
          left: _menuAt.dx,
          top: _menuAt.dy,
          child: KitMenu(
            minWidth: 220,
            items: () => items(_menuTab),
            builder: (context, toggle, open) {
              _toggleMenu = toggle;
              _menuOpen = open;
              return const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.vertical,
    required this.onSelect,
    required this.onClose,
    required this.onMenu,
  });

  final TabLabel label;
  final bool selected;
  final bool vertical;
  final VoidCallback onSelect;
  final VoidCallback onClose;
  /// Right-click, with the point in the strip's coordinates.
  final ValueChanged<Offset> onMenu;

  void _menuAt(BuildContext context, Offset global, Offset local) {
    final strip = context.findAncestorStateOfType<_TabStripState>()?.context.findRenderObject();
    final box = strip is RenderBox ? strip : null;
    onMenu(box?.globalToLocal(global) ?? local);
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Listener(
      onPointerDown: (event) {
        if (event.buttons & kMiddleMouseButton != 0) onClose();
      },
      child: GestureDetector(
        onSecondaryTapUp: (details) => _menuAt(context, details.globalPosition, details.localPosition),
        onLongPressStart: (details) => _menuAt(context, details.globalPosition, details.localPosition),
        child: KitTooltip(
        message: label.title,
        child: Pressable(
          onPressed: onSelect,
          builder: (context, s) => Container(
            padding: const EdgeInsets.only(left: 10, right: 3),
            decoration: BoxDecoration(
              color: selected ? c.surface : (s.pressed ? c.pressed : (s.hovered ? c.hover : null)),
              // The selected tab is square with an accent line on top (on the left when vertical); Flutter can't
              // round mixed-colour borders.
              border: selected
                  ? Border(
                      top: vertical ? BorderSide.none : BorderSide(color: c.accent, width: 2),
                      left: vertical ? BorderSide(color: c.accent, width: 2) : BorderSide.none,
                    )
                  : null,
              borderRadius: selected
                  ? null
                  : (vertical
                      ? const BorderRadius.horizontal(right: Radius.circular(kitRadius))
                      : const BorderRadius.vertical(top: Radius.circular(kitRadius))),
            ),
            child: Row(
              children: [
                label.loading ? const KitSpinner(size: 12) : Icon(Icons.public, size: 14, color: c.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: KitText.small(context, color: selected ? c.text : c.textDim)
                        .copyWith(fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
                  ),
                ),
                KitIconButton.compact(Icons.close, tooltip: 'Close tab (Ctrl+W)', onPressed: onClose),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}
