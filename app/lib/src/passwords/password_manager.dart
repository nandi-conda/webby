import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../bindings.dart';
import '../bookmarks/bookmark_store.dart';
import '../incognito.dart';
import '../summary_cache.dart';
import '../tabs/device_tabs.dart';
import '../tabs/sessions.dart';
import '../web_view.dart';
import 'generator.dart';
import 'native.dart';
import 'page_script.dart';
import 'sync/vault_sync.dart';
import 'vault.dart';

/// Owns the profile's [Vault] and keeps the authenticator's passkeys in it.
class PasswordManager extends ChangeNotifier {
  PasswordManager._();

  static final PasswordManager instance = PasswordManager._();

  Vault? vault;

  /// Syncs [vault] with the user's other devices; null until the vault is open.
  VaultSync? sync;

  /// Why the vault couldn't be opened, if it couldn't.
  String? error;
  bool _opening = false;
  PasswordNative? _native;
  Timer? _passkeySync;
  int _passkeySerial = 0;

  /// Prefix for messages from [passwordPageScript]; random per run so pages can't guess it.
  final String messagePrefix = '\u0001webby-passwords:${_token()}:';

  static String _token() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(12, (_) => random.nextInt(256)));
  }

  PasswordNative? get native => _native;
  bool get passkeysInVault => _passkeySync != null;

  /// Opens the vault (once) and moves passkeys into it if the runtime supports that.
  Future<void> start(WebbyBindings bindings) async {
    if (_opening || vault != null) return;
    _opening = true;
    _native = PasswordNative.of(bindings);
    if (Incognito.active) {
      await _startIncognito();
      return;
    }
    try {
      final opened = await Vault.open();
      vault = opened;
      opened.addListener(notifyListeners);
      _attachPasskeys(opened);
      sync = VaultSync(opened, onPasskeysChanged: _passkeysSynced, bookmarks: BookmarkStore.instance, tabs: DeviceTabs.instance,
          summaries: SummaryCache.instance, sessions: SessionStore.instance);
    } on VaultUnavailable catch (e) {
      error = e.message;
      debugPrint('webby: $error');
    } catch (e) {
      error = 'Could not open the password vault: $e';
      debugPrint('webby: $error');
    }
    notifyListeners();
  }

  /// Incognito windows fill from an existing vault but never write it (the normal window owns the file and its sync),
  /// and passkeys made here live only in the authenticator's memory.
  Future<void> _startIncognito() async {
    try {
      if (Vault.exists()) vault = await Vault.open();
    } catch (e) {
      debugPrint('webby: incognito window without saved passwords: $e');
    }
    _native?.usePasskeyVault(vault?.passkeys ?? const []);
    notifyListeners();
  }

  void _attachPasskeys(Vault vault) {
    final native = _native;
    if (native == null || !native.usePasskeyVault(vault.passkeys)) return;
    // The authenticator now has the vault's passkeys plus any from the old file. Save that, then drop the file.
    _passkeySerial = native.passkeySerial;
    vault.setPasskeys(native.exportPasskeys()).then((_) {
      if (!native.deletePasskeyFile()) debugPrint('webby: could not delete the old passkeys file');
    });
    // Passkeys are created inside libwebby during a sign-up; save them as soon as they appear.
    _passkeySync = Timer.periodic(const Duration(milliseconds: 250), (_) => syncPasskeys());
  }

  /// Saves the authenticator's passkeys into the vault if they changed.
  void syncPasskeys() {
    final native = _native;
    final vault = this.vault;
    if (native == null || vault == null || _passkeySync == null) return;
    final serial = native.passkeySerial;
    if (serial == _passkeySerial) return;
    _passkeySerial = serial;
    vault.setPasskeys(native.exportPasskeys());
  }

  /// Hands passkeys that came in from another device to the authenticator, and takes away ones deleted elsewhere.
  void _passkeysSynced(Set<String> removed) {
    final native = _native;
    final vault = this.vault;
    if (native == null || vault == null || !passkeysInVault) return;
    for (final id in removed) {
      native.removePasskey(id);
    }
    native.usePasskeyVault(vault.passkeys);
    // Save whatever the authenticator ends up with on the next tick, in case it kept one the vault lacks.
    _passkeySerial = -1;
  }

  void deletePasskey(String credentialId) {
    final native = _native;
    if (native == null || !passkeysInVault) return;
    native.removePasskey(credentialId);
    syncPasskeys();
  }

  /// Passkeys to show: the vault's copy, or nothing when the runtime keeps them in its own file.
  List<Map<String, Object?>> get passkeys => passkeysInVault ? vault?.passkeys ?? const [] : const [];
}

/// What the browser is offering the user about passwords on the current page.
sealed class PasswordOffer {
  const PasswordOffer(this.origin);
  final String origin;
}

/// "Save this password?" after a login on [origin]. [existing] is set when it would replace a saved password.
class SaveOffer extends PasswordOffer {
  const SaveOffer(super.origin, this.username, this.password, this.existing);
  final String username;
  final String password;
  final SavedPassword? existing;
}

