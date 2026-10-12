import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/passwords/vault.dart';
import 'package:webby/src/summarize.dart';
import 'package:webby/src/summary_cache.dart';

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

  test('summary cache keys, persists, trims and clears', () {
    final dir = Directory.systemTemp.createTempSync('webby-summaries');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/summaries.json');
    final key = SummaryCache.keyFor('https://e.com/a#part');
    expect(key, SummaryCache.keyFor('https://e.com/a'));
    expect(SummaryCache.keyFor('https://e.com/a', selection: 'x'), isNot(key));
    final cache = SummaryCache(file);
    cache.store(key, const CachedSummary(title: 'A', url: 'https://e.com/a', text: '- one', at: 1000));
    final again = SummaryCache(file);
    expect(again.lookup(key)!.text, '- one');
    for (var i = 0; i < SummaryCache.limit + 5; i++) {
      again.store('k$i', CachedSummary(title: '', url: '', text: '$i', at: 2000 + i));
    }
    expect(again.lookup(key), isNull);
    expect(again.lookup('k${SummaryCache.limit + 4}'), isNotNull);
    again.clear(since: DateTime.fromMillisecondsSinceEpoch(2000 + SummaryCache.limit));
    expect(again.lookup('k${SummaryCache.limit + 4}'), isNull);
    expect(again.lookup('k${SummaryCache.limit}'), isNull);
    expect(SummaryCache(file).lookup('k10'), isNotNull);
  });

  test('follow-up questions carry the page, summary and earlier answers', () {
    final body = questionRequest(
      page: page,
      title: 'Example',
      url: 'https://example.com/',
      summary: '- sum',
      questions: [(question: 'q1', answer: 'a1')],
      question: 'q2',
    );
    final messages = (body['messages'] as List).cast<Map<String, Object?>>();
    expect(messages.map((m) => m['role']), ['system', 'user', 'assistant', 'user', 'assistant', 'user']);
    expect(messages[1]['content'], contains('Some readable text'));
    expect(messages[2]['content'], '- sum');
    expect(messages.last['content'], 'q2');
    final noPage = questionRequest(page: null, title: 'T', url: 'u', summary: 's', questions: const [], question: 'q');
    expect((noPage['messages'] as List)[1]['content'], contains('go by your summary'));
  });

  test('saved summaries keep their questions', () {
    final dir = Directory.systemTemp.createTempSync('webby-summaries');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/summaries.json');
    SummaryCache(file).store('k', const CachedSummary(
        title: 't', url: 'u', text: 's', at: 1, questions: [(question: 'why?', answer: 'because')]));
    expect(SummaryCache(file).lookup('k')!.questions.single, (question: 'why?', answer: 'because'));
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
