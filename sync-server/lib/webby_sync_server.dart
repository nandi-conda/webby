// webby-sync: keeps one opaque, end-to-end encrypted blob per sync key. It never sees passwords: the blob is
// encrypted on the devices, the blob id and token are derived from a key the server never gets, and only the token's
// SHA-256 is stored.
//
//   GET    /v1/blobs/<64 hex>   -> 200 blob + ETag, or 404
//   PUT    /v1/blobs/<64 hex>   If-None-Match: * (create) or If-Match: <etag> -> 200/201 + ETag, or 412
//   DELETE /v1/blobs/<64 hex>   -> 204
//   GET    /healthz             -> 200
//
// Every blob request carries `Authorization: Bearer <token>`. The first write of a blob fixes its token.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Largest blob accepted. A vault with thousands of passwords is well under this.
const maxBlobBytes = 4 * 1024 * 1024;

final _blobPath = RegExp(r'^/v1/blobs/([0-9a-f]{64})$');

class SyncServer {
  SyncServer(this.dataDir) {
    dataDir.createSync(recursive: true);
  }

  final Directory dataDir;
  final Map<String, Future<void>> _locks = {};

  File _blob(String id) => File('${dataDir.path}/$id.blob');
  File _meta(String id) => File('${dataDir.path}/$id.meta');

  /// Runs [action] with no other request for the same blob in flight.
  Future<T> _locked<T>(String id, Future<T> Function() action) {
    final previous = _locks[id] ?? Future.value();
    final result = previous.then((_) => action());
    final done = result.then((_) {}, onError: (_) {});
    _locks[id] = done;
    done.then((_) {
      if (identical(_locks[id], done)) _locks.remove(id);
    });
    return result;
  }

  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    try {
      if (request.uri.path == '/healthz') {
        response.write('ok');
        return;
      }
      final match = _blobPath.firstMatch(request.uri.path);
      if (match == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final id = match.group(1)!;
      final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      if (!auth.startsWith('Bearer ') || auth.length < 30) {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      final tokenHash = _hash(auth.substring(7));

      switch (request.method) {
        case 'GET' || 'HEAD':
          await _locked(id, () async {
            final meta = _readMeta(id);
            if (meta == null) {
              response.statusCode = HttpStatus.notFound;
            } else if (!_same(meta['token'] as String, tokenHash)) {
              response.statusCode = HttpStatus.forbidden;
            } else {
              response.headers.set(HttpHeaders.etagHeader, meta['etag'] as String);
              response.headers.contentType = ContentType('application', 'octet-stream');
              if (request.method == 'GET') response.add(await _blob(id).readAsBytes());
            }
          });
        case 'PUT':
          final body = await _readBody(request);
          if (body == null) {
            response.statusCode = HttpStatus.requestEntityTooLarge;
            return;
          }
          await _locked(id, () async {
            final meta = _readMeta(id);
            final ifMatch = request.headers.value(HttpHeaders.ifMatchHeader);
            final ifNoneMatch = request.headers.value(HttpHeaders.ifNoneMatchHeader);
            if (meta != null && !_same(meta['token'] as String, tokenHash)) {
              response.statusCode = HttpStatus.forbidden;
              return;
            }
            final stale = meta == null
                ? ifMatch != null
                : (ifNoneMatch == '*' || (ifMatch != null && ifMatch != '*' && ifMatch != meta['etag']));
            if (stale) {
              response.statusCode = HttpStatus.preconditionFailed;
              return;
            }
            if (ifMatch == null && ifNoneMatch != '*') {
              // Unconditional writes would let devices overwrite each other.
              response.statusCode = HttpStatus.preconditionRequired;
              return;
            }
            final etag = '"${sha256.convert(body).toString().substring(0, 32)}"';
            await _writeAtomically(_blob(id), body);
            await _writeAtomically(
                _meta(id), utf8.encode(jsonEncode({'token': tokenHash, 'etag': etag, 'updated': _now()})));
            response.statusCode = meta == null ? HttpStatus.created : HttpStatus.ok;
            response.headers.set(HttpHeaders.etagHeader, etag);
          });
        case 'DELETE':
          await _locked(id, () async {
            final meta = _readMeta(id);
            if (meta != null && !_same(meta['token'] as String, tokenHash)) {
              response.statusCode = HttpStatus.forbidden;
              return;
            }
            for (final file in [_blob(id), _meta(id)]) {
              if (file.existsSync()) file.deleteSync();
            }
            response.statusCode = HttpStatus.noContent;
          });
        default:
          response.statusCode = HttpStatus.methodNotAllowed;
      }
    } on FileSystemException catch (error) {
      stderr.writeln('webby-sync: $error');
      response.statusCode = error.osError?.errorCode == 28 ? 507 : HttpStatus.internalServerError;
    } finally {
      await response.close();
    }
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Map<String, Object?>? _readMeta(String id) {
    final file = _meta(id);
    if (!file.existsSync() || !_blob(id).existsSync()) return null;
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  static Future<List<int>?> _readBody(HttpRequest request) async {
    // Read the whole request even when it's too big, so the client gets the 413 rather than a reset connection.
    final bytes = BytesBuilder(copy: false);
    var tooBig = request.contentLength > maxBlobBytes;
    await for (final chunk in request) {
      if (tooBig) continue;
      bytes.add(chunk);
      tooBig = bytes.length > maxBlobBytes;
    }
    return tooBig ? null : bytes.takeBytes();
  }

  static Future<void> _writeAtomically(File file, List<int> bytes) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }
}

Future<HttpServer> serve(SyncServer server, {InternetAddress? address, int port = 8080}) async {
  HttpServer http;
  if (address != null) {
    http = await HttpServer.bind(address, port);
  } else {
    try {
      http = await HttpServer.bind(InternetAddress.anyIPv6, port);
    } on SocketException {
      // No IPv6 on this host.
      http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    }
  }
  http.autoCompress = false;
  http.listen(server.handle);
  return http;
}
