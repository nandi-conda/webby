import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/passwords/vault.dart';
import 'package:webby/src/summarize.dart';

const page = PageText(title: 'Example', url: 'https://example.com/', text: 'Some readable text about examples.');

void main() {
  late HttpServer server;
  late Uri endpoint;
  final requests = <(Map<String, String>, Map<String, Object?>)>[];
  int status = 200;

  setUp(() async {
    requests.clear();
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}/chat/completions');
    server.listen((request) async {
      final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
      requests.add(({'authorization': request.headers.value('authorization') ?? ''}, body));
      request.response.statusCode = status;
      if (status != 200) {
        request.response.write(jsonEncode({'error': {'message': 'nope'}}));
      } else {
        request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        for (final piece in ['It is ', 'about examples.', '\n• One']) {
          request.response.write('data: ${jsonEncode({'choices': [{'delta': {'content': piece}}]})}\n\n');
        }
        request.response.write(': keep-alive\n\ndata: [DONE]\n\n');
      }
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('streams the summary and sends the key only as a bearer token', () async {
    final pieces = await streamSummary('sk-test', page, endpoint: endpoint).toList();
    expect(pieces.join(), 'It is about examples.\n• One');
    final (headers, body) = requests.single;
    expect(headers['authorization'], 'Bearer sk-test');
    expect(body['model'], 'deepseek-chat');
    expect(body['stream'], true);
    expect(jsonEncode(body), isNot(contains('sk-test')));
    expect(jsonEncode(body), contains('Some readable text'));
  });

  test('explains a rejected key', () async {
    status = 401;
    await expectLater(
      streamSummary('bad', page, endpoint: endpoint).toList(),
      throwsA(isA<SummaryError>().having((e) => e.message, 'message', contains('API key'))),
    );
    status = 500;
    await expectLater(
      streamSummary('k', page, endpoint: endpoint).toList(),
      throwsA(isA<SummaryError>().having((e) => e.message, 'message', contains('nope'))),
    );
  });

  test('page script carries the prefix and request id', () {
    final script = pageTextScript('\u0001p:', 'abc');
    expect(script, contains('"\\u0001p:"'));
    expect(script, contains('"abc"'));
    expect(script, contains("type: 'pagetext'"));
  });

  test('API keys stay in the vault and out of sync', () async {
    final vault = await Vault.open();
    await vault.setSecret(deepSeekKeySecret, 'sk-secret');
    expect(jsonEncode(vault.toSyncDoc().toJson()), isNot(contains('sk-secret')));
    expect(File(vault.path).readAsStringSync(), isNot(contains('sk-secret')));
    final again = await Vault.open();
    expect(again.secret(deepSeekKeySecret), 'sk-secret');
    await again.setSecret(deepSeekKeySecret, null);
    expect((await Vault.open()).secret(deepSeekKeySecret), isNull);
  }, skip: Platform.environment['WEBBY_VAULT_FILE'] == null ? 'needs WEBBY_VAULT_FILE and WEBBY_VAULT_KEYRING=0' : false);
}
