// Where the encrypted vault is kept between devices: one blob behind GET/PUT with ETags, on the webby-sync server or
// in a WebDAV folder.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sync_crypto.dart';

/// The webby-sync server used when the user doesn't pick one.
const defaultSyncServer = 'https://webby-sync.fly.dev';

/// Another device wrote the blob since we read it.
class SyncConflict implements Exception {
  const SyncConflict();
}

/// The server refused or failed; [message] is meant for the user.
class SyncStoreError implements Exception {
  const SyncStoreError(this.message);
  final String message;
  @override
  String toString() => message;
}

class StoredBlob {
  const StoredBlob(this.bytes, this.etag);
  final List<int> bytes;
  final String? etag;
}

abstract class BlobStore {
  /// The blob, or null if nothing has been synced yet.
  Future<StoredBlob?> read();

  /// Writes the blob if it is still at [ifMatch] (or still absent when [ifMatch] is null) and returns its new ETag;
  /// throws [SyncConflict] otherwise.
  Future<String?> write(List<int> bytes, {String? ifMatch});

  Future<void> delete();
}

/// The blobs a sync key has on the server, all with the same token and encryption key.
enum SyncBlob { vault, bookmarks, tabs, summaries, sessions, secrets }

/// Which kind of storage the user picked.
enum SyncBackend { webbySync, webdav }

/// Sync settings, kept inside the (encrypted) vault and never synced themselves.
class SyncSettings {
  SyncSettings({
    required this.code,
    this.backend = SyncBackend.webbySync,
    this.server = defaultSyncServer,
    this.username = '',
    this.password = '',
    this.etag,
    this.lastSync,
    this.lastError,
  });

  factory SyncSettings.fromJson(Map<String, Object?> json) => SyncSettings(
        code: json['code'] as String,
        backend: json['backend'] == 'webdav' ? SyncBackend.webdav : SyncBackend.webbySync,
        server: json['server'] as String? ?? defaultSyncServer,
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        etag: json['etag'] as String?,
        lastSync: json['lastSync'] as int?,
        lastError: json['lastError'] as String?,
      );

  /// The sync key as a code (see [SyncKey.code]).
  final String code;
  final SyncBackend backend;

  /// The webby-sync server's base URL, or the WebDAV folder's URL.
  final String server;

  /// WebDAV login (an app password, ideally).
  final String username;
  final String password;

  /// The blob version this device last merged; the next write is conditional on it.
  String? etag;

  /// Seconds since the epoch of the last successful sync.
  int? lastSync;
  String? lastError;

  SyncKey get key => SyncKey.fromCode(code);

  /// What another device needs to join: the code, plus the server when it isn't the default. Goes in the QR code.
  String get pairingLink {
    final query = <String, String>{'code': code};
    if (backend == SyncBackend.webdav) {
      query['webdav'] = server;
    } else if (server != defaultSyncServer) {
      query['server'] = server;
    }
    return Uri(scheme: 'webby-sync', path: 'pair', queryParameters: query).toString();
  }

