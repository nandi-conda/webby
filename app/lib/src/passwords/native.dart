// dart:ffi bindings for the password manager's parts of native/webby_ffi.h. They're looked up one by one so the app
// still runs (without autofill, and with passkeys in their file) on a Ladybird runtime that predates them.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../bindings.dart';

class PasswordNative {
  PasswordNative._(DynamicLibrary lib)
      : setMessagePrefix = _lookup(lib, 'webby_view_set_message_prefix',
            (l, n) => l.lookupFunction<Void Function(ViewPtr, Pointer<Utf8>), void Function(ViewPtr, Pointer<Utf8>)>(n)),
        nextMessage = _lookup(lib, 'webby_view_next_message',
            (l, n) => l.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>(n)),
        _useVault = _lookup(lib, 'webby_passkeys_use_vault',
            (l, n) => l.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>(n)),
        _serial = _lookup(lib, 'webby_passkeys_serial', (l, n) => l.lookupFunction<Uint64 Function(), int Function()>(n)),
        _export = _lookup(lib, 'webby_passkeys_export',
            (l, n) => l.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(n)),
        _remove = _lookup(lib, 'webby_passkeys_remove',
            (l, n) => l.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>(n)),
        _deleteFile =
            _lookup(lib, 'webby_passkeys_delete_file', (l, n) => l.lookupFunction<Int32 Function(), int Function()>(n));

  static T? _lookup<T>(DynamicLibrary lib, String name, T Function(DynamicLibrary, String) lookup) =>
      lib.providesSymbol(name) ? lookup(lib, name) : null;

  static PasswordNative? _instance;

  /// The bindings for the libwebby.so that [bindings] loaded.
  static PasswordNative of(WebbyBindings bindings) =>
      _instance ??= PasswordNative._(DynamicLibrary.open('${bindings.prefix}/lib/libwebby.so'));

  final void Function(ViewPtr, Pointer<Utf8>)? setMessagePrefix;
  final Pointer<Utf8> Function(ViewPtr)? nextMessage;
  final int Function(Pointer<Utf8>)? _useVault;
  final int Function()? _serial;
  final Pointer<Utf8> Function()? _export;
  final int Function(Pointer<Utf8>)? _remove;
  final int Function()? _deleteFile;

  bool get supportsMessages => setMessagePrefix != null && nextMessage != null;
  bool get supportsPasskeyVault =>
      _useVault != null && _serial != null && _export != null && _remove != null && _deleteFile != null;

  /// Moves passkeys into the vault: the authenticator keeps [passkeys] (plus any it had that aren't among them) in
  /// memory from now on. Returns false if the runtime can't.
  bool usePasskeyVault(List<Map<String, Object?>> passkeys) {
    if (!supportsPasskeyVault) return false;
    final json = jsonEncode(passkeys).toNativeUtf8();
    try {
      return _useVault!(json) == 0;
    } finally {
      malloc.free(json);
    }
  }

  /// Changes whenever the authenticator's passkeys do (0 while they're still in passkeys.json).
  int get passkeySerial => _serial?.call() ?? 0;

  List<Map<String, Object?>> exportPasskeys() {
    if (_export == null) return const [];
    return (jsonDecode(_export().toDartString()) as List<Object?>).whereType<Map<String, Object?>>().toList();
  }

  void removePasskey(String credentialId) {
    if (_remove == null) return;
    final id = credentialId.toNativeUtf8();
    try {
      _remove(id);
    } finally {
      malloc.free(id);
    }
  }

  /// Deletes the old plaintext passkeys.json once the vault holds its passkeys.
  bool deletePasskeyFile() => _deleteFile?.call() == 0;
}
