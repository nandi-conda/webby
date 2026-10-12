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
import 'clipboard.dart';
import 'color_scheme.dart';
import 'context_menu.dart';
import 'file_picker.dart';
import 'geolocation.dart';
import 'frame_bench.dart';
import 'keys.dart';
import 'page_compat.dart';
import 'page_dialogs.dart';
import 'passwords/native.dart';
import 'site_permissions.dart';

/// Drives one Ladybird view: pumps the event loop, hands presented frames to Flutter and exposes page state.
///
/// Frames go into an external texture (native memory straight to the engine). Where that isn't available, or with
/// WEBBY_TEXTURE=0, each frame is copied into Dart and decoded into an image instead.
class WebbyController extends ChangeNotifier {
  WebbyController({String initialUrl = 'https://ladybird.org', bool? useTexture}) : _pendingUrl = initialUrl {
    // Shown (address bar, tab title) until the page reports its own, so a tab opened on a link isn't taken for a
    // blank new tab.
    url = initialUrl;
    _start(useTexture);
  }

  /// A tab that shows [url] and [title] but loads nothing until it is first shown (a restored background tab), so
  /// reopening many tabs doesn't start a WebContent process for each.
  WebbyController.unloaded(this.url, {this.title = ''}) : _pendingUrl = url {
    _visible = false;
    _discarded = true;
    _start(null);
  }

  /// Takes over a view the page opened (see [onNewView]); it is already loading.
  WebbyController.adopt(ViewPtr view, {bool? useTexture}) : _pendingUrl = null {
    _start(useTexture);
    _view = view;
    _applyMessagePrefix();
    _applyVisible();
    _colorScheme = PageColorScheme.follow(_bindings, () => _view);
  }

  void _start(bool? useTexture) {
    _bindings = WebbyBindings.open();
    // The texture plugin is Linux-only; Android shows frames as images.
    _useTexture = useTexture ?? (!Platform.isAndroid && Platform.environment['WEBBY_TEXTURE'] != '0');
    if (_useTexture) _createTexture();
    // Pump Ladybird's event loop from the Dart thread; all FFI calls stay on this thread.
    _live.add(this);
    _startTrace();
    _wake();
  }

  // WEBBY_TRACE=1: every 5 s, print how often the pump ran and what each view did, to find what keeps the CPU busy.
  static Timer? _trace;
  static int _pumps = 0;
  static int _dartFrames = 0;
  static void _startTrace() {
    if (_trace != null || Platform.environment['WEBBY_TRACE'] != '1') return;
    WidgetsBinding.instance.addPersistentFrameCallback((_) => _dartFrames++);
    final pushed = <WebbyController, int>{};
    _trace = Timer.periodic(const Duration(seconds: 5), (_) {
      final views = _live.map((c) {
        final frames = c.stats.frames - (pushed[c] ?? 0);
        pushed[c] = c.stats.frames;
        return '${c._visible ? 'shown' : 'hidden'}${c.isLoading ? ' loading' : ''} frames=$frames';
      });
      stderr.writeln('webby-trace pumps=$_pumps dartFrames=$_dartFrames delay=${_pumpDelay.inMilliseconds}ms '
          '[${views.join('; ')}]');
      _pumps = _dartFrames = 0;
      // What the shown pages are animating.
      for (final c in _live.where((c) => c._visible && c._messagePrefix.isNotEmpty)) {
        if (!_traced.contains(c)) {
          _traced.add(c);
          c.pageMessages.where((m) => m.startsWith('{"type":"trace"')).listen((m) => stderr.writeln('webby-trace page $m'));
        }
        c.runJavaScript('''(() => { try { const a = document.getAnimations().map(a => {
          const t = a.effect && a.effect.target; return (a.animationName || a.transitionProperty || a.constructor.name) +
          '@' + (t ? t.tagName + '.' + String(t.className).slice(0, 40) : '?') + ':' + a.playState; });
          window.prompt(${jsonEncode(c._messagePrefix)} + JSON.stringify({type: 'trace', url: location.href,
          animations: a.slice(0, 12), count: a.length})); } catch (e) {} })()''');
      }
    });
  }
  static final Set<WebbyController> _traced = {};

  /// Called with each view the page opens (a target=_blank link, window.open()); the receiver owns the controller.
  /// Without a listener such views are closed at once rather than left running unseen.
  void Function(WebbyController controller)? onNewView;