  /// Reads a pairing link or a bare code. WebDAV logins aren't in links; the user types them on the new device.
  static SyncSettings fromPairing(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('webby-sync:')) {
      final uri = Uri.parse(trimmed);
      final code = uri.queryParameters['code'] ?? '';
      SyncKey.fromCode(code);
      final webdav = uri.queryParameters['webdav'];
      if (webdav != null) return SyncSettings(code: code, backend: SyncBackend.webdav, server: webdav);
      return SyncSettings(code: code, server: uri.queryParameters['server'] ?? defaultSyncServer);
    }
    return SyncSettings(code: SyncKey.fromCode(trimmed).code);
  }

  SyncSettings copyWith({String? etag, int? lastSync, String? lastError, bool clearError = false}) => SyncSettings(
        code: code,
        backend: backend,
        server: server,
        username: username,
        password: password,
        etag: etag ?? this.etag,
        lastSync: lastSync ?? this.lastSync,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );

  Map<String, Object?> toJson() => {
        'code': code,
        'backend': backend == SyncBackend.webdav ? 'webdav' : 'webby-sync',
        'server': server,
        if (username.isNotEmpty) 'username': username,
        if (password.isNotEmpty) 'password': password,
        if (etag != null) 'etag': etag,
        if (lastSync != null) 'lastSync': lastSync,
        if (lastError != null) 'lastError': lastError,
      };

  /// The passwords blob, or another of the sync key's [SyncBlob]s.
  BlobStore store(SyncKeys keys, {SyncBlob blob = SyncBlob.vault}) {
    final base = server.endsWith('/') ? server.substring(0, server.length - 1) : server;
    final blobId = switch (blob) {
      SyncBlob.vault => keys.blobId,
      SyncBlob.bookmarks => keys.bookmarksBlobId,
      SyncBlob.tabs => keys.tabsBlobId,
      SyncBlob.summaries => keys.summariesBlobId,
      SyncBlob.sessions => keys.sessionsBlobId,
      SyncBlob.secrets => keys.secretsBlobId,
    };
    if (backend == SyncBackend.webdav) {
      final login = base64Encode(utf8.encode('$username:$password'));
      return HttpBlobStore(Uri.parse('$base/webby-sync-${blobId.substring(0, 32)}.json'),
          {HttpHeaders.authorizationHeader: 'Basic $login'});
    }
    return HttpBlobStore(
        Uri.parse('$base/v1/blobs/$blobId'), {HttpHeaders.authorizationHeader: 'Bearer ${keys.authToken}'});
  }
}

/// A blob at one URL, read with GET and written with conditional PUT: the webby-sync API, and plain WebDAV.
class HttpBlobStore implements BlobStore {
  HttpBlobStore(this.url, this.headers, {HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
  }

  final Uri url;
  final Map<String, String> headers;
  final HttpClient _client;

  Future<HttpClientResponse> _send(String method, {List<int>? body, Map<String, String> extra = const {}}) async {
    try {
      final request = await _client.openUrl(method, url);
      headers.forEach(request.headers.set);
      extra.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType('application', 'octet-stream');
        request.contentLength = body.length;
        request.add(body);
      }
      return await request.close().timeout(const Duration(seconds: 30));
    } on SocketException catch (error) {
      throw SyncStoreError('Can\'t reach ${url.host} (${error.osError?.message ?? error.message}).');
    } on HandshakeException {
      throw SyncStoreError('${url.host} has a bad TLS certificate.');
    } on TimeoutException {
      throw SyncStoreError('${url.host} took too long to answer.');
    }
  }

  Never _fail(HttpClientResponse response) {
    switch (response.statusCode) {
      case 401 || 403:
        throw SyncStoreError(headers[HttpHeaders.authorizationHeader]!.startsWith('Basic')
            ? 'The WebDAV server didn\'t accept the username and password.'
            : 'The sync server refused this device\'s key.');
      case 404 || 405 || 409:
        throw SyncStoreError('There\'s no sync folder at $url.');
      case 413:
        throw const SyncStoreError('The vault is too big for the sync server.');
      case 507:
        throw const SyncStoreError('The sync server is out of space.');
      default:
        throw SyncStoreError('The sync server answered ${response.statusCode} ${response.reasonPhrase}.');
    }
  }

  static Future<List<int>> _body(HttpClientResponse response) =>
      response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));

  @override
  Future<StoredBlob?> read() async {
    final response = await _send('GET', extra: {HttpHeaders.cacheControlHeader: 'no-cache'});
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      _fail(response);
    }
    return StoredBlob(await _body(response), response.headers.value(HttpHeaders.etagHeader));
  }

  @override
  Future<String?> write(List<int> bytes, {String? ifMatch}) async {
    final response = await _send('PUT',
        body: bytes,
        extra: ifMatch != null ? {HttpHeaders.ifMatchHeader: ifMatch} : {HttpHeaders.ifNoneMatchHeader: '*'});
    await response.drain<void>();
    if (response.statusCode == 412) throw const SyncConflict();
    if (response.statusCode < 200 || response.statusCode > 299) _fail(response);
    return response.headers.value(HttpHeaders.etagHeader);
  }

  @override
  Future<void> delete() async {
    final response = await _send('DELETE');
    await response.drain<void>();
    if (response.statusCode != 404 && (response.statusCode < 200 || response.statusCode > 299)) _fail(response);
  }
}
