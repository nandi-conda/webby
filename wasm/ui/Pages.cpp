/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Pages.h"
#include "Profile.h"

#include <QDateTime>
#include <QUrl>

using namespace Qt::StringLiterals;

namespace WebbyUI::Pages {

static QString const style = uR"css(
body { font-family: sans-serif; margin: 0; background: #fff; color: #202124; }
main { max-width: 860px; margin: 32px auto; padding: 0 24px; }
h1 { font-size: 26px; font-weight: normal; margin: 0 0 20px; }
h2 { font-size: 14px; color: #5f6368; margin: 24px 0 6px; font-weight: bold; }
ul { list-style: none; margin: 0; padding: 0; }
li { display: flex; gap: 12px; padding: 6px 8px; border-radius: 6px; align-items: baseline; }
li:hover { background: #f1f3f4; }
.time { color: #5f6368; font-size: 12px; min-width: 44px; }
a { color: #1a0dab; text-decoration: none; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.host { color: #5f6368; font-size: 12px; white-space: nowrap; }
.empty { color: #5f6368; }
)css"_s;

static QString pages_dir() { return Profile::dir() + u"/pages"_s; }

QString write_page(QString const& name, QString const& title, QString const& body)
{
    auto path = pages_dir() + u'/' + name;
    auto html = u"<!doctype html><html><head><meta charset=\"utf-8\"><title>"_s + title + u"</title><style>"_s + style
        + u"</style></head><body><main><h1>"_s + title + u"</h1>"_s + body + u"</main></body></html>"_s;
    if (!Profile::write_atomic(path, html.toUtf8()))
        return {};
    return QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded);
}

static QString row(QString const& url, QString const& title, QString const& time = {})
{
    auto host = QUrl(url).host();
    auto label = title.isEmpty() ? url : title;
    QString out = u"<li>"_s;
    if (!time.isNull())
        out += u"<span class=\"time\">"_s + time + u"</span>"_s;
    out += u"<a href=\""_s + url.toHtmlEscaped() + u"\" title=\""_s + url.toHtmlEscaped() + u"\">"_s + label.toHtmlEscaped()
        + u"</a><span class=\"host\">"_s + host.toHtmlEscaped() + u"</span></li>"_s;
    return out;
}

QString history_page()
{
    auto const& visits = Profile::History::the().visits();
    QString body;
    QString day;
    int shown = 0;
    for (auto i = visits.size() - 1; i >= 0 && shown < 1000; --i, ++shown) {
        auto const& v = visits[i];
        auto when = QDateTime::fromMSecsSinceEpoch(v.time);
        auto d = when.date().toString(u"dddd, d MMMM yyyy"_s);
        if (d != day) {
            body += day.isEmpty() ? u""_s : u"</ul>"_s;
            body += u"<h2>"_s + d + u"</h2><ul>"_s;
            day = d;
        }
        body += row(v.url, v.title, when.toString(u"HH:mm"_s));
    }
    if (shown)
        body += u"</ul>"_s;
    else
        body = u"<p class=\"empty\">Pages you visit show up here.</p>"_s;
    return write_page(u"history.html"_s, u"History"_s, body);
}

static void folder_rows(Profile::Bookmark const& folder, QString& body)
{
    for (auto const& c : folder.children) {
        if (c.folder) {
            body += u"<h2>"_s + c.title.toHtmlEscaped() + u"</h2><ul>"_s;
            folder_rows(c, body);
            body += u"</ul>"_s;
        } else {
            body += row(c.url, c.title);
        }
    }
}

QString bookmarks_page()
{
    auto const& b = Profile::Bookmarks::the();
    QString body;
    for (auto const* root : { &b.bar(), &b.other() }) {
        if (root->children.isEmpty())
            continue;
        body += u"<h2>"_s + root->title.toHtmlEscaped() + u"</h2><ul>"_s;
        folder_rows(*root, body);
        body += u"</ul>"_s;
    }
    if (body.isEmpty())
        body = u"<p class=\"empty\">No bookmarks yet. Press Ctrl+D or click the star in the address bar to add the page.</p>"_s;
    return write_page(u"bookmarks.html"_s, u"Bookmarks"_s, body);
}

static QString human_size(qint64 bytes)
{
    if (bytes < 1024)
        return QStringLiteral("%1 B").arg(bytes);
    if (bytes < 1024 * 1024)
        return QStringLiteral("%1 KB").arg(bytes / 1024.0, 0, 'f', 1);
    return QStringLiteral("%1 MB").arg(bytes / (1024.0 * 1024.0), 0, 'f', 1);
}

QString downloads_page()
{
    auto downloads = Profile::read_downloads();
    QString body;
    for (auto i = downloads.size() - 1; i >= 0; --i) {
        auto const& d = downloads[i];
        auto when = QDateTime::fromMSecsSinceEpoch(d.time).toString(u"d MMM HH:mm"_s);
        auto name = d.path.isEmpty() ? QUrl(d.url).fileName() : d.path.section(u'/', -1);
        body += u"<li><span class=\"time\">"_s + when + u"</span>"_s;
        if (d.error.isEmpty())
            body += u"<a href=\""_s + QUrl::fromLocalFile(d.path).toString(QUrl::FullyEncoded).toHtmlEscaped() + u"\" title=\""_s
                + d.path.toHtmlEscaped() + u"\">"_s + name.toHtmlEscaped() + u"</a><span class=\"host\">"_s
                + human_size(d.size) + u" · "_s + QUrl(d.url).host().toHtmlEscaped() + u"</span>"_s;
        else
            body += u"<span>"_s + name.toHtmlEscaped() + u"</span><span class=\"host\">Failed: "_s + d.error.toHtmlEscaped()
                + u"</span>"_s;
        body += u"</li>"_s;
    }
    if (body.isEmpty())
        body = u"<p class=\"empty\">Files you download show up here.</p>"_s;
    else
        body = u"<ul>"_s + body + u"</ul>"_s;
    return write_page(u"downloads.html"_s, u"Downloads"_s, body);
}

QString shortcuts_page()
{
    static char const* const rows[][2] = {
        { "Ctrl+T", "New tab" }, { "Ctrl+W", "Close tab" }, { "Ctrl+Shift+T", "Reopen closed tab" },
        { "Ctrl+Tab, Ctrl+PgDn", "Next tab" }, { "Ctrl+Shift+Tab, Ctrl+PgUp", "Previous tab" }, { "Ctrl+1 … Ctrl+8", "Go to tab" },
        { "Ctrl+9", "Last tab" }, { "Ctrl+L, Alt+D, F6", "Address bar" }, { "Ctrl+K", "Search from the address bar" },
        { "Alt+Left, Alt+Right", "Back, forward" }, { "Ctrl+R, F5", "Reload" }, { "Alt+Home", "Home page" },
        { "Ctrl+F, F3, Ctrl+G", "Find in page, next match" }, { "Ctrl+=, Ctrl+-, Ctrl+0", "Zoom in, out, reset" },
        { "Ctrl+D", "Bookmark this page" }, { "Ctrl+Shift+B", "Show bookmarks bar" }, { "Ctrl+Shift+O", "Bookmark manager" },
        { "Ctrl+H", "History" }, { "Ctrl+J", "Downloads" }, { "Middle-click, Ctrl+click a link", "Open link in new tab" },
    };
    QString body = u"<ul>"_s;
    for (auto const& r : rows)
        body += u"<li><span class=\"key\">"_s + QString::fromUtf8(r[0]).toHtmlEscaped() + u"</span><span>"_s
            + QString::fromUtf8(r[1]).toHtmlEscaped() + u"</span></li>"_s;
    body += u"</ul><style>.key { min-width: 260px; color: #5f6368; font-family: monospace; }</style>"_s;
    return write_page(u"shortcuts.html"_s, u"Keyboard shortcuts"_s, body);
}

QString passwords_page()
{
    // Drawn by its script from what the browser sends (window.__webbyVaultShow); the browser gives this page alone
    // the channel (window.__webbyVault, Passwords.cpp).
    auto body = uR"html(<input id="search" type="search" placeholder="Search passwords" autocomplete="off">
<div id="note" class="empty">Opening the password vault…</div>
<div id="content"></div>
<style>
#search { width: 100%; box-sizing: border-box; font-size: 14px; padding: 8px 12px; border: 1px solid #dadce0; border-radius: 18px; margin-bottom: 8px; }
.row { display: flex; gap: 10px; align-items: center; padding: 6px 8px; border-radius: 6px; }
.row:hover { background: #f1f3f4; }
.site { min-width: 200px; max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.user { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #3c4043; }
.secret { font-family: monospace; min-width: 160px; color: #3c4043; }
button { font-size: 12px; padding: 3px 10px; border: 1px solid #dadce0; border-radius: 12px; background: #fff; color: #1a73e8; cursor: pointer; }
button:hover { background: #e8f0fe; }
button.danger { color: #d93025; }
.edit { display: flex; gap: 6px; padding: 4px 8px 10px; flex-wrap: wrap; }
.edit input { font-size: 13px; padding: 4px 8px; border: 1px solid #dadce0; border-radius: 6px; }
.warn { background: #fef7e0; padding: 8px 12px; border-radius: 6px; color: #5f4b00; margin: 8px 0; }
</style>
<script>
(() => {
  let data = null, editing = null, adding = false, shown = new Set();
  const $ = (tag, props = {}, ...children) => {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) { if (k === 'onclick') el.onclick = v; else el.setAttribute(k, v); }
    for (const c of children) el.append(c);
    return el;
  };
  const send = (m) => window.__webbyVault && window.__webbyVault.send(m);
  const host = (origin) => { try { return new URL(origin).host; } catch (e) { return origin; } };
  const button = (text, onclick, cls) => $('button', cls ? { class: cls, onclick } : { onclick }, text);
  const editor = (p) => {
    const user = $('input', { placeholder: 'Username', value: p ? p.username : '' });
    const pass = $('input', { placeholder: 'Password', value: p ? p.password : '' });
    const site = $('input', { placeholder: 'https://example.com' });
    window.__webbyVaultGenerated = (g) => { pass.value = g; };
    const save = () => {
      if (p) send({ type: 'update', id: p.id, username: user.value, password: pass.value });
      else send({ type: 'add', site: site.value.includes('://') ? site.value : 'https://' + site.value, username: user.value, password: pass.value });
      editing = null; adding = false;
    };
    return $('div', { class: 'edit' }, ...(p ? [] : [site]), user, pass, button('Generate', () => send({ type: 'generate' })),
      button('Save', save), button('Cancel', () => { editing = null; adding = false; render(); }));
  };
  function render() {
    const note = document.getElementById('note'), content = document.getElementById('content');
    content.textContent = '';
    if (!data) return;
    if (data.error) {
      note.textContent = data.error;
      content.append(button('Try again', () => send({ type: 'retry' })));
      if (data.canStartOver)
        content.append(' ', button('Start a new vault (keeps the old file)', () => send({ type: 'startOver' }), 'danger'));
      return;
    }
    note.textContent = '';
    if (data.keyInFile)
      content.append($('div', { class: 'warn' }, 'The vault key is in vault.key next to the vault (no desktop keyring was reachable). Opening webby on the desktop moves it into the keyring.'));
    const q = document.getElementById('search').value.toLowerCase();
    const match = (...s) => !q || s.some((x) => (x || '').toLowerCase().includes(q));
    const passwords = data.passwords.filter((p) => match(p.origin, p.username)).sort((a, b) => host(a.origin).localeCompare(host(b.origin)) || a.username.localeCompare(b.username));
    content.append($('h2', {}, `Passwords (${passwords.length})`));
    content.append(adding ? editor(null) : button('Add password', () => { adding = true; render(); }));
    if (!passwords.length) content.append($('p', { class: 'empty' }, q ? 'No saved password matches.' : 'No saved passwords yet. Sign in to a site and webby offers to save it.'));
    for (const p of passwords) {
      const visible = shown.has(p.id);
      content.append($('div', { class: 'row' },
        $('a', { class: 'site', href: p.origin, title: p.origin }, host(p.origin)),
        $('span', { class: 'user' }, p.username || '(no username)'),
        $('span', { class: 'secret' }, visible ? p.password : '••••••••••'),
        button(visible ? 'Hide' : 'Show', () => { visible ? shown.delete(p.id) : shown.add(p.id); render(); }),
        button('Copy', () => send({ type: 'copy', id: p.id })),
        button('Edit', () => { editing = p.id; render(); }),
        button('Delete', () => send({ type: 'delete', id: p.id }), 'danger')));
      if (editing === p.id) content.append(editor(p));
    }
    const passkeys = data.passkeys.filter((k) => match(k.rpId, k.userName, k.userDisplayName));
    content.append($('h2', {}, `Passkeys (${passkeys.length})`));
    if (!passkeys.length) content.append($('p', { class: 'empty' }, 'No passkeys. Sites that offer passkey sign-in save them here.'));
    for (const k of passkeys)
      content.append($('div', { class: 'row' }, $('span', { class: 'site' }, k.rpId),
        $('span', { class: 'user' }, k.userDisplayName && k.userDisplayName !== k.userName ? `${k.userDisplayName} (${k.userName})` : k.userName),
        button('Delete', () => send({ type: 'deletePasskey', id: k.credentialId }), 'danger')));
    const never = data.neverSave.filter((o) => match(o));
    if (never.length) {
      content.append($('h2', {}, 'Never saved'));
      for (const o of never)
        content.append($('div', { class: 'row' }, $('span', { class: 'user' }, host(o)), button('Allow saving', () => send({ type: 'allowSave', origin: o }))));
    }
  }
  window.__webbyVaultShow = (d) => { data = d; render(); };
  document.getElementById('search').addEventListener('input', render);
  send({ type: 'ready' });
})();
</script>)html"_s;
    return write_page(u"passwords.html"_s, u"Passwords and passkeys"_s, body);
}

QString about_page()
{
    auto body = u"<p>Webby, built to WebAssembly: the Ladybird engine and this Qt interface run as wasm components under "
                "latha-gui.</p><ul><li><span class=\"time\">Profile</span><span>"_s
        + Profile::dir().toHtmlEscaped()
        + u"</span></li><li><span class=\"time\">Source</span><a href=\"https://github.com/nandi-conda/webby\">"
          "github.com/nandi-conda/webby</a></li></ul>"_s;
    return write_page(u"about.html"_s, u"About Webby"_s, body);
}

bool is_own_page(QString const& url)
{
    return url.startsWith(QUrl::fromLocalFile(pages_dir() + u'/').toString(QUrl::FullyEncoded));
}

QString refresh(QString const& url)
{
    if (url.endsWith(u"/history.html"_s))
        return history_page();
    if (url.endsWith(u"/bookmarks.html"_s))
        return bookmarks_page();
    if (url.endsWith(u"/downloads.html"_s))
        return downloads_page();
    if (url.endsWith(u"/passwords.html"_s))
        return passwords_page();
    if (url.endsWith(u"/sync.html"_s))
        return sync_page();
    if (url.endsWith(u"/devices.html"_s))
        return devices_page();
    if (url.endsWith(u"/sessions.html"_s))
        return sessions_page();
    return url;
}

}
