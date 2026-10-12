import 'dart:io';
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

/// [visits] (newest first) split into days, and each day into rows: back-to-back visits to the same page are one row.
List<List<List<HistoryEntry>>> groupHistory(Iterable<HistoryEntry> visits) {
  final days = <List<List<HistoryEntry>>>[];
  DateTime? day;
  for (final entry in visits) {
    final date = entry.date;
    if (day == null || date.year != day.year || date.month != day.month || date.day != day.day) {
      day = date;
      days.add([]);
    }
    final rows = days.last;
    if (rows.isNotEmpty && HistoryStore.samePage(rows.last.first.url, entry.url)) {
      rows.last.add(entry);
    } else {
      rows.add([entry]);
    }
  }
  return days;
}

/// The history page (Ctrl+H): every visit, newest first and grouped by day, with search, deleting single visits and
/// clearing the history.
///
/// Pops with a URL when the user opens a page from here (the browser opens it in a new tab). Middle-click or the
/// row's right-click menu opens one in a background tab and stays here.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.store, this.onOpenInNewTab});

  final HistoryStore? store;
  final ValueChanged<String>? onOpenInNewTab;

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
    final c = KitTheme.of(context);
    final days = groupHistory(visits);
    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        for (final day in days)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                    child: Text(historyDayLabel(day.first.first.date, now), style: KitText.heading(context)),
                  ),
                  Container(
                    clipBehavior: Clip.antiAlias,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: c.surface,
                      border: Border.all(color: c.border),
                      borderRadius: BorderRadius.circular(kitRadius),
                    ),
                    child: Column(
                      children: [
                        for (final group in day)
                          _HistoryRow(
                            entry: group.first,
                            repeats: group.length,
                            onOpen: () => Navigator.pop(context, group.first.url),
                            onOpenInNewTab: widget.onOpenInNewTab == null
                                ? null
                                : () {
                                    widget.onOpenInNewTab!(group.first.url);
                                    showKitToast(context, 'Opened in a new tab');
                                  },
                            onRemove: () => _store.remove(group),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
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

/// One row of the history page: time, page title and site in fixed columns, and a remove button at the right that
/// shows while the row is hovered (always on phones, which can't hover).
class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    required this.entry,
    required this.repeats,
    required this.onOpen,
    required this.onRemove,
    this.onOpenInNewTab,
  });

  final HistoryEntry entry;

  /// How many back-to-back visits to the page this row stands for.
  final int repeats;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  final VoidCallback? onOpenInNewTab;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final entry = widget.entry;
    final host = Uri.tryParse(entry.url)?.host ?? '';
    final site = host.startsWith('www.') ? host.substring(4) : host;
    final dim = KitText.dim(context, small: true);
    final showRemove = _hovered || Platform.isAndroid || Platform.isIOS;
    final row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        onTertiaryTapUp: widget.onOpenInNewTab == null ? null : (_) => widget.onOpenInNewTab!(),
        child: Container(
          height: 40,
          color: _hovered ? c.hover : null,
          padding: const EdgeInsets.only(left: 14, right: 6),
          child: Row(
            children: [
              SizedBox(width: 48, child: Text(_clock(entry.date), style: dim)),
              Icon(Icons.public, size: 16, color: c.textDim),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Flexible(child: Text(entry.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (widget.repeats > 1) Text('  ×${widget.repeats}', style: dim),
                    if (site.isNotEmpty && entry.title.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Flexible(child: Text(site, maxLines: 1, overflow: TextOverflow.ellipsis, style: dim)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Keeps its place while hidden so the titles don't shift.
              Visibility(
                visible: showRemove,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: KitIconButton.compact(Icons.close, tooltip: 'Remove from history', onPressed: widget.onRemove),
              ),
            ],
          ),
        ),
      ),
    );
    final newTab = widget.onOpenInNewTab;
    if (newTab == null) return row;
    return KitMenu(
      minWidth: 200,
      items: () => [
        KitMenuItem('Open in new tab', onSelected: newTab),
        KitMenuItem('Remove from history', onSelected: widget.onRemove),
      ],
      builder: (context, toggle, open) => GestureDetector(onSecondaryTap: toggle, child: row),
    );
  }
}
