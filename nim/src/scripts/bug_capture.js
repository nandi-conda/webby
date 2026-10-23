(() => {
  // Bug reports (features/bugreport.nim): keeps the page's recent console messages, errors, fetch/XHR requests,
  // clicks, typing and in-page navigations, so ⋮ > Report a bug can attach them to a screenshot or a recording, the
  // way Jam's extension does. Nothing leaves the page until webby asks for it with __webbyBug.dump(); typed text in
  // password, card and one-time-code fields is kept as ***.
  if (window.__webbyBug) return;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  const send = (message) => { try { prompt.call(window, PREFIX + JSON.stringify(message)); } catch (e) {} };
  const KEEP = 1000;          // entries of each kind
  const TEXT = 2000;          // characters of one console argument
  const BODY = 4096;          // characters of a request or response body
  const self = { doc: Math.random().toString(36).slice(2), seq: 0, console: [], network: [], actions: [] };
  const add = (list, item) => {
    item.seq = ++self.seq;
    list.push(item);
    if (list.length > KEEP) list.splice(0, list.length - KEEP);
    return item;
  };
  const clip = (s, n) => (s.length > n ? s.slice(0, n) + '…' : s);
  const absolute = (url) => { try { return new URL(String(url), location.href).href; } catch (e) { return String(url); } };
  // Wrapped functions still read as native code, so pages that check don't notice.
  const disguise = (fn, original) => {
    try { Object.defineProperty(fn, 'toString', { value: () => Function.prototype.toString.call(original) }); } catch (e) {}
    return fn;
  };

  // --- console -------------------------------------------------------------------------------------------------
  const show = (v, depth = 0) => {
    if (typeof v === 'string') return v;
    if (v === undefined) return 'undefined';
    if (typeof v === 'function') return 'function ' + (v.name || '(anonymous)');
    if (typeof v === 'symbol' || typeof v === 'bigint') return String(v);
    if (v instanceof Error) return (v.name || 'Error') + ': ' + v.message + (v.stack ? '\n' + v.stack : '');
    if (typeof Element !== 'undefined' && v instanceof Element) {
      return '<' + v.tagName.toLowerCase() + (v.id ? '#' + v.id : '') + '>';
    }
    try {
      const seen = new WeakSet();
      return JSON.stringify(v, (k, x) => {
        if (typeof x === 'object' && x !== null) { if (seen.has(x)) return '[circular]'; seen.add(x); }
        if (typeof x === 'bigint') return String(x);
        if (typeof x === 'function') return 'function ' + (x.name || '');
        return x;
      });
    } catch (e) { return String(v); }
  };
  const stackLines = (stack) => String(stack || '').split('\n').map((l) => l.trim()).filter((l) => l && !/bug_capture|__webbyBug|run_javascript/.test(l)).slice(0, 10);
  for (const level of ['log', 'info', 'warn', 'error', 'debug', 'trace']) {
    const original = console[level];
    if (typeof original !== 'function') continue;
    console[level] = disguise(function (...args) {
      try {
        const entry = { t: Date.now(), level: level === 'trace' ? 'debug' : level, args: args.map((a) => clip(show(a), TEXT)) };
        if (level === 'error' || level === 'trace') entry.trace = stackLines(new Error().stack).slice(1);
        add(self.console, entry);
      } catch (e) {}
      return original.apply(this, args);
    }, original);
  }
  window.addEventListener('error', (e) => {
    if (e.target && e.target !== window) {
      // A resource that failed to load (an <img>, <script>, stylesheet)
      const el = e.target;
      const url = el.src || el.href;
      if (url) add(self.network, { t: Date.now(), method: 'GET', url: scrubUrl(absolute(url)), status: 0, duration: 0,
        error: 'Failed to load', kind: (el.tagName || '').toLowerCase() });
      return;
    }
    const where = e.filename ? e.filename + ':' + e.lineno + ':' + e.colno : '';
    add(self.console, { t: Date.now(), level: 'error', args: [clip('Uncaught ' + (e.error ? show(e.error) : e.message), TEXT)],
      trace: e.error && e.error.stack ? stackLines(e.error.stack) : (where ? [where] : []) });
  }, true);
  window.addEventListener('unhandledrejection', (e) => {
    add(self.console, { t: Date.now(), level: 'error', args: [clip('Unhandled promise rejection: ' + show(e.reason), TEXT)],
      trace: e.reason && e.reason.stack ? stackLines(e.reason.stack) : [] });
  });

  // --- network -------------------------------------------------------------------------------------------------
  // Credentials stay out of reports: secret headers and secret-looking fields in bodies become ***.
  const SECRET_HEADER = /^(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|x-auth-token|x-csrf-token|x-xsrf-token)$/i;
  const SECRET_FIELD = /pass(word|wd)?|secret|token|api[-_]?key|auth|session|otp|cvv|cvc|card[-_]?number/i;
  const scrub = (s) => {
    s = s.replace(/("([^"\\]*)"\s*:\s*)"(?:[^"\\]|\\.)*"/g, (m, head, key) => (SECRET_FIELD.test(key) ? head + '"***"' : m));
    if (/^\s*[[{<]/.test(s)) return s;
    // A form body: key=value&...
    return s.replace(/(^|&)([^=&]*)=([^&]*)/g, (m, sep, key) => {
      let name = key;
      try { name = decodeURIComponent(key.replace(/\+/g, ' ')); } catch (e) {}
      return SECRET_FIELD.test(name) ? sep + key + '=***' : m;
    });
  };
  const scrubUrl = (u) => {
    const q = u.indexOf('?');
    if (q < 0) return u;
    const hash = u.indexOf('#', q);
    const end = hash < 0 ? u.length : hash;
    return u.slice(0, q + 1) + scrub(u.slice(q + 1, end)) + u.slice(end);
  };
  const bodyText = (b) => (typeof b === 'string' ? clip(scrub(b), BODY) : b instanceof URLSearchParams ? clip(scrub(b.toString()), BODY) : undefined);
  const headersOf = (h) => {
    const out = {};
    try {
      if (!h) return out;
      if (typeof h.forEach === 'function' && !Array.isArray(h)) h.forEach((v, k) => { out[k] = v; });
      else if (Array.isArray(h)) for (const [k, v] of h) out[k] = v;
      else for (const k of Object.keys(h)) out[k] = String(h[k]);
      for (const k of Object.keys(out)) if (SECRET_HEADER.test(k)) out[k] = '***';
    } catch (e) {}
    return out;
  };
  const textual = (type) => /json|text|xml|javascript|graphql|x-www-form-urlencoded/i.test(type || '');
  if (typeof window.fetch === 'function') {
    const original = window.fetch;
    window.fetch = disguise(function (input, init) {
      let entry;
      try {
        const isRequest = typeof Request !== 'undefined' && input instanceof Request;
        entry = add(self.network, { t: Date.now(), kind: 'fetch',
          method: String((init && init.method) || (isRequest && input.method) || 'GET').toUpperCase(),
          url: scrubUrl(absolute(isRequest ? input.url : input)), requestHeaders: headersOf((init && init.headers) || (isRequest && input.headers)),
          requestBody: init ? bodyText(init.body) : undefined, pending: true });
      } catch (e) {}
      const started = performance.now();
      const p = original.apply(this, arguments);
      if (entry) {
        p.then((r) => {
          entry.pending = false;
          entry.seq = ++self.seq;   // so a dump that saw it waiting picks it up again
          entry.duration = Math.round(performance.now() - started);
          entry.status = r.status;
          entry.statusText = r.statusText;
          entry.responseHeaders = headersOf(r.headers);
          entry.type = r.headers.get('content-type') || '';
          const size = r.headers.get('content-length');
          if (size) entry.size = Number(size);
          // Bodies of failed requests help most, as in Jam; read from a copy so the page's own read still works.
          if (r.status >= 400 && textual(entry.type)) {
            try { r.clone().text().then((s) => { entry.responseBody = clip(scrub(s), BODY); }, () => {}); } catch (e) {}
          }
        }, (err) => {
          entry.pending = false;
          entry.seq = ++self.seq;
          entry.duration = Math.round(performance.now() - started);
          entry.status = 0;
          entry.error = String(err && err.message || err);
        });
      }
      return p;
    }, original);
  }
  if (typeof XMLHttpRequest !== 'undefined') {
    const proto = XMLHttpRequest.prototype;
    const open = proto.open, sendXhr = proto.send, setHeader = proto.setRequestHeader;
    proto.open = disguise(function (method, url) {
      this.__webbyBug = { method: String(method || 'GET').toUpperCase(), url: scrubUrl(absolute(url)), requestHeaders: {} };
      return open.apply(this, arguments);
    }, open);
    proto.setRequestHeader = disguise(function (k, v) {
      if (this.__webbyBug) this.__webbyBug.requestHeaders[k] = String(v);
      return setHeader.apply(this, arguments);
    }, setHeader);
    proto.send = disguise(function (body) {
      const info = this.__webbyBug;
      if (info) {
        const entry = add(self.network, { t: Date.now(), kind: 'xhr', method: info.method, url: info.url,
          requestHeaders: info.requestHeaders, requestBody: bodyText(body), pending: true });
        const started = performance.now();
        this.addEventListener('loadend', () => {
          entry.pending = false;
          entry.seq = ++self.seq;
          entry.duration = Math.round(performance.now() - started);
          entry.status = this.status;
          entry.statusText = this.statusText;
          try {
            entry.type = this.getResponseHeader('content-type') || '';
            const raw = this.getAllResponseHeaders() || '';
            const headers = {};
            for (const line of raw.trim().split(/[\r\n]+/)) {
              const i = line.indexOf(':');
              if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
            }
            entry.responseHeaders = headersOf(headers);
            if ((this.responseType === '' || this.responseType === 'text') && typeof this.responseText === 'string') {
              entry.size = this.responseText.length;
              if (this.status >= 400 || this.status === 0) entry.responseBody = clip(scrub(this.responseText), BODY);
            }
          } catch (e) {}
          if (this.status === 0) entry.error = 'Network error';
        });
      }
      return sendXhr.apply(this, arguments);
    }, sendXhr);
  }
  const resources = () => {
    // The page's other loads (documents, scripts, images, styles) from Resource Timing, where the engine has it.
    const out = [];
    try {
      const origin = performance.timeOrigin || (Date.now() - performance.now());
      for (const r of performance.getEntriesByType('navigation').concat(performance.getEntriesByType('resource'))) {
        if (r.initiatorType === 'fetch' || r.initiatorType === 'xmlhttprequest') continue;
        out.push({ t: Math.round(origin + r.startTime), kind: r.entryType === 'navigation' ? 'document' : (r.initiatorType || 'other'),
          method: 'GET', url: scrubUrl(r.name), duration: Math.round(r.duration), status: r.responseStatus || undefined,
          size: r.transferSize || r.encodedBodySize || undefined });
      }
    } catch (e) {}
    return out;
  };

  // --- what the user did ---------------------------------------------------------------------------------------
  const SENSITIVE = /pass|secret|token|card|cc-|cvv|cvc|ssn|otp|one-time|pin\b|security.?code/i;
  const sensitive = (el) => {
    if (!el || !el.getAttribute) return true;
    const type = (el.getAttribute('type') || '').toLowerCase();
    if (type === 'password') return true;
    return [el.getAttribute('autocomplete'), el.getAttribute('name'), el.id, el.getAttribute('placeholder')]
      .some((v) => v && SENSITIVE.test(v));
  };
  const describe = (el) => {
    if (!el || el.nodeType !== 1) return null;
    const attributes = { tagName: el.tagName.toLowerCase() };
    if (el.id) attributes.id = el.id;
    const cls = typeof el.className === 'string' ? el.className.trim() : '';
    if (cls) attributes.className = clip(cls, 200);
    for (const name of ['type', 'name', 'role', 'aria-label', 'href', 'autocomplete', 'placeholder']) {
      const v = el.getAttribute(name);
      if (v) attributes[name] = clip(v, 200);
    }
    let text = '';
    try { text = (el.innerText || el.value || el.getAttribute('alt') || el.getAttribute('title') || '').trim().replace(/\s+/g, ' '); } catch (e) {}
    if (sensitive(el) && /^(input|textarea)$/.test(attributes.tagName)) text = '';
    if (/^(body|html)$/.test(attributes.tagName)) text = '';
    return { attributes, text: clip(text, 128) };
  };
  const clickable = (el) => {
    for (let n = el, i = 0; n && n.nodeType === 1 && i < 6; n = n.parentElement, i++) {
      if (/^(a|button|input|select|textarea|label|summary)$/i.test(n.tagName) || n.getAttribute('role') === 'button' || n.onclick) return n;
    }
    return el;
  };
  document.addEventListener('click', (e) => {
    const target = describe(clickable(e.target));
    if (!target) return;
    add(self.actions, { t: Date.now(), kind: 'click', x: Math.round(e.clientX), y: Math.round(e.clientY), button: e.button,
      modifiers: { altKey: e.altKey, ctrlKey: e.ctrlKey, metaKey: e.metaKey, shiftKey: e.shiftKey }, target });
  }, true);
  document.addEventListener('change', (e) => {
    const el = e.target;
    if (!el || !/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) return;
    const type = (el.getAttribute('type') || '').toLowerCase();
    let text = type === 'checkbox' || type === 'radio' ? (el.checked ? 'checked' : 'unchecked') : String(el.value || '');
    const hidden = sensitive(el);
    add(self.actions, { t: Date.now(), kind: 'input', target: describe(el), text: hidden ? '***' : clip(text, 128), redacted: hidden });
  }, true);
  document.addEventListener('keydown', (e) => {
    if (/^(Shift|Control|Alt|Meta|AltGraph|CapsLock)$/.test(e.key)) return;
    if (!/^(Enter|Escape|Tab|Backspace|Delete|Arrow\w+|F\d+)$/.test(e.key) && !(e.ctrlKey || e.metaKey)) return;
    if (e.repeat) return;
    let key = e.key;
    if ((e.ctrlKey || e.metaKey) && key.length === 1) key = (e.ctrlKey ? 'Control+' : 'Meta+') + key;
    add(self.actions, { t: Date.now(), kind: 'key', key, target: describe(e.target) });
  }, true);
  const navigated = (how) => add(self.actions, { t: Date.now(), kind: 'navigation', url: location.href, how });
  for (const name of ['pushState', 'replaceState']) {
    const original = history[name];
    if (typeof original !== 'function') continue;
    history[name] = disguise(function () {
      const r = original.apply(this, arguments);
      try { navigated(name); } catch (e) {}
      return r;
    }, original);
  }
  window.addEventListener('popstate', () => navigated('popstate'));
  window.addEventListener('hashchange', () => navigated('hashchange'));

  // --- handing it over -----------------------------------------------------------------------------------------
  const newer = (list, since) => list.filter((x) => x.seq > since);
  self.dump = (id, sinceByDoc) => {
    // sinceByDoc: what webby already has of each document's entries ({doc: seq}).
    const since = (sinceByDoc && sinceByDoc[self.doc]) || 0;
    // prompt() while the document is still parsing can wedge Ladybird's navigation, so that waits.
    const go = () => send({
      type: 'bugDump', id, doc: self.doc, seq: self.seq, url: location.href, title: document.title,
      userAgent: navigator.userAgent, language: navigator.language,
      viewport: { width: innerWidth, height: innerHeight, dpr: window.devicePixelRatio || 1 },
      timeOrigin: Math.round(performance.timeOrigin || 0),
      console: newer(self.console, since), network: newer(self.network, since),
      actions: newer(self.actions, since), resources: resources(),
    });
    // A document whose parser never finishes (Ladybird gives up on some) still answers after a while.
    if (document.readyState === 'loading') {
      let sent = false;
      const once = () => { if (!sent) { sent = true; go(); } };
      document.addEventListener('DOMContentLoaded', once, { once: true });
      setTimeout(once, 1500);
    } else go();
  };
  Object.defineProperty(window, '__webbyBug', { value: self, enumerable: false });
})();
