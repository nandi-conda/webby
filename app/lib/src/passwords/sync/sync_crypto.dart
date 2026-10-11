// The sync key, the code devices pair with, and encryption of what goes to the server.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'sync_doc.dart';

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const _codePrefix = 'webby1';
const _version = 'webby-sync-v1';

/// The code is wrong: mistyped, cut short, or not a webby sync code.
class BadSyncCode implements Exception {
  const BadSyncCode(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The server's copy can't be read with this sync key.
class SyncDecryptError implements Exception {
  const SyncDecryptError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The 256-bit secret every paired device shares. Whoever has it can read the synced passwords.
class SyncKey {
  SyncKey(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != 32) throw const BadSyncCode('A sync key is 32 bytes.');
  }

  factory SyncKey.generate() {
    final random = Random.secure();
    return SyncKey(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  /// Reads a code made by [code], ignoring case, spaces and dashes, and accepting 0/1/8 typed for O/I/B.
  factory SyncKey.fromCode(String text) {
    var cleaned = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (cleaned.startsWith(_codePrefix.toUpperCase())) cleaned = cleaned.substring(_codePrefix.length);
    cleaned = cleaned.replaceAll('0', 'O').replaceAll('1', 'I').replaceAll('8', 'B');
    // 32 key bytes + 2 check bytes = 34 bytes = 55 base32 characters (272 bits, rounded up to 275).
    if (cleaned.length != 55) throw const BadSyncCode('That sync code is the wrong length.');
    final bytes = _base32Decode(cleaned);
    if (bytes == null || bytes.length < 34) throw const BadSyncCode('That isn\'t a sync code.');
    final key = bytes.sublist(0, 32);
    final check = _check(key);
    if (bytes[32] != check[0] || bytes[33] != check[1]) {
      throw const BadSyncCode('That sync code has a typo in it.');
    }
    return SyncKey(key);
  }

  final Uint8List bytes;

  /// The key as `webby1-XXXXX-XXXXX-…`: base32 with two check bytes, so typos are caught.
  String get code {
    final text = _base32Encode([...bytes, ..._check(bytes)]);
    final groups = [for (var i = 0; i < text.length; i += 5) text.substring(i, min(i + 5, text.length))];
    return [_codePrefix, ...groups].join('-');
  }

  static List<int> _check(List<int> key) {
    // CRC-16/CCITT: plenty for catching typos.
    var crc = 0xFFFF;
    for (final byte in key) {
      crc ^= byte << 8;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
      }
    }
    return [crc >> 8, crc & 0xFF];
  }

  Future<SyncKeys> derive() async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<List<int>> part(String info) async {
      final derived = await hkdf.deriveKey(
          secretKey: SecretKey(bytes), nonce: utf8.encode(_version), info: utf8.encode(info));
      return derived.extractBytes();
    }

    return SyncKeys(
      blobId: _hex(await part('id')),
      bookmarksBlobId: _hex(await part('id-bookmarks')),
      authToken: base64UrlEncode(await part('auth')).replaceAll('=', ''),
      encryptionKey: SecretKey(await part('enc')),
    );
  }
}

/// What a [SyncKey] turns into: where the blob lives, how to prove we may write it, and how to read it.
class SyncKeys {
  SyncKeys({required this.blobId, required this.bookmarksBlobId, required this.authToken, required this.encryptionKey});

  /// 64 hex characters naming the blob on the server.
  final String blobId;

  /// The same for the bookmarks blob, which sits beside the passwords one with the same token and encryption key.
  final String bookmarksBlobId;

  /// Bearer token for the webby-sync server, which keeps only its hash.
  final String authToken;
  final SecretKey encryptionKey;

  static final _cipher = AesGcm.with256bits();

  Future<List<int>> seal(SyncDoc doc) async {
    final clear = utf8.encode(doc.canonical());
    final box = await _cipher.encrypt(clear, secretKey: encryptionKey, aad: utf8.encode(_version));
    return utf8.encode(jsonEncode({
      'format': 'webby-sync',
      'version': 1,
      'nonce': base64Encode(box.nonce),
      'data': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    }));
  }

  Future<SyncDoc> open(List<int> sealed) async {
    Map<String, Object?> envelope;
    try {
      envelope = jsonDecode(utf8.decode(sealed)) as Map<String, Object?>;
    } catch (_) {
      throw const SyncDecryptError('The synced data on the server is damaged.');
    }
    if (envelope['format'] != 'webby-sync') throw const SyncDecryptError('The server has something else stored.');
    if (envelope['version'] != 1) {
      throw const SyncDecryptError('Another device synced with a newer webby. Update webby here to keep syncing.');
    }
    try {
      final box = SecretBox(base64Decode(envelope['data'] as String),
          nonce: base64Decode(envelope['nonce'] as String), mac: Mac(base64Decode(envelope['mac'] as String)));
      final clear = await _cipher.decrypt(box, secretKey: encryptionKey, aad: utf8.encode(_version));
      return SyncDoc.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, Object?>);
    } on SecretBoxAuthenticationError {
      throw const SyncDecryptError('The synced data doesn\'t match this sync code.');
    } catch (error) {
      throw SyncDecryptError('The synced data on the server is damaged ($error).');
    }
  }
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _base32Encode(List<int> bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

List<int>? _base32Decode(String text) {
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final char in text.split('')) {
    final value = _alphabet.indexOf(char);
    if (value < 0) return null;
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
    buffer &= (1 << bits) - 1;
  }
  return out;
}
