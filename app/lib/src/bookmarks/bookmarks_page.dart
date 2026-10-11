import 'dart:io';

import 'package:flutter/material.dart';

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
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete "${node.label}"?'),
            content: Text('The folder and the $count bookmark${count == 1 ? '' : 's'} in it will be deleted.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
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
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: path,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'File (bookmarks.html)'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, path.text), child: Text(action)),
        ],
      ),
    );
    path.dispose();
    final trimmed = result?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed.startsWith('~/') ? '${Platform.environment['HOME']}${trimmed.substring(1)}' : trimmed;
  }

  void _say(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

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

  Widget _folderTree() {
    return ListView(
      children: [
        for (final (folder, depth) in _store.folders)
          ListTile(
            dense: true,
            selected: identical(folder, _folder) && _query.isEmpty,
            contentPadding: EdgeInsets.only(left: 12.0 + 16 * depth, right: 8),
            leading: Icon(
              identical(folder, _store.bar)
                  ? Icons.bookmarks_outlined
                  : (identical(folder, _folder) ? Icons.folder_open : Icons.folder_outlined),
              size: 20,
            ),
            title: Text(folder.label, overflow: TextOverflow.ellipsis),
            onTap: () => setState(() {
              _folder = folder;
              _search.clear();
            }),
          ),
      ],
    );
  }

  Widget _tile(Bookmark node, {Key? key, int? index}) {
    return ListTile(
      key: key,
      leading: Icon(node.isFolder ? Icons.folder_outlined : Icons.public),
      title: Text(node.label, overflow: TextOverflow.ellipsis),
      subtitle: node.isFolder
          ? Text('${node.children!.length} item${node.children!.length == 1 ? '' : 's'}')
          : Text(node.url!, overflow: TextOverflow.ellipsis),
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => editBookmark(context, node, store: _store),
          ),
          IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(node)),
          if (index != null)
            ReorderableDragStartListener(
              index: index,
              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle)),
            ),
        ],
      ),
    );
  }

  Widget _contents() {
    final query = _query;
    if (query.isNotEmpty) {
      final matches = _store.all
          .where((n) => n.title.toLowerCase().contains(query) || (n.url?.toLowerCase().contains(query) ?? false))
          .toList();
      if (matches.isEmpty) return const Center(child: Text('No bookmarks match.'));
      return ListView(children: [for (final node in matches) _tile(node)]);
    }
    final children = _folder.children!;
    if (children.isEmpty) {
      return Center(
        child: Text(
          identical(_folder, _store.bar)
              ? 'No bookmarks yet. Bookmark a page with the star in the address bar or Ctrl+D.'
              : 'This folder is empty.',
        ),
      );
    }
    return ReorderableListView(
      buildDefaultDragHandles: false,
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
        return Scaffold(
          appBar: AppBar(
            title: const Text('Bookmarks'),
            actions: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    hintText: 'Search bookmarks',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: () => newBookmarkFolder(context, _folder, store: _store),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (choice) {
                  if (choice == 'import') _import();
                  if (choice == 'export') _export();
                  if (choice == 'bar') _store.showBar = !_store.showBar;
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'import', child: Text('Import bookmarks.html…')),
                  const PopupMenuItem(value: 'export', child: Text('Export bookmarks.html…')),
                  CheckedPopupMenuItem(value: 'bar', checked: _store.showBar, child: const Text('Show bookmarks bar')),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_store.loadError != null)
                MaterialBanner(content: Text(_store.loadError!), actions: [const SizedBox.shrink()]),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 240, child: _folderTree()),
                    const VerticalDivider(width: 1),
                    Expanded(child: _contents()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
