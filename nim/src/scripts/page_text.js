
(() => {
  const PREFIX = ${jsonEncode(prefix)};
  const ID = ${jsonEncode(id)};
  const LIMIT = $maxSummaryInputChars;
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'CANVAS', 'IFRAME', 'NAV', 'FOOTER', 'ASIDE',
    'FORM', 'BUTTON', 'SELECT', 'INPUT', 'TEXTAREA', 'HEAD']);
  const BLOCK = new Set(['P', 'DIV', 'LI', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BR', 'TR', 'SECTION', 'ARTICLE', 'PRE',
    'BLOCKQUOTE', 'UL', 'OL', 'TABLE', 'HEADER', 'MAIN', 'FIGCAPTION', 'DT', 'DD']);
  const textOf = (root) => {
    const out = [];
    let size = 0;
    const walk = (node) => {
      if (size > LIMIT) return;
      if (node.nodeType === 3) {
        const t = node.nodeValue.replace(/\s+/g, ' ');
        if (t.trim()) { out.push(t); size += t.length; }
        return;
      }
      if (node.nodeType !== 1) return;
      const tag = node.tagName.toUpperCase();
      if (SKIP.has(tag) || node.hidden || node.getAttribute('aria-hidden') === 'true') return;
      if (node.getAttribute('role') === 'navigation') return;
      const block = BLOCK.has(tag);
      if (/^H[1-6]$/.test(tag)) out.push('\n## ');
      else if (block) out.push('\n');
      for (let child = node.firstChild; child; child = child.nextSibling) walk(child);
      if (block) out.push('\n');
    };
    walk(root);
    return out.join('').replace(/[ \t]*\n[ \t\n]*/g, '\n').replace(/ {2,}/g, ' ').trim();
  };
  let text = '';
  let selection = false;
  try {
    const selected = String(window.getSelection ? window.getSelection() : '').trim();
    if (selected.length >= $minSelection) { text = selected; selection = true; }
  } catch (e) {}
  if (!text) {
    const body = document.body || document.documentElement;
    const candidates = [document.querySelector('article'), document.querySelector('main'),
      document.querySelector('[role="main"]')];
    for (const candidate of candidates) {
      if (!candidate) continue;
      const t = textOf(candidate);
      if (t.length >= 500) { text = t; break; }
    }
    if (!text && body) text = textOf(body);
  }
  const message = { type: 'pagetext', id: ID, selection, title: document.title || '', url: location.href,
    lang: document.documentElement.lang || '', text: text.slice(0, LIMIT) };
  const prompt = window.prompt, sent = PREFIX + JSON.stringify(message);
  setTimeout(() => { try { prompt.call(window, sent); } catch (e) {} }, 0);
})();
