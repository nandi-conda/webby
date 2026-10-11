import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows a flatkit dialog. The dialog gets a transparent [Material] so the text fields in it work wherever it's
/// opened from.
Future<T?> showWebbyDialog<T>(BuildContext context, WidgetBuilder builder) =>
    showKitDialog<T>(context, (context) => Material(type: MaterialType.transparency, child: builder(context)));

/// A labelled field for dialogs: the label above, the field under it.
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: KitText.dim(context, small: true)),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

/// A full-window screen pushed over the browser: a header with a back button, [title] and [actions], then [body].
class KitPage extends StatelessWidget {
  const KitPage({super.key, required this.title, required this.body, this.actions = const []});

  final String title;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context)},
      child: Focus(
        autofocus: true,
        child: Material(
          color: c.background,
          // Clear the phone's status and navigation bars.
          child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border(bottom: BorderSide(color: c.border)),
                ),
                child: Row(
                  children: [
                    KitIconButton(Icons.arrow_back, tooltip: 'Back (Esc)', onPressed: () => Navigator.maybePop(context)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(title, style: KitText.heading(context).copyWith(fontSize: 15))),
                    for (final action in actions) Padding(padding: const EdgeInsets.only(left: 6), child: action),
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// A notice strip across the top of a screen.
class KitBanner extends StatelessWidget {
  const KitBanner({super.key, required this.message, this.icon = Icons.warning_amber, this.danger = false});

  final String message;
  final IconData icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final color = danger ? c.danger : c.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.hover,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: KitText.body(context).copyWith(color: color))),
        ],
      ),
    );
  }
}

/// A two-line list row: [leading] icon, [title] over a dimmed [subtitle], and [trailing] actions.
class KitTile extends StatelessWidget {
  const KitTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing = const [],
    this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final Widget? subtitle;
  final List<Widget> trailing;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return KitListRow(
      height: subtitle == null ? 34 : 48,
      selected: selected,
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  DefaultTextStyle.merge(
                    style: KitText.dim(context, small: true),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: subtitle!,
                  ),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}
