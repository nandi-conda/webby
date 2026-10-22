
(() => {
  if (window.__webbyManifest) return;
  window.__webbyManifest = true;
  const PREFIX = ${jsonEncode(prefix)};
  const prompt = window.prompt;
  let last = null;
  // Not while the document is still being parsed: a prompt() then can leave Ladybird's parser paused for good (no
  // DOMContentLoaded, no first paint, the page loading forever; joshuamorris.info's head scripts adding <link>s did it).
  // A change seen while loading is reported on DOMContentLoaded instead.
  const report = () => {
    if (document.readyState === 'loading') return;
    const link = document.querySelector('link[rel~="manifest"][href]');
    const href = link ? link.href : '';
    if (href === last) return;
    last = href;
    try { prompt.call(window, PREFIX + JSON.stringify({ type: 'manifest', href })); } catch (e) {}
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', report, { once: true });
  else report();
  try { new MutationObserver(report).observe(document.head || document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel'] }); } catch (e) {}
})();
