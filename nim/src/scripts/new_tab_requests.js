
(() => {
  if (window.__webbyOpen) return;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  const open = window.open;
  if (typeof open !== 'function') return;
  window.__webbyOpen = true;
  const send = (message) => { try { prompt.call(window, PREFIX + JSON.stringify(message)); return true; } catch (e) { return false; } };
  const wrapped = function (url, target, features) {
    try {
      const name = target === undefined || target === null || target === '' ? '_blank' : String(target);
      const words = String(features === undefined || features === null ? '' : features).toLowerCase().split(/[\s,]+/);
      const detached = words.some((w) => w === 'noopener' || w === 'noreferrer' || w === 'noopener=1' || w === 'noreferrer=1');
      const activated = !navigator.userActivation || navigator.userActivation.isActive;
      if (name.toLowerCase() === '_blank' && detached && activated && url !== undefined && url !== null && url !== '') {
        const href = new URL(String(url), document.baseURI).href;
        if (/^https?:/i.test(href) && send({ type: 'openTab', url: href })) return null;
      }
    } catch (e) {}
    return open.apply(this, arguments);
  };
  try { Object.defineProperty(wrapped, 'toString', { value: () => open.toString(), configurable: true }); } catch (e) {}
  window.open = wrapped;
  // A plain click on <a target=_blank> (noopener unless rel=opener) would open the same shared window; the page's
  // own handlers run first, and a click they took over is left alone.
  window.addEventListener('click', (event) => {
    try {
      if (event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
      const link = event.target && event.target.closest ? event.target.closest('a[href], area[href]') : null;
      if (!link || String(link.target).toLowerCase() !== '_blank' || link.hasAttribute('download')) return;
      if (/(^|\s)opener(\s|$)/i.test(link.rel || '')) return;
      if (!/^https?:/i.test(link.href)) return;
      if (send({ type: 'openTab', url: link.href })) event.preventDefault();
    } catch (e) {}
  });
})();
