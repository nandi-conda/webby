import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/pwa/app_store.dart';
import 'package:webby/src/pwa/manifest.dart';

void main() {
  final doc = Uri.parse('https://example.com/app/index.html');
  final manifestUrl = Uri.parse('https://example.com/app/manifest.webmanifest');

  WebAppManifest parse(Map<String, Object?> json) =>
      WebAppManifest.parse(jsonEncode(json), manifestUrl: manifestUrl, documentUrl: doc)!;

  group('manifest', () {
    test('resolves URLs against the manifest and defaults scope', () {
      final m = parse({
        'name': 'Example',
        'start_url': './?source=pwa',
        'icons': [
          {'src': 'icons/192.png', 'sizes': '192x192', 'type': 'image/png'},
          {'src': 'icons/512.png', 'sizes': '512x512', 'type': 'image/png'},
          {'src': 'icons/mask.png', 'sizes': '256x256', 'type': 'image/png', 'purpose': 'maskable'},
        ],
      });
      expect(m.startUrl.toString(), 'https://example.com/app/?source=pwa');
      expect(m.scope.toString(), 'https://example.com/app/');
      expect(m.id, m.startUrl);
      expect(m.bestIcon!.src.toString(), 'https://example.com/app/icons/512.png');
      expect(m.inScope(Uri.parse('https://example.com/app/x')), isTrue);
      expect(m.inScope(Uri.parse('https://example.com/other')), isFalse);
      expect(m.inScope(Uri.parse('https://evil.com/app/')), isFalse);
    });

    test('rejects cross-origin start_url and a scope that excludes it', () {
      final m = parse({'short_name': 'Ex', 'start_url': 'https://other.com/', 'scope': '/elsewhere/'});
      expect(m.title, 'Ex');
      expect(m.startUrl, doc);
      expect(m.scope.toString(), 'https://example.com/app/');
    });

    test('needs a name', () {
      expect(WebAppManifest.parse('{"start_url": "/"}', manifestUrl: manifestUrl, documentUrl: doc), isNull);
      expect(WebAppManifest.parse('not json', manifestUrl: manifestUrl, documentUrl: doc), isNull);
    });

    test('uses id when same-origin', () {
      expect(parse({'name': 'A', 'id': '/my-app'}).id.toString(), 'https://example.com/my-app');
      expect(parse({'name': 'A', 'id': 'https://x.org/'}).id, doc);
    });
  });

  group('app store', () {
    late Directory home;
    late AppStore store;
    setUp(() {
      home = Directory.systemTemp.createTempSync('webby-pwa');
      store = AppStore(dataHome: home.path, environment: {'WEBBY_LADYBIRD_PREFIX': '/opt/lb'}, executable: '/opt/webby/webby');
    });
    tearDown(() => home.deleteSync(recursive: true));

    test('installs, writes a launcher and uninstalls', () async {
      final m = parse({
        'name': 'Example',
        'description': 'Line one\nline two',
        'start_url': '/app/?a=1&b=%20',
        'icons': [
          {'src': 'icon.webp', 'sizes': '256x256'},
        ],
      });
      final app = await store.install(
        m,
        iconToPng: (bytes) async => Uint8List.fromList([1, 2, 3]),
        download: (url) async => (Uint8List.fromList([9]), 'image/webp'),
      );
      expect(app.iconPath, endsWith('/icon.png'));
      expect(File(app.iconPath!).readAsBytesSync(), [1, 2, 3]);
      expect(store.byId(m.id.toString())!.name, 'Example');
      expect(store.forUrl(m.startUrl)!.slug, app.slug);

      final entry = store.desktopFile(app.slug).readAsStringSync();
      expect(entry, contains('Name=Example\n'));
      expect(entry, contains(r'Comment=Line one\nline two'));
      expect(entry, contains('Exec=env WEBBY_LADYBIRD_PREFIX=/opt/lb /opt/webby/webby "--app=https://example.com/app/?a=1&b=%%20"\n'));
      expect(entry, contains('Icon=${app.iconPath}\n'));

      await store.uninstall(app);
      expect(store.apps, isEmpty);
      expect(store.desktopFile(app.slug).existsSync(), isFalse);
    });

    test('slugs are stable and file-name safe', () {
      expect(AppStore.slugFor('https://example.com/app/'), AppStore.slugFor('https://example.com/app/'));
      expect(AppStore.slugFor('https://example.com/app/'), matches(RegExp(r'^example-com-[0-9a-f]{8}$')));
    });
  });
}
