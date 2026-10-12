import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../incognito.dart';

/// One visit to a page.
class HistoryEntry {
  HistoryEntry({required this.id, required this.url, required this.title, required this.time});

  final String id;
  final String url;
  String title;

  /// Milliseconds since the epoch.
  final int time;

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(time);

  /// [title], or the URL when the page had none.
  String get label => title.isNotEmpty ? title : url;

  Map<String, Object?> toJson() => {'id': id, 'url': url, 'title': title, 't': time};
}

/// A page the address bar can suggest: the newest title seen for it and how often it was visited.
class HistorySuggestion {
  HistorySuggestion(this.url, this.title, this.visits, this.lastVisit);

  final String url;
  final String title;
  final int visits;
  final int lastVisit;
}

/// Milliseconds since the epoch; tests replace it.
@visibleForTesting
int Function() historyClock = () => DateTime.now().millisecondsSinceEpoch;

/// One profile's browsing history, the way Chrome keeps it: every visit with its URL, title and time, for the History
/// page (Ctrl+H) and the address bar's suggestions. Visits older than [keepFor] are dropped.
///
/// Stored as JSON lines in `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<WEBBY_PROFILE|default>/history.jsonl`
/// (or $WEBBY_HISTORY_FILE). New visits and title changes are appended, so several windows can add to the same file;
/// deleting rewrites the whole file through a temporary one so deleted pages are really gone from the disk.
/// Incognito windows record nothing.
class HistoryStore extends ChangeNotifier {
  HistoryStore(this.file) {
    reload();
  }

  static HistoryStore? _instance;

  /// The current profile's history, loaded on first use.
  static HistoryStore get instance => _instance ??= HistoryStore(defaultFile());

  static const keepFor = Duration(days: 90);

  static File defaultFile() {
    final env = Platform.environment;
    final override = env['WEBBY_HISTORY_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final xdg = env['XDG_DATA_HOME'];
    final dataHome = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '/tmp'}/.local/share';
    final name = env['WEBBY_PROFILE'] ?? '';
    // Profile names become directory names (same rule as bookmarks and the password vault).
    final profile = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
    return File('$dataHome/webby/profiles/$profile/history.jsonl');
  }

  final File file;

  /// Oldest first.
  final List<HistoryEntry> _entries = [];
  int _idCounter = 0;

  /// Every visit, newest first.
  Iterable<HistoryEntry> get entries => _entries.reversed;

  int get length => _entries.length;

  /// Reads the file again, picking up visits other windows have added since.
  void reload() {
    _merge();
    notifyListeners();
  }

