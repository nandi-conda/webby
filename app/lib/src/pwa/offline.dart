import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../bindings.dart';

/// Switches Ladybird's network process to cache-only while the machine has no network, so pages and installed web
/// apps opened before load from the HTTP disk cache (`webby_set_offline`, patches/0003-offline-disk-cache.patch).
/// It stands in for service workers, which Ladybird registers but never runs.
///
/// "No network" means no default route (IPv4 or IPv6), which is what turning off Wi-Fi or pulling the cable gives. A
/// network that is up but can't reach the internet still counts as online, so a firewall or captive portal never
/// strands the browser on the cache. `WEBBY_OFFLINE=1` forces offline, `WEBBY_OFFLINE=0` turns the switching off.
class OfflineMonitor extends ChangeNotifier {
  OfflineMonitor._(this._setOffline, this._env);

  static OfflineMonitor? _instance;

  /// Starts the monitor once; null when the runtime is too old to have `webby_set_offline`.
  static OfflineMonitor? start(WebbyBindings bindings, {Map<String, String>? environment}) {
    if (_instance != null) return _instance;
    final lib = DynamicLibrary.open('${bindings.prefix}/lib/libwebby.so');
    if (!lib.providesSymbol('webby_set_offline')) return null;
    final setOffline = lib.lookupFunction<Void Function(Int32), void Function(int)>('webby_set_offline');
    return _instance = OfflineMonitor._(setOffline, environment ?? Platform.environment).._run();
  }

  static OfflineMonitor? get instance => _instance;

  final void Function(int) _setOffline;
  final Map<String, String> _env;
  Timer? _timer;
  bool offline = false;

  void _run() {
    final forced = _env['WEBBY_OFFLINE'];
    if (forced == '0') return;
    if (forced == '1') {
      _apply(true);
      return;
    }
    check();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => check());
  }

  /// Looks at the routing table now, e.g. right after a page failed to load.
  void check() => _apply(!hasDefaultRoute());

  void _apply(bool value) {
    if (value == offline) return;
    offline = value;
    _setOffline(value ? 1 : 0);
    notifyListeners();
  }

  /// Whether the kernel has a default route; true when that can't be read, so webby never goes offline by mistake.
  static bool hasDefaultRoute({String ipv4 = '/proc/net/route', String ipv6 = '/proc/net/ipv6_route'}) {
    var readable = false;
    try {
      final lines = File(ipv4).readAsLinesSync();
      readable = true;
      // Iface Destination Gateway Flags ...: destination 00000000 with the RTF_UP flag.
      for (final line in lines.skip(1)) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length > 3 && fields[1] == '00000000' && (int.tryParse(fields[3], radix: 16) ?? 0) & 1 == 1) {
          return true;
        }
      }
    } catch (_) {}
    try {
      final lines = File(ipv6).readAsLinesSync();
      readable = true;
      // dest prefixlen src srclen nexthop metric refcnt use flags iface: ::/0 that isn't on loopback or a reject route.
      for (final line in lines) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 10 || fields[0] != '0' * 32 || fields[1] != '00') continue;
        final flags = int.tryParse(fields[8], radix: 16) ?? 0;
        if (fields[9] != 'lo' && flags & 0x0200 == 0) return true;
      }
    } catch (_) {}
    return !readable;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
