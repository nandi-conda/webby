import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'incognito.dart';
import 'passwords/sync/sync_doc.dart';

/// A summary kept so it can be read again without asking DeepSeek a second time.
class CachedSummary {
  const CachedSummary({
    required this.title,
    required this.url,
    required this.text,
    required this.at,
    this.selection = false,
    this.questions = const [],
    this.updatedAt = 0,
  });

  factory CachedSummary.fromJson(Map<String, Object?> json) => CachedSummary(
    title: json['title'] as String? ?? '',
    url: json['url'] as String? ?? '',
    text: json['text'] as String? ?? '',
    at: json['at'] as int? ?? 0,
    selection: json['selection'] == true,
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? (json['at'] as num? ?? 0).toInt() ~/ 1000,
    questions: [
      for (final entry in json['questions'] as List<Object?>? ?? const [])
        if (entry is Map<String, Object?> && entry['q'] is String && entry['a'] is String)
          (question: entry['q'] as String, answer: entry['a'] as String),
    ],
  );

  final String title;
  final String url;
  final String text;

  /// When it was made, in milliseconds since the epoch.
  final int at;
  final bool selection;

  /// Follow-up questions asked about the page, with their answers, oldest first.
  final List<({String question, String answer})> questions;

  /// When it last changed (made, or a question answered), in seconds since the epoch; the newest copy wins in sync.
  final int updatedAt;

  CachedSummary withUpdatedAt(int seconds) => CachedSummary(
      title: title, url: url, text: text, at: at, selection: selection, questions: questions, updatedAt: seconds);

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    'text': text,
    'at': at,
    if (selection) 'selection': true,
    if (questions.isNotEmpty) 'questions': [for (final qa in questions) {'q': qa.question, 'a': qa.answer}],
    'updatedAt': updatedAt,
  };
}

/// Summaries by page (and by selection), newest last, in `profiles/<profile>/summaries.json`. Incognito windows keep
/// them in memory only. They sync to the other devices in their own blob (see [toSyncDoc]).
class SummaryCache extends ChangeNotifier {
  SummaryCache(this.file) {
    _load();
  }

  static SummaryCache? _instance;
  static SummaryCache get instance => _instance ??= SummaryCache(Incognito.active ? null : defaultFile());

  /// How many summaries are kept; the oldest go first.
  static const limit = 300;

  static File defaultFile() {
    final env = Platform.environment;
    final override = env['WEBBY_SUMMARIES_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final xdg = env['XDG_DATA_HOME'];
    final dataHome = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '/tmp'}/.local/share';
    final name = env['WEBBY_PROFILE'] ?? '';
    final profile = RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
    return File('$dataHome/webby/profiles/$profile/summaries.json');
  }

  final File? file;
  final Map<String, CachedSummary> _entries = {};

  /// When summaries were cleared (seconds), by key, so the clearing reaches other devices.
  final Map<String, int> _deleted = {};

  /// The cache key of a page summary: the URL without its #fragment, or for a selection, the URL and the selected text.
  static String keyFor(String url, {String? selection}) {
    final uri = Uri.tryParse(url);
    final page = uri == null ? url : uri.removeFragment().toString();
    return selection == null ? page : '$page\n${_hash(selection)}';
  }

  static String _hash(String text) {
    // FNV-1a, 64-bit: enough to tell selections apart.
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode(text)) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return hash.toUnsigned(64).toRadixString(16);
  }

  CachedSummary? lookup(String key) => _entries[key];

  void store(String key, CachedSummary summary) {
    final previous = _entries.remove(key)?.updatedAt ?? _deleted[key] ?? 0;
    _entries[key] = summary.withUpdatedAt(max(_seconds(), previous + 1));
    _deleted.remove(key);
    _trim();
    _save();
    notifyListeners();
  }

  static int _seconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void _trim() {
    while (_entries.length > limit) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Forgets summaries made since [since] (all of them when null), for Clear browsing data.
  void clear({DateTime? since}) {
    final now = _seconds();
    final gone = [
      for (final entry in _entries.entries)
        if (since == null || entry.value.at >= since.millisecondsSinceEpoch) entry.key,
    ];
    for (final key in gone) {
      _deleted[key] = max(now, _entries.remove(key)!.updatedAt + 1);
    }
    _save();
    notifyListeners();
  }

  /// The summaries in their synced form: one record per key, plus tombstones for cleared ones.
  SyncDoc toSyncDoc() => SyncDoc(summaries: {
    for (final entry in _deleted.entries) entry.key: {'updatedAt': entry.value, 'deleted': true},
    for (final entry in _entries.entries) entry.key: entry.value.toJson(),
  });

  /// Replaces the summaries with a merged [SyncDoc]. Returns whether anything changed.
  bool applySyncDoc(SyncDoc doc) {
    if (toSyncDoc() == SyncDoc(summaries: doc.summaries)) return false;
    final live = [
      for (final entry in doc.summaries.entries)
        if (!isDeleted(entry.value)) (entry.key, CachedSummary.fromJson(entry.value)),
    ]..sort((a, b) => a.$2.updatedAt.compareTo(b.$2.updatedAt));
    _entries
      ..clear()
      ..addEntries([for (final (key, summary) in live) MapEntry(key, summary)]);
    _deleted
      ..clear()
      ..addAll({
        for (final entry in doc.summaries.entries)
          if (isDeleted(entry.value)) entry.key: updatedAtOf(entry.value),
      });
    _trim();
    _save();
    notifyListeners();
    return true;
  }

  void _load() {
    final file = this.file;
    if (file == null || !file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      for (final entry in (json['summaries'] as Map<String, Object?>? ?? const {}).entries) {
        if (entry.value is Map<String, Object?>) _entries[entry.key] = CachedSummary.fromJson(entry.value as Map<String, Object?>);
      }
      for (final entry in (json['deleted'] as Map<String, Object?>? ?? const {}).entries) {
        if (entry.value is int) _deleted[entry.key] = entry.value as int;
      }
    } catch (error) {
      debugPrint('webby: ignoring damaged summaries file: $error');
    }
  }

  void _save() {
    final file = this.file;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(jsonEncode({
        'version': 1,
        'summaries': {for (final entry in _entries.entries) entry.key: entry.value.toJson()},
        if (_deleted.isNotEmpty) 'deleted': _deleted,
      }));
      temporary.renameSync(file.path);
    } catch (error) {
      debugPrint('webby: could not save summaries: $error');
    }
  }
}
