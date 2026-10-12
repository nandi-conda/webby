import 'package:flutter/widgets.dart';

/// Swallows route pushes from the platform ("flutter/navigation" pushRouteInformation). Android sends one for every
/// link opened from another app when Flutter's deep linking is on, and MaterialApp turns a URL without a path into
/// "/" and pushes its home, a whole second browser page with its own tabs, on top of the first. Links reach the
/// browser through AndroidHost instead. Install it before runApp, so it is asked before WidgetsApp's own observer.
class PlatformRouteGuard with WidgetsBindingObserver {
  static PlatformRouteGuard? _installed;

  static void install() {
    if (_installed != null) return;
    WidgetsBinding.instance.addObserver(_installed = PlatformRouteGuard());
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async => true;

  @override
  // ignore: deprecated_member_use
  Future<bool> didPushRoute(String route) async => true;
}
