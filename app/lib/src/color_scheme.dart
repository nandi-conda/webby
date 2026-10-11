import 'dart:ffi';

import 'package:flutter/foundation.dart';

import 'bindings.dart';

/// Makes pages follow the desktop's light or dark setting: `prefers-color-scheme` and the blank canvas match
/// [brightness], live (`webby_view_set_color_scheme`). main.dart feeds it the brightness flatkit's KitSystemTheme picks,
/// so pages and the browser UI always agree, KDE colour schemes included.
class PageColorScheme {
  PageColorScheme._();

  /// The brightness pages should use; every view follows changes at once.
  static final ValueNotifier<Brightness> brightness = ValueNotifier(Brightness.light);

  static bool _looked = false;
  static void Function(ViewPtr, int)? _set;

  /// Applies [brightness] to [view] now and whenever it changes; returns the listener to remove, or null when the
  /// runtime is too old to have `webby_view_set_color_scheme` (pages then keep Ladybird's default).
  static VoidCallback? follow(WebbyBindings bindings, ViewPtr Function() view) {
    final set = _lookup(bindings);
    if (set == null) return null;
    void apply() {
      final v = view();
      if (v != nullptr) set(v, brightness.value == Brightness.dark ? 2 : 1);
    }

    apply();
    brightness.addListener(apply);
    return apply;
  }

  static void unfollow(VoidCallback? listener) {
    if (listener != null) brightness.removeListener(listener);
  }

  static void Function(ViewPtr, int)? _lookup(WebbyBindings bindings) {
    if (_looked) return _set;
    _looked = true;
    final lib = DynamicLibrary.open('${bindings.prefix}/lib/libwebby.so');
    if (!lib.providesSymbol('webby_view_set_color_scheme')) return null;
    return _set = lib.lookupFunction<Void Function(ViewPtr, Int32), void Function(ViewPtr, int)>(
      'webby_view_set_color_scheme',
    );
  }
}
