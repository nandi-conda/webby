import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' show Random;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flatkit/flatkit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webby_texture/webby_texture.dart';

import 'bindings.dart';
import 'context_menu.dart';
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

  /// The page's focused text field (see `webby_view_ime_state` in webby_ffi.h), or null when nothing editable has
  /// focus or the runtime can't tell.
  PageTextField? textField;
  String _textFieldJson = '';

  /// Messages from the browser's own page scripts (see `webby_view_set_message_prefix` in webby_ffi.h). Every page
  /// script shares one prefix (random per view unless set, so pages can't guess it) and tells its messages apart by
  /// their JSON "type".
  Stream<String> get pageMessages => _pageMessages.stream;
  final _pageMessages = StreamController<String>.broadcast();
  late final PasswordNative _passwordNative = PasswordNative.of(_bindings);
  String _messagePrefix = _randomPrefix();
  String get messagePrefix => _messagePrefix;
  set messagePrefix(String prefix) {
    _messagePrefix = prefix;
    _applyMessagePrefix();
  }

  static String _randomPrefix() {
    final random = Random.secure();
    return '\u0001webby:${base64UrlEncode(List<int>.generate(12, (_) => random.nextInt(256)))}:';
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

  /// Types [text] from an on-screen keyboard, first replacing [replaceLength] UTF-16 units that start [replaceStart]
  /// units from the caret (negative: before it).
  void commitText(String text, {int replaceStart = 0, int replaceLength = 0}) {
    final commit = _bindings.imeCommit;
    if (commit == null) return;
    _ifAttached((v) => _withString(text, (s) => commit(v, s, replaceStart, replaceLength)));
  }

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

  // Ladybird has one event loop for every view; with several tabs, one pump per tick is enough.
  static final _pumpClock = Stopwatch()..start();
  static int _lastPumpMicros = -1000000;

  void _pump() {
    final now = _pumpClock.elapsedMicroseconds;
    if (now - _lastPumpMicros >= 3000) {
      _lastPumpMicros = now;
      _bindings.pump();
    }
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
      final imeState = _bindings.imeState;
      if (imeState != null) {
        final json = imeState(_view).toDartString();
        if (json != _textFieldJson) {
          _textFieldJson = json;
          final state = jsonDecode(json) as Map<String, Object?>;
          textField = state['enabled'] == true
              ? PageTextField(before: state['before'] as String? ?? '', after: state['after'] as String? ?? '')
              : null;
        }
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

/// The text around the caret in the page's focused text field.
class PageTextField {
  const PageTextField({required this.before, required this.after});
  final String before;
  final String after;
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
  const WebbyView({super.key, required this.controller, this.focusNode, this.isBrowserShortcut, this.onOpenInNewTab});

  final WebbyController controller;
  final FocusNode? focusNode;

  /// Keys the browser keeps for itself (Ctrl+D...): they aren't sent to the page and bubble up to the app's shortcuts.
  final bool Function(KeyEvent event)? isBrowserShortcut;

  /// Opens a URL in a new tab, for the context menu's "Open link in new tab". Without it those rows open in this view.
  final void Function(String url)? onOpenInNewTab;

  @override
  State<WebbyView> createState() => _WebbyViewState();
}

class _WebbyViewState extends State<WebbyView> with TextInputClient {
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode(debugLabel: 'WebbyView');
  late ContextMenuAgent _contextMenu;
  Size? _lastSize;
  double? _lastRatio;
  int _clickCount = 0;
  int _lastButtons = 0;
  Duration _lastDownTime = Duration.zero;
  Offset _lastDownPosition = Offset.zero;

  // A right-click waiting for the page's report: where it was (global) and a timer that shows a plain menu if the
  // page never reports it (Shift+right-click skips the page, and some pages can't run the script).
  Offset? _menuPosition;
  Timer? _menuFallback;
  // The flatkit menu hangs off a zero-size anchor placed where the user right-clicked.
  List<KitMenuEntry> _menuItems = const [];
  Offset _menuAnchor = Offset.zero;
  VoidCallback? _toggleMenu;
  bool _menuOpen = false;

  // Touch: a tap clicks, a drag scrolls the page (and flings it on release).
  int? _touchPointer;
  Offset _touchStart = Offset.zero;
  Offset _touchLast = Offset.zero;
  bool _touchScrolling = false;
  VelocityTracker? _touchVelocity;
  Timer? _fling;

  // On-screen keyboard: connected while a text field in the page has focus.
  static final bool _softKeyboard = Platform.isAndroid || Platform.isIOS;
  TextInputConnection? _input;
  TextEditingValue _inputValue = TextEditingValue.empty;
  DateTime _lastInputEdit = DateTime.fromMillisecondsSinceEpoch(0);


  double get _ratio => MediaQuery.devicePixelRatioOf(context);
  Offset _toDevice(Offset local) => local * _ratio;

  int get _modifiers => modifiersFromKeyboard(HardwareKeyboard.instance);

  @override
  void initState() {
    super.initState();
    _contextMenu = ContextMenuAgent(widget.controller, onRequest: _onContextMenuRequest);
    if (_softKeyboard) {
      widget.controller.addListener(_syncTextInput);
      _focusNode.addListener(_syncTextInput);
    }
  }

  @override
  void didUpdateWidget(WebbyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _contextMenu.dispose();
      _contextMenu = ContextMenuAgent(widget.controller, onRequest: _onContextMenuRequest);
      _cancelContextMenu();
    }
  }

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
    if (event.kind == PointerDeviceKind.touch) {
      _touchDown(event);
      return;
    }
    final isRepeat = event.timeStamp - _lastDownTime < const Duration(milliseconds: 500) &&
        (event.localPosition - _lastDownPosition).distance < 5;
    _clickCount = isRepeat ? _clickCount + 1 : 1;
    _lastDownTime = event.timeStamp;
    _lastDownPosition = event.localPosition;
    final buttons = _ladybirdButtons(event.buttons);
    final pressed = buttons & ~_lastButtons;
    _lastButtons = buttons;
    if (pressed & 2 != 0) _expectContextMenu(event.position);
    widget.controller.mouseEvent(0, _toDevice(event.localPosition),
        button: pressed == 0 ? buttons : pressed, buttons: buttons, modifiers: _modifiers, clickCount: _clickCount);
  }

  // Ladybird fires the page's contextmenu event on the right button's press; the page script reports it right after.
  void _expectContextMenu(Offset position) {
    _menuFallback?.cancel();
    _menuPosition = position;
    _menuFallback = Timer(const Duration(milliseconds: 400), () => _showContextMenu(null));
  }

  void _cancelContextMenu() {
    _menuFallback?.cancel();
    _menuFallback = null;
    _menuPosition = null;
  }

  void _onContextMenuRequest(ContextMenuTarget target) {
    // Only right-clicks the user made here open a menu; a report without one is ignored.
    if (_menuPosition == null) return;
    if (target.prevented) {
      _cancelContextMenu();
      return;
    }
    _showContextMenu(target);
  }

  Future<void> _showContextMenu(ContextMenuTarget? target) async {
    final position = _menuPosition;
    _cancelContextMenu();
    if (position == null || !mounted) return;
    final items = await contextMenuItems(context,
        controller: widget.controller,
        target: target,
        onOpenInNewTab: widget.onOpenInNewTab,
        afterAction: () => _focusNode.requestFocus());
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    // A menu that is still open from the last right-click closes first, then opens again at the new spot.
    if (_menuOpen) _toggleMenu?.call();
    setState(() {
      _menuItems = items;
      _menuAnchor = box.globalToLocal(position);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_menuOpen) _toggleMenu?.call();
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _touchUp(event);
      return;
    }
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
    if (event.kind == PointerDeviceKind.touch) {
      if (event is PointerMoveEvent) _touchMove(event);
      return;
    }
    _lastButtons = _ladybirdButtons(event.buttons);
    widget.controller.mouseEvent(2, _toDevice(event.localPosition),
        buttons: _lastButtons, modifiers: _modifiers);
  }

  void _touchDown(PointerDownEvent event) {
    // One finger at a time; pinch zoom isn't supported.
    if (_touchPointer != null) return;
    _stopFling();
    _touchPointer = event.pointer;
    _touchStart = _touchLast = event.localPosition;
    _touchScrolling = false;
    _touchVelocity = VelocityTracker.withKind(PointerDeviceKind.touch)..addPosition(event.timeStamp, event.localPosition);
  }

  void _touchMove(PointerMoveEvent event) {
    if (event.pointer != _touchPointer) return;
    _touchVelocity?.addPosition(event.timeStamp, event.localPosition);
    if (!_touchScrolling && (event.localPosition - _touchStart).distance < kTouchSlop) return;
    _touchScrolling = true;
    _scrollBy(event.localPosition, _touchLast - event.localPosition);
    _touchLast = event.localPosition;
  }

  void _touchUp(PointerUpEvent event) {
    if (event.pointer != _touchPointer) return;
    _touchPointer = null;
    if (_touchScrolling) {
      _startFling(event.localPosition, _touchVelocity?.getVelocity().pixelsPerSecond ?? Offset.zero);
      return;
    }
    // A tap: click where the finger went down.
    final position = _toDevice(_touchStart);
    final controller = widget.controller;
    controller.mouseEvent(2, position);
    controller.mouseEvent(0, position, button: 1, buttons: 1, clickCount: 1);
    controller.mouseEvent(1, position, button: 1, clickCount: 1);
    // Tapping a field that already has focus brings back a keyboard the user dismissed.
    _input?.show();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _touchPointer) _touchPointer = null;
  }

  /// Scrolls by [delta] logical pixels, as a trackpad would.
  void _scrollBy(Offset position, Offset delta) =>
      widget.controller.wheelEvent(_toDevice(position), _toDevice(delta), precise: true);

  void _startFling(Offset position, Offset velocity) {
    if (velocity.distance < 200) return;
    // The page moves with the finger, so it scrolls against the finger's direction.
    var speed = -velocity;
    _fling = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      speed *= 0.95;
      if (speed.distance < 60) {
        _stopFling();
        return;
      }
      _scrollBy(position, speed * 0.016);
    });
  }

  void _stopFling() {
    _fling?.cancel();
    _fling = null;
  }

  /// Opens the on-screen keyboard while the page has a text field focused, and closes it otherwise.
  void _syncTextInput() {
    final field = _focusNode.hasFocus ? widget.controller.textField : null;
    if (field == null) {
      _input?.close();
      _input = null;
      return;
    }
    final value = TextEditingValue(
        text: field.before + field.after, selection: TextSelection.collapsed(offset: field.before.length));
    final input = _input;
    if (input == null || !input.attached) {
      _inputValue = value;
      _input = TextInput.attach(this, const TextInputConfiguration(inputAction: TextInputAction.go, autocorrect: false))
        ..setEditingState(value)
        ..show();
      return;
    }
    // The page changed the field by itself (a script, or another field took focus). While the user types, the page
    // lags behind the keyboard, so only catch up once typing pauses.
    if (value.text != _inputValue.text && DateTime.now().difference(_lastInputEdit) > const Duration(milliseconds: 500)) {
      _inputValue = value;
      input.setEditingState(value);
    }
  }

  void _pressKey(int keyCode, int codePoint) {
    widget.controller.keyEvent(true, keyCode, 0, codePoint, false);
    widget.controller.keyEvent(false, keyCode, 0, 0, false);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _inputValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    final old = _inputValue;
    _inputValue = value;
    if (value.text == old.text) return;
    _lastInputEdit = DateTime.now();

    // The keyboard sends whole values; find the span that changed (longest common prefix and suffix).
    final before = old.text, after = value.text;
    final shorter = before.length < after.length ? before.length : after.length;
    var start = 0;
    while (start < shorter && before.codeUnitAt(start) == after.codeUnitAt(start)) {
      start++;
    }
    var oldEnd = before.length, newEnd = after.length;
    while (oldEnd > start && newEnd > start && before.codeUnitAt(oldEnd - 1) == after.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    final caret = old.selection.isValid ? old.selection.extentOffset : before.length;
    final inserted = after.substring(start, newEnd);
    if (inserted.isEmpty && oldEnd == caret) {
      // Deleting just before the caret: Backspace works in every kind of field.
      for (var i = before.substring(start, oldEnd).characters.length; i > 0; i--) {
        _pressKey(0x08, 0);
      }
      return;
    }
    widget.controller.commitText(inserted, replaceStart: start - caret, replaceLength: oldEnd - start);
  }

  @override
  void performAction(TextInputAction action) => _pressKey(0x0D, 0x0A);

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() => _input = null;

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
    if (widget.isBrowserShortcut?.call(event) ?? false) return KeyEventResult.ignored;
    final mapped = ladybirdKeyFor(event);
    if (mapped == null) return KeyEventResult.ignored;
    widget.controller.keyEvent(
        event is! KeyUpEvent, mapped.keyCode, _modifiers, mapped.codePoint, event is KeyRepeatEvent);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _cancelContextMenu();
    _contextMenu.dispose();
    _stopFling();
    if (_softKeyboard) {
      widget.controller.removeListener(_syncTextInput);
      _focusNode.removeListener(_syncTextInput);
    }
    _input?.close();
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
              onPointerCancel: _onPointerCancel,
              onPointerSignal: _onPointerSignal,
              onPointerPanZoomUpdate: _onPanZoomUpdate,
              child: ColoredBox(
                color: Colors.white,
                child: Stack(children: [
                  Positioned.fill(child: _page()),
                  Positioned(
                    left: _menuAnchor.dx,
                    top: _menuAnchor.dy,
                    child: KitMenu(
                      minWidth: 200,
                      items: () => _menuItems,
                      builder: (context, toggle, open) {
                        _toggleMenu = toggle;
                        _menuOpen = open;
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    });
  }
}
