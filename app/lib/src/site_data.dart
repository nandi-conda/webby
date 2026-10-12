// Clearing what sites leave behind: one site's cookies and storage from the site settings panel, and Chrome's
// "Clear browsing data" for everything (see webby_clear_site_data / webby_clear_browsing_data in webby_ffi.h).

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import 'bindings.dart';
import 'ui.dart';

class SiteData {
  SiteData._(this._clearSite, this._clearAll);

  static SiteData? _instance;
  static bool _looked = false;

  /// Null with a runtime that predates clearing site data.
  static SiteData? of(WebbyBindings bindings) {
    if (_looked) return _instance;
    _looked = true;
    final lib = bindings.library;
    if (!lib.providesSymbol('webby_clear_site_data')) return null;
    return _instance = SiteData._(
      lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('webby_clear_site_data'),
      lib.lookupFunction<Void Function(Int64, Int32), void Function(int, int)>('webby_clear_browsing_data'),
    );
  }

  static const cache = 1;
  static const siteData = 2;
  static const history = 4;

  final void Function(Pointer<Utf8>) _clearSite;
  final void Function(int, int) _clearAll;

  /// Deletes the cookies and stored data of [url]'s site.
  void clearSite(String url) {
    final s = url.toNativeUtf8();
    try {
      _clearSite(s);
    } finally {
      malloc.free(s);
    }
  }

  /// Clears [what] (flags above) used since [since] (null: all time).
  void clearBrowsingData(int what, {DateTime? since}) => _clearAll(since?.millisecondsSinceEpoch ?? 0, what);
}

/// Asks before deleting [site]'s cookies and data. Returns whether the user went ahead.
Future<bool> confirmClearSiteData(BuildContext context, String site) async {
  final result = await showWebbyDialog<bool>(context, (dialogContext) => KitDialog(
        title: 'Delete site data?',
        content: Text('This deletes the cookies and data $site stored in this browser. You\'ll be signed out of it.'),
        actions: [
          KitButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
          KitButton.danger('Delete', autofocus: true, onPressed: () => Navigator.of(dialogContext).pop(true)),
        ],
      ));
  return result ?? false;
}

/// Chrome's "Clear browsing data" dialog. Returns whether anything was cleared.
Future<bool> showClearBrowsingData(BuildContext context, SiteData data) async {
  const ranges = [
    (Duration(hours: 1), 'Last hour'),
    (Duration(hours: 24), 'Last 24 hours'),
    (Duration(days: 7), 'Last 7 days'),
    (Duration(days: 28), 'Last 4 weeks'),
    (Duration.zero, 'All time'),
  ];
  var range = Duration.zero;
  var cookies = true;
  var cached = true;
  var history = false;

  final cleared = await showWebbyDialog<bool>(context, (dialogContext) {
    return StatefulBuilder(builder: (context, setState) {
      Widget option(String label, String detail, bool value, ValueChanged<bool> changed) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KitCheckbox(value: value, onChanged: (v) => setState(() => changed(v))),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Text(label), Text(detail, style: KitText.dim(context, small: true))],
                  ),
                ),
              ],
            ),
          );
      return KitDialog(
        title: 'Clear browsing data',
        width: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Time range')),
                KitSelect<Duration>(value: range, options: ranges, onChanged: (v) => setState(() => range = v)),
              ],
            ),
            const SizedBox(height: 8),
            option('Cookies and other site data', 'Signs you out of most sites.', cookies, (v) => cookies = v),
            option('Cached images and files', 'Pages may load more slowly next time.', cached, (v) => cached = v),
            option('Browsing history', 'Pages the engine remembers visiting.', history, (v) => history = v),
          ],
        ),
        actions: [
          KitButton('Cancel', onPressed: () => Navigator.of(dialogContext).pop(false)),
          KitButton.primary('Clear data', onPressed: !(cookies || cached || history)
              ? null
              : () {
                  data.clearBrowsingData(
                    (cookies ? SiteData.siteData : 0) | (cached ? SiteData.cache : 0) | (history ? SiteData.history : 0),
                    since: range == Duration.zero ? null : DateTime.now().subtract(range),
                  );
                  Navigator.of(dialogContext).pop(true);
                }),
        ],
      );
    });
  });
  return cleared ?? false;
}
