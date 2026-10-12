import 'package:flatkit/flatkit.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

import 'bookmark_dialog.dart';
import 'bookmark_store.dart';

/// The row of bookmarks under the toolbar: links open on click (in a new tab on middle-click), folders open a menu,
/// right-click offers open in new tab, edit and delete. Items drag to reorder, and dropping onto the middle of a folder
/// moves the item into it. On touch screens a long press starts the drag; letting go without moving opens the menu.
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
        // 30 px at normal text size; grows with the system font scale (Android phones often run above 1.0) so labels
        // aren't clipped top and bottom.
        final height = MediaQuery.textScalerOf(context).scale(20) + 10;
        // Phones and narrow windows get a shorter hint that fits on one line; Ctrl+D means nothing on a touch screen.
        final platform = Theme.of(context).platform;
        final touch = platform == TargetPlatform.android || platform == TargetPlatform.iOS;
        final compact = touch || MediaQuery.sizeOf(context).width < 600;
        return Container(
          // The empty-state hint may wrap on a narrow screen, so it gets a minimum height instead of a fixed one.
          height: items.isEmpty ? null : height,
          constraints: BoxConstraints(minHeight: height),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      compact
                          ? 'Tap the star to bookmark a page.'
                          : 'Bookmark pages with the star in the address bar or Ctrl+D; they show up here.',
                      style: KitText.dim(context, small: true),
                    ),
                  ),
                )
              // Dropping past the last item (on the bar's empty end) moves it to the end.
              : DragTarget<Bookmark>(
                  onWillAcceptWithDetails: (d) => identical(bookmarks.parentOf(d.data), bookmarks.bar),
                  onAcceptWithDetails: (d) => bookmarks.reorder(bookmarks.bar, items.indexOf(d.data), items.length),
                  builder: (context, _, _) => ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    children: [
                      for (final node in items)
                        _DragItem(
                          key: ValueKey(node.id),
                          node: node,
                          store: bookmarks,
                          touch: touch,
                          builder: (menu) => _BarItem(
                              node: node, store: bookmarks, onOpen: onOpen, onOpenInNewTab: onOpenInNewTab, menu: menu),
                        ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

/// Where a dragged bookmark would land relative to the item under the pointer.
enum _Drop { before, after, into }

/// Makes a bar item draggable and a drop target: the left or right half places the dragged item before or after it,
/// the middle half of a folder moves it into the folder.
class _DragItem extends StatefulWidget {
  const _DragItem({super.key, required this.node, required this.store, required this.touch, required this.builder});

  final Bookmark node;
  final BookmarkStore store;
  final bool touch;

  /// Builds the item; it puts its right-click menu in the handle so a long press that never moved can open it.
  final Widget Function(_MenuHandle menu) builder;

  @override
  State<_DragItem> createState() => _DragItemState();
}

/// Lets the drag wrapper open the right-click menu of the item it wraps.
class _MenuHandle {
  VoidCallback? open;
}

class _DragItemState extends State<_DragItem> {
  _Drop? _drop;
  final _menu = _MenuHandle();
  // How far the finger has gone since it went down, to tell a long press from a long-press drag.
  Offset _downAt = Offset.zero;
  double _moved = 0;

  _Drop _dropAt(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    final x = box.globalToLocal(global).dx / box.size.width;
    if (widget.node.isFolder && x > 0.25 && x < 0.75) return _Drop.into;
    return x < 0.5 ? _Drop.before : _Drop.after;
  }

  void _accept(Bookmark dragged, Offset global) {
    // Dropping an item on itself leaves it where it was (the bar's own target would otherwise move it to the end).
    if (identical(dragged, widget.node)) return;
    final store = widget.store;
    final drop = _dropAt(global);
    if (drop == _Drop.into) {
      store.update(dragged, parent: widget.node);
      return;
    }
    final siblings = store.bar.children!;
    final from = siblings.indexOf(dragged);
    final to = siblings.indexOf(widget.node) + (drop == _Drop.after ? 1 : 0);
    if (from < 0) {
      store.update(dragged, parent: store.bar);
      final moved = siblings.indexOf(dragged);
      if (moved >= 0) store.reorder(store.bar, moved, to);
    } else {
      store.reorder(store.bar, from, to);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final node = widget.node;
    final feedback = Material(
      type: MaterialType.transparency,
      child: Container(
        height: 26,
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(kitRadius),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(node.isFolder ? Icons.folder_outlined : Icons.public, size: 14, color: c.textDim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(node.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DefaultTextStyle.of(context).style),
            ),
          ],
        ),
      ),
    );
    final child = widget.builder(_menu);
    final dimmed = Opacity(opacity: 0.4, child: child);
    final draggable = widget.touch
        ? Listener(
            onPointerDown: (e) {
              _downAt = e.position;
              _moved = 0;
            },
            onPointerMove: (e) {
              final d = (e.position - _downAt).distance;
              if (d > _moved) _moved = d;
            },
            child: LongPressDraggable<Bookmark>(
              data: node,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: feedback,
              childWhenDragging: dimmed,
              // Held and let go in place: that's the touch screen's right-click. The item is rebuilt (with a new
              // menu) as it swaps back in for the dimmed copy, so the menu opens after that frame.
              onDragEnd: (_) {
                if (_moved >= kTouchSlop) return;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _menu.open?.call();
                });
              },
              child: child,
            ),
          )
        : Draggable<Bookmark>(
            data: node,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            childWhenDragging: dimmed,
            child: child,
          );
    return DragTarget<Bookmark>(
      onMove: (d) {
        final drop = _dropAt(d.offset);
        if (drop != _drop) setState(() => _drop = drop);
      },
      onLeave: (_) => setState(() => _drop = null),
      onAcceptWithDetails: (d) {
        setState(() => _drop = null);
        _accept(d.data, d.offset);
      },
      builder: (context, candidates, _) {
        final drop = candidates.any((b) => !identical(b, node)) ? _drop : null;
        final edge = BorderSide(color: c.focus, width: 2);
        return Container(
          decoration: BoxDecoration(
            color: drop == _Drop.into ? c.hover : null,
            border: Border(
              left: drop == _Drop.before ? edge : const BorderSide(width: 2, color: Color(0x00000000)),
              right: drop == _Drop.after ? edge : const BorderSide(width: 2, color: Color(0x00000000)),
            ),
          ),
          child: draggable,
        );
      },
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({required this.node, required this.store, required this.onOpen, this.onOpenInNewTab, this.menu});

  final Bookmark node;
  final BookmarkStore store;
  final void Function(String url) onOpen;
  final void Function(String url)? onOpenInNewTab;
  final _MenuHandle? menu;

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
        menu?.open = toggleContext;
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