  /// Set once the page called window.close().
  bool closeRequested = false;

  late final WebbyBindings _bindings;
  late final bool _useTexture;
  ViewPtr _view = nullptr;
  // The last size given to setViewport, so a discarded view can be recreated at that size.
  ({int width, int height, double ratio})? _viewport;
  bool _visible = true;
  bool _discarded = false;
  Timer? _releaseFrames;
  VoidCallback? _colorScheme;
  String? _pendingUrl;
  bool _disposed = false;

  int _frameSerial = 0;
  int _stateSerial = -1;
  int _lastCompatMicros = 0;

  /// More page scripts to run alongside [pageCompatScript]: as soon as navigation starts and every so often while a
  /// page loads, so they land before most of the page's own scripts look for what they provide. Each returns the
  /// script for the page as it is now, or '' for none; the scripts must be safe to run more than once.
  final List<String Function()> pageScripts = [];
  WebbyTexture? _texture;
  bool _texturePending = false;
  bool _decoding = false;
  ui.Image? _image;

  String url = '';
  String title = '';
  String hoveredLink = '';

  /// Whether the page's pointer was last put there by a tap rather than a mouse; [hoveredLink] then only says what
  /// was tapped last, so there is no link preview to show.
  bool pointerIsTouch = false;
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
  late final ClipboardBridge _clipboard = ClipboardBridge.of(_bindings);
  late final PageFilePicker? _filePicker = PageFilePicker.of(_bindings);
  late final PagePermissions? _permissions = PagePermissions.of(_bindings)?..allowedThisTime = _allowedThisTime;
  late final LocationBridge? _location = LocationBridge.of(_bindings);
  late final PageDialogs? _dialogs = PageDialogs.of(_bindings);

  /// The page's alert(), confirm() or prompt() waiting for the user, or null.
  PageDialog? get dialog => _dialogs?.current;

  /// Answers [dialog] with that id: OK or Cancel, and for a prompt what the user typed.
  void respondToDialog(int id, {required bool accepted, String? text}) {
    final dialogs = _dialogs;
    if (dialogs == null) return;
    _ifAttached((v) => dialogs.respond(v, id, accepted: accepted, text: text));
  }

  /// A site's request for a permission (such as the location) waiting for the user, or null. Requests the user
  /// already answered for the site are answered without showing up here.
  PermissionRequest? get permissionRequest => _permissions?.request ?? _asks.firstOrNull?.$1;

  /// "Allow this time" answers, by "origin permission"; they last as long as the tab.
  final Set<String> _allowedThisTime = {};

  /// Requests from the browser's own page scripts (see [askPermission]), oldest first.
  final List<(PermissionRequest, Completer<bool>)> _asks = [];
  int _askIds = 0;

  /// What [origin] may do with [permission] in this tab: a remembered answer, or allow after "Allow this time".
  PermissionSetting permissionFor(String origin, String permission) => _allowedThisTime.contains('$origin $permission')
      ? PermissionSetting.allow
      : SitePermissionStore.instance.get(origin, permission);

  /// Asks the user, like the engine's own requests, whether [origin] may use [permission] (for features the
  /// browser's page scripts provide, such as notifications). Completes at once when the site was answered before.
  Future<bool> askPermission(String origin, String permission) {
    final setting = permissionFor(origin, permission);
    if (setting != PermissionSetting.ask) return Future.value(setting == PermissionSetting.allow);
    final waiting = _asks.where((a) => a.$1.origin == origin && a.$1.permission == permission).firstOrNull;
    if (waiting != null) return waiting.$2.future;
    final completer = Completer<bool>();
    _asks.add((PermissionRequest(id: --_askIds, permission: permission, origin: origin), completer));
    notifyListeners();
    return completer.future;
  }
  // Set while a paste waits for the system clipboard; key events that come meanwhile queue up behind it.
  Future<void>? _pendingPaste;
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

