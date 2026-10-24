(() => {
  // A small "Ask AI about this" button next to text the user selects. Clicking it posts
  // {"type": "askselection", "text", "title", "url"} as a page message; Summarize opens its panel with the selection.
  if (window.__webbyAskSelection || window.top !== window) return;
  window.__webbyAskSelection = true;
  const PREFIX = ${jsonEncode(prefix)};
  const MAX = 8000;

  // Pages sometimes replace window.prompt; use a pristine one from a fresh frame if so.
  const isNative = (f) => { try { return /\[native code\]/.test(Function.prototype.toString.call(f)); } catch (e) { return false; } };
  const send = (message) => {
    let host = window;
    if (!isNative(window.prompt)) {
      try {
        const frame = document.createElement('iframe');
        frame.style.display = 'none';
        (document.body || document.documentElement).appendChild(frame);
        host = frame.contentWindow;
      } catch (e) {}
    }
    const text = PREFIX + JSON.stringify(message);
    setTimeout(() => { try { host.prompt.call(host, text); } catch (e) {} }, 0);
  };

  let holder = null;
  let button = null;
  let range = null;
  let text = '';
  let pressed = false;
  let timer = 0;

  const build = () => {
    holder = document.createElement('div');
    Object.assign(holder.style, { position: 'fixed', zIndex: '2147483647', left: '0px', top: '0px', display: 'none',
      margin: '0', padding: '0', border: '0' });
    const root = holder.attachShadow ? holder.attachShadow({ mode: 'closed' }) : holder;
    button = document.createElement('button');
    button.type = 'button';
    button.textContent = '✦ Ask AI about this';
    const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    Object.assign(button.style, { all: 'initial', display: 'block', cursor: 'pointer', whiteSpace: 'nowrap',
      font: '500 13px/1 system-ui, -apple-system, "Segoe UI", sans-serif', padding: '8px 12px', borderRadius: '16px',
      background: dark ? '#e8eaed' : '#202124', color: dark ? '#202124' : '#ffffff',
      boxShadow: '0 2px 8px rgba(0,0,0,0.3)', userSelect: 'none' });
    button.addEventListener('mouseenter', () => { button.style.opacity = '0.88'; });
    button.addEventListener('mouseleave', () => { button.style.opacity = '1'; });
    root.appendChild(button);
    // Keep the selection (and the page's own handlers out of it): a press here mustn't clear or change it.
    for (const type of ['mousedown', 'pointerdown', 'touchstart', 'mouseup', 'pointerup', 'touchend', 'dblclick',
      'contextmenu']) {
      holder.addEventListener(type, (event) => {
        event.stopPropagation();
        if (type === 'mousedown' || type === 'pointerdown') event.preventDefault();
      });
    }
    holder.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      const message = { type: 'askselection', text, title: document.title || '', url: location.href };
      hide();
      // Never prompt() while the document is still being parsed: it wedges Ladybird.
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => send(message), { once: true });
      } else send(message);
    });
  };

  const hide = () => {
    if (holder) holder.style.display = 'none';
    range = null;
  };

  const inEditable = (node) => {
    for (let el = node && node.nodeType === 1 ? node : node && node.parentElement; el; el = el.parentElement) {
      if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el.isContentEditable) return true;
    }
    return false;
  };

  const place = () => {
    if (!range || !holder) return;
    const rects = range.getClientRects();
    const last = rects.length ? rects[rects.length - 1] : range.getBoundingClientRect();
    const first = rects.length ? rects[0] : last;
    if (!last || (last.width === 0 && last.height === 0 && last.top === 0)) { hide(); return; }
    holder.style.display = 'block';
    const w = holder.offsetWidth || 150;
    const h = holder.offsetHeight || 30;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    let top = last.bottom + 8;
    if (top + h > vh - 4) top = first.top - h - 8;
    if (last.bottom < 0 || first.top > vh) { holder.style.display = 'none'; return; }
    let left = last.right - w / 2;
    left = Math.max(4, Math.min(vw - w - 4, left));
    top = Math.max(4, Math.min(vh - h - 4, top));
    holder.style.left = Math.round(left) + 'px';
    holder.style.top = Math.round(top) + 'px';
  };

  const update = () => {
    timer = 0;
    if (pressed) return;
    let selection = null;
    try { selection = document.getSelection(); } catch (e) {}
    const selected = selection ? String(selection).trim() : '';
    if (!selection || selection.isCollapsed || selection.rangeCount === 0 || selected.length < 2 ||
        inEditable(selection.anchorNode) || inEditable(document.activeElement)) {
      hide();
      return;
    }
    if (!holder) build();
    if (!holder.isConnected) (document.body || document.documentElement).appendChild(holder);
    text = selected.slice(0, MAX);
    range = selection.getRangeAt(0).cloneRange();
    place();
  };

  const soon = (ms) => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(update, ms);
  };

  const fromHolder = (event) => holder && event.composedPath && event.composedPath().includes(holder);
  window.addEventListener('mousedown', (event) => {
    if (fromHolder(event)) return;
    pressed = true;
    hide();
  }, true);
  window.addEventListener('mouseup', (event) => {
    if (fromHolder(event)) return;
    pressed = false;
    if (event.button !== 0) return;   // a right-click's menu has its own "Ask AI about this"
    soon(10);
  }, true);
  window.addEventListener('touchend', () => { pressed = false; soon(300); }, true);
  window.addEventListener('keyup', (event) => {
    if (event.key === 'Escape') hide();
    else if (event.shiftKey || event.key === 'Shift' || ((event.ctrlKey || event.metaKey) && event.key === 'a')) soon(150);
  }, true);
  document.addEventListener('selectionchange', () => { if (!pressed) soon(250); });
  window.addEventListener('scroll', () => { if (range) place(); }, true);
  window.addEventListener('resize', () => { if (range) place(); });
})();
