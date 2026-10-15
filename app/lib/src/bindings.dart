// dart:ffi bindings for native/webby_ffi.h (libwebby.so, built inside the Ladybird tree).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'android.dart';
import 'content_blocking.dart';

typedef ViewPtr = Pointer<Void>;

class WebbyBindings {
  WebbyBindings._(this.prefix, DynamicLibrary lib)
      : library = lib,
        imeState = lib.providesSymbol('webby_view_ime_state')
            ? lib.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>('webby_view_ime_state')
            : null,
        imeCommit = lib.providesSymbol('webby_view_ime_commit')
            ? lib.lookupFunction<Void Function(ViewPtr, Pointer<Utf8>, Int32, Int32),
                void Function(ViewPtr, Pointer<Utf8>, int, int)>('webby_view_ime_commit')
            : null,
        init = lib.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('webby_init'),
        pump = lib.lookupFunction<Int32 Function(), int Function()>('webby_pump'),
        viewCreate = lib.lookupFunction<ViewPtr Function(Int32, Int32, Double), ViewPtr Function(int, int, double)>(
            'webby_view_create'),
        viewDestroy = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_destroy'),
        load = lib.lookupFunction<Void Function(ViewPtr, Pointer<Utf8>), void Function(ViewPtr, Pointer<Utf8>)>(
            'webby_view_load'),
        goBack = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_go_back'),
        goForward = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_go_forward'),
        reload = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_reload'),
        stop = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_stop'),
        resize = lib.lookupFunction<Void Function(ViewPtr, Int32, Int32, Double), void Function(ViewPtr, int, int, double)>(
            'webby_view_resize'),
        setFocus = lib.lookupFunction<Void Function(ViewPtr, Int32), void Function(ViewPtr, int)>('webby_view_set_focus'),
        runJavaScript = lib.lookupFunction<Void Function(ViewPtr, Pointer<Utf8>), void Function(ViewPtr, Pointer<Utf8>)>(
            'webby_view_run_javascript'),
        frameSerial = lib.lookupFunction<Uint64 Function(ViewPtr), int Function(ViewPtr)>('webby_view_frame_serial'),
        framePixels = lib.lookupFunction<Pointer<Uint8> Function(ViewPtr), Pointer<Uint8> Function(ViewPtr)>(
            'webby_view_frame_pixels'),
        frameWidth = lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_frame_width'),
        frameHeight = lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_frame_height'),
        stateSerial = lib.lookupFunction<Uint64 Function(ViewPtr), int Function(ViewPtr)>('webby_view_state_serial'),
        url = lib.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>('webby_view_url'),
        title = lib.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>('webby_view_title'),
        hoveredLink = lib.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>(
            'webby_view_hovered_link'),
        isLoading = lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_is_loading'),
        canGoBack = lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_can_go_back'),
        canGoForward = lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_can_go_forward'),
        cursor = lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_cursor'),
        mouseEvent = lib.lookupFunction<Void Function(ViewPtr, Int32, Int32, Int32, Int32, Int32, Int32, Int32),
            void Function(ViewPtr, int, int, int, int, int, int, int)>('webby_view_mouse_event'),
        wheelEvent = lib.lookupFunction<Void Function(ViewPtr, Int32, Int32, Double, Double, Int32, Int32),
            void Function(ViewPtr, int, int, double, double, int, int)>('webby_view_wheel_event'),
        keyEvent = lib.lookupFunction<Void Function(ViewPtr, Int32, Int32, Int32, Uint32, Int32),
            void Function(ViewPtr, int, int, int, int, int)>('webby_view_key_event'),
        webauthnPrompt = lib.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>(
            'webby_view_webauthn_prompt'),
        webauthnRespond = lib.lookupFunction<Void Function(ViewPtr, Int32, Int32), void Function(ViewPtr, int, int)>(
            'webby_view_webauthn_respond');

  /// The Ladybird prefix (contains bin/, lib/, libexec/, share/Lagom).
  final String prefix;

