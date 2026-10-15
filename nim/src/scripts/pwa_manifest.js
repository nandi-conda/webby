
(() => {
  if (window.__webbyManifest) return;
  window.__webbyManifest = true;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  let last = null;
  const report = () => {
    const link = document.querySelector('link[rel~="manifest"][href]');
    const href = link ? link.href : '';
    if (href === last) return;
    last = href;
    try { prompt.call(window, PREFIX + JSON.stringify({ type: 'manifest', href })); } catch (e) {}
  };
  report();
  try { new MutationObserver(report).observe(document.head || document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel'] }); } catch (e) {}
})();
