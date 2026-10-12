import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import '../site_icon.dart';
import '../ui.dart';
import 'device_tabs.dart';
import 'sessions.dart';

/// What the window should open from the sessions panel: [urls] in new tabs, with [active] in front.
typedef SessionOpen = ({List<String> urls, int active});

/// The session manager, shown as a sidebar beside the page (a sheet under it on narrow windows): saved sessions in
/// the style of OneTab, to restore, rename or delete whole or tab by tab.
class SessionsPanel extends StatefulWidget {
  const SessionsPanel({
    super.key,
    this.store,
    required this.onOpen,
    required this.onClose,
    this.onSaveOpenTabs,
    this.onCloseAllAndSave,
    this.wide = true,
  });

  final SessionStore? store;

  /// Opens a whole session, or one of its tabs.
  final ValueChanged<SessionOpen> onOpen;

  /// Hides the panel.
  final VoidCallback onClose;

  /// Saves the window's open tabs as a new session; null hides the button.
  final VoidCallback? onSaveOpenTabs;

  /// Saves the open tabs and closes them; null hides the button.
  final VoidCallback? onCloseAllAndSave;

  /// Beside the page (border on the left) rather than under it.
  final bool wide;

  @override
  State<SessionsPanel> createState() => _SessionsPanelState();
}

class _SessionsPanelState extends State<SessionsPanel> {
  SessionStore get _store => widget.store ?? SessionStore.instance;

  /// The last delete, offered back until the next one or the panel closing.
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
    final c = KitTheme.of(context);
    // A layer of its own, like the other sidebars (their navigator gives them one): without it the panel was
    // repainted with the window on every frame of a page load, and its corner flickered on desktop.
    return RepaintBoundary(
      child: ClipRect(
        child: _panel(context, c),
      ),
    );
  }

  Widget _panel(BuildContext context, KitColors c) {
    return Material(
      color: c.surface,
      child: Container(
        decoration: BoxDecoration(
          border: widget.wide ? Border(left: BorderSide(color: c.border)) : Border(top: BorderSide(color: c.border)),
        ),
        child: ListenableBuilder(
          listenable: _store,
          builder: (context, _) {
            final sessions = _store.sessions;
            final undo = _undo;
            final total = sessions.fold(0, (sum, session) => sum + session.tabs.length);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 40,
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
                  child: Row(
                    children: [
                      Icon(Icons.layers_outlined, size: 16, color: c.textDim),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Sessions', style: KitText.body(context))),
                      if (widget.onSaveOpenTabs != null)
                        KitIconButton(Icons.add, tooltip: 'Save open tabs as session', size: 16,
                            onPressed: widget.onSaveOpenTabs),
                      if (widget.onCloseAllAndSave != null)
                        KitIconButton(Icons.move_to_inbox_outlined, tooltip: 'Close all tabs and save as session',
                            size: 16, onPressed: widget.onCloseAllAndSave),
                      if (sessions.isNotEmpty)
                        KitIconButton(Icons.delete_sweep_outlined, tooltip: 'Delete all sessions', size: 16,
                            onPressed: _deleteAll),
                      KitIconButton(Icons.close, tooltip: 'Close', size: 16, onPressed: widget.onClose),
                    ],
                  ),
                ),
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
                    padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
                    children: [
                      if (sessions.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'No saved sessions. Save your open tabs with the + above, with "Close all tabs and save as '
                            'session", or when you close the window.',
                            style: KitText.dim(context),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                          child: Text(
                            'Total: $total tab${total == 1 ? '' : 's'} in ${sessions.length} '
                            'session${sessions.length == 1 ? '' : 's'}',
                            style: KitText.dim(context, small: true),
                          ),
                        ),
                      for (final session in sessions)
                        _SessionGroup(
                          key: ObjectKey(session),
                          session: session,
                          onRestore: () => widget.onOpen((
                            urls: [for (final tab in session.tabs) tab.url],
                            active: session.active.clamp(0, session.tabs.length - 1),
                          )),
                          onRename: () => _rename(session),
                          onDelete: () => _delete(session),
                          onOpenTab: (tab) => widget.onOpen((urls: [tab.url], active: 0)),
                          onRemoveTab: (index) => _removeTab(session, index),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
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
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '$count tab${count == 1 ? '' : 's'}',
                style: KitText.heading(context).copyWith(fontSize: 20, fontWeight: FontWeight.w300, color: c.textDim),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.heading(context)),
                    Text(
                      sessionCreated(session.savedAt),
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
            // Faint until the row is hovered, like OneTab; always there for touch. A colour rather than Opacity: an
            // Opacity per row is an offscreen layer each, redrawn with every page frame, and made the sidebar's
            // lower part flicker on desktop while pages loaded.
            KitIconButton(
              Icons.close,
              size: 14,
              color: _hover ? c.text : c.border,
              tooltip: 'Remove from session',
              onPressed: widget.onRemove,
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