  /// Whether this view is on screen. Background tabs are hidden: the page is told so (it stops rendering, see
  /// `webby_view_set_visible`), no frames are copied out, and after [_frameGrace] its texture and frame copies are
  /// freed. Showing it again pushes the last frame straight away.
  bool get visible => _visible;
  set visible(bool value) {
    if (value == _visible) return;
    _visible = value;
    if (value) {
      _releaseFrames?.cancel();
      _releaseFrames = null;
      if (_discarded) _restore();
      if (_useTexture && _texture == null && !_texturePending) _createTexture();
      // Re-read the frame Ladybird already has, even if it hasn't changed since the tab was hidden.
      _frameSerial = -1;
    } else {
      _releaseFrames ??= Timer(_frameGrace, _freeFrames);
    }
    _applyVisible();
    _wake();
  }

  /// How long a hidden view keeps its texture, so quickly flipping between tabs doesn't flash.
  static const _frameGrace = Duration(seconds: 10);

  /// Whether the native view (and its WebContent process) was thrown away to save memory; see [discard].
  bool get isDiscarded => _discarded;

  /// Throws away a hidden view's page and WebContent process, keeping [url] and [title] for the tab strip. Showing
  /// the view again loads [url] afresh (scroll position, form contents and back/forward history are lost).
  void discard() {
    if (_visible || _discarded || _view == nullptr || _disposed) return;
    _discarded = true;
    _pendingUrl = url;
    PageColorScheme.unfollow(_colorScheme);
    _colorScheme = null;
    _bindings.viewDestroy(_view);
    _view = nullptr;
    _stateSerial = -1;
    isLoading = false;
    webauthnPrompt = null;
    _webauthnPromptJson = '';
    _permissions?.reset();
    _dialogs?.reset();
    _freeFrames();
    notifyListeners();
  }

  void _restore() {
    _discarded = false;
    final viewport = _viewport;
    if (viewport != null) _attach(viewport.width, viewport.height, viewport.ratio);
  }

  void _createTexture() {
    _texturePending = true;
    WebbyTexture.create().then((texture) {
      _texturePending = false;
      if (_disposed || !_visible) {
        texture?.dispose();
      } else {
        _texture = texture;
        _frameSerial = -1;
      }
    });
  }

  void _freeFrames() {
    _releaseFrames?.cancel();
    _releaseFrames = null;
    if (_visible) return;
    _texture?.dispose();
    _texture = null;
    _image?.dispose();
    _image = null;
    frameWidth = 0;
    frameHeight = 0;
    // A page that was just put away won't be looked at for a while: give back what its scripts left behind now
    // rather than whenever it next allocates enough to trigger a collection.
    collectGarbage();
  }

  static bool _collectLooked = false;
  static void Function(ViewPtr)? _collect;

  /// Asks the page's JavaScript heap to collect garbage now (see `webby_view_collect_garbage` in webby_ffi.h).
  /// Does nothing on runtimes without it.
  void collectGarbage() {
    if (_view == nullptr) return;
    if (!_collectLooked) {
      _collectLooked = true;
      final lib = _bindings.library;
      if (lib.providesSymbol('webby_view_collect_garbage')) {
        _collect = lib.lookupFunction<Void Function(ViewPtr), void Function(ViewPtr)>('webby_view_collect_garbage');
      }
    }
    _collect?.call(_view);
  }

  /// [collectGarbage] on every live page, for when the system runs short of memory.
  static void collectAllGarbage() {
    for (final controller in _live) {
      controller.collectGarbage();
    }
  }

  static bool _visibleLooked = false;
  static void Function(ViewPtr, int)? _setVisible;
  static ViewPtr Function(ViewPtr)? _takeNewView;
  static int Function(ViewPtr)? _closeRequested;

  void _takeNewViews() {
    final take = _takeNewView;
    if (take == null) return;
    for (var view = take(_view); view != nullptr; view = take(_view)) {
      final listener = onNewView;
      if (listener == null) {
        _bindings.viewDestroy(view);
      } else {
        listener(WebbyController.adopt(view));
      }
    }
  }

  void _applyVisible() {
    if (_view == nullptr) return;
    if (!_visibleLooked) {
      _visibleLooked = true;
      // Runtimes older than webby_view_set_visible keep hidden pages rendering; frames are still not copied out.
      final lib = _bindings.library;
      if (lib.providesSymbol('webby_view_set_visible')) {
        _setVisible = lib.lookupFunction<Void Function(ViewPtr, Int32), void Function(ViewPtr, int)>(
          'webby_view_set_visible',
        );
      }
      if (lib.providesSymbol('webby_view_take_new_view')) {
        _takeNewView = lib.lookupFunction<ViewPtr Function(ViewPtr), ViewPtr Function(ViewPtr)>('webby_view_take_new_view');
        _closeRequested =
            lib.lookupFunction<Int32 Function(ViewPtr), int Function(ViewPtr)>('webby_view_close_requested');
      }
    }
    _setVisible?.call(_view, _visible ? 1 : 0);
  }

