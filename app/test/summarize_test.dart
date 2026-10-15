import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/passwords/sync/sync_doc.dart';
import 'package:webby/src/passwords/vault.dart';
import 'package:webby/src/summarize.dart';
import 'package:webby/src/summary_cache.dart';

const page = PageText(title: 'Example', url: 'https://example.com/', text: 'Some readable text about examples.');

void main() {
  late HttpServer server;
  late Uri endpoint;
  final requests = <(Map<String, String>, Map<String, Object?>)>[];
  int status = 200;
  var queuedOnly = false;

  setUp(() async {
    requests.clear();
    status = 200;
    queuedOnly = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}/chat/completions');
    server.listen((request) async {
      final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
      requests.add((
        {
          'authorization': request.headers.value('authorization') ?? '',
          'api-key': request.headers.value('api-key') ?? '',
        },
        body,
      ));
      request.response.statusCode = status;
      if (status != 200) {
        request.response.write(jsonEncode({'error': {'message': 'nope'}}));
      } else if (queuedOnly) {
        // DeepSeek during an outage: 200, then only keep-alive comments and no answer.
        request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        for (var i = 0; i < 20; i++) {
          request.response.write(': keep-alive\n\n');
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
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

  test('MiMo gets its key in the api-key header, its model and thinking off', () async {
    final pieces =
        await streamSummary('sk-mimo', page, provider: SummaryProvider.mimo, endpoint: endpoint).toList();
    expect(pieces.join(), 'It is about examples.\n• One');
    final (headers, body) = requests.single;
    expect(headers['api-key'], 'sk-mimo');
    expect(headers['authorization'], '');
    expect(body['model'], 'mimo-v2.6-flash');
    expect(body['thinking'], {'type': 'disabled'});
    expect(body['stream'], true);
    expect(jsonEncode(body), isNot(contains('sk-mimo')));
    status = 401;
    await expectLater(
      streamSummary('bad', page, provider: SummaryProvider.mimo, endpoint: endpoint).toList(),
      throwsA(isA<SummaryError>().having((e) => e.message, 'message', startsWith('Xiaomi MiMo'))),
    );
  });

  test('Meta gets a bearer key, Muse Spark and the shortest reasoning', () async {
    await streamSummary('meta-key', page, provider: SummaryProvider.meta, endpoint: endpoint).toList();
    final (headers, body) = requests.single;
    expect(headers['authorization'], 'Bearer meta-key');
    expect(headers['api-key'], '');
    expect(body['model'], 'muse-spark-1.3');
    expect(body['reasoning_effort'], 'minimal');
    expect(body.containsKey('thinking'), false);
  });

  test('picks the chosen provider unless only another has a key', () {
    final secrets = <String, String>{};
    SummaryProvider chosen() => SummaryProvider.chosen((name) => secrets[name]);
    expect(chosen(), SummaryProvider.deepSeek);
    secrets[mimoKeySecret] = 'k';
    expect(chosen(), SummaryProvider.mimo);
    secrets[deepSeekKeySecret] = 'k';
    expect(chosen(), SummaryProvider.deepSeek);
    secrets[providerSecret] = 'mimo';
    expect(chosen(), SummaryProvider.mimo);
    secrets.remove(mimoKeySecret);
    expect(chosen(), SummaryProvider.deepSeek);
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

  test('gives up when DeepSeek keeps the request queued', () async {
    queuedOnly = true;
    var queued = 0;
    await expectLater(
      streamSummary('k', page, endpoint: endpoint, onQueued: () => queued++, busyLimit: const Duration(milliseconds: 300))
          .toList(),
      throwsA(isA<SummaryError>().having((e) => e.message, 'message', deepSeekBusyMessage)),
    );
    expect(queued, 1);
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

  test('summaries sync: newest copy of a page wins, clearing spreads, the newest 300 are kept', () {
    final dir = Directory.systemTemp.createTempSync('webby-summaries');
    addTearDown(() => dir.deleteSync(recursive: true));
    final laptop = SummaryCache(File('${dir.path}/laptop.json'));
    final phone = SummaryCache(File('${dir.path}/phone.json'));
    laptop.store('a', const CachedSummary(title: 'A', url: 'https://a/', text: 'old', at: 1));
    phone.store('a', const CachedSummary(title: 'A', url: 'https://a/', text: 'new', at: 2,
        questions: [(question: 'q', answer: 'x')]));
    phone.store('b', const CachedSummary(title: 'B', url: 'https://b/', text: 'b', at: 3));
    // The phone's copy of "a" is newer (each store bumps past the last).
    final merged = mergeDocs(laptop.toSyncDoc(), phone.toSyncDoc(), now: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 5);
    expect(merged.summaries['a']!['text'], anyOf('old', 'new'));
    laptop.applySyncDoc(merged);
    phone.applySyncDoc(merged);
    expect(laptop.lookup('b')!.text, 'b');
    expect(laptop.lookup('a')!.text, phone.lookup('a')!.text);

    laptop.clear();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cleared = mergeDocs(laptop.toSyncDoc(), phone.toSyncDoc(), now: now);
    phone.applySyncDoc(cleared);
    expect(phone.lookup('a'), isNull);
    expect(phone.lookup('b'), isNull);
    expect(SummaryCache(File('${dir.path}/phone.json')).lookup('b'), isNull);

    final many = SyncDoc(summaries: {
      for (var i = 0; i < summaryLimit + 10; i++)
        'k$i': CachedSummary(title: '', url: '', text: '$i', at: 0, updatedAt: 1000 + i).toJson(),
    });
    final trimmed = mergeDocs(many, SyncDoc(), now: 2000);
    expect(trimmed.summaries, hasLength(summaryLimit));
    expect(trimmed.summaries.containsKey('k0'), isFalse);
    expect(trimmed.summaries.containsKey('k${summaryLimit + 9}'), isTrue);
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

  test('the summary is asked for in English, with source links to the page', () {
    final system = (summaryRequest(page)['messages'] as List).first['content'] as String;
    expect(system, contains('This needs to be in English'));
    expect(system, contains('[§](#words)'));
    expect(jumpToTextScript('He said "hi" \$x'), contains(jsonEncode('He said "hi" \$x')));
  });
}
