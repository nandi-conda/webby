import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webby_texture/webby_texture.dart';

import 'bindings.dart';
import 'frame_bench.dart';
import 'keys.dart';
import 'passwords/native.dart';

/// Drives one Ladybird view: pumps the event loop, hands presented frames to Flutter and exposes page state.
///
/// Frames go into an external texture (native memory straight to the engine). Where that isn't available, or with
/// WEBBY_TEXTURE=0, each frame is copied into Dart and decoded into an image instead.
class WebbyController extends ChangeNotifier {
  WebbyController({String initialUrl = 'https://ladybird.org', bool? useTexture}) : _pendingUrl = initialUrl {
    _bindings = WebbyBindings.open();
    if (useTexture ?? Platform.environment['WEBBY_TEXTURE'] != '0') {
      _texturePending = true;
      WebbyTexture.create().then((texture) {
        _texturePending = false;
        if (_disposed) {
          texture?.dispose();
        } else {
          _texture = texture;
        }
      });
    }
    // Pump Ladybird's event loop from the Dart thread; all FFI calls stay on this thread.
    _pumpTimer = Timer.periodic(const Duration(milliseconds: 4), (_) => _pump());
  }

  late final WebbyBindings _bindings;
  late final Timer _pumpTimer;
  ViewPtr _view = nullptr;
  String? _pendingUrl;
  bool _disposed = false;

  int _frameSerial = 0;
  int _stateSerial = -1;
  WebbyTexture? _texture;
  bool _texturePending = false;
  bool _decoding = false;
  ui.Image? _image;

  String url = '';
  String title = '';
  String hoveredLink = '';
  bool isLoading = false;
  bool canGoBack = false;
  bool canGoForward = false;
  int cursor = 0;

  /// Size in device pixels of the frame on screen (0 before the first one).
  int frameWidth = 0;
  int frameHeight = 0;
  final FrameStats stats = FrameStats();
  /// A passkey request waiting for the user (see `webby_view_webauthn_prompt` in webby_ffi.h), or null.
  Map<String, Object?>? webauthnPrompt;
  String _webauthnPromptJson = '';

  /// Messages from the browser's own page scripts (see `webby_view_set_message_prefix` in webby_ffi.h); none arrive
  /// until [messagePrefix] is set.
  Stream<String> get pageMessages => _pageMessages.stream;
  final _pageMessages = StreamController<String>.broadcast();
  late final PasswordNative _passwordNative = PasswordNative.of(_bindings);
  String _messagePrefix = '';
  String get messagePrefix => _messagePrefix;
  set messagePrefix(String prefix) {
    _messagePrefix = prefix;
    _applyMessagePrefix();
  }

  void _applyMessagePrefix() {
    final setPrefix = _passwordNative.setMessagePrefix;
    if (_view == nullptr || setPrefix == null) return;
    _withString(_messagePrefix, (s) => setPrefix(_view, s));
  }

  ui.Image? get image => _image;

  /// The texture to show once it has a frame; null when frames come as [image]s.
  int? get textureId => frameWidth > 0 ? _texture?.id : null;
  bool get isAttached => _view != nullptr;

  /// Creates the native view the first time the widget knows its size, then keeps it in sync.
  void setViewport(int width, int height, double devicePixelRatio) {
    if (width <= 0 || height <= 0) return;
    if (_view == nullptr) {
      _view = _bindings.viewCreate(width, height, devicePixelRatio);
      _applyMessagePrefix();
      if (_pendingUrl != null) {
        load(_pendingUrl!);
        _pendingUrl = null;
      }
      return;
    }
    _bindings.resize(_view, width, height, devicePixelRatio);
  }

  void load(String input) {
    if (_view == nullptr) {
      _pendingUrl = input;
      return;
    }
    _withString(input, (s) => _bindings.load(_view, s));
  }

  void goBack() => _ifAttached(_bindings.goBack);
  void goForward() => _ifAttached(_bindings.goForward);
  void reload() => _ifAttached(_bindings.reload);
  void stop() => _ifAttached(_bindings.stop);
  void setFocus(bool focused) => _ifAttached((v) => _bindings.setFocus(v, focused ? 1 : 0));
  void runJavaScript(String source) => _ifAttached((v) => _withString(source, (s) => _bindings.runJavaScript(v, s)));

  /// Answers [webauthnPrompt]: `accepted: false` cancels it; for a sign-in, [accountIndex] picks one of its accounts.
  void respondToWebAuthn({required bool accepted, int accountIndex = -1}) =>
      _ifAttached((v) => _bindings.webauthnRespond(v, accepted ? 1 : 0, accountIndex));

  void mouseEvent(int type, Offset position, {int button = 0, int buttons = 0, int modifiers = 0, int clickCount = 0}) =>
      _ifAttached((v) => _bindings.mouseEvent(
          v, type, position.dx.round(), position.dy.round(), button, buttons, modifiers, clickCount));

  void wheelEvent(Offset position, Offset delta, {bool precise = false, int modifiers = 0}) => _ifAttached(
      (v) => _bindings.wheelEvent(v, position.dx.round(), position.dy.round(), delta.dx, delta.dy, precise ? 1 : 0, modifiers));