  /// libwebby.so itself, for bindings that are looked up separately.
  final DynamicLibrary library;

  /// On-screen keyboard support (see webby_view_ime_state in webby_ffi.h); null with a runtime that predates it.
  final Pointer<Utf8> Function(ViewPtr)? imeState;
  final void Function(ViewPtr, Pointer<Utf8>, int, int)? imeCommit;

  final int Function(Pointer<Utf8>) init;
  final int Function() pump;
  final ViewPtr Function(int, int, double) viewCreate;
  final void Function(ViewPtr) viewDestroy;
  final void Function(ViewPtr, Pointer<Utf8>) load;
  final void Function(ViewPtr) goBack;
  final void Function(ViewPtr) goForward;
  final void Function(ViewPtr) reload;
  final void Function(ViewPtr) stop;
  final void Function(ViewPtr, int, int, double) resize;
  final void Function(ViewPtr, int) setFocus;
  final void Function(ViewPtr, Pointer<Utf8>) runJavaScript;
  final int Function(ViewPtr) frameSerial;
  final Pointer<Uint8> Function(ViewPtr) framePixels;
  final int Function(ViewPtr) frameWidth;
  final int Function(ViewPtr) frameHeight;
  final int Function(ViewPtr) stateSerial;
  final Pointer<Utf8> Function(ViewPtr) url;
  final Pointer<Utf8> Function(ViewPtr) title;
  final Pointer<Utf8> Function(ViewPtr) hoveredLink;
  final int Function(ViewPtr) isLoading;
  final int Function(ViewPtr) canGoBack;
  final int Function(ViewPtr) canGoForward;
  final int Function(ViewPtr) cursor;
  final void Function(ViewPtr, int, int, int, int, int, int, int) mouseEvent;
  final void Function(ViewPtr, int, int, double, double, int, int) wheelEvent;
  final void Function(ViewPtr, int, int, int, int, int) keyEvent;
  final Pointer<Utf8> Function(ViewPtr) webauthnPrompt;
  final void Function(ViewPtr, int, int) webauthnRespond;

  static WebbyBindings? _instance;

  /// Finds the Ladybird prefix, loads libwebby.so and starts Ladybird.
  ///
  /// Search order: $WEBBY_LADYBIRD_PREFIX, then `<executable dir>/lib/ladybird` (a bundled runtime). On Android the
  /// prefix is the one [AndroidHost.prepare] set up, and libwebby.so comes with the app's native libraries.
  static WebbyBindings open() {
    if (_instance != null) return _instance!;

    if (Platform.isAndroid) {
      final prefix = AndroidHost.ladybirdPrefix;
      if (prefix == null) throw StateError('Could not set up Ladybird: ${AndroidHost.prepareError}');
      return _instance = _start(prefix, DynamicLibrary.open('libwebby.so'));
    }

    final candidates = <String>[
      if (Platform.environment['WEBBY_LADYBIRD_PREFIX'] case final env? when env.isNotEmpty) env,
      '${File(Platform.resolvedExecutable).parent.path}/lib/ladybird',
    ];

    final tried = <String>[];
    for (final prefix in candidates) {
      final libraryPath = '$prefix/lib/libwebby.so';
      if (!File(libraryPath).existsSync()) {
        tried.add(libraryPath);
        continue;
      }
      return _instance = _start(prefix, DynamicLibrary.open(libraryPath));
    }
    throw StateError('libwebby.so not found. Set WEBBY_LADYBIRD_PREFIX to the Ladybird build prefix.\n'
        'Tried:\n  ${tried.join('\n  ')}');
  }

  static WebbyBindings _start(String prefix, DynamicLibrary library) {
    final bindings = WebbyBindings._(prefix, library);
    ContentBlocking.prepareEngine();
    final prefixUtf8 = prefix.toNativeUtf8();
    final result = bindings.init(prefixUtf8);
    malloc.free(prefixUtf8);
    if (result != 0) {
      throw StateError('webby_init failed ($result) for Ladybird prefix $prefix');
    }
    return bindings;
  }
}
