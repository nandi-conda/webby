import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webby_keyring/webby_keyring.dart';

/// A saved site password.
class SavedPassword {
  SavedPassword({
    required this.id,
    required this.origin,
    required this.username,
    required this.password,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SavedPassword.fromJson(Map<String, Object?> json) => SavedPassword(
        id: json['id'] as String,
        origin: json['origin'] as String,
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        createdAt: json['createdAt'] as int? ?? 0,
        updatedAt: json['updatedAt'] as int? ?? 0,
      );

  final String id;

  /// scheme://host[:port] of the page the password was saved on; it is only offered there.
  String origin;
  String username;
  String password;

  /// Seconds since the epoch.
  final int createdAt;
  int updatedAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'origin': origin,
        'username': username,
        'password': password,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

/// Where the vault's master key lives.
enum VaultKeyStore {
  /// The desktop keyring (Secret Service), the normal case.
  keyring,

  /// A key file next to the vault, readable only by the user. Used when there is no keyring to talk to.
  file,
}

/// The vault couldn't be opened; nothing is read or written until the cause is fixed.
class VaultUnavailable implements Exception {
  VaultUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// The canonical origin of a page URL, or null for pages that can't have saved passwords (about:, file:, data:...).
String? originOf(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) return null;
  return uri.origin;
}

/// One profile's encrypted store of passwords and passkeys.
///
/// On disk it is `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<profile>/vault.json` (or $WEBBY_VAULT_FILE): a
/// JSON envelope around the AES-256-GCM encrypted contents. The 256-bit key is random and kept in the desktop
/// keyring under `{application: webby, profile: <profile>}`; without a keyring it goes in `vault.key` beside the vault.
///
/// Passkeys are owned by the authenticator in libwebby (see `webby_passkeys_*` in webby_ffi.h); the vault keeps the
/// JSON it hands over in [passkeys] and gives it back at startup.
class Vault extends ChangeNotifier {
  Vault._(this.profile, this._file, this._key, this.keyStore, Map<String, Object?> contents) {
    for (final entry in (contents['passwords'] as List<Object?>? ?? const [])) {
      if (entry is Map<String, Object?>) _passwords.add(SavedPassword.fromJson(entry));
    }
    for (final origin in (contents['neverSave'] as List<Object?>? ?? const [])) {
      if (origin is String) _neverSave.add(origin);
    }
    _passkeys = (contents['passkeys'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>().toList();
  }

  static final _cipher = AesGcm.with256bits();
  static const _aad = 'webby-vault-v1';

  final String profile;
  final File _file;
  final SecretKey _key;
  final VaultKeyStore keyStore;

  final List<SavedPassword> _passwords = [];
  final Set<String> _neverSave = {};
  List<Map<String, Object?>> _passkeys = [];
  Future<void> _saving = Future.value();

  List<SavedPassword> get passwords => List.unmodifiable(_passwords);
  List<Map<String, Object?>> get passkeys => List.unmodifiable(_passkeys);
  String get path => _file.path;

  static String _profileName() {
    final name = Platform.environment['WEBBY_PROFILE'] ?? '';
    // Profile names become directory names.
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name) && name != '.' && name != '..' ? name : 'default';
  }

  static Directory _dataHome() {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return Directory(xdg);
    return Directory('${Platform.environment['HOME'] ?? '/tmp'}/.local/share');
  }

  /// Opens (or creates) the vault of the current profile ($WEBBY_PROFILE, default "default").
  ///
  /// $WEBBY_VAULT_KEYRING=0 skips the keyring and keeps the key in a file (meant for tests and headless machines).
  static Future<Vault> open() async {
    final profile = _profileName();
    final override = Platform.environment['WEBBY_VAULT_FILE'];
    final file = override != null && override.isNotEmpty
        ? File(override)
        : File('${_dataHome().path}/webby/profiles/$profile/vault.json');
    final directory = file.parent;
    if (!directory.existsSync()) directory.createSync(recursive: true);
    _restrict(directory.path, '700');
    final keyFile = File('${directory.path}/vault.key');

    final useKeyring = Platform.environment['WEBBY_VAULT_KEYRING'] != '0';
    String? keyringError;
    String? encodedKey;
    var keyStore = VaultKeyStore.keyring;

    if (useKeyring) {
      try {
        encodedKey = await WebbyKeyring.lookup(profile);
      } on PlatformException catch (error) {
        keyringError = error.message ?? error.code;
      } on MissingPluginException {
        keyringError = 'built without keyring support';
      }
    } else {
      keyringError = 'disabled by WEBBY_VAULT_KEYRING=0';
    }

    if (encodedKey == null && keyFile.existsSync()) {
      encodedKey = keyFile.readAsStringSync().trim();
      keyStore = VaultKeyStore.file;
      // A keyring has turned up since the key was written to a file: move the key into it.
      if (keyringError == null) {
        try {
          await WebbyKeyring.store(profile, encodedKey);
          keyFile.deleteSync();
          keyStore = VaultKeyStore.keyring;
        } catch (error) {
          debugPrint('webby: keeping the vault key in ${keyFile.path}: $error');
        }
      }
    }

    if (encodedKey == null) {
      if (file.existsSync()) {
        // Never replace a vault we can't read with an empty one.
        throw VaultUnavailable(keyringError != null
            ? 'The password vault at ${file.path} is locked: its key is in the keyring, which isn\'t reachable '
                '($keyringError).'
            : 'The key for the password vault at ${file.path} is missing from the keyring.');
      }
      final random = Random.secure();
      encodedKey = base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
      if (keyringError == null) {
        try {
          await WebbyKeyring.store(profile, encodedKey);
        } catch (error) {
          keyringError = '$error';
        }
      }
      if (keyringError != null) {
        debugPrint('webby: no keyring ($keyringError); keeping the vault key in ${keyFile.path}');
        _writePrivate(keyFile, utf8.encode(encodedKey));
        keyStore = VaultKeyStore.file;
      }
    }

    final keyBytes = base64Decode(encodedKey);
    if (keyBytes.length != 32) throw VaultUnavailable('The password vault key is damaged.');
    final key = SecretKey(keyBytes);

    var contents = <String, Object?>{};
    if (file.existsSync()) {
      contents = await _decrypt(key, file.readAsStringSync());
    }
    final vault = Vault._(profile, file, key, keyStore, contents);
    if (!file.existsSync()) await vault._save();
    return vault;
  }

  static Future<Map<String, Object?>> _decrypt(SecretKey key, String text) async {
    try {
      final envelope = jsonDecode(text) as Map<String, Object?>;
      if (envelope['format'] != 'webby-vault' || envelope['version'] != 1) {
        throw VaultUnavailable('The password vault was written by a newer webby.');
      }
      final box = SecretBox(
        base64Decode(envelope['data'] as String),
        nonce: base64Decode(envelope['nonce'] as String),
        mac: Mac(base64Decode(envelope['mac'] as String)),
      );
      final clear = await _cipher.decrypt(box, secretKey: key, aad: utf8.encode(_aad));
      return jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
    } on VaultUnavailable {
      rethrow;
    } on SecretBoxAuthenticationError {
      throw VaultUnavailable('The password vault doesn\'t match the key in the keyring.');
    } catch (error) {
      throw VaultUnavailable('The password vault is damaged ($error).');
    }
  }

  static void _restrict(String path, String mode) {
    try {
      Process.runSync('chmod', [mode, path]);
    } catch (_) {}
  }

  /// Writes [bytes] to [file] atomically, readable only by the user.
  static void _writePrivate(File file, List<int> bytes) {
    final temporary = File('${file.path}.tmp');
    temporary.writeAsBytesSync(const [], flush: true);
    _restrict(temporary.path, '600');
    temporary.writeAsBytesSync(bytes, flush: true);
    temporary.renameSync(file.path);
  }

  Future<void> _save() {
    // Saves run one at a time, in order, each writing the state of the moment it starts.
    return _saving = _saving.then((_) async {
      final clear = utf8.encode(jsonEncode({
        'version': 1,
        'passwords': [for (final password in _passwords) password.toJson()],
        'neverSave': _neverSave.toList()..sort(),
        'passkeys': _passkeys,
      }));
      final box = await _cipher.encrypt(clear, secretKey: _key, aad: utf8.encode(_aad));
      final envelope = jsonEncode({
        'format': 'webby-vault',
        'version': 1,
        'cipher': 'AES-256-GCM',
        'nonce': base64Encode(box.nonce),
        'data': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
      _writePrivate(_file, utf8.encode(envelope));
    }).catchError((Object error) {
      debugPrint('webby: could not save the password vault: $error');
    });
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  /// Waits for pending writes (tests and shutdown).
  Future<void> flush() => _saving;

  List<SavedPassword> passwordsFor(String origin) => _passwords.where((p) => p.origin == origin).toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  SavedPassword? find(String origin, String username) {
    for (final password in _passwords) {
      if (password.origin == origin && password.username == username) return password;
    }
    return null;
  }

  /// Saves a password, replacing the one for the same site and username.
  SavedPassword savePassword(String origin, String username, String password) {
    final existing = find(origin, username);
    if (existing != null) {
      existing.password = password;
      existing.updatedAt = _now();
      _changed();
      return existing;
    }
    final random = Random.secure();
    final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final saved = SavedPassword(
        id: id, origin: origin, username: username, password: password, createdAt: _now(), updatedAt: _now());
    _passwords.add(saved);
    _changed();
    return saved;
  }

  void updatePassword(SavedPassword entry, {required String origin, required String username, required String password}) {
    entry
      ..origin = origin
      ..username = username
      ..password = password
      ..updatedAt = _now();
    _changed();
  }

  void deletePassword(SavedPassword entry) {
    _passwords.removeWhere((p) => p.id == entry.id);
    _changed();
  }

  bool isNeverSave(String origin) => _neverSave.contains(origin);

  void setNeverSave(String origin, bool never) {
    if (never ? _neverSave.add(origin) : _neverSave.remove(origin)) _changed();
  }

  List<String> get neverSaveOrigins => _neverSave.toList()..sort();

  /// Replaces the stored passkeys with the authenticator's current list (see `webby_passkeys_export`).
  Future<void> setPasskeys(List<Map<String, Object?>> passkeys) {
    _passkeys = passkeys;
    notifyListeners();
    return _save();
  }
}