  void keyEvent(bool down, int keyCode, int modifiers, int codePoint, bool repeat) =>
      _ifAttached((v) => _bindings.keyEvent(v, down ? 1 : 0, keyCode, modifiers, codePoint, repeat ? 1 : 0));

  void _ifAttached(void Function(ViewPtr) action) {
    if (_view != nullptr) action(_view);
  }

  void _withString(String value, void Function(Pointer<Utf8>) action) {
    final native = value.toNativeUtf8();
    try {
      action(native);
    } finally {
      malloc.free(native);
    }
  }

  void _pump() {
    _bindings.pump();
    if (_view == nullptr) return;

    final stateSerial = _bindings.stateSerial(_view);
    if (stateSerial != _stateSerial) {
      _stateSerial = stateSerial;
      url = _bindings.url(_view).toDartString();
      title = _bindings.title(_view).toDartString();
      hoveredLink = _bindings.hoveredLink(_view).toDartString();
      isLoading = _bindings.isLoading(_view) != 0;
      canGoBack = _bindings.canGoBack(_view) != 0;
      canGoForward = _bindings.canGoForward(_view) != 0;
      cursor = _bindings.cursor(_view);
      final prompt = _bindings.webauthnPrompt(_view).toDartString();
      if (prompt != _webauthnPromptJson) {
        _webauthnPromptJson = prompt;
        webauthnPrompt = prompt.isEmpty ? null : jsonDecode(prompt) as Map<String, Object?>;
      }
      notifyListeners();
    }

    final nextMessage = _passwordNative.nextMessage;
    if (nextMessage != null && _messagePrefix.isNotEmpty) {
      for (var message = nextMessage(_view).toDartString(); message.isNotEmpty; message = nextMessage(_view).toDartString()) {
        _pageMessages.add(message);
      }
    }

    // Until we know whether there's a texture, leave frames unread; the latest one goes wherever it ends up.
    if (_texturePending) return;
    final frameSerial = _bindings.frameSerial(_view);
    final texture = _texture;
    if (frameSerial == _frameSerial || (texture == null && _decoding)) return;
    _frameSerial = frameSerial;
    final width = _bindings.frameWidth(_view);
    final height = _bindings.frameHeight(_view);
    if (width <= 0 || height <= 0) return;
    final clock = Stopwatch()..start();

    if (texture != null) {
      // The plugin copies the frame into the texture before returning, so the native buffer can change after this.
      texture.push(_bindings.framePixels(_view), width, height);
      stats.add(clock.elapsedMicroseconds, 0);
      // The texture repaints itself; the widget only needs rebuilding when the frame size changes.
      if (width != frameWidth || height != frameHeight) {
        frameWidth = width;
        frameHeight = height;
        notifyListeners();
      }
      return;
    }

    // Copy now: the native buffer may be rewritten by the next pump while the image decodes.
    final pixels = Uint8List.fromList(_bindings.framePixels(_view).asTypedList(width * height * 4));
    final copyMicros = clock.elapsedMicroseconds;
    _decoding = true;
    ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.bgra8888, (image) {
      _decoding = false;
      stats.add(copyMicros, clock.elapsedMicroseconds);
      if (_disposed) {
        image.dispose();
        return;
      }
      _image?.dispose();
      _image = image;
      frameWidth = width;
      frameHeight = height;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pumpTimer.cancel();
    _texture?.dispose();
    _texture = null;
    if (_view != nullptr) {
      _bindings.viewDestroy(_view);
      _view = nullptr;
    }
    _image?.dispose();
    _pageMessages.close();
    super.dispose();
  }
}

/// Mouse button bits as Ladybird defines them (Web::UIEvents::MouseButton).
int _ladybirdButtons(int flutterButtons) {
  var result = 0;
  if (flutterButtons & kPrimaryMouseButton != 0) result |= 1;
  if (flutterButtons & kSecondaryMouseButton != 0) result |= 2;
  if (flutterButtons & kMiddleMouseButton != 0) result |= 4;
  if (flutterButtons & kBackMouseButton != 0) result |= 8;
  if (flutterButtons & kForwardMouseButton != 0) result |= 16;
  return result;
}

const _cursors = <int, MouseCursor>{
  1: SystemMouseCursors.none, // Hidden
  2: SystemMouseCursors.basic, // Arrow
  3: SystemMouseCursors.precise, // Crosshair
  4: SystemMouseCursors.text, // IBeam
  5: SystemMouseCursors.resizeLeftRight,
  6: SystemMouseCursors.resizeUpDown,
  7: SystemMouseCursors.resizeUpLeftDownRight,
  8: SystemMouseCursors.resizeUpRightDownLeft,
  9: SystemMouseCursors.resizeColumn,
  10: SystemMouseCursors.resizeRow,
  11: SystemMouseCursors.click, // Hand
  12: SystemMouseCursors.help,
  13: SystemMouseCursors.grab, // OpenHand
  14: SystemMouseCursors.grabbing, // Drag
  15: SystemMouseCursors.copy, // DragCopy
  16: SystemMouseCursors.move,
  17: SystemMouseCursors.wait,
  18: SystemMouseCursors.forbidden, // Disallowed
  19: SystemMouseCursors.precise, // Eyedropper
  20: SystemMouseCursors.zoomIn,
};

/// Shows a [WebbyController]'s page and forwards pointer and keyboard input to it.
class WebbyView extends StatefulWidget {
  const WebbyView({super.key, required this.controller, this.focusNode});

