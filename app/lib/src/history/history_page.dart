import 'dart:math' as math;

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import '../ui.dart';
import 'history_store.dart';

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// The heading for the visits made on [day]: "Today - Monday, October 12, 2026", "Yesterday - …", or the date.
String historyDayLabel(DateTime day, DateTime now) {
  final date = '${_weekdays[day.weekday - 1]}, ${_months[day.month - 1]} ${day.day}, ${day.year}';
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(day.year, day.month, day.day);
  final daysAgo = today.difference(that).inHours ~/ 24;
  if (daysAgo == 0) return 'Today - $date';
  if (daysAgo == 1) return 'Yesterday - $date';
  return date;
}

String _clock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// The history page (Ctrl+H): every visit, newest first and grouped by day, with search, deleting single visits and
/// clearing the history.
///
/// Pops with a URL when the user opens a page from here.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.store});

  final HistoryStore? store;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  HistoryStore get _store => widget.store ?? HistoryStore.instance;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Other windows may have added visits since this one last read the file.
    _store.reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _row(HistoryEntry entry) {
    final c = KitTheme.of(context);
    final host = Uri.tryParse(entry.url)?.host ?? '';
    return KitListRow(
      height: 36,
      onTap: () => Navigator.pop(context, entry.url),
      child: Row(
        children: [
          SizedBox(width: 44, child: Text(_clock(entry.date), style: KitText.dim(context, small: true))),
          Icon(Icons.public, size: 16, color: c.textDim),
          const SizedBox(width: 10),
          Flexible(child: Text(entry.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (host.isNotEmpty && entry.title.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(host, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.dim(context, small: true)),
            ),
          ],
          const Spacer(),
          KitIconButton.compact(Icons.close, tooltip: 'Remove from history', onPressed: () => _store.remove([entry])),
        ],
      ),
    );
  }

  Widget _contents() {
    final query = _search.text.trim();
    final visits = _store.search(query);
    if (visits.isEmpty) {
      return Center(
        child: Text(
          query.isEmpty ? 'Pages you visit will show up here.' : 'No history matches.',
          style: KitText.dim(context),
        ),
      );
    }
    // Day headings between the visits.
    final now = DateTime.now();
    final rows = <Object>[];
    DateTime? day;
    for (final entry in visits) {
      final date = entry.date;
      if (day == null || date.year != day.year || date.month != day.month || date.day != day.day) {
        day = date;
        rows.add(historyDayLabel(date, now));
      }
      rows.add(entry);
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            if (row is HistoryEntry) return _row(row);
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
              child: Text(row as String, style: KitText.heading(context)),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) => KitPage(
        title: 'History',
        actions: [
          SizedBox(
            width: math.min(260, width * 0.4),
            child: KitTextField(
              controller: _search,
              hint: 'Search history',
              prefixIcon: Icons.search,
              onChanged: (_) => setState(() {}),
            ),
          ),
          KitIconButton(
            Icons.delete_sweep_outlined,
            tooltip: 'Clear history',
            onPressed: _store.length == 0 ? null : () => showClearHistoryDialog(context, store: _store),
          ),
        ],
        body: _contents(),
      ),
    );
  }
}

/// How far back "Clear history" goes.
enum HistoryRange {
  hour('Last hour', Duration(hours: 1)),
  day('Last 24 hours', Duration(days: 1)),
  week('Last 7 days', Duration(days: 7)),
  month('Last 4 weeks', Duration(days: 28)),
  all('All time', null);

  const HistoryRange(this.label, this.duration);

  final String label;
  final Duration? duration;

  /// The time clearing starts from, or null for everything.
  DateTime? get since => duration == null ? null : DateTime.now().subtract(duration!);
}

/// Asks how much history to delete and deletes it. Returns whether anything was cleared.
Future<bool> showClearHistoryDialog(BuildContext context, {HistoryStore? store}) async {
  var range = HistoryRange.all;
  final cleared = await showWebbyDialog<bool>(
    context,
    (context) => StatefulBuilder(
      builder: (context, setState) => KitDialog(
        title: 'Clear history',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LabeledField(
              label: 'Time range',
              child: Align(
                alignment: Alignment.centerLeft,
                child: KitSelect<HistoryRange>(
                  value: range,
                  options: [for (final r in HistoryRange.values) (r, r.label)],
                  onChanged: (value) => setState(() => range = value),
                ),
              ),
            ),
            Text('The pages you visited in this time are deleted from this device.', style: KitText.dim(context)),
          ],
        ),
        actions: [
          KitButton('Cancel', onPressed: () => Navigator.pop(context, false)),
          KitButton.danger('Clear', onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    ),
  );
  if (cleared != true) return false;
  (store ?? HistoryStore.instance).clear(since: range.since);
  return true;
}
