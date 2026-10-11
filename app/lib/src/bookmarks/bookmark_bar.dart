import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import 'bookmark_dialog.dart';
import 'bookmark_store.dart';

/// The row of bookmarks under the toolbar: links open on click (in a new tab on middle-click), folders open a menu,
/// right-click offers open in new tab, edit and delete.
class BookmarkBar extends StatelessWidget {
  const BookmarkBar({super.key, required this.onOpen, this.onOpenInNewTab, this.store});

  final void Function(String url) onOpen;

  /// Opens a URL in a new tab; without it the new-tab entries aren't offered and middle-click opens in place.
  final void Function(String url)? onOpenInNewTab;
  final BookmarkStore? store;

  @override
  Widget build(BuildContext context) {
    final bookmarks = store ?? BookmarkStore.instance;
    return ListenableBuilder(
      listenable: bookmarks,
      builder: (context, _) {
        if (!bookmarks.showBar) return const SizedBox.shrink();
        final c = KitTheme.of(context);
        final items = bookmarks.bar.children!;
        return Container(
          height: 30,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Bookmark pages with the star in the address bar or Ctrl+D; they show up here.',
                      style: KitText.dim(context, small: true),
                    ),
                  ),
                )
              : ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  children: [for (final node in items) _BarItem(node: node, store: bookmarks, onOpen: onOpen, onOpenInNewTab: onOpenInNewTab)],
                ),
        );
      },
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({required this.node, required this.store, required this.onOpen, this.onOpenInNewTab});

  final Bookmark node;
  final BookmarkStore store;
  final void Function(String url) onOpen;
  final void Function(String url)? onOpenInNewTab;

  /// Links in [folder] and its subfolders, each subfolder's links labelled with its path.
  List<KitMenuEntry> _folderEntries(Bookmark folder, [String path = '']) {
    final entries = <KitMenuEntry>[];
    for (final child in folder.children!) {
      if (child.isFolder) {
        final sub = _folderEntries(child, '$path${child.label} / ');
        if (sub.isNotEmpty) {
          if (entries.isNotEmpty) entries.add(const KitMenuDivider());
          entries.addAll(sub);
        }
      } else {
        entries.add(KitMenuItem('$path${child.label}', onSelected: () => onOpen(child.url!)));
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    // Right-click menu around the button; folders also open their own menu on a left click.
    return KitMenu(
      items: () {
        final newTab = onOpenInNewTab;
        final links = node.descendants.where((n) => !n.isFolder).toList();
        return [
          if (newTab != null && !node.isFolder) ...[
            KitMenuItem('Open in new tab', onSelected: () => newTab(node.url!)),
            const KitMenuDivider(),
          ],
          if (newTab != null && node.isFolder && links.isNotEmpty) ...[
            KitMenuItem(
              links.length == 1 ? 'Open in new tab' : 'Open all ${links.length} in new tabs',
              onSelected: () {
                // Each new tab goes right after the current one, so add them last first to keep the folder order.
                for (final link in links.reversed) {
                  newTab(link.url!);
                }
              },
            ),
            const KitMenuDivider(),
          ],
          KitMenuItem('Edit…', onSelected: () => editBookmark(context, node, store: store)),
          KitMenuItem('Delete', danger: true, onSelected: () => store.remove(node)),
        ];
      },
      builder: (context, toggleContext, _) {
        Widget chip(VoidCallback onPressed, {bool open = false}) => GestureDetector(
          onSecondaryTap: toggleContext,
          // Middle-click opens a link in a new tab, as in other browsers.
          onTertiaryTapUp: node.isFolder ? null : (_) => (onOpenInNewTab ?? onOpen)(node.url!),
          child: Pressable(
            onPressed: onPressed,
            builder: (context, s) => Container(
              constraints: const BoxConstraints(maxWidth: 200),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: s.pressed || open ? c.pressed : (s.hovered ? c.hover : const Color(0x00000000)),
                borderRadius: BorderRadius.circular(kitRadius),
                border: s.focused ? Border.all(color: c.focus, width: 2) : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(node.isFolder ? Icons.folder_outlined : Icons.public, size: 14, color: c.textDim),
                  const SizedBox(width: 6),
                  Flexible(child: Text(node.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ),
        );

        if (!node.isFolder) {
          return KitTooltip(message: '${node.label}\n${node.url}', child: chip(() => onOpen(node.url!)));
        }
        return KitMenu(
          minWidth: 200,
          items: () {
            final entries = _folderEntries(node);
            return entries.isEmpty ? [const KitMenuItem('(empty)', onSelected: null)] : entries;
          },
          builder: (context, toggle, open) => chip(toggle, open: open),
        );
      },
    );
  }
}
