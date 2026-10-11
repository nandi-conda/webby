import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import '../ui.dart';
import 'bookmark_store.dart';

/// Bookmarks the page (or opens its existing bookmark) and shows the editor, as the star button and Ctrl+D do.
Future<void> bookmarkPage(
  BuildContext context, {
  required String url,
  required String title,
  BookmarkStore? store,
}) async {
  if (url.isEmpty) return;
  final bookmarks = store ?? BookmarkStore.instance;
  final existing = bookmarks.bookmarkFor(url);
  final node = existing ?? bookmarks.add(title: title.isNotEmpty ? title : url, url: url);
  await editBookmark(context, node, store: bookmarks, justAdded: existing == null);
}

/// Edits [node]'s name, address and folder, or removes it.
Future<void> editBookmark(BuildContext context, Bookmark node, {BookmarkStore? store, bool justAdded = false}) async {
  final bookmarks = store ?? BookmarkStore.instance;
  final result = await showWebbyDialog<_Edit>(
    context,
    (context) => _BookmarkDialog(store: bookmarks, node: node, justAdded: justAdded),
  );
  if (result == null) return;
  if (result.remove) {
    bookmarks.remove(node);
  } else {
    bookmarks.update(node, title: result.title, url: result.url, parent: result.parent);
  }
}

/// Asks for a new folder's name and creates it in [parent].
Future<Bookmark?> newBookmarkFolder(BuildContext context, Bookmark parent, {BookmarkStore? store}) async {
  final bookmarks = store ?? BookmarkStore.instance;
  final name = TextEditingController(text: 'New folder');
  final title = await showWebbyDialog<String>(
    context,
    (context) => KitDialog(
      title: 'New folder',
      content: LabeledField(
        label: 'Name',
        child: KitTextField(
          controller: name,
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.pop(context)),
        KitButton.primary('Create', onPressed: () => Navigator.pop(context, name.text)),
      ],
    ),
  );
  name.dispose();
  if (title == null || title.trim().isEmpty) return null;
  return bookmarks.addFolder(title.trim(), parent: parent);
}

class _Edit {
  const _Edit({this.title, this.url, this.parent, this.remove = false});
  final String? title;
  final String? url;
  final Bookmark? parent;
  final bool remove;
}

class _BookmarkDialog extends StatefulWidget {
  const _BookmarkDialog({required this.store, required this.node, required this.justAdded});

  final BookmarkStore store;
  final Bookmark node;
  final bool justAdded;

  @override
  State<_BookmarkDialog> createState() => _BookmarkDialogState();
}

class _BookmarkDialogState extends State<_BookmarkDialog> {
  late final _title = TextEditingController(text: widget.node.title);
  late final _url = TextEditingController(text: widget.node.url ?? '');
  late Bookmark? _parent = widget.store.parentOf(widget.node);

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(
    context,
    _Edit(title: _title.text.trim(), url: widget.node.isFolder ? null : _url.text.trim(), parent: _parent),
  );

  /// "Bookmarks bar / Docs / Dart" for a folder nested that deep.
  String _path(Bookmark folder) {
    final names = <String>[];
    for (Bookmark? node = folder; node != null; node = widget.store.parentOf(node)) {
      names.insert(0, node.title);
    }
    return names.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    // A folder can't go inside itself.
    final folders = widget.store.folders.where((f) => !node.isFolder || !node.descendants.contains(f.$1)).toList();
    final heading = node.isFolder ? 'Edit folder' : (widget.justAdded ? 'Bookmark added' : 'Edit bookmark');
    final parent = _parent;
    return KitDialog(
      title: heading,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledField(
            label: 'Name',
            child: KitTextField(controller: _title, autofocus: true, onSubmitted: (_) => _done()),
          ),
          if (!node.isFolder)
            LabeledField(
              label: 'URL',
              child: KitTextField(controller: _url, keyboardType: TextInputType.url, autocorrect: false, enableSuggestions: false, onSubmitted: (_) => _done()),
            ),
          if (!widget.store.isRoot(node) && parent != null)
            LabeledField(
              label: 'Folder',
              child: Align(
                alignment: Alignment.centerLeft,
                child: KitSelect<Bookmark>(
                  value: parent,
                  options: [for (final (folder, _) in folders) (folder, _path(folder))],
                  onChanged: (folder) => setState(() => _parent = folder),
                ),
              ),
            ),
        ],
      ),
      actions: [
        if (!widget.store.isRoot(node))
          KitButton.danger('Remove', onPressed: () => Navigator.pop(context, const _Edit(remove: true))),
        if (!widget.justAdded) KitButton('Cancel', onPressed: () => Navigator.pop(context)),
        KitButton.primary('Done', onPressed: _done),
      ],
    );
  }
}
