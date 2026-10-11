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

  /// Calls [open] with each link the app is asked to open while it is running.
  static void onOpenUrl(void Function(String url) open) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openUrl' && call.arguments is String) open(call.arguments as String);
    });
  }
}