  /// Creates the native view the first time the widget knows its size, then keeps it in sync.
  void setViewport(int width, int height, double devicePixelRatio) {
    if (width <= 0 || height <= 0) return;
    _viewport = (width: width, height: height, ratio: devicePixelRatio);
    if (_discarded) return;
    if (_view == nullptr) {
      _attach(width, height, devicePixelRatio);
      return;
    }
    _bindings.resize(_view, width, height, devicePixelRatio);
    _wake();
  }

  void _attach(int width, int height, double devicePixelRatio) {
    _view = _bindings.viewCreate(width, height, devicePixelRatio);
    if (_view == nullptr) return;
    _applyMessagePrefix();
    _applyVisible();
    _colorScheme = PageColorScheme.follow(_bindings, () => _view);
    if (_pendingUrl != null) {
      load(_pendingUrl!);
      _pendingUrl = null;
    }
  }

  void load(String input) {
    if (_view == nullptr) {
      _pendingUrl = input;
      return;
    }
    _withString(input, (s) => _bindings.load(_view, s));
    _wake();
  }

  void goBack() => _ifAttached(_bindings.goBack);
  void goForward() => _ifAttached(_bindings.goForward);
  void reload() => _ifAttached(_bindings.reload);
  void stop() => _ifAttached(_bindings.stop);
  void setFocus(bool focused) {
    _ifAttached((v) => _bindings.setFocus(v, focused ? 1 : 0));
    // Let navigator.clipboard.read*() see what was copied in other apps.
    if (focused) _clipboard.pullSystemClipboard();
  }

  void runJavaScript(String source) => _ifAttached((v) => _withString(source, (s) => _bindings.runJavaScript(v, s)));

  /// Answers [webauthnPrompt]: `accepted: false` cancels it; for a sign-in, [accountIndex] picks one of its accounts.
  void respondToWebAuthn({required bool accepted, int accountIndex = -1}) =>
      _ifAttached((v) => _bindings.webauthnRespond(v, accepted ? 1 : 0, accountIndex));

  /// Answers [permissionRequest]. [remember] keeps the answer for the site; an allow without it lasts for this tab.
  void answerPermission({required bool allow, required bool remember}) {
    final permissions = _permissions;
    if (permissions != null && permissions.request != null) {
      _ifAttached((v) => permissions.answer(v, allow: allow, remember: remember));
      permissions.request = null;
      notifyListeners();
      return;
    }
    if (_asks.isEmpty) return;
    final (request, completer) = _asks.removeAt(0);
    if (remember) {
      SitePermissionStore.instance
          .set(request.origin, request.permission, allow ? PermissionSetting.allow : PermissionSetting.block);
    } else if (allow) {
      _allowedThisTime.add('${request.origin} ${request.permission}');
    }
    completer.complete(allow);
    notifyListeners();
  }

  /// Forgets this tab's "allow this time" answers for [origin].
  void forgetPermissions(String origin) => _allowedThisTime.removeWhere((key) => key.startsWith('$origin '));

  void mouseEvent(int type, Offset position, {int button = 0, int buttons = 0, int modifiers = 0, int clickCount = 0}) =>
      _ifAttached((v) => _bindings.mouseEvent(
          v, type, position.dx.round(), position.dy.round(), button, buttons, modifiers, clickCount));

  void wheelEvent(Offset position, Offset delta, {bool precise = false, int modifiers = 0}) => _ifAttached(
      (v) => _bindings.wheelEvent(v, position.dx.round(), position.dy.round(), delta.dx, delta.dy, precise ? 1 : 0, modifiers));

  void keyEvent(bool down, int keyCode, int modifiers, int codePoint, bool repeat) {
    void send() => _ifAttached((v) => _bindings.keyEvent(v, down ? 1 : 0, keyCode, modifiers, codePoint, repeat ? 1 : 0));
    // Ladybird pastes from its own clipboard on Ctrl+V, so give it the system clipboard's text first.
    final isPaste = down && keyCode == 0x56 && modifiers & (modAlt | modCtrl | modShift | modSuper) == modCtrl;
    if (isPaste && _clipboard.isSupported) {
      _afterPendingPaste(() => _clipboard.pullSystemClipboard().then((_) => send()));
    } else if (_pendingPaste != null) {
      _afterPendingPaste(send);
    } else {
      send();
    }
  }

