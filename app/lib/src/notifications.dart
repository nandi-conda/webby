// Web notifications (the Notification API), which Ladybird doesn't have: a page script provides window.Notification,
// asks through the site permission prompt (see site_permissions.dart) and hands notifications to the system's
// notification service: the freedesktop one over D-Bus on Linux, Android's notification manager on phones.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import 'android.dart';
import 'site_permissions.dart';
import 'web_view.dart';

/// JavaScript that defines `window.Notification` for the page. [permission] is the site's answer so far ("granted",
/// "denied" or "default"). Messages go through the browser's page-message channel (see passwords/page_script.dart):
///   {"type": "notificationPermission", "id"}   Notification.requestPermission(); answered by calling
///                                              `__webbyNotifications.resolve(id, permission)`
///   {"type": "notify", "id", "title", "body", "tag"}   a new Notification
///   {"type": "notificationClose", "id"}   notification.close()
/// The browser calls `__webbyNotifications.click(id)` / `.closed(id)` when the user clicks or dismisses one.
String notificationPageScript(String prefix, String permission) => '''
(() => {
  const state = window.__webbyNotifications;
  if (state) { state.permission = ${jsonEncode(permission)}; return; }
  if ('Notification' in window) return;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  const send = (message) => { try { prompt.call(window, PREFIX + JSON.stringify(message)); } catch (e) {} };
  const self = {
    permission: ${jsonEncode(permission)},
    nextId: 1,
    waiting: new Map(),
    shown: new Map(),
    resolve(id, permission) {
      self.permission = permission;
      const done = self.waiting.get(id);
      self.waiting.delete(id);
      if (done) done(permission);
    },
    click(id) { const n = self.shown.get(id); if (n) n.dispatchEvent(new Event('click')); },
    closed(id) { const n = self.shown.get(id); self.shown.delete(id); if (n) n.dispatchEvent(new Event('close')); },
  };
  Object.defineProperty(window, '__webbyNotifications', { value: self });

  class Notification extends EventTarget {
    constructor(title, options = {}) {
      super();
      if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required");
      this.title = String(title);
      this.body = options.body === undefined ? '' : String(options.body);
      this.tag = options.tag === undefined ? '' : String(options.tag);
      this.icon = options.icon === undefined ? '' : String(options.icon);
      this.data = options.data === undefined ? null : options.data;
      this.dir = options.dir || 'auto';
      this.lang = options.lang || '';
      this.silent = options.silent === undefined ? null : !!options.silent;
      this.requireInteraction = !!options.requireInteraction;
      for (const name of ['click', 'show', 'error', 'close']) {
        let handler = null;
        Object.defineProperty(this, 'on' + name, {
          get: () => handler,
          set: (value) => {
            if (handler) this.removeEventListener(name, handler);
            handler = typeof value === 'function' ? value : null;
            if (handler) this.addEventListener(name, handler);
          },
        });
      }
      const id = self.nextId++;
      this._webbyId = id;
      setTimeout(() => {
        if (self.permission !== 'granted') { this.dispatchEvent(new Event('error')); return; }
        self.shown.set(id, this);
        send({ type: 'notify', id, title: this.title, body: this.body, tag: this.tag });
        this.dispatchEvent(new Event('show'));
      }, 0);
    }
    close() {
      if (!self.shown.has(this._webbyId)) return;
      send({ type: 'notificationClose', id: this._webbyId });
      self.closed(this._webbyId);
    }
    static get permission() { return self.permission; }
    static get maxActions() { return 0; }
    static requestPermission(callback) {
      const result = self.permission !== 'default'
        ? Promise.resolve(self.permission)
        : new Promise((resolve) => {
            const id = self.nextId++;
            self.waiting.set(id, resolve);
            send({ type: 'notificationPermission', id });
          });
      if (typeof callback === 'function') result.then(callback);
      return result;
    }
  }
  Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true });
})();
''';

/// Gives one tab's pages notifications.
class NotificationAgent {
  NotificationAgent(this.controller, {this.onClick}) {
    controller.addListener(_onPageChanged);
    _messages = controller.pageMessages.listen(_onMessage);
    SitePermissionStore.instance.addListener(_onSettingsChanged);
  }

  final WebbyController controller;

  /// Called when the user clicks one of this tab's notifications, to bring the tab forward.
  final VoidCallback? onClick;

  late final StreamSubscription<String> _messages;
  String _scriptedUrl = '';
  bool _wasLoading = false;
  /// The page's notification ids to the system's, for this tab's current document.
  final Map<int, SystemNotification> _shown = {};

  /// Notifications need a secure page, like the other permission-gated features.
  String? get _origin {
    final origin = originOf(controller.url);
    if (origin == null) return null;
    final uri = Uri.parse(origin);
    final secure = uri.scheme == 'https' || uri.host == 'localhost' || uri.host == '127.0.0.1';
    return secure ? origin : null;
  }

  String _permission(String origin) => switch (controller.permissionFor(origin, SitePermissionKind.notifications.name)) {
        PermissionSetting.allow => 'granted',
        PermissionSetting.block => 'denied',
        PermissionSetting.ask => 'default',
      };

  void _inject() {
    final origin = _origin;
    if (origin == null || !controller.isAttached || controller.messagePrefix.isEmpty) return;
    controller.runJavaScript(notificationPageScript(controller.messagePrefix, _permission(origin)));
  }

  void _onPageChanged() {
    final loadFinished = _wasLoading && !controller.isLoading;
    _wasLoading = controller.isLoading;
    if (controller.url == _scriptedUrl && !loadFinished) return;
    if (originOf(controller.url) != originOf(_scriptedUrl)) _shown.clear();
    _scriptedUrl = controller.url;
    _inject();
  }

