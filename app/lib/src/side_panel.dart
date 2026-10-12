import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

/// Shows a full-screen page (bookmarks, history, passwords…) as a sidebar beside the browser instead.
///
/// The page runs in a navigator of its own, so it works unchanged: what it pops with goes to [onResult] and the
/// page stays (the sidebar stays open, like the sessions one), popping with nothing (its back button, Esc)
/// closes the sidebar, and pages it pushes open inside the sidebar.
class SidePanel extends StatefulWidget {
  const SidePanel({super.key, required this.page, required this.onClose, this.onResult, this.wide = true});

  final WidgetBuilder page;
  final VoidCallback onClose;
  final ValueChanged<Object>? onResult;

  /// Beside the page (border on the left) rather than under it.
  final bool wide;

  @override
  State<SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<SidePanel> {
  final _navigator = GlobalKey<NavigatorState>();

  Route<Object?> _pageRoute() {
    final route = _PanelPageRoute(
      builder: widget.page,
      // What the page opens goes to the browser; the page itself stays.
      onResult: (result) => widget.onResult?.call(result),
      keepsPage: (result) => result != null && widget.onResult != null,
    );
    route.popped.then((_) {
      if (mounted) widget.onClose();
    });
    return route;
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: widget.wide ? Border(left: BorderSide(color: c.border)) : Border(top: BorderSide(color: c.border)),
      ),
      child: ClipRect(
        child: Navigator(
          key: _navigator,
          onGenerateInitialRoutes: (_, _) => [
            PageRouteBuilder<void>(pageBuilder: (_, _, _) => const SizedBox.shrink()),
            _pageRoute(),
          ],
        ),
      ),
    );
  }
}

class _PanelPageRoute extends PageRouteBuilder<Object?> {
  _PanelPageRoute({required WidgetBuilder builder, required this.onResult, required this.keepsPage})
    : super(
        pageBuilder: (context, _, _) => builder(context),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      );

  final ValueChanged<Object> onResult;
  final bool Function(Object?) keepsPage;

  @override
  bool didPop(Object? result) {
    if (!keepsPage(result)) return super.didPop(result);
    onResult(result!);
    return false;
  }
}
