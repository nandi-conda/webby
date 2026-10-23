
(() => {
  if (location.href !== 'about:blank' || window.top !== window || window.opener) return;
  const d = document;
  if (d.getElementById('webby-home') || (d.body && d.body.children.length)) return;
  const data = __WEBBY_HOME_DATA__;

  const scheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;
  // The address bar's rule: an address loads, anything else searches the engine the address bar uses.
  const queryUrl = data.queryUrl || 'https://www.google.com/search?q=%s';
  const toUrl = (text) => {
    const t = text.trim();
    if (!t) return '';
    const search = queryUrl.split('%s').join(encodeURIComponent(t));
    if (/\s/.test(t)) return search;
    const s = scheme.exec(t);
    if (s && !/^[^:]+:\d/.test(t)) {
      const known = ['about:', 'data:', 'file:', 'mailto:', 'view-source:'];
      return t.includes('://') || known.includes(s[0].toLowerCase()) ? t : search;
    }
    let authority = t.split(/[/?#]/)[0];
    if (authority.includes('@')) authority = authority.split('@').pop();
    const m = /^(\[[0-9a-fA-F:.]+\]|[^\s/:?#@]+)(:\d{1,5})?$/.exec(authority);
    if (!m) return search;
    const host = m[1].toLowerCase();
    if (host === 'localhost' || host.startsWith('[') || /^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return 'http://' + t;
    return /^([a-z0-9-]+\.)+[a-z]{2,63}\.?$/.test(host) ? 'https://' + t : search;
  };

  const el = (tag, cls, text) => {
    const e = d.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  };
  const hostOf = (url) => { try { return new URL(url).hostname.replace(/^www\./, ''); } catch (e) { return url; } };
  const hue = (s) => { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) % 360; return h; };

  const tile = (item) => {
    const host = hostOf(item.url);
    const a = el('a', 'tile');
    a.href = item.url;
    a.title = item.title ? item.title + '\n' + item.url : item.url;
    const badge = el('span', 'badge', (host[0] || '?').toUpperCase());
    badge.style.setProperty('--h', hue(host));
    const text = el('span', 'text');
    text.append(el('span', 'name', item.title || host), el('span', 'host', host));
    a.append(badge, text);
    return a;
  };
  const section = (title, items) => {
    const s = el('section');
    s.append(el('h2', '', title));
    const grid = el('div', 'grid');
    for (const item of items) grid.append(tile(item));
    s.append(grid);
    return s;
  };

  d.title = '';
  const meta = el('meta');
  meta.name = 'viewport';
  meta.content = 'width=device-width, initial-scale=1';
  const style = el('style');
  style.textContent = `
    :root { color-scheme: light dark; --bg: #f6f6f7; --card: #ffffff; --hover: #ececee; --text: #1d1d1f;
      --dim: #6e6e73; --line: #d9d9de; --accent: #2f6fde; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #1b1b1d; --card: #262628; --hover: #313134; --text: #ececee; --dim: #9a9aa0; --line: #3a3a3e;
        --accent: #6d9cff; }
    }
    html, body { margin: 0; min-height: 100%; background: var(--bg); color: var(--text);
      font: 14px/1.4 Inter, "Noto Sans", "DejaVu Sans", system-ui, sans-serif; }
    #webby-home { box-sizing: border-box; max-width: 760px; margin: 0 auto; padding: 14vh 20px 48px; }
    #webby-home.empty { padding-top: 30vh; }
    .logo { font-size: 40px; font-weight: 700; letter-spacing: -1px; text-align: center; margin: 0 0 24px; }
    .logo span { color: var(--accent); }
    form { margin: 0 0 40px; }
    input { box-sizing: border-box; width: 100%; height: 48px; padding: 0 20px; border: 1px solid var(--line);
      border-radius: 24px; background: var(--card); color: var(--text); font: inherit; font-size: 16px; outline: none; }
    input:focus { border-color: var(--accent); }
    h2 { font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: var(--dim);
      margin: 28px 4px 10px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 8px; }
    .tile { display: flex; align-items: center; gap: 10px; min-width: 0; padding: 10px; border-radius: 10px;
      background: var(--card); color: inherit; text-decoration: none; }
    .tile:hover { background: var(--hover); }
    .badge { flex: none; width: 32px; height: 32px; border-radius: 50%; display: flex; align-items: center;
      justify-content: center; font-weight: 600; color: #fff; background: hsl(var(--h) 45% 46%); }
    .text { display: flex; flex-direction: column; min-width: 0; }
    .name, .host { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .host { font-size: 12px; color: var(--dim); }
  `;
  d.head.append(meta, style);

  const main = el('main');
  main.id = 'webby-home';
  const logo = el('div', 'logo', 'webb');
  logo.append(el('span', '', 'y'));
  const form = el('form');
  const input = el('input');
  input.type = 'text';
  input.placeholder = 'Search ' + (data.engine || 'Google') + ' or type a URL';
  input.autocomplete = 'off';
  input.spellcheck = false;
  form.append(input);
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const url = toUrl(input.value);
    if (url) location.href = url;
  });
  main.append(logo, form);
  const bookmarks = data.bookmarks || [];
  if (bookmarks.length) main.append(section('Bookmarks', bookmarks));
  else main.classList.add('empty');
  d.body.append(main);
})();
