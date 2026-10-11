import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/passwords/sync/sync_crypto.dart';
import 'package:webby/src/passwords/sync/sync_doc.dart';
import 'package:webby/src/passwords/sync/sync_engine.dart';
import 'package:webby/src/passwords/sync/sync_store.dart';
import 'package:webby/src/tabs/device_tabs.dart';

import 'passwords/sync_test.dart' show MemoryStore;

void main() {
  late Directory temp;
  late MemoryStore server;
  late SyncSettings settings;
  var clock = 1000000;
  var files = 0;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webby-device-tabs');
    server = MemoryStore();
    settings = SyncSettings(code: SyncKey.generate().code);
    deviceTabsClock = () => clock;
  });
  tearDown(() => temp.deleteSync(recursive: true));

  DeviceTabs device(String name) => DeviceTabs(File('${temp.path}/${files++}/device.json'))..name = name;

  /// What VaultSync does for tabs; returns whether it would sync again.
  Future<bool> sync(DeviceTabs tabs) async {
    final outcome = await syncOnce(settings, tabs.toSyncDoc(), store: server, now: clock, blob: SyncBlob.tabs);
    return tabs.applySyncDoc(outcome.doc);
  }

  test('each device sees the others\' tabs, not its own', () async {
    final laptop = device('laptop');
    final phone = device('phone');
    laptop.setTabs([
      const DeviceTab('Ladybird', 'https://ladybird.org/'),
      const DeviceTab('', 'about:blank'),
      const DeviceTab('HN', 'https://news.ycombinator.com/'),
    ]);
    phone.setTabs([const DeviceTab('Docs', 'https://docs.example/')]);
    expect(await sync(laptop), isFalse);
    expect(await sync(phone), isFalse);
    await sync(laptop);

    expect(laptop.devices.map((d) => d.name), ['phone']);
    expect(laptop.devices.single.tabs, [const DeviceTab('Docs', 'https://docs.example/')]);
    expect(phone.devices.single.name, 'laptop');
    expect(phone.devices.single.tabs.map((t) => t.url), ['https://ladybird.org/', 'https://news.ycombinator.com/']);
    expect(phone.devices.single.seenAt, clock);
  });

  test('nothing is written until tabs change or the hourly heartbeat', () async {
    final laptop = device('laptop')..setTabs([const DeviceTab('A', 'https://a.example/')]);
    await sync(laptop);
    final version = server.version;
    expect(laptop.needsPublish, isFalse);
    clock += 600;
    await sync(laptop);
    expect(server.version, version);
    clock += 3600;
    expect(laptop.needsPublish, isTrue);
    await sync(laptop);
    expect(server.version, version + 1);
    laptop.setTabs([const DeviceTab('B', 'https://b.example/')]);
    expect(laptop.needsPublish, isTrue);
  });

  test('turning sharing off removes the device for the others', () async {
    final laptop = device('laptop')..setTabs([const DeviceTab('A', 'https://a.example/')]);
    final phone = device('phone');
    await sync(laptop);
    await sync(phone);
    expect(phone.devices, hasLength(1));
    laptop.share = false;
    clock++;
    await sync(laptop);
    await sync(phone);
    expect(phone.devices, isEmpty);
    // It still sees the phone.
    expect(laptop.devices.map((d) => d.name), ['phone']);
  });

  test('a device whose record was removed with a clock ahead of its own puts it back', () async {
    final laptop = device('laptop')..setTabs([const DeviceTab('A', 'https://a.example/')]);
    await sync(laptop);
    final keys = await settings.key.derive();
    final doc = await keys.open((await server.read())!.bytes);
    doc.devices[laptop.deviceId] = {'updatedAt': clock + 5000, 'deleted': true};
    server.bytes = await keys.seal(doc);
    expect(await sync(laptop), isTrue);
    expect(await sync(laptop), isFalse);
    final after = await keys.open((await server.read())!.bytes);
    expect(isDeleted(after.devices[laptop.deviceId]!), isFalse);
  });

  test('devices not seen for a month drop out', () {
    final old = {'name': 'old', 'updatedAt': 0, 'tabs': <Object?>[]};
    final recent = {'name': 'new', 'updatedAt': deviceLifetime.inSeconds, 'tabs': <Object?>[]};
    final merged = mergeDocs(SyncDoc(devices: {'a': old}), SyncDoc(devices: {'b': recent}),
        now: deviceLifetime.inSeconds + 10);
    expect(merged.devices.keys, ['b']);
  });

  test('the device id and name persist', () {
    final file = File('${temp.path}/persist/device.json');
    final first = DeviceTabs(file)..name = 'desk';
    final again = DeviceTabs(file);
    expect(again.deviceId, first.deviceId);
    expect(again.name, 'desk');
    expect(again.share, isTrue);
  });

  test('the tabs blob is separate from the others', () async {
    final keys = await settings.key.derive();
    expect({keys.blobId, keys.bookmarksBlobId, keys.tabsBlobId}, hasLength(3));
  });
}
