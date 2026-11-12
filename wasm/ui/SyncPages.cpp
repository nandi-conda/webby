/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The Sync and Tabs from other devices pages (the Nim front end's two sync side panels, nim/src/features/sync.nim),
// written into the profile's pages/ folder like the other own pages. Their links and forms go to
// <pages>/sync-do?op=…, which the chrome catches before it loads (BrowserWindow, run_sync_action) and answers with the
// page to show next.

#include "Pages.h"
#include "Profile.h"
#include "Sync.h"

#include <QDateTime>
#include <QUrl>
#include <QUrlQuery>

using namespace Qt::StringLiterals;

namespace WebbyUI::Pages {

static QString s_message;      // shown once at the top of the next Sync page (an error from the last action)
static bool s_code_shown = false;

static QString const sync_style = uR"css(
p.dim { color: #5f6368; }
.small { font-size: 12px; }
.banner { background: #fce8e6; color: #a50e0e; padding: 10px 12px; border-radius: 8px; margin: 12px 0; }
.note { background: #e8f0fe; color: #174ea6; padding: 10px 12px; border-radius: 8px; margin: 12px 0; }
form { margin: 8px 0 18px; }
label { display: block; margin: 8px 0 4px; }
label.inline { display: inline; margin: 0 14px 0 4px; }
input[type=text], input[type=password] { width: 100%; max-width: 560px; padding: 6px 8px; font-size: 14px;
  border: 1px solid #dadce0; border-radius: 6px; box-sizing: border-box; }
button, a.button { display: inline-block; margin: 10px 8px 0 0; padding: 7px 16px; font-size: 14px; border-radius: 18px;
  border: 1px solid #dadce0; background: #fff; color: #1a73e8; cursor: pointer; text-decoration: none; }
button.suggested, a.suggested { background: #1a73e8; color: #fff; border-color: #1a73e8; }
button.destructive { color: #d93025; }
.mono { font-family: monospace; font-size: 15px; word-break: break-all; background: #f1f3f4; padding: 10px; border-radius: 6px; }
hr { border: 0; border-top: 1px solid #e0e0e0; margin: 22px 0; }
h2 .when { font-weight: normal; margin-left: 8px; }
)css"_s;

static QString esc(QString const& s) { return s.toHtmlEscaped(); }

static QString ago(qint64 seconds, bool yesterday = false)
{
    auto d = Profile::now_seconds() - seconds;
    if (d < 60)
        return u"just now"_s;
    if (d < 3600)
        return QString::number(d / 60) + u" min ago"_s;
    if (d < 86400)
        return QString::number(d / 3600) + u" h ago"_s;
    if (yesterday && d / 86400 == 1)
        return u"yesterday"_s;
    return QString::number(d / 86400) + u" days ago"_s;
}

static QString storage_fields()
{
    return uR"html(
<label>Store the encrypted copy on</label>
<input type="radio" name="storage" value="webby" id="st-webby" checked><label class="inline" for="st-webby">Webby sync</label>
<input type="radio" name="storage" value="custom" id="st-custom"><label class="inline" for="st-custom">My sync server</label>
<input type="radio" name="storage" value="webdav" id="st-webdav"><label class="inline" for="st-webdav">WebDAV</label>
<label>Server address (runs sync-worker from the webby repo) or WebDAV folder address; not needed for Webby sync</label>
<input type="text" name="server" placeholder="https://cloud.example.com/remote.php/dav/files/me/webby">
<label>WebDAV username and password (an app password is best)</label>
<input type="text" name="user" placeholder="Username">
<input type="password" name="pass" placeholder="Password">
)html"_s;
}

static QString page(QString const& name, QString const& title, QString const& body)
{
    return write_page(name, title, u"<style>"_s + sync_style + u"</style>"_s + body);
}

static QString banner(QString const& message, bool error = true)
{
    return u"<div class=\""_s + (error ? u"banner"_s : u"note"_s) + u"\">"_s + esc(message) + u"</div>"_s;
}

QString sync_page()
{
    QString body;
    if (!s_message.isEmpty()) {
        body += banner(s_message);
        s_message.clear();
    }
    if (!Sync::enabled()) {
        s_code_shown = false;
        body += uR"html(
<p><b>Keep your passwords, passkeys, bookmarks and tabs on all your devices</b></p>
<p class="dim">Webby encrypts them on this device with a sync code that only your devices know, then stores the encrypted
copy on a sync server or in your own WebDAV folder. Nobody without the code, the server included, can read them.</p>
<h2>Turn on sync</h2>
<form action="sync-do"><input type="hidden" name="op" value="on">)html"_s
            + storage_fields() + uR"html(<button class="suggested">Turn on sync</button></form>
<hr>
<h2>I have a sync code</h2>
<form action="sync-do"><input type="hidden" name="op" value="join">
<label>Sync code from your other device (or the pairing link)</label>
<input type="text" name="code" placeholder="webby1-…">)html"_s
            + storage_fields() + u"<button class=\"suggested\">Join</button></form>"_s;
        return page(u"sync.html"_s, u"Sync"_s, body);
    }

    auto s = Sync::settings();
    if (!Sync::last_error().isEmpty())
        body += banner(u"Sync isn't working: "_s + Sync::last_error());
    auto last = Sync::last_sync();
    auto status = Sync::syncing() ? u"Syncing with "_s + Sync::where() + u"…"_s
                                  : u"Synced with "_s + Sync::where() + u' ' + (last > 0 ? ago(last) : u"not yet"_s) + u'.';
    body += u"<p>"_s + esc(status) + u"</p>"_s;
    body += u"<a class=\"button\" href=\"sync-do?op=now\">Sync now</a><a class=\"button\" href=\"sync-do?op=devices\">Tabs from other devices</a>"_s;

    body += u"<hr><h2>Add another device</h2><p class=\"dim\">In webby on the other device, open Sync › I have a sync code, then "
            "paste the code (or the pairing link). Keep them private: they unlock your passwords."_s
        + (Sync::is_webdav(s) ? u" The other device also needs the WebDAV login."_s : QString()) + u"</p>"_s;
    if (!s_code_shown) {
        body += u"<a class=\"button\" href=\"sync-do?op=show\">Show sync code</a>"_s;
    } else {
        auto code = Sync::code_of(s);
        auto link = Sync::pairing_link(s);
        body += u"<p class=\"mono\">"_s + esc(code) + u"</p><a class=\"button\" href=\"sync-do?op=copy-code\">Copy code</a>"_s;
        if (link != u"webby-sync:pair?code="_s + code)
            body += u"<p class=\"mono small\">"_s + esc(link) + u"</p><a class=\"button\" href=\"sync-do?op=copy-link\">Copy pairing link</a>"_s;
        body += u"<a class=\"button\" href=\"sync-do?op=hide\">Hide</a>"_s;
    }

    body += uR"html(<hr><h2>Use a pairing link</h2>
<p class="dim small">To switch this device to another sync server or code: paste the pairing link shown in Sync on a device
that already uses it.</p>
<form action="sync-do"><input type="hidden" name="op" value="join">
<input type="text" name="code" placeholder="webby-sync:pair?code=…"><button>Switch</button></form>
<hr><h2>Turn off</h2>
<a class="button" href="sync-do?op=off">Turn off sync on this device</a>
<form action="sync-do"><input type="hidden" name="op" value="erase">
<p class="dim small">Turning off everywhere deletes the encrypted copy on the server and your other devices stop syncing.
Passwords and bookmarks already on each device stay there.</p>
<input type="checkbox" name="sure" value="1" id="sure"><label class="inline" for="sure">Erase the synced copy</label>
<br><button class="destructive">Turn off everywhere and erase</button></form>)html"_s;
    return page(u"sync.html"_s, u"Sync"_s, body);
}

QString devices_page()
{
    QString body;
    if (!s_message.isEmpty()) {
        body += banner(s_message);
        s_message.clear();
    }
    if (!Sync::enabled()) {
        body += uR"html(<p><b>See the tabs open on your other devices</b></p>
<p class="dim">Tabs travel with your passwords and bookmarks, encrypted with your sync code. Turn on sync here and on your
other devices to see their tabs.</p><a class="button suggested" href="sync-do?op=sync">Set up sync</a>)html"_s;
        return page(u"devices.html"_s, u"Tabs from other devices"_s, body);
    }
    body += Sync::syncing() ? u"<a class=\"button\">Syncing…</a>"_s : u"<a class=\"button\" href=\"sync-do?op=now&amp;back=devices\">Refresh</a>"_s;
    if (!Sync::last_error().isEmpty())
        body += banner(u"Sync isn't working: "_s + Sync::last_error());
    auto list = Sync::devices();
    if (list.isEmpty())
        body += u"<p class=\"empty\">No other devices have shared their tabs yet. They show up here once webby on another device is "
                "syncing with the same sync code.</p>"_s;
    for (auto const& d : list) {
        body += u"<h2>"_s + esc(d.name) + u"<span class=\"when\">"_s + esc(ago(d.seen_at, true)) + u"</span></h2>"_s;
        if (d.tabs.size() > 1)
            body += u"<a class=\"button\" href=\"sync-do?op=open-all&amp;device="_s + esc(QString::fromLatin1(QUrl::toPercentEncoding(d.id)))
                + u"\">Open all</a>"_s;
        if (d.tabs.isEmpty()) {
            body += u"<p class=\"empty small\">No open tabs</p>"_s;
            continue;
        }
        body += u"<ul>"_s;
        for (auto const& t : d.tabs) {
            auto host = QUrl(t.url).host();
            body += u"<li><a href=\""_s + esc(t.url) + u"\" title=\""_s + esc(t.url) + u"\">"_s + esc(t.title.isEmpty() ? (host.isEmpty() ? t.url : host) : t.title)
                + u"</a><span class=\"host\">"_s + esc(host) + u"</span></li>"_s;
        }
        body += u"</ul>"_s;
    }
    auto n = Sync::shared_tabs().size();
    body += u"<hr><p>This device: "_s + esc(Sync::device_name()) + u"</p><p class=\"dim small\">"_s
        + (Sync::sharing() ? u"Your other devices see the "_s + QString::number(n) + (n == 1 ? u" tab"_s : u" tabs"_s) + u" open here."_s
                           : u"Your other devices don't see the tabs open here."_s)
        + u"</p>"_s;
    body += u"<form action=\"sync-do\"><input type=\"hidden\" name=\"op\" value=\"rename\"><label>Name this device (other devices list "
            "its tabs under this name)</label><input type=\"text\" name=\"name\" value=\""_s
        + esc(Sync::device_name()) + u"\"><button>Rename</button></form>"_s;
    body += u"<form action=\"sync-do\"><input type=\"hidden\" name=\"op\" value=\"share\"><input type=\"checkbox\" name=\"on\" value=\"1\" id=\"share\""_s
        + (Sync::sharing() ? u" checked"_s : QString()) + u" onchange=\"this.form.submit()\"><label class=\"inline\" for=\"share\">Share this device's tabs</label>"
                                                        "<button>Save</button></form>"_s;
    return page(u"devices.html"_s, u"Tabs from other devices"_s, body);
}

bool is_sync_action(QString const& url)
{
    return is_own_page(url) && QUrl(url).path().endsWith(u"/sync-do"_s);
}

static bool valid_server(QString const& text)
{
    QUrl u(text);
    return (u.scheme() == u"http" || u.scheme() == u"https") && !u.host().isEmpty();
}

// Settings from a Turn on / Join form: the code (or a new one) and where to sync.
static QJsonObject settings_from(QUrlQuery const& q, bool join, QString& error)
{
    auto value = [&](char const* key) { return q.queryItemValue(QString::fromLatin1(key), QUrl::FullyDecoded).trimmed(); };
    QString code;
    QJsonObject paired;
    if (join) {
        paired = Sync::from_pairing(value("code"), &error);
        if (paired.isEmpty()) {
            if (error.isEmpty())
                error = u"That isn't a sync code."_s;
            return {};
        }
        code = Sync::code_of(paired);
        // A pasted pairing link says where to sync.
        if (value("code").startsWith(u"webby-sync:"))
            return paired;
    }
    if (code.isEmpty())
        code = Sync::generate_code();
    auto storage = value("storage");
    bool webdav = storage == u"webdav";
    bool webby = storage.isEmpty() || storage == u"webby";
    auto address = value("server");
    if (!webby && !valid_server(address)) {
        error = u"Enter the server's address, like https://cloud.example.com/remote.php/dav/files/me/webby"_s;
        return {};
    }
    return Sync::new_settings(code, webdav, webby ? Sync::default_server() : address, webdav ? value("user") : QString(),
        webdav ? q.queryItemValue(u"pass"_s, QUrl::FullyDecoded) : QString());
}

SyncAction run_sync_action(QString const& url)
{
    QUrlQuery q(QUrl(url).query());
    auto op = q.queryItemValue(u"op"_s);
    SyncAction action;
    action.load = sync_page_url();
    if (op == u"on" || op == u"join") {
        QString error;
        auto s = settings_from(q, op == u"join", error);
        if (s.isEmpty())
            s_message = error;
        else if (auto why = Sync::enable(s); !why.isEmpty())
            s_message = u"Couldn't turn on sync: "_s + why;
        s_code_shown = false;
    } else if (op == u"now") {
        Sync::sync_now();
        if (q.queryItemValue(u"back"_s) == u"devices")
            action.load = devices_page_url();
    } else if (op == u"devices") {
        action.load = devices_page_url();
        if (Sync::enabled() && !Sync::syncing())
            Sync::sync_now(); // fetch the latest from the other devices
    } else if (op == u"sync") {
        // (the Sync page)
    } else if (op == u"show") {
        s_code_shown = true;
    } else if (op == u"hide") {
        s_code_shown = false;
    } else if (op == u"copy-code" || op == u"copy-link") {
        auto s = Sync::settings();
        action.copy = op == u"copy-code" ? Sync::code_of(s) : Sync::pairing_link(s);
        action.load = {};
    } else if (op == u"off" || op == u"erase") {
        if (op == u"erase" && q.queryItemValue(u"sure"_s).isEmpty()) {
            s_message = u"Tick \"Erase the synced copy\" first."_s;
        } else {
            Sync::disable(op == u"erase", [](QString const& error) {
                if (!error.isEmpty())
                    s_message = u"Couldn't turn off sync: "_s + error;
            });
        }
    } else if (op == u"open-all") {
        auto id = q.queryItemValue(u"device"_s, QUrl::FullyDecoded);
        for (auto const& d : Sync::devices()) {
            if (d.id == id) {
                for (auto const& t : d.tabs)
                    action.open.append(t.url);
            }
        }
        action.load = {};
    } else if (op == u"rename") {
        Sync::set_device_name(q.queryItemValue(u"name"_s, QUrl::FullyDecoded));
        action.load = devices_page_url();
    } else if (op == u"share") {
        Sync::set_sharing(!q.queryItemValue(u"on"_s).isEmpty());
        action.load = devices_page_url();
    }
    return action;
}

QString sync_page_url() { return QUrl::fromLocalFile(Profile::dir() + u"/pages/sync.html"_s).toString(QUrl::FullyEncoded); }
QString devices_page_url() { return QUrl::fromLocalFile(Profile::dir() + u"/pages/devices.html"_s).toString(QUrl::FullyEncoded); }

}
