import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/content_blocking.dart';

void main() {
  group('ContentBlocking.ladybirdProfileDirs', () {
    test('a temporary profile has no fixed place', () {
      expect(ContentBlocking.ladybirdProfileDirs(['--disable-sandbox', '--temporary-profile']), isNull);
    });

    test('a profile path holds config and data', () {
      final dirs = ContentBlocking.ladybirdProfileDirs(['--profile-path=/run/p']);
      expect(dirs?.config, '/run/p/config');
      expect(dirs?.data, '/run/p/data');
      expect(ContentBlocking.ladybirdProfileDirs(['--profile-path', '/q'])?.config, '/q/config');
    });

    test('named profiles live under Ladybird/Profiles', () {
      expect(ContentBlocking.ladybirdProfileDirs(['--profile', 'work'])?.config, endsWith('/Ladybird/Profiles/work'));
      expect(ContentBlocking.ladybirdProfileDirs([])?.data, endsWith('/Ladybird/Profiles/default'));
    });
  });

  test('writeLadybirdSettings switches the blocker and keeps other settings', () {
    final dir = Directory.systemTemp.createTempSync('webby-cb-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/config/Settings.json');
    file.parent.createSync();
    file.writeAsStringSync(jsonEncode({
      'geolocationEnabled': true,
      'contentBlockers': {'enabled': false, 'builtInLists': {'easyList': false, 'fanboySocial': true}},
      'backgroundNetworking': {'enabled': true, 'features': {'contentBlockerSubscriptionUpdates': false}},
    }));

    ContentBlocking.writeLadybirdSettings(file, true, updateLists: true);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(json['geolocationEnabled'], true);
    expect(json['contentBlockers']['enabled'], true);
    expect(json['contentBlockers']['builtInLists'], {'easyList': true, 'fanboySocial': true, 'easyPrivacy': true});
    expect(json['backgroundNetworking']['enabled'], true);
    expect(json['backgroundNetworking']['features']['contentBlockerSubscriptionUpdates'], true);

    ContentBlocking.writeLadybirdSettings(file, false, updateLists: false);
    final off = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(off['contentBlockers']['enabled'], false);
    expect(off['backgroundNetworking']['features']['contentBlockerSubscriptionUpdates'], false);
  });

  test('writeLadybirdSettings creates a missing file', () {
    final dir = Directory.systemTemp.createTempSync('webby-cb-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/new/Settings.json');
    ContentBlocking.writeLadybirdSettings(file, true, updateLists: true);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(json['contentBlockers'], {'enabled': true, 'builtInLists': {'easyList': true, 'easyPrivacy': true}});
  });
}
