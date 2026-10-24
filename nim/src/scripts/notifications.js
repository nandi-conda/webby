
(() => {
  const state = window.__webbyNotifications;
  if (state) { state.setPermission(${jsonEncode(permission)}); return; }
  // Ladybird has a Notification interface of its own, but without permission or requestPermission(), so pages that
  // ask (Slack's "enable notifications") got nothing. Only an engine that answers Notification.permission keeps its own.
  if (window.Notification && typeof window.Notification.permission === 'string') return;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  const send = (message) => {
    const text = PREFIX + JSON.stringify(message);
    setTimeout(() => { try { prompt.call(window, text); } catch (e) {} }, 0);
  };
  const self = {
    permission: ${jsonEncode(permission)},
    nextId: 1,
    waiting: new Map(),
    shown: new Map(),
    statuses: new Set(),
    setPermission(permission) {
      if (permission === self.permission) return;
      self.permission = permission;
      for (const status of self.statuses) status.dispatchEvent(new Event('change'));
    },
    resolve(id, permission) {
      self.setPermission(permission);
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

  // navigator.permissions.query({name: 'notifications'}), which sites check before offering to turn notifications on.
  // Ladybird only has navigator.permissions behind its experimental switch, so provide it, or answer notifications
  // ourselves in front of the engine's.
  class PermissionStatus extends EventTarget {
    // A status for anything but notifications stays at "prompt": the page has to ask the feature itself.
    constructor(name) {
      super();
      this.name = name;
      let handler = null;
      Object.defineProperty(this, 'onchange', {
        get: () => handler,
        set: (value) => {
          if (handler) this.removeEventListener('change', handler);
          handler = typeof value === 'function' ? value : null;
          if (handler) this.addEventListener('change', handler);
        },
      });
      if (name === 'notifications') self.statuses.add(this);
    }
    get state() {
      if (this.name !== 'notifications') return 'prompt';
      return self.permission === 'default' ? 'prompt' : self.permission;
    }
  }
  const notificationsStatus = (descriptor) => {
    if (descriptor && descriptor.name === 'notifications') return Promise.resolve(new PermissionStatus('notifications'));
    return null;
  };
  const permissions = navigator.permissions;
  if (permissions && typeof permissions.query === 'function') {
    const query = permissions.query;
    permissions.query = function (descriptor) {
      return notificationsStatus(descriptor) || query.call(this, descriptor);
    };
  } else {
    const shim = {
      query(descriptor) {
        if (descriptor === undefined || descriptor === null || typeof descriptor.name !== 'string')
          return Promise.reject(new TypeError("Failed to execute 'query' on 'Permissions': required member name is undefined."));
        return notificationsStatus(descriptor) || Promise.resolve(new PermissionStatus(descriptor.name));
      },
    };
    try { Object.defineProperty(navigator, 'permissions', { value: shim, configurable: true }); } catch (e) {}
  }
})();
