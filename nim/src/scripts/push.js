(() => {
  // Service worker registration and Web Push for pages (features/site/push.nim). Ladybird accepts register() but
  // can't run a service worker, and has no PushManager, so sites said "web push isn't supported". This stands in
  // for both: registrations are remembered by the browser, subscriptions come from its push service connection,
  // and the browser runs the worker script's push and notificationclick handlers itself when a message arrives.
  // There is no fetch interception or offline cache.
  const STATE = ${jsonEncode(state)};
  if (window.__webbyPush) { window.__webbyPush.update(STATE); return; }
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  // Never prompt() while the document is parsing (it pauses the parser for good): such messages wait for
  // DOMContentLoaded.
  const later = [];
  const send = (message) => {
    const text = PREFIX + JSON.stringify(message);
    const go = () => setTimeout(() => { try { prompt.call(window, text); } catch (e) {} }, 0);
    if (document.readyState === 'loading') later.push(go); else go();
  };
  document.addEventListener('DOMContentLoaded', () => { for (const go of later.splice(0)) go(); });

  let nextId = 1;
  const waiting = new Map();
  const call = (op, args) => new Promise((resolve, reject) => {
    const id = nextId++;
    waiting.set(id, { resolve, reject });
    send({ type: 'push', op, id, ...args });
  });

  const fromB64url = (s) => {
    let t = String(s).replace(/-/g, '+').replace(/_/g, '/');
    while (t.length % 4) t += '=';
    const bin = atob(t);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  };
  const toB64url = (bytes) => {
    let s = '';
    for (const b of bytes) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  const keyBytes = (key) => {
    if (typeof key === 'string') {
      try { return fromB64url(key); } catch (e) {
        throw new DOMException('The provided applicationServerKey is not encoded as base64url without padding.', 'InvalidCharacterError');
      }
    }
    if (key instanceof ArrayBuffer) return new Uint8Array(key);
    if (ArrayBuffer.isView(key)) return new Uint8Array(key.buffer, key.byteOffset, key.byteLength);
    throw new TypeError('The provided applicationServerKey is not a BufferSource or string.');
  };
  const handlerProps = (target, names) => {
    for (const name of names) {
      let handler = null;
      Object.defineProperty(target, 'on' + name, {
        get: () => handler,
        set: (value) => {
          if (handler) target.removeEventListener(name, handler);
          handler = typeof value === 'function' ? value : null;
          if (handler) target.addEventListener(name, handler);
        },
        configurable: true,
      });
    }
  };
  const notificationPermission = () =>
    window.Notification && typeof window.Notification.permission === 'string' ? window.Notification.permission : self.state.permission;
  const pushPermission = () => {
    const p = notificationPermission();
    return p === 'default' ? 'prompt' : p;
  };

  class PushSubscriptionOptions {
    constructor(key) {
      this.userVisibleOnly = true;
      this.applicationServerKey = key ? keyBytes(key).slice().buffer : null;
    }
  }
  class PushSubscription {
    constructor(scope, d) {
      this._scope = scope;
      this._keys = { p256dh: d.p256dh, auth: d.auth };
      this.endpoint = d.endpoint;
      this.expirationTime = null;
      this.options = new PushSubscriptionOptions(d.key);
    }
    getKey(name) { const k = this._keys[name]; return k ? fromB64url(k).buffer : null; }
    toJSON() { return { endpoint: this.endpoint, expirationTime: null, keys: { ...this._keys } }; }
    unsubscribe() { return call('unsubscribe', { scope: this._scope }).then((r) => !!r); }
  }
  class PushManager {
    constructor(scope) { this._scope = scope; }
    static get supportedContentEncodings() { return ['aes128gcm']; }
    subscribe(options = {}) {
      let key = '';
      try {
        if (options && options.applicationServerKey != null) key = toB64url(keyBytes(options.applicationServerKey));
      } catch (e) { return Promise.reject(e); }
      return call('subscribe', { scope: this._scope, key }).then((d) => new PushSubscription(this._scope, d));
    }
    getSubscription() {
      const d = self.state.subscriptions[this._scope];
      return Promise.resolve(d ? new PushSubscription(this._scope, d) : null);
    }
    permissionState() { return Promise.resolve(pushPermission()); }
  }
  class ServiceWorker extends EventTarget {
    constructor(scriptURL, scope) {
      super();
      this.scriptURL = scriptURL;
      this.state = 'activated';
      this._scope = scope;
      handlerProps(this, ['statechange', 'error']);
    }
    postMessage(message) {
      let data;
      try { data = JSON.stringify(message === undefined ? null : message); } catch (e) {
        throw new DOMException("Failed to execute 'postMessage' on 'ServiceWorker': the message could not be cloned.", 'DataCloneError');
      }
      send({ type: 'push', op: 'postMessage', scope: this._scope, data });
    }
  }
  class ServiceWorkerRegistration extends EventTarget {
    constructor(scope, scriptURL) {
      super();
      this.scope = scope;
      this.installing = null;
      this.waiting = null;
      this.active = new ServiceWorker(scriptURL, scope);
      this.updateViaCache = 'imports';
      this.pushManager = new PushManager(scope);
      this.navigationPreload = {
        enable: () => Promise.resolve(), disable: () => Promise.resolve(),
        setHeaderValue: () => Promise.resolve(), getState: () => Promise.resolve({ enabled: false, headerValue: 'true' }),
      };
      handlerProps(this, ['updatefound']);
    }
    update() { return Promise.resolve(this); }
    unregister() { return call('unregister', { scope: this.scope }).then((r) => !!r); }
    showNotification(title, options = {}) {
      if (notificationPermission() !== 'granted')
        return Promise.reject(new TypeError('No notification permission has been granted for this origin.'));
      return call('showNotification', { scope: this.scope, title: String(title), options: plainOptions(options) }).then(() => undefined);
    }
    getNotifications() { return Promise.resolve([]); }
  }
  const plainOptions = (o) => {
    const out = {};
    for (const k of ['body', 'tag', 'icon', 'badge', 'image', 'dir', 'lang', 'requireInteraction', 'silent', 'renotify', 'timestamp'])
      if (o && o[k] !== undefined) out[k] = o[k];
    try { out.data = o && o.data !== undefined ? JSON.parse(JSON.stringify(o.data)) : null; } catch (e) { out.data = null; }
    return out;
  };

  const registrations = new Map();   // scope -> ServiceWorkerRegistration
  let readyResolve;
  const ready = new Promise((resolve) => { readyResolve = resolve; });
  const covering = (url) => {
    let best = null;
    for (const r of registrations.values())
      if (url.startsWith(r.scope) && (!best || r.scope.length > best.scope.length)) best = r;
    return best;
  };
  const checkReady = () => { const r = covering(location.href); if (r) readyResolve(r); };

  class ServiceWorkerContainer extends EventTarget {
    constructor() {
      super();
      this.controller = null;
      this.ready = ready;
      handlerProps(this, ['controllerchange', 'message', 'messageerror']);
    }
    register(url, options = {}) {
      let scriptURL, scope;
      try {
        scriptURL = new URL(String(url), location.href);
        scope = new URL(options && options.scope ? String(options.scope) : './', scriptURL);
      } catch (e) { return Promise.reject(new TypeError("Failed to execute 'register' on 'ServiceWorkerContainer': invalid URL")); }
      if (scriptURL.origin !== location.origin || scope.origin !== location.origin)
        return Promise.reject(new DOMException("Failed to register a ServiceWorker: The origin of the provided scriptURL or scope does not match the current origin.", 'SecurityError'));
      return call('register', { scriptURL: scriptURL.href, scope: scope.href, kind: options && options.type === 'module' ? 'module' : 'classic' }).then(() => {
        let r = registrations.get(scope.href);
        if (!r || r.active.scriptURL !== scriptURL.href) {
          r = new ServiceWorkerRegistration(scope.href, scriptURL.href);
          registrations.set(scope.href, r);
        }
        checkReady();
        return r;
      });
    }
    getRegistration(url) {
      let u;
      try { u = new URL(url === undefined ? location.href : String(url), location.href).href; } catch (e) { return Promise.reject(e); }
      return Promise.resolve(covering(u) || undefined);
    }
    getRegistrations() { return Promise.resolve([...registrations.values()]); }
    startMessages() {}
  }
  const container = new ServiceWorkerContainer();
  const engine = navigator.serviceWorker;   // Ladybird's own, until we replace it below

  const self = {
    state: STATE,
    update(state) {
      self.state = state;
      const scopes = new Set();
      for (const r of state.registrations) {
        scopes.add(r.scope);
        const known = registrations.get(r.scope);
        if (!known || known.active.scriptURL !== r.scriptURL) registrations.set(r.scope, new ServiceWorkerRegistration(r.scope, r.scriptURL));
      }
      for (const scope of [...registrations.keys()]) if (!scopes.has(scope)) registrations.delete(scope);
      checkReady();
    },
    settle(id, ok, value) {
      const w = waiting.get(id);
      waiting.delete(id);
      if (!w) return;
      if (ok) w.resolve(value);
      else w.reject(value && value.name === 'TypeError' ? new TypeError(value.message) : new DOMException(value ? value.message : 'Failed', value ? value.name : 'AbortError'));
    },
    message(scope, data) {
      const r = registrations.get(scope);
      // The engine's MessageEvent only takes its own ServiceWorker as the source.
      // Listeners added before this script was in are on the engine's container.
      for (const target of engine && engine !== container ? [container, engine] : [container]) {
        const event = new MessageEvent('message', { data, origin: location.origin });
        Object.defineProperty(event, 'source', { value: r ? r.active : null });
        try { target.dispatchEvent(event); } catch (e) {}
      }
    },
  };
  Object.defineProperty(window, '__webbyPush', { value: self });

  // A register() that ran before this script was in (an inline or early module script) went to the engine, which
  // keeps the registration's scope but no worker. The script it fetched shows up in resource timing as an "other"
  // load of a .js file: register that ourselves.
  const adopt = () => {
    try {
      if (!engine || typeof engine.getRegistrations !== 'function') return;
      engine.getRegistrations().then((list) => {
        for (const r of list) {
          if (registrations.has(r.scope)) continue;
          const w = r.active || r.waiting || r.installing;
          let scriptURL = w && w.scriptURL;
          if (!scriptURL) {
            const loads = performance.getEntriesByType('resource').filter((e) => {
              try {
                const u = new URL(e.name);
                return e.initiatorType === 'other' && u.origin === location.origin && /\.m?js$/.test(u.pathname);
              } catch (err) { return false; }
            });
            if (loads.length) scriptURL = loads[loads.length - 1].name;
          }
          if (scriptURL) container.register(scriptURL, { scope: r.scope }).catch(() => {});
        }
      }, () => {});
    } catch (e) {}
  };
  // The script's load may finish after this runs: look again a little later.
  adopt();
  for (const ms of [1000, 3000, 8000]) setTimeout(adopt, ms);

  Object.defineProperty(navigator, 'serviceWorker', { get: () => container, configurable: true });
  for (const [name, value] of Object.entries({ PushManager, PushSubscription, PushSubscriptionOptions, ServiceWorker,
    ServiceWorkerContainer, ServiceWorkerRegistration }))
    Object.defineProperty(window, name, { value, writable: true, configurable: true });

  // navigator.permissions.query({name: 'push'}) follows the notification permission.
  const permissions = navigator.permissions;
  if (permissions && typeof permissions.query === 'function') {
    const query = permissions.query;
    permissions.query = function (descriptor) {
      if (descriptor && descriptor.name === 'push') {
        const status = new EventTarget();
        Object.defineProperty(status, 'name', { value: 'push' });
        Object.defineProperty(status, 'state', { get: pushPermission });
        handlerProps(status, ['change']);
        return Promise.resolve(status);
      }
      return query.call(this, descriptor);
    };
  }
  self.update(STATE);
})();