/// "Fill a saved password?" when the page has a login form and there's a choice of accounts.
class FillOffer extends PasswordOffer {
  const FillOffer(super.origin, this.accounts);
  final List<SavedPassword> accounts;
}

/// "Use a strong password?" when the user is on a sign-up or change-password field.
class GenerateOffer extends PasswordOffer {
  const GenerateOffer(super.origin, this.password);
  final String password;
}

/// Connects one [WebbyController] to the [PasswordManager]: runs the form script in its pages, fills saved
/// passwords and offers to save new ones.
class PasswordAgent extends ChangeNotifier {
  PasswordAgent(this.controller, [PasswordManager? manager]) : manager = manager ?? PasswordManager.instance {
    controller.addListener(_onPageChanged);
    _messages = controller.pageMessages.listen(_onMessage);
    controller.messagePrefix = this.manager.messagePrefix;
  }

  final WebbyController controller;
  final PasswordManager manager;
  late final StreamSubscription<String> _messages;

  PasswordOffer? offer;
  String _scriptedUrl = '';
  bool _wasLoading = false;
  String? _filledOrigin;

  /// The generated password the user put in the page, saved without asking once the form is sent with it.
  String? _generated;

  void _onPageChanged() {
    // Run the script once per load, and again when the URL changes without a load (single-page apps reuse the page,
    // and the script skips pages that already have it).
    final loadFinished = _wasLoading && !controller.isLoading;
    _wasLoading = controller.isLoading;
    if (controller.url != _scriptedUrl || loadFinished) {
      if (controller.url != _scriptedUrl) {
        _filledOrigin = null;
        _generated = null;
        if (offer is FillOffer && offer!.origin != originOf(controller.url)) _setOffer(null);
      }
      _scriptedUrl = controller.url;
      if (originOf(controller.url) != null && controller.isAttached) {
        controller.runJavaScript(passwordPageScript(manager.messagePrefix));
      }
    }
  }

  void _onMessage(String text) {
    final vault = manager.vault;
    final origin = originOf(controller.url);
    if (vault == null || origin == null) return;
    Map<String, Object?> message;
    try {
      message = jsonDecode(text) as Map<String, Object?>;
    } catch (_) {
      return;
    }

    switch (message['type']) {
      case 'newPassword' || 'submit' when Incognito.active:
        // Nothing is saved from an incognito window, so there's nothing to offer.
        return;
      case 'newPassword':
        // Not again for the confirm field once a password is in, or while one is on offer.
        if (_generated != null || offer is SaveOffer || (offer is GenerateOffer && offer!.origin == origin)) return;
        _setOffer(GenerateOffer(origin, generatePassword()));
      case 'fields' || 'focus':
        final accounts = vault.passwordsFor(origin);
        if (accounts.isEmpty || offer is SaveOffer) return;
        if (accounts.length == 1 && message['type'] == 'fields' && _filledOrigin != origin) {
          // One account: fill it straight away, the way other browsers do.
          fill(accounts.single);
        } else if (_filledOrigin != origin || accounts.length > 1) {
          _setOffer(FillOffer(origin, accounts));
        }
      case 'submit':
        final username = message['username'] as String? ?? '';
        final password = message['password'] as String? ?? '';
        if (password.isEmpty) return;
        if (password == _generated) {
          _generated = null;
          vault.savePassword(origin, username, password);
          if (offer is GenerateOffer) _setOffer(null);
          return;
        }
        if (vault.isNeverSave(origin)) return;
        final existing = vault.find(origin, username);
        if (existing != null && existing.password == password) return;
        _setOffer(SaveOffer(origin, username, password, existing));
    }
  }

  void _setOffer(PasswordOffer? value) {
    offer = value;
    notifyListeners();
  }

  void fill(SavedPassword account) {
    final origin = originOf(controller.url);
    if (origin == null || origin != account.origin) return;
    _filledOrigin = origin;
    controller.runJavaScript(passwordFillScript(origin, account.username, account.password));
    if (offer is FillOffer) _setOffer(null);
  }

  /// Puts [offer]'s password in the page's new-password fields; it's saved when the form is sent.
  void useGenerated(GenerateOffer offer) {
    if (originOf(controller.url) != offer.origin) return;
    _generated = offer.password;
    controller.runJavaScript(passwordFillNewScript(offer.origin, offer.password));
    _setOffer(null);
  }

  void regenerate(GenerateOffer offer) => _setOffer(GenerateOffer(offer.origin, generatePassword()));

  void save(SaveOffer offer) {
    manager.vault?.savePassword(offer.origin, offer.username, offer.password);
    _setOffer(null);
  }

  void neverSave(SaveOffer offer) {
    manager.vault?.setNeverSave(offer.origin, true);
    _setOffer(null);
  }

  void dismiss() => _setOffer(null);

  @override
  void dispose() {
    controller.removeListener(_onPageChanged);
    _messages.cancel();
    super.dispose();
  }
}
