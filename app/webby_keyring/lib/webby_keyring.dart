import 'package:flutter/services.dart';

/// The desktop keyring (Secret Service: GNOME Keyring, KWallet, KeePassXC...) through libsecret.
///
/// Every call throws a [PlatformException] with code `unavailable` when there's no keyring to talk to (no libsecret,
/// no D-Bus session, or no Secret Service running), and a [MissingPluginException] where the plugin isn't built in.
class WebbyKeyring {
  static const _channel = MethodChannel('webby_keyring');

  /// The secret stored for [profile], or null if there is none.
  static Future<String?> lookup(String profile) =>
      _channel.invokeMethod<String>('lookup', {'profile': profile});

  /// Stores [secret] for [profile] in the default collection, replacing any earlier one.
  static Future<void> store(String profile, String secret) =>
      _channel.invokeMethod<void>('store', {'profile': profile, 'secret': secret});
}
