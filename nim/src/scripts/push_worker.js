(() => {
  // A stand-in service worker global scope (features/site/push.nim). It runs in a hidden view showing the worker
  // script's own URL, so the script sees its origin and location; push.nim then runs the script inside
  // `with (__webbySW.scope) { ... }`, so `self`, `registration`, `clients`, `addEventListener` and friends are ours
  // while everything else (fetch, caches, crypto, timers) is the page's. Events come in through dispatch(); clients,
  // notifications and subscriptions go out through the browser.
  if (window.__webbySW) return;
  const PREFIX = ${jsonEncode(prefix)};
  const SCOPE = ${jsonEncode(scope)};
  const SCRIPT = ${jsonEncode(script)};
  const prompt = window.prompt;
  const send = (message) => {
    const text = PREFIX + JSON.stringify(message);
    setTimeout(() => { try { prompt.call(window, text); } catch (e) {} }, 0);
  };
  let nextId = 1;
  const waiting = new Map();
  const call = (op, args) => new Promise((resolve, reject) => {
    const id = nextId++;
    waiting.set(id, { resolve, reject });
    send({ type: 'sw', op, id, ...args });
  });
  const fromB64 = (s) => {
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
    if (typeof key === 'string') return fromB64(key);
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

  class PushSubscription {
    constructor(d) {
      this._keys = { p256dh: d.p256dh, auth: d.auth };
      this.endpoint = d.endpoint;
      this.expirationTime = null;
      this.options = { userVisibleOnly: true, applicationServerKey: d.key ? fromB64(d.key).buffer : null };
    }
    getKey(name) { const k = this._keys[name]; return k ? fromB64(k).buffer : null; }
    toJSON() { return { endpoint: this.endpoint, expirationTime: null, keys: { ...this._keys } }; }
    unsubscribe() { return call('unsubscribe', {}).then((r) => !!r); }
  }
  const pushManager = {
    subscribe(options = {}) {
      let key = '';
      try {
        if (options && options.applicationServerKey != null) key = toB64url(keyBytes(options.applicationServerKey));
      } catch (e) { return Promise.reject(e); }
      return call('subscribe', { key }).then((d) => new PushSubscription(d));
    },
    getSubscription() { return call('getSubscription', {}).then((d) => (d ? new PushSubscription(d) : null)); },
    permissionState() { return call('permission', {}); },
  };

  const shown = new Map();   // id -> Notification still on screen
  class WorkerNotification {
    constructor(id, title, o) {
      this._id = id;
      this.title = title;
      for (const k of ['body', 'tag', 'icon', 'badge', 'image', 'dir', 'lang', 'data'])
        this[k] = o[k] === undefined ? (k === 'data' ? null : k === 'dir' ? 'auto' : '') : o[k];
      this.requireInteraction = !!o.requireInteraction;
      this.silent = o.silent === undefined ? null : !!o.silent;
      this.renotify = !!o.renotify;
      this.timestamp = o.timestamp || Date.now();
      this.actions = [];
    }
    close() {
      if (!shown.has(this._id)) return;
      shown.delete(this._id);
      send({ type: 'sw', op: 'closeNotification', nid: this._id });
    }
  }
  let shownInEvent = 0;
  const plainOptions = (o) => {
    const out = {};
    for (const k of ['body', 'tag', 'icon', 'badge', 'image', 'dir', 'lang', 'requireInteraction', 'silent', 'renotify', 'timestamp'])
      if (o && o[k] !== undefined) out[k] = o[k];
    try { out.data = o && o.data !== undefined ? JSON.parse(JSON.stringify(o.data)) : null; } catch (e) { out.data = null; }
    return out;
  };

  const active = { scriptURL: SCRIPT, state: 'activated', postMessage() {}, addEventListener() {}, removeEventListener() {} };
  const registration = Object.assign(new EventTarget(), {
    scope: SCOPE,
    installing: null,
    waiting: null,
    active,
    updateViaCache: 'imports',
    pushManager,
    navigationPreload: {
      enable: () => Promise.resolve(), disable: () => Promise.resolve(),
      setHeaderValue: () => Promise.resolve(), getState: () => Promise.resolve({ enabled: false, headerValue: 'true' }),
    },
    update() { return Promise.resolve(registration); },
    unregister() { return call('unregister', {}).then((r) => !!r); },
    showNotification(title, options = {}) {
      const o = plainOptions(options);
      return call('showNotification', { title: String(title), options: o }).then((id) => {
        shownInEvent++;
        const n = new WorkerNotification(id, String(title), o);
        if (o.tag) for (const [k, v] of shown) if (v.tag === o.tag) shown.delete(k);
        shown.set(id, n);
      });
    },
    getNotifications(filter = {}) {
      return Promise.resolve([...shown.values()].filter((n) => !filter.tag || n.tag === filter.tag));
    },
  });

  class Client {
    constructor(d) {
      this.id = d.id;
      this.url = d.url;
      this.type = 'window';
      this.frameType = 'top-level';
      this.focused = !!d.focused;
      this.visibilityState = d.visibilityState || 'hidden';
    }
    postMessage(message) {
      let data;
      try { data = JSON.stringify(message === undefined ? null : message); } catch (e) {
        throw new DOMException("Failed to execute 'postMessage' on 'Client': the message could not be cloned.", 'DataCloneError');
      }
      send({ type: 'sw', op: 'clientPostMessage', client: this.id, data });
    }
    focus() { return call('focus', { client: this.id }).then((d) => new Client(d)); }
    navigate(url) { return call('navigate', { client: this.id, url: new URL(url, SCOPE).href }).then((d) => (d ? new Client(d) : null)); }
  }
  const clients = {
    matchAll(options = {}) {
      return call('matchAll', {}).then((list) => (options.type && options.type !== 'window' && options.type !== 'all' ? [] : list.map((d) => new Client(d))));
    },
    get(id) { return clients.matchAll().then((list) => list.find((c) => c.id === id)); },
    openWindow(url) { return call('openWindow', { url: new URL(url, SCOPE).href }).then((d) => (d ? new Client(d) : null)); },
    claim() { return Promise.resolve(); },
  };

  class ExtendableEvent extends Event {
    constructor(type, init) { super(type, init); this._promises = []; }
    waitUntil(p) { this._promises.push(Promise.resolve(p)); }
  }
  class PushMessageData {
    constructor(bytes) { this._bytes = bytes; }
    arrayBuffer() { return this._bytes.slice().buffer; }
    bytes() { return this._bytes.slice(); }
    blob() { return new Blob([this._bytes]); }
    text() { return new TextDecoder().decode(this._bytes); }
    json() { return JSON.parse(this.text()); }
  }
  class PushEvent extends ExtendableEvent {
    constructor(type, init = {}) { super(type, init); this.data = init.data || null; }
  }
  class NotificationEvent extends ExtendableEvent {
    constructor(type, init = {}) { super(type, init); this.notification = init.notification; this.action = init.action || ''; this.reply = null; }
  }
  class PushSubscriptionChangeEvent extends ExtendableEvent {
    constructor(type, init = {}) { super(type, init); this.oldSubscription = init.oldSubscription || null; this.newSubscription = init.newSubscription || null; }
  }
  class ExtendableMessageEvent extends ExtendableEvent {
    constructor(type, init = {}) { super(type, init); this.data = init.data; this.origin = init.origin || ''; this.source = init.source || null; this.ports = []; this.lastEventId = ''; }
  }

  const scope = new EventTarget();
  handlerProps(scope, ['install', 'activate', 'fetch', 'message', 'messageerror', 'push', 'pushsubscriptionchange',
    'notificationclick', 'notificationclose', 'sync', 'periodicsync']);
  Object.assign(scope, {
    self: scope,
    globalThis: scope,
    registration,
    clients,
    serviceWorker: active,
    location: window.location,
    skipWaiting: () => Promise.resolve(),
    importScripts: (...urls) => {
      for (const url of urls) {
        const xhr = new XMLHttpRequest();
        xhr.open('GET', new URL(url, SCRIPT).href, false);
        xhr.send();
        if (xhr.status !== 200) throw new DOMException("Failed to execute 'importScripts': " + url + ' failed to load.', 'NetworkError');
        self.run(xhr.responseText);
      }
    },
    ExtendableEvent, PushEvent, NotificationEvent, PushSubscriptionChangeEvent, ExtendableMessageEvent, PushMessageData,
  });

  const self = {
    scope,
    run: null,   // set inside the with block: runs imported scripts in it
    settle(id, ok, value) {
      const w = waiting.get(id);
      waiting.delete(id);
      if (!w) return;
      if (ok) w.resolve(value);
      else w.reject(value && value.name === 'TypeError' ? new TypeError(value.message) : new DOMException(value ? value.message : 'Failed', value ? value.name : 'AbortError'));
    },
    started() { send({ type: 'sw', op: 'started' }); },
    failed(e) { send({ type: 'sw', op: 'failed', error: String(e && e.stack || e) }); },
    dispatch(kind, eventId, d) {
      let event;
      if (kind === 'push') event = new PushEvent('push', { data: d.data === null ? null : new PushMessageData(fromB64(d.data)) });
      else if (kind === 'notificationclick' || kind === 'notificationclose') {
        let n = shown.get(d.nid);
        if (!n) n = new WorkerNotification(d.nid, d.title, d.options || {});
        if (kind === 'notificationclick') shown.set(d.nid, n); else shown.delete(d.nid);
        event = new NotificationEvent(kind, { notification: n, action: d.action || '' });
      } else if (kind === 'pushsubscriptionchange')
        event = new PushSubscriptionChangeEvent(kind, { oldSubscription: d.old ? new PushSubscription(d.old) : null });
      else if (kind === 'message')
        event = new ExtendableMessageEvent('message', { data: d.data, origin: location.origin, source: d.source ? new Client(d.source) : null });
      else return;
      shownInEvent = 0;
      try { scope.dispatchEvent(event); } catch (e) { console.error(e); }
      Promise.allSettled(event._promises).then((results) => {
        for (const r of results) if (r.status === 'rejected') console.error('[service worker] ' + kind + ':', r.reason);
        send({ type: 'sw', op: 'done', event: eventId, shown: shownInEvent });
      });
    },
  };
  Object.defineProperty(window, '__webbySW', { value: self });
})();
