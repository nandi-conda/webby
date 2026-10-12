import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import '../site_icon.dart';
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

  /// The last delete, offered back until the next one or leaving the page.
  ({String message, VoidCallback undo})? _undo;

  void _delete(SavedSession session) {
    _store.delete(session);
    setState(() => _undo = (message: 'Deleted "${session.name}"', undo: () => _store.restoreDeleted(session)));
  }

  void _removeTab(SavedSession session, int index) {
    final tab = _store.removeTab(session, index);
    if (tab == null) return;
    final label = tab.title.isEmpty ? tab.url : tab.title;
    setState(() => _undo = (message: 'Removed "$label"', undo: () => _store.restoreTab(session, tab, index)));
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
        final total = sessions.fold(0, (sum, session) => sum + session.tabs.length);
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
                  message: undo.message,
                  onUndo: () {
                    undo.undo();
                    setState(() => _undo = null);
                  },
                  onDismiss: () => setState(() => _undo = null),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(0, 16, 0, 20),
                  children: [
                    if (sessions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No saved sessions. Save your open tabs from the Sessions menu, with "Close all tabs and '
                          'save as session", or when you close the window.',
                          style: KitText.dim(context),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                        child: Text(
                          'Total: $total tab${total == 1 ? '' : 's'} in ${sessions.length} '
                          'session${sessions.length == 1 ? '' : 's'}',
                          style: KitText.dim(context),
                        ),
                      ),
                    for (final session in sessions)
                      _SessionGroup(
                        key: ObjectKey(session),
                        session: session,
                        onRestore: () => Navigator.pop<SessionOpen>(
                          context,
                          (
                            urls: [for (final tab in session.tabs) tab.url],
                            active: session.active.clamp(0, session.tabs.length - 1),
                          ),
                        ),
                        onRename: () => _rename(session),
                        onDelete: () => _delete(session),
                        onOpenTab: (tab) => Navigator.pop<SessionOpen>(context, (urls: [tab.url], active: 0)),
                        onRemoveTab: (index) => _removeTab(session, index),
                      ),
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

/// "Created Oct 12, 2026, 14:05": when a session was saved, in full.
String sessionCreated(int seconds) {
  final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  final name = defaultSessionName(time);
  final comma = name.indexOf(',');
  return 'Created ${name.substring(0, comma)}, ${time.year}${name.substring(comma)}';
}

/// One saved session the way OneTab shows a tab group: its size and date, the actions, then every tab.
class _SessionGroup extends StatelessWidget {
  const _SessionGroup({
    super.key,
    required this.session,
    required this.onRestore,
    required this.onRename,
    required this.onDelete,
    required this.onOpenTab,
    required this.onRemoveTab,
  });

  final SavedSession session;
  final VoidCallback onRestore;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<DeviceTab> onOpenTab;
  final ValueChanged<int> onRemoveTab;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final count = session.tabs.length;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '$count tab${count == 1 ? '' : 's'}',
                style: KitText.heading(context).copyWith(fontSize: 22, fontWeight: FontWeight.w300, color: c.textDim),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.heading(context)),
                    Text(
                      '${sessionCreated(session.savedAt)} · ${seenAgo(session.savedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: KitText.dim(context, small: true),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 18,
            children: [
              _LinkButton('Restore all', onTap: onRestore),
              _LinkButton('Delete', onTap: onDelete),
              _LinkButton('Rename', onTap: onRename),
            ],
          ),
          const SizedBox(height: 6),
          for (final (i, tab) in session.tabs.indexed)
            _TabLink(tab: tab, onOpen: () => onOpenTab(tab), onRemove: () => onRemoveTab(i)),
        ],
      ),
    );
  }
}

/// A plain text action in the accent colour, underlined on hover.
class _LinkButton extends StatefulWidget {
  const _LinkButton(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_LinkButton> createState() => _LinkButtonState();
}

class _LinkButtonState extends State<_LinkButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            widget.label,
            style: KitText.small(context, color: c.accent).copyWith(
              decoration: _hover ? TextDecoration.underline : null,
              decorationColor: c.accent,
            ),
          ),
        ),
      ),
    );
  }
}

/// A saved tab: remove button, site icon and title. Clicking the title opens it.
class _TabLink extends StatefulWidget {
  const _TabLink({required this.tab, required this.onOpen, required this.onRemove});

  final DeviceTab tab;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  State<_TabLink> createState() => _TabLinkState();
}

class _TabLinkState extends State<_TabLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final tab = widget.tab;
    final uri = Uri.tryParse(tab.url);
    final host = uri == null || uri.host.isEmpty ? tab.url : uri.host;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: _hover ? c.hover : null,
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            // Faint until the row is hovered, like OneTab; always there for touch.
            Opacity(
              opacity: _hover ? 1 : 0.45,
              child: KitIconButton(Icons.close, size: 14, tooltip: 'Remove from session', onPressed: widget.onRemove),
            ),
            const SizedBox(width: 4),
            SiteIcon(tab.url),
            const SizedBox(width: 10),
            Flexible(
              child: KitTooltip(
                message: tab.url,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onOpen,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text(
                        tab.title.isEmpty ? host : tab.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: KitText.body(context).copyWith(
                          decoration: _hover ? TextDecoration.underline : null,
                          decorationColor: c.textDim,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
            Text('You can restore the $tabCount tab${tabCount == 1 ? '' : 's'} later from the Sessions menu.'),
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
