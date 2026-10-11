import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef _PushNative = Void Function(IntPtr, Pointer<Uint8>, Int32, Int32);
typedef _Push = void Function(int, Pointer<Uint8>, int, int);

/// A Flutter external texture that takes BGRA frames straight from native memory.
///
/// Show it with `Texture(textureId: texture.id)`. [push] copies the frame on the calling thread; the pointer only
/// has to stay valid for the call.
class WebbyTexture {
  WebbyTexture._(this.id, this._handle, this._push);

  static const _channel = MethodChannel('webby_texture');

  /// The id to pass to a `Texture` widget.
  final int id;
  final int _handle;
  final _Push _push;
  bool _disposed = false;

  /// Registers a texture, or returns null where the plugin isn't available (callers fall back to images).
  static Future<WebbyTexture?> create() async {
    try {
      // The plugin library is linked into the runner, so its symbols are visible process-wide.
      final push = DynamicLibrary.process().lookupFunction<_PushNative, _Push>('webby_texture_push');
      final result = await _channel.invokeListMethod<int>('create');
      if (result == null || result.length != 2) return null;
      return WebbyTexture._(result[0], result[1], push);
    } catch (error) {
      debugPrint('webby: external texture unavailable, falling back to images ($error)');
      return null;
    }
  }

  void push(Pointer<Uint8> bgra, int width, int height) {
    if (!_disposed) _push(_handle, bgra, width, height);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _channel.invokeMethod<void>('dispose', _handle);
  }
}