  final WebbyController controller;
  final FocusNode? focusNode;

  @override
  State<WebbyView> createState() => _WebbyViewState();
}

class _WebbyViewState extends State<WebbyView> {
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode(debugLabel: 'WebbyView');
  Size? _lastSize;
  double? _lastRatio;
  int _clickCount = 0;
  int _lastButtons = 0;
  Duration _lastDownTime = Duration.zero;
  Offset _lastDownPosition = Offset.zero;

  double get _ratio => MediaQuery.devicePixelRatioOf(context);
  Offset _toDevice(Offset local) => local * _ratio;

  int get _modifiers => modifiersFromKeyboard(HardwareKeyboard.instance);

  void _syncViewport(Size size) {
    final ratio = _ratio;
    if (size == _lastSize && ratio == _lastRatio) return;
    _lastSize = size;
    _lastRatio = ratio;
    final width = (size.width * ratio).round();
    final height = (size.height * ratio).round();
    // Resize after layout; creating/resizing the view can synchronously notify listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.setViewport(width, height, ratio);
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _focusNode.requestFocus();
    final isRepeat = event.timeStamp - _lastDownTime < const Duration(milliseconds: 500) &&
        (event.localPosition - _lastDownPosition).distance < 5;
    _clickCount = isRepeat ? _clickCount + 1 : 1;
    _lastDownTime = event.timeStamp;
    _lastDownPosition = event.localPosition;
    final buttons = _ladybirdButtons(event.buttons);
    final pressed = buttons & ~_lastButtons;
    _lastButtons = buttons;
    widget.controller.mouseEvent(0, _toDevice(event.localPosition),
        button: pressed == 0 ? buttons : pressed, buttons: buttons, modifiers: _modifiers, clickCount: _clickCount);
  }

  void _onPointerUp(PointerUpEvent event) {
    // Flutter reports the buttons still held; the released one is what was down before.
    final released = _lastButtons & ~_ladybirdButtons(event.buttons);
    _lastButtons = _ladybirdButtons(event.buttons);
    widget.controller.mouseEvent(1, _toDevice(event.localPosition),
        button: released == 0 ? 1 : released,
        buttons: _ladybirdButtons(event.buttons),
        modifiers: _modifiers,
        clickCount: _clickCount);
  }

  void _onPointerMove(PointerEvent event) {
    _lastButtons = _ladybirdButtons(event.buttons);
    widget.controller.mouseEvent(2, _toDevice(event.localPosition),
        buttons: _lastButtons, modifiers: _modifiers);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      widget.controller.wheelEvent(_toDevice(event.localPosition), _toDevice(event.scrollDelta),
          precise: event.kind == PointerDeviceKind.trackpad, modifiers: _modifiers);
    }
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    widget.controller.wheelEvent(_toDevice(event.localPosition), _toDevice(-event.localPanDelta),
        precise: true, modifiers: _modifiers);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final mapped = ladybirdKeyFor(event);
    if (mapped == null) return KeyEventResult.ignored;
    widget.controller.keyEvent(
        event is! KeyUpEvent, mapped.keyCode, _modifiers, mapped.codePoint, event is KeyRepeatEvent);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  Widget _page() {
    final controller = widget.controller;
    final textureId = controller.textureId;
    if (textureId != null) {
      // One device pixel per texel: size the texture to the frame rather than stretching it while a resize is in
      // flight.
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: controller.frameWidth / _ratio,
          height: controller.frameHeight / _ratio,
          child: Texture(textureId: textureId, filterQuality: FilterQuality.none),
        ),
      );
    }
    if (controller.image == null) return const SizedBox.shrink();
    return RawImage(
      image: controller.image,
      alignment: Alignment.topLeft,
      fit: BoxFit.none,
      scale: _ratio,
      filterQuality: FilterQuality.none,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _syncViewport(constraints.biggest);
      return Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKeyEvent,
        onFocusChange: widget.controller.setFocus,
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => MouseRegion(
            cursor: _cursors[widget.controller.cursor] ?? SystemMouseCursors.basic,
            onExit: (event) => widget.controller.mouseEvent(3, _toDevice(event.localPosition)),
            child: Listener(
              onPointerDown: _onPointerDown,
              onPointerUp: _onPointerUp,
              onPointerMove: _onPointerMove,
              onPointerHover: _onPointerMove,
              onPointerSignal: _onPointerSignal,
              onPointerPanZoomUpdate: _onPanZoomUpdate,
              child: ColoredBox(
                color: Colors.white,
                child: SizedBox.expand(child: _page()),
              ),
            ),
          ),
        ),
      );
    });
  }
}
