import 'dart:io';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import '../ui.dart';
import 'bookmark_dialog.dart';
import 'bookmark_html.dart';
import 'bookmark_store.dart';

/// The bookmark manager: browse folders, search, edit, delete, reorder, import and export.
///
/// Pops with a URL when the user opens a bookmark from here.
class BookmarksPage extends StatefulWidget {
  const BookmarksPage({super.key, this.store});

  final BookmarkStore? store;

  @override
  State<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends State<BookmarksPage> {
  BookmarkStore get _store => widget.store ?? BookmarkStore.instance;
  late Bookmark _folder = _store.bar;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim().toLowerCase();

  Future<bool> _confirmDelete(Bookmark node) async {
    if (!node.isFolder || node.children!.isEmpty) return true;
    final count = node.descendants.where((n) => !n.isFolder).length;
    return await showWebbyDialog<bool>(
          context,
          (context) => KitDialog(
            title: 'Delete "${node.label}"?',
            content: Text('The folder and the $count bookmark${count == 1 ? '' : 's'} in it will be deleted.'),
            actions: [
              KitButton('Cancel', onPressed: () => Navigator.pop(context, false)),
              KitButton.danger('Delete', onPressed: () => Navigator.pop(context, true)),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _delete(Bookmark node) async {
    if (!await _confirmDelete(node)) return;
    if (identical(node, _folder) || node.descendants.contains(_folder)) _folder = _store.parentOf(node) ?? _store.bar;
    _store.remove(node);
  }

  Future<String?> _askPath(String title, String action) async {
    final path = TextEditingController(text: '${Platform.environment['HOME'] ?? '.'}/bookmarks.html');
    final result = await showWebbyDialog<String>(
      context,
      (context) => KitDialog(
        title: title,
        content: LabeledField(
          label: 'File (bookmarks.html)',
          child: KitTextField(
            controller: path,
            autofocus: true,
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ),
        actions: [
          KitButton('Cancel', onPressed: () => Navigator.pop(context)),
          KitButton.primary(action, onPressed: () => Navigator.pop(context, path.text)),
        ],
      ),
    );
    path.dispose();
    final trimmed = result?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed.startsWith('~/') ? '${Platform.environment['HOME']}${trimmed.substring(1)}' : trimmed;
  }

  void _say(String message) => showKitToast(context, message, duration: const Duration(seconds: 4));

  Future<void> _import() async {
    final path = await _askPath('Import bookmarks', 'Import');
    if (path == null) return;
    try {
      final parsed = parseBookmarksHtml(await File(path).readAsString());
      final count = _store.import(toBar: parsed.toolbar, toOther: parsed.other);
      _say('Imported $count bookmark${count == 1 ? '' : 's'} from $path');
    } catch (error) {
      _say('Could not import $path: $error');
    }
  }

  Future<void> _export() async {
    final path = await _askPath('Export bookmarks', 'Export');
    if (path == null) return;
    try {
      await File(path).writeAsString(exportBookmarksHtml(_store));
      _say('Exported bookmarks to $path');
    } catch (error) {
      _say('Could not export to $path: $error');
    }
  }

  Widget _folderTree({bool shrinkWrap = false}) {
    return ListView(
      shrinkWrap: shrinkWrap,
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final (folder, depth) in _store.folders)
          KitListRow(
            selected: identical(folder, _folder) && _query.isEmpty,
            padding: EdgeInsets.only(left: 12.0 + 16 * depth, right: 8),
            onTap: () => setState(() {
              _folder = folder;
              _search.clear();
            }),
            child: Row(
              children: [
                Icon(
                  identical(folder, _store.bar)
                      ? Icons.bookmarks_outlined
                      : (identical(folder, _folder) ? Icons.folder_open : Icons.folder_outlined),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(folder.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _tile(Bookmark node, {Key? key, int? index}) {
    final c = KitTheme.of(context);
    return KitTile(
      key: key,
      icon: node.isFolder ? Icons.folder_outlined : Icons.public,
      title: node.label,
      subtitle: Text(
        node.isFolder ? '${node.children!.length} item${node.children!.length == 1 ? '' : 's'}' : node.url!,
      ),
      onTap: () {
        if (node.isFolder) {
          setState(() {
            _folder = node;
            _search.clear();
          });
        } else {
          Navigator.pop(context, node.url);
        }
      },
      trailing: [
        KitIconButton.compact(
          Icons.edit_outlined,
          tooltip: 'Edit',
          onPressed: () => editBookmark(context, node, store: _store),
        ),
        KitIconButton.compact(Icons.delete_outline, tooltip: 'Delete', onPressed: () => _delete(node)),
        if (index != null)
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(Icons.drag_handle, size: 14, color: c.textDim),
              ),
            ),
          ),
      ],
    );
  }

  Widget _contents() {
    final query = _query;
    if (query.isNotEmpty) {
      final matches = _store.all
          .where((n) => n.title.toLowerCase().contains(query) || (n.url?.toLowerCase().contains(query) ?? false))
          .toList();
      if (matches.isEmpty) return Center(child: Text('No bookmarks match.', style: KitText.dim(context)));
      return ListView(children: [for (final node in matches) _tile(node)]);
    }
    final children = _folder.children!;
    if (children.isEmpty) {
      return Center(
        child: Text(
          identical(_folder, _store.bar)
              ? 'No bookmarks yet. Bookmark a page with the star in the address bar or Ctrl+D.'
              : 'This folder is empty.',
          style: KitText.dim(context),
        ),
      );
    }
    return ReorderableListView(
      buildDefaultDragHandles: false,
      // No lift shadow: the row moves as it is.
      proxyDecorator: (child, index, animation) => child,
      onReorder: (oldIndex, newIndex) => _store.reorder(_folder, oldIndex, newIndex),
      children: [for (final (index, node) in children.indexed) _tile(node, key: ValueKey(node.id), index: index)],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        // The open folder may have been deleted from another screen.
        if (_store.find(_folder.id) == null) _folder = _store.bar;
        final c = KitTheme.of(context);
        // In a sidebar or on a phone the search goes under the header and the folders above the bookmarks.
        return LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;
        final search = KitTextField(
          controller: _search,
          hint: 'Search bookmarks',
          prefixIcon: Icons.search,
          onChanged: (_) => setState(() {}),
        );
        return KitPage(
          title: 'Bookmarks',
          actions: [
            if (!narrow) SizedBox(width: 260, child: search),
            if (narrow)
              KitIconButton(
                Icons.create_new_folder_outlined,
                tooltip: 'New folder',
                onPressed: () => newBookmarkFolder(context, _folder, store: _store),
              )
            else
              KitButton(
                'New folder',
                icon: Icons.create_new_folder_outlined,
                onPressed: () => newBookmarkFolder(context, _folder, store: _store),
              ),
            KitMenu(
              minWidth: 220,
              items: () => [
                KitMenuItem('Import bookmarks.html…', onSelected: _import),
                KitMenuItem('Export bookmarks.html…', onSelected: _export),
                const KitMenuDivider(),
                KitMenuItem(
                  'Show bookmarks bar',
                  checked: _store.showBar,
                  onSelected: () => _store.showBar = !_store.showBar,
                ),
              ],
              builder: (context, toggle, open) => KitIconButton(Icons.more_vert, tooltip: 'More', onPressed: toggle),
            ),
          ],
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_store.loadError != null) KitBanner(message: _store.loadError!, danger: true),
              if (narrow) ...[
                Padding(padding: const EdgeInsets.all(8), child: search),
                Container(
                  constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.3),
                  color: c.surface,
                  child: _folderTree(shrinkWrap: true),
                ),
                const KitDivider(),
                Expanded(child: _contents()),
              ] else
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(width: 240, color: c.surface, child: _folderTree()),
                      const KitVerticalDivider(),
                      Expanded(child: _contents()),
                    ],
                  ),
                ),
            ],
          ),
        );
        });
      },
    );
  }
}
