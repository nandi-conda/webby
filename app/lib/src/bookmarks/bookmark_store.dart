import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A bookmarked page, or a folder of them (a folder has no [url]).
class Bookmark {
  Bookmark._({required this.id, required this.title, this.url, required this.addedAt})
    : children = url == null ? <Bookmark>[] : null;

  factory Bookmark.link({required String id, required String title, required String url, int? addedAt}) =>
      Bookmark._(id: id, title: title, url: url, addedAt: addedAt ?? _now());

  factory Bookmark.folder({required String id, required String title, int? addedAt}) =>
      Bookmark._(id: id, title: title, addedAt: addedAt ?? _now());

  static Bookmark? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final title = json['title'] as String? ?? '';
    final addedAt = json['addedAt'] as int? ?? 0;
    final url = json['url'];
    if (url is String) return Bookmark.link(id: id, title: title, url: url, addedAt: addedAt);
    final folder = Bookmark.folder(id: id, title: title, addedAt: addedAt);
    for (final child in (json['children'] as List<Object?>? ?? const [])) {
      final node = Bookmark.fromJson(child);
      if (node != null) folder.children!.add(node);
    }
    return folder;
  }

  final String id;
  String title;
  String? url;

  /// The folder's contents in display order; null for a link.
  final List<Bookmark>? children;

  /// Seconds since the epoch.
  final int addedAt;

  bool get isFolder => children != null;

  /// [title], or the URL when the page had none.
  String get label => title.isNotEmpty ? title : (url ?? '');

  /// This node and everything under it, depth first.
  Iterable<Bookmark> get descendants sync* {
    yield this;
    for (final child in children ?? const <Bookmark>[]) {
      yield* child.descendants;
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    if (url != null) 'url': url,
    'addedAt': addedAt,
    if (children != null) 'children': [for (final child in children!) child.toJson()],
  };
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// One profile's bookmarks: a "Bookmarks bar" folder shown under the toolbar and an "Other bookmarks" folder.
///
/// Stored as JSON in `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<WEBBY_PROFILE|default>/bookmarks.json` (or
/// $WEBBY_BOOKMARKS_FILE). Every change is written straight away, through a temporary file so a crash can't leave
/// half a file behind.
class BookmarkStore extends ChangeNotifier {
  BookmarkStore(this.file) {
    _load();
  }

  static BookmarkStore? _instance;

  /// The current profile's bookmarks, loaded on first use.
  static BookmarkStore get instance => _instance ??= BookmarkStore(defaultFile());

  static File defaultFile() {
    final override = Platform.environment['WEBBY_BOOKMARKS_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final env = Platform.environment;
    final xdg = env['XDG_DATA_HOME'];
    final dataHome = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '/tmp'}/.local/share';
    final name = env['WEBBY_PROFILE'] ?? '';
    // Profile names become directory names (same rule as the password vault).
    final profile = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
    return File('$dataHome/webby/profiles/$profile/bookmarks.json');
  }

  final File file;
  late Bookmark bar;
  late Bookmark other;
  bool _showBar = true;
  int _idCounter = 0;

  /// Why the file couldn't be read (it was set aside and an empty set started), or null.
  String? loadError;

  bool get showBar => _showBar;
  set showBar(bool value) {
    if (value == _showBar) return;
    _showBar = value;
    _changed();
  }

  List<Bookmark> get roots => [bar, other];

  void _load() {
    bar = Bookmark.folder(id: 'bar', title: 'Bookmarks bar', addedAt: 0);
    other = Bookmark.folder(id: 'other', title: 'Other bookmarks', addedAt: 0);
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      _showBar = json['showBar'] as bool? ?? true;
      final roots = json['roots'] as Map<String, Object?>? ?? const {};
      for (final (root, key) in [(bar, 'bar'), (other, 'other')]) {
        final saved = Bookmark.fromJson(roots[key]);
        if (saved != null && saved.isFolder) root.children!.addAll(saved.children!);
      }
    } catch (error) {
      // Keep the unreadable file for the user rather than overwriting it on the next save.
      final aside = '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      try {
        file.renameSync(aside);
      } catch (_) {}
      loadError = 'Could not read ${file.path} ($error); it was moved to $aside.';
      bar.children!.clear();
      other.children!.clear();
    }
  }

  void _save() {
    final directory = file.parent;
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final contents = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'showBar': _showBar,
      'roots': {'bar': bar.toJson(), 'other': other.toJson()},
    });
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(contents, flush: true);
    temp.renameSync(file.path);
  }

  void _changed() {
    _save();
    notifyListeners();
  }

  String _newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_idCounter++).toRadixString(36)}';

  Iterable<Bookmark> get all =>
      roots.expand((root) => root.descendants).where((node) => !identical(node, bar) && !identical(node, other));

  /// Every folder, the two roots first, each with its depth below its root.
  List<(Bookmark, int)> get folders {
    final result = <(Bookmark, int)>[];
    void walk(Bookmark folder, int depth) {
      result.add((folder, depth));
      for (final child in folder.children!) {
        if (child.isFolder) walk(child, depth + 1);
      }
    }

    for (final root in roots) {
      walk(root, 0);
    }
    return result;
  }

  Bookmark? find(String id) {
    for (final node in roots.expand((root) => root.descendants)) {
      if (node.id == id) return node;
    }
    return null;
  }

  Bookmark? parentOf(Bookmark node) {
    for (final folder in roots.expand((root) => root.descendants)) {
      if (folder.children?.any((child) => identical(child, node)) ?? false) return folder;
    }
    return null;
  }

  /// The first bookmark of [url], or null when the page isn't bookmarked.
  Bookmark? bookmarkFor(String url) {
    if (url.isEmpty) return null;
    for (final node in all) {
      if (node.url == url) return node;
    }
    return null;
  }

  bool isRoot(Bookmark node) => identical(node, bar) || identical(node, other);

  Bookmark add({required String title, required String url, Bookmark? parent}) {
    final node = Bookmark.link(id: _newId(), title: title, url: url);
    (parent ?? bar).children!.add(node);
    _changed();
    return node;
  }

  Bookmark addFolder(String title, {Bookmark? parent}) {
    final node = Bookmark.folder(id: _newId(), title: title);
    (parent ?? other).children!.add(node);
    _changed();
    return node;
  }

  /// Renames, re-points or moves [node]. A folder can't move into itself or one of its own folders.
  void update(Bookmark node, {String? title, String? url, Bookmark? parent}) {
    if (title != null) node.title = title;
    if (url != null && !node.isFolder) node.url = url;
    if (parent != null && parent.isFolder && !isRoot(node)) {
      final current = parentOf(node);
      final intoItself = node.isFolder && node.descendants.any((d) => identical(d, parent));
      if (current != null && !identical(current, parent) && !intoItself) {
        current.children!.remove(node);
        parent.children!.add(node);
      }
    }
    _changed();
  }

  /// Moves the child at [oldIndex] of [folder] to [newIndex] (in the list as it was before the move).
  void reorder(Bookmark folder, int oldIndex, int newIndex) {
    final children = folder.children!;
    if (oldIndex < 0 || oldIndex >= children.length) return;
    final node = children.removeAt(oldIndex);
    if (newIndex > oldIndex) newIndex--;
    children.insert(newIndex.clamp(0, children.length), node);
    _changed();
  }

  void remove(Bookmark node) {
    if (isRoot(node)) return;
    parentOf(node)?.children!.remove(node);
    _changed();
  }

  /// Adds imported bookmarks: [toBar] goes on the bookmarks bar (skipping links already there), [toOther] into a
  /// new "Imported" folder in Other bookmarks. Returns how many links were added.
  int import({required List<Bookmark> toBar, required List<Bookmark> toOther}) {
    var count = 0;
    Bookmark copy(Bookmark node) {
      if (!node.isFolder) {
        count++;
        return Bookmark.link(id: _newId(), title: node.title, url: node.url!, addedAt: node.addedAt);
      }
      final folder = Bookmark.folder(id: _newId(), title: node.title, addedAt: node.addedAt);
      folder.children!.addAll(node.children!.map(copy));
      return folder;
    }

    final onBar = bar.children!.where((n) => n.url != null).map((n) => n.url).toSet();
    for (final node in toBar) {
      if (node.url != null && onBar.contains(node.url)) continue;
      bar.children!.add(copy(node));
    }
    if (toOther.isNotEmpty) {
      final folder = Bookmark.folder(id: _newId(), title: 'Imported');
      folder.children!.addAll(toOther.map(copy));
      other.children!.add(folder);
    }
    _changed();
    return count;
  }
}