  void _afterPendingPaste(FutureOr<void> Function() step) {
    late final Future<void> next;
    next = (_pendingPaste ?? Future<void>.value()).then((_) => step()).whenComplete(() {
      if (identical(_pendingPaste, next)) _pendingPaste = null;
    });
    _pendingPaste = next;
  }

  /// Types [text] from an on-screen keyboard, first replacing [replaceLength] UTF-16 units that start [replaceStart]
  /// units from the caret (negative: before it).
  void commitText(String text, {int replaceStart = 0, int replaceLength = 0}) {
    final commit = _bindings.imeCommit;
    if (commit == null) return;
    _ifAttached((v) => _withString(text, (s) => commit(v, s, replaceStart, replaceLength)));
  }

  void _ifAttached(void Function(ViewPtr) action) {
    if (_view != nullptr) {
      action(_view);
      _wake();
    }
  }

  void _withString(String value, void Function(Pointer<Utf8>) action) {
    final native = value.toNativeUtf8();
    try {
      action(native);
    } finally {
      malloc.free(native);
    }
  }

  // Ladybird has one event loop for every view, pumped by one timer for all tabs. It ticks every 4 ms while anything
  // is happening (events, frames, loading, input) and backs off to [_idleTick] once things go quiet, so an idle
  // browser doesn't wake the CPU 250 times a second per tab. Any call into a view ([_ifAttached]) speeds it up again.
  static final _pumpClock = Stopwatch()..start();
  static final Set<WebbyController> _live = {};
  static Timer? _pumpTimer;
  static Duration _pumpDelay = Duration.zero;
  static int _quietTicks = 0;
  static WebbyBindings? _pumpBindings;
  static const _busyTick = Duration(milliseconds: 4);
  static const _idleTick = Duration(milliseconds: 100);

  /// Back to fast ticking now, e.g. after input was sent to a page.
  static void _wake() {
    _quietTicks = 0;
    if (_pumpTimer != null && _pumpDelay <= _busyTick) return;
    _pumpTimer?.cancel();
    _schedulePump(_busyTick);
  }

  static void _schedulePump(Duration delay) {
    _pumpDelay = delay;
    _pumpTimer = Timer(delay, _pumpAll);
  }

  static void _pumpAll() {
    _pumpTimer = null;
    _pumps++;
    if (_live.isEmpty) return;
    final bindings = _pumpBindings ??= _live.first._bindings;
    var busy = bindings.pump() > 0;
    final first = _live.first;
    first._clipboard.pushPageCopies();
    first._location?.poll();
    for (final controller in _live.toList()) {
      if (_live.contains(controller) && controller._pump()) busy = true;
    }
    if (_live.isEmpty) return;
    _quietTicks = busy ? 0 : _quietTicks + 1;
    // About a quarter second of quiet at full speed, then progressively slower.
    final delay = _quietTicks < 60
        ? _busyTick
        : _quietTicks < 80
        ? const Duration(milliseconds: 16)
        : _quietTicks < 100
        ? const Duration(milliseconds: 50)
        : _idleTick;
    if (_pumpTimer == null) _schedulePump(delay);
  }

  void _runPageCompat() {
    _lastCompatMicros = _pumpClock.elapsedMicroseconds;
    runJavaScript(pageCompatScript);
    for (final script in pageScripts.toList()) {
      final source = script();
      if (source.isNotEmpty) runJavaScript(source);
    }
  }

