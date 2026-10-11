import 'dart:io';

import 'package:test/test.dart';
import 'package:webby_sync_server/webby_sync_server.dart';

void main() {
  late Directory dir;
  late HttpServer http;
  final client = HttpClient();
  final id = 'ab' * 32;
  const token = 'Bearer abcdefghijklmnopqrstuvwxyz0123456789';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('webby-sync');
    http = await serve(SyncServer(dir), address: InternetAddress.loopbackIPv4, port: 0);
  });

  tearDown(() async {
    await http.close(force: true);
    await dir.delete(recursive: true);
  });

  Future<(int, String?, String)> call(String method,
      {String path = '', String auth = token, List<int>? body, Map<String, String> headers = const {}}) async {
    final request = await client.openUrl(
        method, Uri.parse('http://127.0.0.1:${http.port}${path.isEmpty ? '/v1/blobs/$id' : path}'));
    request.headers.set('Authorization', auth);
    headers.forEach(request.headers.set);
    if (body != null) request.add(body);
    final response = await request.close();
    final text = String.fromCharCodes(await response.fold<List<int>>([], (a, b) => a..addAll(b)));
    return (response.statusCode, response.headers.value('etag'), text);
  }

  test('create, read, conditional update, conflict, delete', () async {
    expect((await call('GET')).$1, 404);
    expect((await call('PUT', body: [1])).$1, 428, reason: 'unconditional writes are refused');
    final created = await call('PUT', body: 'one'.codeUnits, headers: {'If-None-Match': '*'});
    expect(created.$1, 201);
    expect((await call('PUT', body: 'x'.codeUnits, headers: {'If-None-Match': '*'})).$1, 412);

    final read = await call('GET');
    expect(read.$1, 200);
    expect(read.$2, created.$2);
    expect(read.$3, 'one');

    final updated = await call('PUT', body: 'two'.codeUnits, headers: {'If-Match': created.$2!});
    expect(updated.$1, 200);
    expect(updated.$2, isNot(created.$2));
    expect((await call('PUT', body: 'three'.codeUnits, headers: {'If-Match': created.$2!})).$1, 412);
    expect((await call('GET')).$3, 'two');

    expect((await call('DELETE')).$1, 204);
    expect((await call('GET')).$1, 404);
  });

  test('a blob only answers to the token that created it', () async {
    await call('PUT', body: 'one'.codeUnits, headers: {'If-None-Match': '*'});
    const other = 'Bearer zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
    expect((await call('GET', auth: other)).$1, 403);
    expect((await call('PUT', auth: other, body: [1], headers: {'If-Match': '*'})).$1, 403);
    expect((await call('DELETE', auth: other)).$1, 403);
    expect((await call('GET', auth: '')).$1, 401);
  });

  test('rejects bad paths and huge blobs', () async {
    expect((await call('GET', path: '/v1/blobs/../../etc/passwd')).$1, 404);
    expect((await call('GET', path: '/healthz')).$1, 200);
    final big = List<int>.filled(maxBlobBytes + 1, 0);
    expect((await call('PUT', body: big, headers: {'If-None-Match': '*'})).$1, 413);
  });
}
