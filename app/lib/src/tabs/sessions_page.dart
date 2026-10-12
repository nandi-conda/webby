import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import '../ui.dart';
import 'device_tabs.dart';
import 'device_tabs_page.dart' show seenAgo;
import 'sessions.dart';

/// What the window should open from the sessions page: [urls] in new tabs, with [active] in front.
typedef SessionOpen = ({List<String> urls, int active});

/// The session manager: saved sessions to restore, rename or delete.
///
/// Pops with a [SessionOpen] when the user restores a session or opens one of its tabs.
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, this.store, this.onSaveOpenTabs});

  final SessionStore? store;

  /// Saves the window's open tabs as a new session; null hides the button.
  final VoidCallback? onSaveOpenTabs;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  SessionStore get _store => widget.store ?? SessionStore.instance;
  final _expanded = <SavedSession>{};

  /// The last deleted session, offered back until the next delete or leaving the page.
  SavedSession? _undo;

  void _delete(SavedSession session) {
    _store.delete(session);
    setState(() => _undo = session);
  }

  Future<void> _deleteAll() async {
    final count = _store.sessions.length;
    final ok = await showWebbyDialog<bool>(
      context,
      (context) => KitDialog(
        title: 'Delete all sessions?',
        content: Text('All $count saved session${count == 1 ? '' : 's'} will be deleted. This can\'t be undone.'),
        actions: [
          KitButton('Cancel', onPressed: () => Navigator.pop(context)),
          KitButton.danger('Delete all', onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok == true) {
      _store.deleteAll();
      setState(() => _undo = null);
    }
  }

  Future<void> _rename(SavedSession session) async {
    final name = await askSessionName(context, title: 'Rename session', initial: session.name, action: 'Rename');
    if (name != null) _store.rename(session, name);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final sessions = _store.sessions;
        final undo = _undo;
        return KitPage(
          title: 'Sessions',
          actions: [
            if (widget.onSaveOpenTabs != null)
              KitButton('Save open tabs', icon: Icons.add, onPressed: widget.onSaveOpenTabs),
            if (sessions.isNotEmpty) KitButton('Delete all', icon: Icons.delete_sweep_outlined, onPressed: _deleteAll),
          ],
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_store.loadError != null) KitBanner(message: _store.loadError!, danger: true),
              if (undo != null)
                _UndoStrip(
                  message: 'Deleted "${undo.name}"',
                  onUndo: () {
                    _store.restoreDeleted(undo);
                    setState(() => _undo = null);
                  },
                  onDismiss: () => setState(() => _undo = null),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                    if (sessions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No saved sessions. Save your open tabs from the bookmarks menu, with "Close all tabs and '
                          'save as session", or when you close the window.',
                          style: KitText.dim(context),
                        ),
                      ),
                    for (final session in sessions) ...[
                      _SessionRow(
                        session: session,
                        expanded: _expanded.contains(session),
                        onToggle: () => setState(() {
                          if (!_expanded.remove(session)) _expanded.add(session);
                        }),
                        onRestore: () => Navigator.pop<SessionOpen>(
                          context,
                          (urls: [for (final tab in session.tabs) tab.url], active: session.active),
                        ),
                        onRename: () => _rename(session),
                        onDelete: () => _delete(session),
                      ),
                      if (_expanded.contains(session))
                        for (final tab in session.tabs)
                          _TabRow(
                            tab: tab,
                            onOpen: () => Navigator.pop<SessionOpen>(context, (urls: [tab.url], active: 0)),
                          ),
                    ],
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: KitCheckbox(
                        value: _store.askOnQuit,
                        label: 'Ask to save open tabs as a session when closing the window',
                        onChanged: (value) => _store.askOnQuit = value,
                      ),
                    ),
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

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.expanded,
    required this.onToggle,
    required this.onRestore,
    required this.onRename,
    required this.onDelete,
  });

  final SavedSession session;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onRestore;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final count = session.tabs.length;
    return KitTile(
      icon: expanded ? Icons.expand_more : Icons.chevron_right,
      title: session.name,
      subtitle: Text('$count tab${count == 1 ? '' : 's'} · saved ${seenAgo(session.savedAt)}'),
      onTap: onToggle,
      trailing: [
        KitButton('Restore', onPressed: onRestore),
        const SizedBox(width: 4),
        KitIconButton(Icons.edit_outlined, tooltip: 'Rename', onPressed: onRename),
        KitIconButton(Icons.delete_outline, tooltip: 'Delete', onPressed: onDelete),
      ],
    );
  }
}

