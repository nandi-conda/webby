import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/site_permissions.dart';
import 'package:webby/src/site_settings.dart';

/// Stands in for a view's native permission queue (webby_view_permission_request/respond).
class FakeQueue {
  final requests = <Map<String, Object>>[];
  final answers = <(int, bool)>[];
  Pointer<Utf8> _last = nullptr;

  Pointer<Utf8> request(Pointer<Void> _) {
    if (_last != nullptr) malloc.free(_last);
    return _last = (requests.isEmpty ? '' : jsonEncode(requests.first)).toNativeUtf8();
  }

  void respond(Pointer<Void> _, int id, int granted) {
    final first = requests.firstWhere((r) => r['id'] == id);
    // Like the native side: the answer covers every request from that origin for that permission.
    requests.removeWhere((r) => r['origin'] == first['origin'] && r['permission'] == first['permission']);
    answers.add((id, granted != 0));
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('webby-perms'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('settings persist per origin and reset', () {
    final file = File('${dir.path}/site_permissions.json');
    final store = SitePermissionStore(file);
    expect(store.get('https://maps.google.com', 'geolocation'), PermissionSetting.ask);
    store.set('https://maps.google.com', 'geolocation', PermissionSetting.allow);
    store.set('https://evil.example', 'geolocation', PermissionSetting.block);

    final reloaded = SitePermissionStore(file);
    expect(reloaded.get('https://maps.google.com', 'geolocation'), PermissionSetting.allow);
    expect(reloaded.get('https://evil.example', 'geolocation'), PermissionSetting.block);
    reloaded.reset('https://evil.example');
    expect(SitePermissionStore(file).hasSettings('https://evil.example'), isFalse);
  });

  test('origins and names', () {
    expect(originOf('https://www.google.com/maps/@1,2,3z'), 'https://www.google.com');
    expect(originOf('http://localhost:8080/x'), 'http://localhost:8080');
    expect(originOf('about:blank'), isNull);
    expect(siteName('https://www.google.com'), 'google.com');
    expect(siteName('http://localhost:8080'), 'http://localhost:8080');
  });

  test('requests wait for the user unless the site was answered', () {
    final queue = FakeQueue();
    final permissions = PagePermissions.withFunctions(queue.request, queue.respond);
    final view = Pointer<Void>.fromAddress(1);

    queue.requests.add({'id': 1, 'permission': 'geolocation', 'origin': 'https://a.example'});
    queue.requests.add({'id': 2, 'permission': 'geolocation', 'origin': 'https://a.example'});
    expect(permissions.check(view), isTrue);
    expect(permissions.request?.origin, 'https://a.example');

    // "Allow this time" answers both waiting requests and later ones from this tab, without remembering the site.
    permissions.answer(view, allow: true, remember: false);
    expect(queue.answers, [(1, true)]);
    permissions.check(view);
    expect(permissions.request, isNull);
    queue.requests.add({'id': 3, 'permission': 'geolocation', 'origin': 'https://a.example'});
    permissions.check(view);
    expect(queue.answers.last, (3, true));
    expect(SitePermissionStore.instance.get('https://a.example', 'geolocation'), PermissionSetting.ask);

    // Unknown permissions are refused outright.
    queue.requests.add({'id': 4, 'permission': 'midi', 'origin': 'https://a.example'});
    permissions.check(view);
    expect(queue.answers.last, (4, false));
    expect(permissions.request, isNull);
  });
}