  void _onSettingsChanged() => _inject();

  Future<void> _onMessage(String text) async {
    Map<String, Object?> message;
    try {
      message = jsonDecode(text) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final origin = _origin;
    if (origin == null) return;
    final id = (message['id'] as num?)?.toInt() ?? 0;
    switch (message['type']) {
      case 'notificationPermission':
        var allowed = await controller.askPermission(origin, SitePermissionKind.notifications.name);
        if (allowed) allowed = await SystemNotifications.instance.requestPermission();
        if (_origin != origin) return;
        final answer = allowed ? 'granted' : _permission(origin) == 'denied' ? 'denied' : 'default';
        controller.runJavaScript('window.__webbyNotifications && window.__webbyNotifications.resolve($id, ${jsonEncode(answer)})');
      case 'notify':
        if (_permission(origin) != 'granted') return;
        final notification = await SystemNotifications.instance.show(
          origin: origin,
          tag: message['tag'] as String? ?? '',
          title: message['title'] as String? ?? '',
          body: message['body'] as String? ?? '',
          onClick: () {
            onClick?.call();
            controller.runJavaScript('window.__webbyNotifications && window.__webbyNotifications.click($id)');
          },
          onClosed: () {
            controller.runJavaScript('window.__webbyNotifications && window.__webbyNotifications.closed($id)');
          },
        );
        if (notification != null) _shown[id] = notification;
      case 'notificationClose':
        _shown.remove(id)?.close();
    }
  }

  void dispose() {
    controller.removeListener(_onPageChanged);
    _messages.cancel();
    SitePermissionStore.instance.removeListener(_onSettingsChanged);
  }
}

/// A notification on screen; [close] takes it away.
class SystemNotification {
  SystemNotification._(this._close);
  final Future<void> Function() _close;
  Future<void> close() => _close();
}

/// The system's notification service.
class SystemNotifications {
  SystemNotifications._();
  static final instance = SystemNotifications._();

  /// System ids by "origin tag", so a notification with the tag of an earlier one replaces it (as the spec says).
  final Map<String, int> _tagged = {};
  final Map<int, (VoidCallback, VoidCallback)> _callbacks = {};

  // Linux: org.freedesktop.Notifications on the session bus.
  DBusRemoteObject? _service;
  int _androidIds = 0;

  /// Asks the system to let the app show notifications (Android 13+ asks the user once); true elsewhere.
  Future<bool> requestPermission() async =>
      Platform.isAndroid ? await AndroidHost.requestNotificationPermission() : true;

  Future<SystemNotification?> show({
    required String origin,
    required String tag,
    required String title,
    required String body,
    required VoidCallback onClick,
    required VoidCallback onClosed,
  }) async {
    final site = Uri.parse(origin).host.replaceFirst(RegExp(r'^www\.'), '');
    final key = tag.isEmpty ? null : '$origin $tag';
    try {
      final int id;
      if (Platform.isAndroid) {
        id = (key != null ? _tagged[key] : null) ?? ++_androidIds;
        await AndroidHost.showNotification(id, title, body, site, () => _clicked(id));
      } else {
        id = await _notifyLinux(key != null ? _tagged[key] ?? 0 : 0, title, body, site);
      }
      if (key != null) _tagged[key] = id;
      _callbacks[id] = (onClick, onClosed);
      return SystemNotification._(() => _closeId(id));
    } catch (error) {
      debugPrint('webby: could not show a notification: $error');
      return null;
    }
  }

  void _clicked(int id) {
    final callbacks = _callbacks.remove(id);
    callbacks?.$1();
    callbacks?.$2();
  }

  void _closedBySystem(int id) => _callbacks.remove(id)?.$2();

  Future<void> _closeId(int id) async {
    _callbacks.remove(id);
    try {
      if (Platform.isAndroid) {
        await AndroidHost.cancelNotification(id);
      } else {
        await _service?.callMethod('org.freedesktop.Notifications', 'CloseNotification', [DBusUint32(id)],
            replySignature: DBusSignature(''));
      }
    } catch (_) {}
  }

  DBusRemoteObject _linuxService() {
    final existing = _service;
    if (existing != null) return existing;
    final service = _service = DBusRemoteObject(DBusClient.session(),
        name: 'org.freedesktop.Notifications', path: DBusObjectPath('/org/freedesktop/Notifications'));
    DBusRemoteObjectSignalStream(
            object: service,
            interface: 'org.freedesktop.Notifications',
            name: 'ActionInvoked',
            signature: DBusSignature('us'))
        .listen((signal) => _clicked((signal.values[0] as DBusUint32).value));
    DBusRemoteObjectSignalStream(
            object: service,
            interface: 'org.freedesktop.Notifications',
            name: 'NotificationClosed',
            signature: DBusSignature('uu'))
        .listen((signal) => _closedBySystem((signal.values[0] as DBusUint32).value));
    return service;
  }

  Future<int> _notifyLinux(int replaces, String title, String body, String site) async {
    final result = await _linuxService().callMethod(
      'org.freedesktop.Notifications',
      'Notify',
      [
        const DBusString('Webby'),
        DBusUint32(replaces),
        const DBusString('webby'),
        DBusString(title),
        // Like Chrome, say which site it came from.
        DBusString(body.isEmpty ? site : '$body\n$site'),
        DBusArray.string(['default', 'Open']),
        DBusDict.stringVariant({'desktop-entry': const DBusString('webby')}),
        const DBusInt32(-1),
      ],
      replySignature: DBusSignature('u'),
    );
    return (result.returnValues[0] as DBusUint32).value;
  }
}
