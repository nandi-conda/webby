import 'package:flutter/services.dart';

/// The Android side of the app: android/app/src/main/kotlin/dev/webby/webby/MainActivity.kt.
class AndroidHost {
  static const _channel = MethodChannel('webby/android');

  /// The Ladybird prefix [prepare] set up (resources, links to the helper processes); null until then or if it failed.
  static String? ladybirdPrefix;

  /// Why [prepare] failed, if it did.
  static Object? prepareError;

  /// Unpacks Ladybird's resources and links its helper processes. Must finish before [WebbyBindings.open].
  static Future<void> prepare() async {
    try {
      final paths = await _channel.invokeMapMethod<String, String>('prepare');
      ladybirdPrefix = paths?['prefix'];
    } catch (error) {
      prepareError = error;
    }
  }

  /// The link the app was opened with, if any.
  static Future<String?> initialUrl() async {
    try {
      return await _channel.invokeMethod<String>('initialUrl');
    } on PlatformException {
      return null;
    }
  }

  static void Function(String url)? _openUrl;
  static final Map<int, void Function()> _notificationClicks = {};

  static void _listen() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openUrl' && call.arguments is String) _openUrl?.call(call.arguments as String);
      if (call.method == 'notificationClicked' && call.arguments is int) {
        _notificationClicks.remove(call.arguments as int)?.call();
      }
    });
  }

  /// Calls [open] with each link the app is asked to open while it is running.
  static void onOpenUrl(void Function(String url) open) {
    _openUrl = open;
    _listen();
  }

  /// Asks for the notification permission (Android 13+ shows the system dialog once); whether the app has it.
  static Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Shows (or, with the same [id], replaces) a site's notification; [onClick] runs when the user taps it.
  static Future<void> showNotification(int id, String title, String body, String site, void Function() onClick) async {
    _listen();
    _notificationClicks[id] = onClick;
    await _channel.invokeMethod<void>('showNotification', {'id': id, 'title': title, 'body': body, 'site': site});
  }

  static Future<void> cancelNotification(int id) async {
    _notificationClicks.remove(id);
    await _channel.invokeMethod<void>('cancelNotification', id);
  }
}