class _TabRow extends StatelessWidget {
  const _TabRow({required this.tab, required this.onOpen});

  final DeviceTab tab;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(tab.url);
    final host = uri == null || uri.host.isEmpty ? tab.url : uri.host;
    return KitTooltip(
      message: tab.url,
      child: KitListRow(
        onTap: onOpen,
        height: null,
        padding: const EdgeInsets.fromLTRB(54, 5, 24, 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tab.title.isEmpty ? host : tab.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: KitText.body(context)),
            Text(host, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.dim(context, small: true)),
          ],
        ),
      ),
    );
  }
}

class _UndoStrip extends StatelessWidget {
  const _UndoStrip({required this.message, required this.onUndo, required this.onDismiss});

  final String message;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(color: c.hover, border: Border(bottom: BorderSide(color: c.border))),
      child: Row(
        children: [
          Expanded(child: Text(message, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.body(context))),
          KitButton('Undo', onPressed: onUndo),
          KitIconButton(Icons.close, tooltip: 'Dismiss', onPressed: onDismiss),
        ],
      ),
    );
  }
}

/// Asks for a session name, prefilled with [initial]. Returns null when cancelled.
Future<String?> askSessionName(
  BuildContext context, {
  required String title,
  required String initial,
  String action = 'Save',
  String? message,
}) async {
  final field = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  final name = await showWebbyDialog<String>(
    context,
    (context) => KitDialog(
      title: title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(message)),
          LabeledField(
            label: 'Name',
            child: KitTextField(controller: field, autofocus: true, onSubmitted: (value) => Navigator.pop(context, value)),
          ),
        ],
      ),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.pop(context)),
        KitButton.primary(action, onPressed: () => Navigator.pop(context, field.text)),
      ],
    ),
  );
  field.dispose();
  return name;
}

/// What to do with the open tabs when the window closes.
enum QuitChoice { save, discard, cancel }

/// Asks whether to save the [tabCount] open tabs as a session before the window closes.
/// Returns the choice and the session name; ticking "Don't ask again" turns [SessionStore.askOnQuit] off.
Future<(QuitChoice, String)> askSaveOnQuit(BuildContext context, {required int tabCount, SessionStore? store}) async {
  final sessions = store ?? SessionStore.instance;
  final initial = defaultSessionName(DateTime.now());
  final field = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  var dontAsk = false;
  final choice = await showWebbyDialog<QuitChoice>(
    context,
    (context) => StatefulBuilder(
      builder: (context, setState) => KitDialog(
        title: 'Save open tabs as a session?',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('You can restore the $tabCount tab${tabCount == 1 ? '' : 's'} later from Sessions in the bookmarks menu.'),
            const SizedBox(height: 12),
            LabeledField(
              label: 'Name',
              child: KitTextField(
                controller: field,
                autofocus: true,
                onSubmitted: (_) => Navigator.pop(context, QuitChoice.save),
              ),
            ),
            KitCheckbox(
              value: dontAsk,
              label: 'Don\'t ask again',
              onChanged: (value) => setState(() => dontAsk = value),
            ),
          ],
        ),
        actions: [
          KitButton('Cancel', onPressed: () => Navigator.pop(context, QuitChoice.cancel)),
          KitButton('Don\'t save', onPressed: () => Navigator.pop(context, QuitChoice.discard)),
          KitButton.primary('Save and close', onPressed: () => Navigator.pop(context, QuitChoice.save)),
        ],
      ),
    ),
  );
  final name = field.text;
  field.dispose();
  // Clicking outside or Escape keeps the window open.
  final result = choice ?? QuitChoice.cancel;
  if (dontAsk && result != QuitChoice.cancel) sessions.askOnQuit = false;
  return (result, name);
}