  /// Adds the visits in the file that aren't in memory yet (from other windows) and the titles they got there.
  void _merge() {
    if (!file.existsSync()) return;
    final byId = {for (final e in _entries) e.id: e};
    var lines = 0;
    try {
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        lines++;
        try {
          final json = jsonDecode(line);
          if (json is! Map<String, Object?>) continue;
          final id = json['id'], url = json['url'], time = json['t'];
          if (id is! String || url is! String || time is! int) continue;
          final title = json['title'] as String? ?? '';
          // A later line for the same visit is its title update.
          final known = byId[id];
          if (known != null) {
            if (title.isNotEmpty) known.title = title;
          } else {
            byId[id] = HistoryEntry(id: id, url: url, title: title, time: time);
          }
        } on FormatException {
          // A line cut short by a crash; skip it.
        }
      }
    } catch (error) {
      debugPrint('webby: could not read ${file.path}: $error');
    }
    final cutoff = historyClock() - keepFor.inMilliseconds;
    _entries
      ..clear()
      ..addAll(byId.values.where((e) => e.time >= cutoff).toList()..sort((a, b) => a.time.compareTo(b.time)));
    // Drop expired visits and superseded title lines once they make up a good part of the file.
    if (lines > 200 && lines > _entries.length * 2) _rewrite();
  }

  /// Whether visits to [url] are recorded: web pages and local files, not about: pages, data: URLs and the like.
  static bool records(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && const {'http', 'https', 'file'}.contains(uri.scheme);
  }

  /// Records a visit to [url] and returns it, or null when it isn't recorded (see [records], incognito windows).
  HistoryEntry? record(String url, String title) {
    if (Incognito.active || !records(url)) return null;
    final now = historyClock();
    final entry = HistoryEntry(
      id: '${now.toRadixString(36)}${pid.toRadixString(36)}${(_idCounter++).toRadixString(36)}',
      url: url,
      title: title,
      time: now,
    );
    _entries.add(entry);
    _append(entry);
    notifyListeners();
    return entry;
  }

  /// The page's title arrived (or changed) after the visit was recorded.
  void setTitle(HistoryEntry entry, String title) {
    if (Incognito.active || entry.title == title || !_entries.contains(entry)) return;
    entry.title = title;
    _append(entry);
    notifyListeners();
  }

  void remove(Iterable<HistoryEntry> entries) {
    final ids = {for (final e in entries) e.id};
    // Keep what other windows added since this one last read the file.
    _merge();
    final before = _entries.length;
    _entries.removeWhere((e) => ids.contains(e.id));
    if (_entries.length == before) return;
    _rewrite();
    notifyListeners();
  }

  /// Deletes the visits made since [since], or everything when it's null (Clear browsing data).
  void clear({DateTime? since}) {
    if (since != null) _merge();
    if (since == null) {
      _entries.clear();
    } else {
      final from = since.millisecondsSinceEpoch;
      _entries.removeWhere((e) => e.time >= from);
    }
    _rewrite();
    notifyListeners();
  }

  /// Visits whose title or address contain every word of [query], newest first.
  List<HistoryEntry> search(String query) {
    final words = _words(query);
    if (words.isEmpty) return entries.toList();
    return entries.where((e) => _matches(e.url, e.title, words)).toList();
  }

  /// Pages for the address bar while [input] is typed: the best few matches, one per address. Pages whose address
  /// (without "https://www.") starts with the input come first, then the most and most recently visited.
  List<HistorySuggestion> suggest(String input, {int limit = 6}) {
    final words = _words(input);
    if (words.isEmpty) return const [];
    final pages = <String, HistorySuggestion>{};
    for (final e in _entries) {
      final page = pages[e.url];
      pages[e.url] = HistorySuggestion(
        e.url,
        e.title.isNotEmpty || page == null ? e.title : page.title,
        (page?.visits ?? 0) + 1,
        e.time,
      );
    }
    final now = historyClock();
    final typed = input.trim().toLowerCase();
    double score(HistorySuggestion s) {
      final ageDays = (now - s.lastVisit) / Duration.millisecondsPerDay;
      var value = s.visits / (1 + ageDays / 7);
      final bare = _bare(s.url);
      if (bare.startsWith(typed)) {
        value += 1000;
        // The site itself before its pages.
        if (bare.length - typed.length < 2 || !bare.substring(typed.length).contains('/')) value += 500;
      } else if (bare.contains(typed)) {
        value += 100;
      }
      return value;
    }

    final matches = pages.values.where((s) => _matches(s.url, s.title, words)).toList();
    final scores = {for (final s in matches) s: score(s)};
    matches.sort((a, b) {
      final byScore = scores[b]!.compareTo(scores[a]!);
      return byScore != 0 ? byScore : a.url.length.compareTo(b.url.length);
    });
    return matches.take(limit).toList();
  }

  static List<String> _words(String query) =>
      query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  static bool _matches(String url, String title, List<String> words) {
    final haystack = '${url.toLowerCase()} ${title.toLowerCase()}';
    return words.every(haystack.contains);
  }

  /// The address as typed: no scheme, no "www.", no trailing slash.
  static String _bare(String url) {
    var text = url.toLowerCase().replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
    if (text.startsWith('www.')) text = text.substring(4);
    if (text.endsWith('/')) text = text.substring(0, text.length - 1);
    return text;
  }

  void _append(HistoryEntry entry) {
    try {
      final directory = file.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      file.writeAsStringSync('${jsonEncode(entry.toJson())}\n', mode: FileMode.append, flush: true);
    } catch (error) {
      debugPrint('webby: could not write ${file.path}: $error');
    }
  }

  void _rewrite() {
    if (Incognito.active) return;
    try {
      final directory = file.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(_entries.map((e) => '${jsonEncode(e.toJson())}\n').join(), flush: true);
      temp.renameSync(file.path);
    } catch (error) {
      debugPrint('webby: could not write ${file.path}: $error');
    }
  }
}
