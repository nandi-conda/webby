import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/tabs/device_tabs.dart';
import 'package:webby/src/tabs/open_tabs.dart';

void main() {
  test('open tabs come back with the front one, leaving out blank tabs', () {
    final dir = Directory.systemTemp.createTempSync('open_tabs');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = OpenTabsStore(File('${dir.path}/open_tabs.json'));
    expect(store.read(), isNull);
    store.flush(const [
      DeviceTab('A', 'https://a.example/'),
      DeviceTab('', 'about:blank'),
      DeviceTab('C', 'https://c.example/'),
    ], 2);
    final saved = OpenTabsStore(store.file).read()!;
    expect(saved.tabs.map((t) => t.url), ['https://a.example/', 'https://c.example/']);
    expect(saved.active, 1);
  });
}
