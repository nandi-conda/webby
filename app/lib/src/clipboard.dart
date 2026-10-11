// dart:ffi bindings for the clipboard parts of native/webby_ffi.h. They're looked up one by one so the app still runs
// (with a clipboard pages can only paste their own copies from) on a Ladybird runtime that predates them.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'bindings.dart';

/// Connects Ladybird's clipboard to the system one: text pages copy goes to the system clipboard, and the system
/// clipboard's text is handed to Ladybird before a paste.
class ClipboardBridge {
  ClipboardBridge._(DynamicLibrary lib)
      : _serial = _lookup(lib, 'webby_clipboard_serial', (l, n) => l.lookupFunction<Uint64 Function(), int Function()>(n)),
        _text = _lookup(
            lib, 'webby_clipboard_text', (l, n) => l.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(n)),
        _setText = _lookup(lib, 'webby_clipboard_set_text',
            (l, n) => l.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(n));

  static T? _lookup<T>(DynamicLibrary lib, String name, T Function(DynamicLibrary, String) lookup) =>
      lib.providesSymbol(name) ? lookup(lib, name) : null;

  static ClipboardBridge? _instance;

  /// The bridge for the libwebby.so that [bindings] loaded.
  static ClipboardBridge of(WebbyBindings bindings) =>
      _instance ??= ClipboardBridge._(DynamicLibrary.open('${bindings.prefix}/lib/libwebby.so'));

  final int Function()? _serial;
  final Pointer<Utf8> Function()? _text;
  final void Function(Pointer<Utf8>)? _setText;
  int _lastSerial = 0;

  bool get isSupported => _serial != null && _text != null && _setText != null;

  /// Copies whatever a page put on Ladybird's clipboard since the last call to the system clipboard. Called after
  /// every pump; one bridge serves every view, so a copy goes out once.
  void pushPageCopies() {
    if (!isSupported) return;
    final serial = _serial!();
    if (serial == _lastSerial) return;
    _lastSerial = serial;
    final text = _text!().toDartString();
    if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
  }

  /// Gives Ladybird the system clipboard's text, so the next paste (or navigator.clipboard.read*) sees it.
  Future<void> pullSystemClipboard() async {
    if (!isSupported) return;
    String text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    } catch (_) {
      return;
    }
    final native = text.toNativeUtf8();
    try {
      _setText!(native);
    } finally {
      malloc.free(native);
    }
  }
}
