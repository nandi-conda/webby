import 'package:flutter/material.dart';

import 'bookmark_dialog.dart';
import 'bookmark_store.dart';

/// The row of bookmarks under the toolbar: links open on click, folders open a menu, right-click edits.
class BookmarkBar extends StatelessWidget {
  const BookmarkBar({super.key, required this.onOpen, this.store});

  final void Function(String url) onOpen;
  final BookmarkStore? store;

  @override
  Widget build(BuildContext context) {
    final bookmarks = store ?? BookmarkStore.instance;
    return ListenableBuilder(
      listenable: bookmarks,
      builder: (context, _) {
        if (!bookmarks.showBar) return const SizedBox.shrink();
        final items = bookmarks.bar.children!;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: SizedBox(
            height: 32,
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Bookmark pages with the star in the address bar or Ctrl+D; they show up here.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  )
                : ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    children: [for (final node in items) _BarItem(node: node, store: bookmarks, onOpen: onOpen)],
                  ),
          ),
        );
      },
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({required this.node, required this.store, required this.onOpen});

  final Bookmark node;
  final BookmarkStore store;
  final void Function(String url) onOpen;

  Future<void> _contextMenu(BuildContext context, Offset position) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'edit', child: Text('Edit…')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (!context.mounted) return;
    if (choice == 'edit') await editBookmark(context, node, store: store);
    if (choice == 'delete') store.remove(node);
  }

  @override
  Widget build(BuildContext context) {
    final label = Text(node.label, overflow: TextOverflow.ellipsis);
    final Widget button;
    if (node.isFolder) {
      button = MenuAnchor(
        menuChildren: _menuEntries(node),
        builder: (context, menu, _) => TextButton.icon(
          icon: const Icon(Icons.folder_outlined, size: 16),
          label: label,
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      );
    } else {
      button = Tooltip(
        message: '${node.label}\n${node.url}',
        waitDuration: const Duration(milliseconds: 600),
        child: TextButton.icon(
          icon: const Icon(Icons.public, size: 16),
          label: label,
          onPressed: () => onOpen(node.url!),
        ),
      );
    }
    return GestureDetector(
      onSecondaryTapDown: (details) => _contextMenu(context, details.globalPosition),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: button),
    );
  }

  List<Widget> _menuEntries(Bookmark folder) {
    if (folder.children!.isEmpty) {
      return const [MenuItemButton(onPressed: null, child: Text('(empty)'))];
    }
    return [
      for (final child in folder.children!)
        if (child.isFolder)
          SubmenuButton(
            leadingIcon: const Icon(Icons.folder_outlined, size: 16),
            menuChildren: _menuEntries(child),
            child: Text(child.label),
          )
        else
          MenuItemButton(
            leadingIcon: const Icon(Icons.public, size: 16),
            onPressed: () => onOpen(child.url!),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(child.label, overflow: TextOverflow.ellipsis),
            ),
          ),
    ];
  }
}
