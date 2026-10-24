
(() => {
  if (window.__webbyAtPassport) return;
  const PREFIX = ${jsonEncode(prefix)};

  // Messages go through prompt(PREFIX + json), from a timer, and never while the document is still being parsed
  // (a prompt() then can leave Ladybird's parser paused for good). A page's own window.prompt may be replaced, so use
  // a pristine one from a fresh frame if so (as scripts/passwords.js does).
  let host = window;
  const isNative = (f) => { try { return /\[native code\]/.test(Function.prototype.toString.call(f)); } catch (e) { return false; } };
  if (!isNative(window.prompt)) {
    try {
      const frame = document.createElement('iframe');
      frame.style.display = 'none';
      (document.body || document.documentElement).appendChild(frame);
      host = frame.contentWindow;
    } catch (e) {}
  }
  const prompt = host.prompt;
  const queue = [];
  const flush = () => {
    if (document.readyState === 'loading') return;
    while (queue.length) {
      const text = queue.shift();
      setTimeout(() => { try { prompt.call(host, text); } catch (e) {} }, 0);
    }
  };
  const send = (message) => { queue.push(PREFIX + JSON.stringify(message)); flush(); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', flush, { once: true });

  // ---------------------------------------------------------------------------------------------------------------
  // Handle fields: what the @passport extension recognises (name="handle", id="handle", a placeholder or label that
  // says handle), plus Bluesky's own sign-in fields, which ask for a "username" on bsky.app and its PDS.

  const BLUESKY_HOSTS = /(^|\.)(bsky\.app|bsky\.social|bsky\.network)$/;
  const HANDLE_WORDS = /handle|ハンドル|\.bsky\.social|atproto|at protocol|bluesky/i;
  const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const isTextInput = (el) => el instanceof HTMLInputElement && !el.disabled && !el.readOnly &&
    ['text', 'email', 'search', 'url', ''].includes((el.getAttribute('type') || '').toLowerCase());
  const labelText = (el) => {
    let text = '';
    try { for (const l of el.labels || []) text += ' ' + l.textContent; } catch (e) {}
    return text;
  };
  function isHandleField(el) {
    if (!isTextInput(el)) return false;
    const name = (el.name || '').toLowerCase();
    const id = (el.id || '').toLowerCase();
    if (name === 'handle' || id === 'handle' || /(^|[-_])handle([-_]|$)/.test(name)) return true;
    if (HANDLE_WORDS.test([el.placeholder, el.getAttribute('aria-label'), labelText(el)].join(' '))) return true;
    if (BLUESKY_HOSTS.test(location.hostname)) {
      const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
      return /\busername\b/.test(autocomplete) || el.getAttribute('data-testid') === 'loginUsernameInput' ||
        /user(name)?|login_hint|identifier/i.test(name + ' ' + id);
    }
    return false;
  }
  const handleFields = () => Array.from(document.querySelectorAll('input')).filter((el) => isHandleField(el) && visible(el));

  let lastField = null;
  let offered = false;
  const offer = (el, focused) => {
    lastField = el;
    enableFedCm();
    if (offered && !focused) return;
    offered = true;
    send({ type: 'offer', focused: !!focused, empty: !el.value });
  };
  document.addEventListener('focusin', (event) => {
    const el = event.target;
    if (isHandleField(el)) offer(el, true);
  }, true);
  // A sign-in field already on the page (or one a single-page app adds later) offers the handles too.
  let checkTimer = 0;
  const check = () => {
    checkTimer = 0;
    if (document.readyState === 'loading') return;
    const active = document.activeElement;
    if (active && isHandleField(active)) { offer(active, true); return; }
    const fields = handleFields();
    if (fields.length) offer(fields[0], false);
    else if (offered && !(lastField && lastField.isConnected)) { offered = false; lastField = null; send({ type: 'gone' }); }
  };
  const later = () => { if (!checkTimer) checkTimer = setTimeout(check, 400); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', later, { once: true });
  else later();
  try { new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {}

  // Puts a handle in a field the way a person typing would look to React and co.
  function setValue(input, value) {
    const proto = input instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value');
    input.focus();
    if (setter && setter.set) setter.set.call(input, value); else input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // The field to fill: the handle field last focused or found, else the focused text field, else the selectors the
  // @passport extension tries.
  function target() {
    if (lastField && lastField.isConnected && isTextInput(lastField)) return lastField;
    const active = document.activeElement;
    if (active && (isTextInput(active) || active instanceof HTMLTextAreaElement)) return active;
    const fields = handleFields();
    if (fields.length) return fields[0];
    for (const selector of ['input[name="handle"]', 'input[id="handle"]', 'input[placeholder*="handle" i]',
      'input[autocomplete="username"]']) {
      const el = document.querySelector(selector);
      if (el && isTextInput(el) && visible(el)) return el;
    }
    return null;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // FedCM handle assist (@atpassport/client's requestHandleAssist): navigator.credentials.get() with @passport's
  // FedCM config. Ladybird has no FedCM, so webby answers these itself with its own account chooser, the way the
  // @passport Firefox extension does. The answer is the same token @passport's IdP gives:
  // {"v":1,"did":...,"username":...}, a hint for the site's OAuth sign-in, not a credential.

  const isAtPassportConfig = (configURL) => {
    if (typeof configURL !== 'string' || !configURL) return false;
    try {
      const url = new URL(configURL, location.href);
      const h = url.hostname.toLowerCase();
      const loopback = h === 'localhost' || h === '127.0.0.1' || h === '[::1]';
      if (!loopback && (url.protocol !== 'https:' || !(h === 'atpassport.net' || h.endsWith('.atpassport.net')))) return false;
      return url.pathname === '/fedcm/config.json';
    } catch (e) { return false; }
  };

  const pending = new Map();
  let nextRequest = 1;
  const nav = navigator;
  try {
    if (!nav.credentials) Object.defineProperty(nav, 'credentials', { value: {}, configurable: true });
    const credentials = nav.credentials;
    const originalGet = typeof credentials.get === 'function' ? credentials.get.bind(credentials) : null;
    credentials.get = function (options) {
      const providers = options && options.identity && options.identity.providers;
      if (!Array.isArray(providers) || !providers.some((p) => p && isAtPassportConfig(p.configURL))) {
        if (originalGet) return originalGet(options);
        return Promise.reject(new DOMException('The operation is not supported.', 'NotSupportedError'));
      }
      return new Promise((resolve, reject) => {
        const id = nextRequest++;
        pending.set(id, { resolve, reject });
        const signal = options && options.signal;
        if (signal) signal.addEventListener('abort', () => {
          if (pending.delete(id)) reject(new DOMException('The request was aborted.', 'AbortError'));
        });
        send({ type: 'fedcm', id, rp: location.hostname });
      });
    };
  } catch (e) {}

  // Feature checks (isHandleAssistSupported) look for IdentityCredential and the identity-credentials-get policy.
  // Only on pages with a handle field: elsewhere a site could take it to mean FedCM works for its own sign-in.
  const enableFedCm = () => {
    if ('IdentityCredential' in window) return;
    window.IdentityCredential = class IdentityCredential {};
    for (const policy of [document.permissionsPolicy, document.featurePolicy]) {
      if (!policy || typeof policy.allowsFeature !== 'function') continue;
      const allows = policy.allowsFeature.bind(policy);
      try { policy.allowsFeature = (feature, ...rest) => feature === 'identity-credentials-get' || allows(feature, ...rest); } catch (e) {}
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // On atpassport.net itself: read the handles registered in this browser's @passport session (the same API the
  // extension reads, same-origin here) and hand them to webby, now and after each change on the page.

  const isAtPassportSite = location.protocol === 'https:' &&
    (location.hostname === 'atpassport.net' || location.hostname === 'preview.atpassport.net');
  let lastAccounts = '';
  let syncTimer = 0;
  const syncAccounts = async () => {
    syncTimer = 0;
    try {
      const r = await fetch('/api/user/handles', { credentials: 'include', cache: 'no-store' });
      if (r.status === 401) { send({ type: 'accounts', signedOut: true }); return; }
      if (!r.ok) return;
      const data = await r.json();
      const accounts = Array.isArray(data.accounts) ? data.accounts
        : Array.isArray(data.handles) ? data.handles.map((handle) => ({ handle })) : null;
      if (!accounts) return;
      const text = JSON.stringify(accounts);
      if (text === lastAccounts) return;
      lastAccounts = text;
      send({ type: 'accounts', accounts });
    } catch (e) {}
  };
  // At most every few seconds: the API allows 20 requests a minute.
  const syncSoon = (ms) => { if (!syncTimer) syncTimer = setTimeout(syncAccounts, ms); };
  if (isAtPassportSite) {
    syncSoon(document.readyState === 'loading' ? 1500 : 300);
    document.addEventListener('click', () => syncSoon(3000), true);
    document.addEventListener('submit', () => syncSoon(3000), true);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) syncSoon(500); });
  }

  window.__webbyAtPassport = {
    // Puts `handle` in the page's handle field; tells webby whether there was one (it copies the handle if not).
    fill(handle) {
      const el = target();
      if (el) setValue(el, handle);
      send({ type: 'filled', ok: !!el, handle });
    },
    // webby's answer to a FedCM request: the chosen account's token, or an error name.
    answer(id, token, error) {
      const p = pending.get(id);
      if (!p) return;
      pending.delete(id);
      if (token) p.resolve({ type: 'identity', token, isAutoSelected: false });
      else p.reject(new DOMException(error === 'IdentityCredentialError'
        ? 'No @passport handles in this browser.' : 'The user closed the account chooser.', error || 'AbortError'));
    },
  };
})();