  /// Picks up what changed in this view since the last tick; returns whether anything did (or still is).
  bool _pump() {
    final now = _pumpClock.elapsedMicroseconds;
    if (_view == nullptr) return false;
    var busy = isLoading || _decoding;

    final stateSerial = _bindings.stateSerial(_view);
    if (stateSerial != _stateSerial) {
      busy = true;
      _stateSerial = stateSerial;
      final previous = (url, title, isLoading);
      url = _bindings.url(_view).toDartString();
      title = _bindings.title(_view).toDartString();
      hoveredLink = _bindings.hoveredLink(_view).toDartString();
      isLoading = _bindings.isLoading(_view) != 0;
      if ((url, title, isLoading) != previous) _runPageCompat();
      // Ladybird resets a page's colour scheme to its own default whenever navigation brings up a new WebContent page
      // (cross-site loads), so say it again once the new page is in.
      if (url != previous.$1 || isLoading != previous.$3) _colorScheme?.call();
      canGoBack = _bindings.canGoBack(_view) != 0;
      canGoForward = _bindings.canGoForward(_view) != 0;
      cursor = _bindings.cursor(_view);
      final prompt = _bindings.webauthnPrompt(_view).toDartString();
      if (prompt != _webauthnPromptJson) {
        _webauthnPromptJson = prompt;
        webauthnPrompt = prompt.isEmpty ? null : jsonDecode(prompt) as Map<String, Object?>;
      }
      _filePicker?.check(_view, () => _view);
      _permissions?.check(_view);
      _dialogs?.check(_view);
      closeRequested = (_closeRequested?.call(_view) ?? 0) != 0;
      _takeNewViews();
      if (_disposed) return true;
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

    // A loading page gets the compat script again every so often: the runs above can land in the document being
    // replaced, and a reload keeps the URL and title, so nothing else would reach the new one before it loads.
    if (isLoading && now - _lastCompatMicros >= 100000) _runPageCompat();

    final nextMessage = _passwordNative.nextMessage;
    if (nextMessage != null && _messagePrefix.isNotEmpty) {
      for (var message = nextMessage(_view).toDartString(); message.isNotEmpty; message = nextMessage(_view).toDartString()) {
        _pageMessages.add(message);
        busy = true;
      }
    }

    // Until we know whether there's a texture, leave frames unread; the latest one goes wherever it ends up. Hidden
    // views aren't drawn, so their frames stay in Ladybird until they're shown.
    if (_texturePending || !_visible) return busy;
    final frameSerial = _bindings.frameSerial(_view);
    final texture = _texture;
    if (frameSerial == _frameSerial || (texture == null && _decoding)) return busy;
    _frameSerial = frameSerial;
    final width = _bindings.frameWidth(_view);
    final height = _bindings.frameHeight(_view);
    if (width <= 0 || height <= 0) return true;
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
      return true;
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
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final (_, completer) in _asks) {
      completer.complete(false);
    }
    _asks.clear();
    _live.remove(this);
    if (_live.isEmpty) {
      _pumpTimer?.cancel();
      _pumpTimer = null;
    }
    _releaseFrames?.cancel();
    PageColorScheme.unfollow(_colorScheme);
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

  // Touch: a tap clicks, a drag scrolls the page (and flings it on release), holding still right-clicks.
  int? _touchPointer;
  Offset _touchStart = Offset.zero;
  Offset _touchStartGlobal = Offset.zero;
  Timer? _longPress;
  bool _touchLongPressed = false;
  Offset _touchLast = Offset.zero;
  bool _touchScrolling = false;
  VelocityTracker? _touchVelocity;
  Timer? _fling;

  // On-screen keyboard: connected while a text field in the page has focus.
  static final bool _softKeyboard = Platform.isAndroid || Platform.isIOS;
  TextInputConnection? _input;
  TextEditingValue _inputValue = TextEditingValue.empty;
  DateTime _lastInputEdit = DateTime.fromMillisecondsSinceEpoch(0);
  // Brings the focused field back into view once the keyboard has finished shrinking the page.
  Timer? _revealField;


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
    final shrank = _lastSize != null && size.height < _lastSize!.height;
    _lastSize = size;
    _lastRatio = ratio;
    final width = (size.width * ratio).round();
    final height = (size.height * ratio).round();
    // Resize after layout; creating/resizing the view can synchronously notify listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.setViewport(width, height, ratio);
    });
    // The keyboard opening shrinks the page, which can leave the field being typed in below the new bottom edge.
    // Ladybird doesn't scroll it back into view by itself.
    if (_softKeyboard && shrank && widget.controller.textField != null) {
      _revealField?.cancel();
      _revealField = Timer(const Duration(milliseconds: 150), () {
        if (mounted && widget.controller.textField != null) {
          widget.controller.runJavaScript(
              "document.activeElement && document.activeElement.scrollIntoView({block: 'nearest', inline: 'nearest'})");
        }
      });
    }
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
    widget.controller.pointerIsTouch = false;
    widget.controller.mouseEvent(2, _toDevice(event.localPosition),
        buttons: _lastButtons, modifiers: _modifiers);
  }

  void _touchDown(PointerDownEvent event) {
    // One finger at a time; pinch zoom isn't supported.
    if (_touchPointer != null) return;
    _stopFling();
    _touchPointer = event.pointer;
    _touchStart = _touchLast = event.localPosition;
    _touchStartGlobal = event.position;
    _touchScrolling = false;
    _touchLongPressed = false;
    _longPress?.cancel();
    _longPress = Timer(kLongPressTimeout, _touchLongPress);
    _touchVelocity = VelocityTracker.withKind(PointerDeviceKind.touch)..addPosition(event.timeStamp, event.localPosition);
  }

  void _touchMove(PointerMoveEvent event) {
    // After a long press the menu is open; the finger lifting off it shouldn't scroll the page.
    if (event.pointer != _touchPointer || _touchLongPressed) return;
    _touchVelocity?.addPosition(event.timeStamp, event.localPosition);
    if (!_touchScrolling && (event.localPosition - _touchStart).distance < kTouchSlop) return;
    _touchScrolling = true;
    _longPress?.cancel();
    _scrollBy(event.localPosition, _touchLast - event.localPosition);
    _touchLast = event.localPosition;
  }

  void _touchUp(PointerUpEvent event) {
    if (event.pointer != _touchPointer) return;
    _touchPointer = null;
    _longPress?.cancel();
    if (_touchLongPressed) return;
    if (_touchScrolling) {
      _startFling(event.localPosition, _touchVelocity?.getVelocity().pixelsPerSecond ?? Offset.zero);
      return;
    }
    // A tap: click where the finger went down. The page's pointer stays there afterwards, so it isn't a hover.
    final position = _toDevice(_touchStart);
    final controller = widget.controller;
    controller.pointerIsTouch = true;
    controller.mouseEvent(2, position);
    controller.mouseEvent(0, position, button: 1, buttons: 1, clickCount: 1);
    controller.mouseEvent(1, position, button: 1, clickCount: 1);
    // Tapping a field that already has focus brings back a keyboard the user dismissed.
    _input?.show();
  }

  /// A finger held still is a right-click there: Ladybird fires the page's contextmenu event (the page sees no touch
  /// events at all), and the page script's report opens the same menu as on desktop.
  void _touchLongPress() {
    if (_touchPointer == null || _touchScrolling) return;
    _touchLongPressed = true;
    HapticFeedback.vibrate();
    final position = _toDevice(_touchStart);
    final controller = widget.controller;
    controller.pointerIsTouch = true;
    _expectContextMenu(_touchStartGlobal);
    controller.mouseEvent(2, position);
    controller.mouseEvent(0, position, button: 2, buttons: 2, clickCount: 1);
    controller.mouseEvent(1, position, button: 2, clickCount: 1);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _touchPointer) {
      _touchPointer = null;
      _longPress?.cancel();
    }
  }

  /// Scrolls by [delta] logical pixels, as a trackpad would. Moves are gathered up and sent once per frame: touch
  /// screens report moves faster than the display refreshes, and each scroll the page handles itself (an inner scroll
  /// box) costs WebContent's main thread a layout and paint.
  void _scrollBy(Offset position, Offset delta) {
    _scrollPosition = position;
    final scheduled = _scrollDelta != Offset.zero;
    _scrollDelta += delta;
    if (scheduled || _scrollDelta == Offset.zero) return;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      final delta = _scrollDelta;
      _scrollDelta = Offset.zero;
      if (!mounted || delta == Offset.zero) return;
      widget.controller.wheelEvent(_toDevice(_scrollPosition), _toDevice(delta), precise: true);
    });
  }

  Offset _scrollPosition = Offset.zero;
  Offset _scrollDelta = Offset.zero;

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
      // No suggestions: keyboards like Gboard otherwise add their own spaces (after a period, after a picked word) and
      // smart punctuation that the page never asked for. On Android this also makes it a plain "visible password" field.
      _input = TextInput.attach(
          this,
          const TextInputConfiguration(
            inputAction: TextInputAction.go,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
          ))
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
    _longPress?.cancel();
    _revealField?.cancel();
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
