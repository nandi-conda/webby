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

/// A row of tabs with close buttons and a "new tab" button. Middle-click closes a tab.
class TabStrip extends StatelessWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
  });

  final List<TabLabel> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Container(
      height: 34,
      padding: const EdgeInsets.only(left: 4, top: 4),
      decoration: BoxDecoration(color: c.background, border: Border(bottom: BorderSide(color: c.border))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tabs.length; i++)
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: _Tab(
                  label: tabs[i],
                  selected: i == active,
                  onSelect: () => onSelect(i),
                  onClose: () => onClose(i),
                ),
              ),
            ),
          Center(child: KitIconButton.compact(Icons.add, tooltip: 'New tab (Ctrl+T)', onPressed: onNew)),
          const Spacer(),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected, required this.onSelect, required this.onClose});

  final TabLabel label;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Listener(
      onPointerDown: (event) {
        if (event.buttons & kMiddleMouseButton != 0) onClose();
      },
      child: KitTooltip(
        message: label.title,
        child: Pressable(
          onPressed: onSelect,
          builder: (context, s) => Container(
            padding: const EdgeInsets.only(left: 10, right: 3),
            decoration: BoxDecoration(
              color: selected ? c.surface : (s.pressed ? c.pressed : (s.hovered ? c.hover : null)),
              // The selected tab is square with an accent line on top; Flutter can't round mixed-colour borders.
              border: selected ? Border(top: BorderSide(color: c.accent, width: 2)) : null,
              borderRadius: selected ? null : const BorderRadius.vertical(top: Radius.circular(kitRadius)),
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
    );
  }
}
