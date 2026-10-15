
(() => {
  const QUOTE = ${jsonEncode(words)};
  let WORD;
  try { WORD = new RegExp('[\\p{L}\\p{N}]+', 'gu'); } catch (e) { WORD = /[^\s!-\/:-@\[-`{-~ -¿ -⁯　-〿]+/g; }
  const fold = (s) => {
    s = String(s).toLowerCase();
    try { s = s.normalize('NFKD').replace(/[̀-ͯ]/g, ''); } catch (e) {}
    return s;
  };
  const tokensOf = (s) => fold(s).match(WORD) || [];
  const want = tokensOf(QUOTE);
  if (!want.length) return false;
  const visible = (el) => { try { return el.getClientRects().length > 0; } catch (e) { return true; } };
  const go = (el) => {
    for (let p = el; p; p = p.parentElement) if (p.tagName === 'DETAILS' && !p.open) p.open = true;
    while (el.parentElement && (!visible(el) || /^(SPAN|A|B|I|EM|STRONG|CODE|MARK|SMALL|SUP|SUB|ABBR|CITE|Q|S|U)$/.test(el.tagName))) el = el.parentElement;
    try { el.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (e) { el.scrollIntoView(); }
    const style = el.style, background = style.backgroundColor, outline = style.outline;
    style.backgroundColor = 'rgba(255, 213, 79, 0.45)';
    style.outline = '2px solid rgba(255, 179, 0, 0.9)';
    setTimeout(() => { style.backgroundColor = background; style.outline = outline; }, 1800);
    return true;
  };
  const headings = [...document.querySelectorAll('h1, h2, h3, h4, h5, h6, [role="heading"]')];
  const same = (a, b) => a.length === b.length && a.every((t, i) => t === b[i]);
  const heading = headings.find((h) => visible(h) && same(tokensOf(h.textContent), want));
  if (heading) return go(heading);

  // Every word on the page, with the element holding it. A word split by markup (foo<b>bar</b>) stays one word.
  const BLOCK = /^(P|DIV|LI|H[1-6]|TD|TH|TR|SECTION|ARTICLE|BLOCKQUOTE|PRE|DT|DD|FIGCAPTION|HEADER|MAIN|UL|OL|TABLE|BR|DETAILS|SUMMARY)$/;
  const SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|HEAD)$/;
  const blockOf = (el) => { while (el && !BLOCK.test(el.tagName)) el = el.parentElement; return el; };
  const toks = [], owners = [];
  let lastBlock = null, joinable = false;
  const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const parent = node.parentElement;
    if (!parent || SKIP.test(parent.tagName.toUpperCase())) continue;
    const text = fold(node.nodeValue);
    if (!text.trim()) { joinable = false; continue; }
    const block = blockOf(parent);
    if (block !== lastBlock) joinable = false;
    lastBlock = block;
    WORD.lastIndex = 0;
    let match, end = -1;
    while ((match = WORD.exec(text))) {
      if (match.index === 0 && joinable && toks.length) toks[toks.length - 1] += match[0];
      else { toks.push(match[0]); owners.push(parent); }
      end = match.index + match[0].length;
    }
    joinable = end === text.length;
  }
  const page = ' ' + toks.join(' ') + ' ';
  const starts = [];
  for (let i = 0, at = 1; i < toks.length; i++) { starts.push(at); at += toks[i].length + 1; }
  const tokenAt = (offset) => {
    let lo = 0, hi = starts.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= offset) lo = mid; else hi = mid - 1; }
    return lo;
  };
  // The element of the first visible place showing the word sequence [seq], else of the first hidden one.
  const find = (seq) => {
    const needle = ' ' + seq.join(' ') + ' ';
    let hidden = null;
    for (let at = page.indexOf(needle); at >= 0; at = page.indexOf(needle, at + 1)) {
      const owner = owners[tokenAt(at + 1)];
      if (visible(owner)) return owner;
      hidden = hidden || owner;
    }
    return hidden;
  };
  const whole = find(want);
  if (whole) return go(whole);
  for (let size = want.length - 1; size >= 2; size--) {
    for (let from = 0; from + size <= want.length; from++) {
      const run = want.slice(from, from + size);
      if (size < 3 && run.some((t) => t.length < 4)) continue;
      const owner = find(run);
      if (owner) return go(owner);
    }
  }
  const wanted = new Set(want.filter((t) => t.length >= 3));
  let best = null, bestScore = 0;
  for (const h of headings) {
    const score = new Set(tokensOf(h.textContent).filter((t) => wanted.has(t))).size;
    if (score > bestScore) { best = h; bestScore = score; }
  }
  return best ? go(best) : false;
})();
