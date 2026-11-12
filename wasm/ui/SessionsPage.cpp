/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The Sessions page: the Nim front end's Sessions side panel (nim/src/features/tabs/sessions.nim) as one of the own
// pages. Every session shows expanded the way OneTab shows a tab group (size, name, date, Restore all / Delete /
// Rename, then its tabs, each with a remove button), with a save form on top. Its links and forms go to
// <pages>/sessions-do?op=…, which the chrome runs instead of loading (BrowserWindow, run_sessions_action).

#include "Pages.h"
#include "Sessions.h"

#include <QUrl>
#include <QUrlQuery>

using namespace Qt::StringLiterals;

namespace WebbyUI::Pages {

static QString const sessions_style = uR"css(
p.dim, .dim { color: #5f6368; }
.small { font-size: 12px; }
.banner { background: #fce8e6; color: #a50e0e; padding: 10px 12px; border-radius: 8px; margin: 12px 0; }
.note { background: #f1f3f4; padding: 8px 12px; border-radius: 8px; margin: 12px 0; display: flex; gap: 12px; align-items: center; }
.note span { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
form { margin: 0; display: inline; }
input[type=text] { width: 260px; padding: 6px 8px; font-size: 14px; border: 1px solid #dadce0; border-radius: 6px; }
button, a.button { display: inline-block; margin: 0 8px 0 0; padding: 6px 14px; font-size: 14px; border-radius: 18px;
  border: 1px solid #dadce0; background: #fff; color: #1a73e8; cursor: pointer; text-decoration: none; }
button.suggested { background: #1a73e8; color: #fff; border-color: #1a73e8; }
a.destructive, button.destructive { color: #d93025; }
.bar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 0 0 8px; }
.session { border-top: 1px solid #e0e0e0; padding-top: 12px; margin-top: 14px; }
.head { display: flex; gap: 14px; align-items: center; }
.count { font-size: 24px; font-weight: 300; color: #5f6368; min-width: 72px; }
.name { font-weight: bold; }
.links { margin: 4px 0 4px 86px; }
.links a { color: #1a73e8; margin-right: 12px; font-size: 13px; }
.tabs li { padding: 3px 8px 3px 80px; }
a.x { color: #9aa0a6; font-size: 15px; min-width: 14px; text-align: center; }
a.x:hover { color: #d93025; }
.rename { margin: 6px 0 4px 86px; }
)css"_s;

static QString s_banner;               // an error shown once at the top of the next page
static QString s_undo_message;         // the last delete, offered back until the next action
static std::function<void()> s_undo;
static QString s_renaming;             // the session whose name is being edited
static bool s_confirm_delete_all = false;

static QString esc(QString const& s) { return s.toHtmlEscaped(); }
static QString enc(QString const& s) { return QString::fromLatin1(QUrl::toPercentEncoding(s)); }
static QString plural(qsizetype n, QString const& word) { return QString::number(n) + u' ' + word + (n == 1 ? u""_s : u"s"_s); }

static QString do_link(QString const& query, QString const& label, QString const& cls = {}, QString const& title = {})
{
    return u"<a href=\"sessions-do?"_s + esc(query) + u"\""_s + (cls.isEmpty() ? QString() : u" class=\""_s + cls + u"\""_s)
        + (title.isEmpty() ? QString() : u" title=\""_s + esc(title) + u"\""_s) + u">"_s + label + u"</a>"_s;
}

static QString session_group(Sessions::Session const& s)
{
    QString out = u"<div class=\"session\"><div class=\"head\"><span class=\"count\">"_s + esc(plural(s.tabs.size(), u"tab"_s))
        + u"</span><div><div class=\"name\">"_s + esc(s.name) + u"</div><div class=\"dim small\">"_s
        + esc(Sessions::created_text(s.saved_at)) + u"</div></div></div>"_s;
    auto id = enc(s.id);
    if (s_renaming == s.id) {
        out += u"<div class=\"rename\"><form action=\"sessions-do\"><input type=\"hidden\" name=\"op\" value=\"rename\">"
               "<input type=\"hidden\" name=\"id\" value=\""_s
            + esc(s.id) + u"\"><input type=\"text\" name=\"name\" value=\""_s + esc(s.name)
            + u"\" autofocus> <button class=\"suggested\">Rename</button></form>"_s + do_link(u"op=cancel"_s, u"Cancel"_s) + u"</div>"_s;
    } else {
        out += u"<div class=\"links\">"_s + do_link(u"op=restore&id="_s + id, u"Restore all"_s)
            + do_link(u"op=delete&id="_s + id, u"Delete"_s) + do_link(u"op=rename-ask&id="_s + id, u"Rename"_s) + u"</div>"_s;
    }
    out += u"<ul class=\"tabs\">"_s;
    for (int i = 0; i < s.tabs.size(); ++i) {
        auto const& t = s.tabs[i];
        auto host = QUrl(t.url).host();
        auto label = t.title.isEmpty() ? (host.isEmpty() ? t.url : host) : t.title;
        auto at = u"&id="_s + id + u"&i="_s + QString::number(i);
        out += u"<li>"_s + do_link(u"op=remove-tab"_s + at, u"×"_s, u"x"_s, u"Remove from session"_s)
            + u"<a href=\"sessions-do?"_s + esc(u"op=open"_s + at) + u"\" title=\""_s + esc(t.url) + u"\">"_s + esc(label)
            + u"</a><span class=\"host\">"_s + esc(host) + u"</span></li>"_s;
    }
    out += u"</ul></div>"_s;
    return out;
}

QString sessions_page()
{
    QString body = u"<style>"_s + sessions_style + u"</style>"_s;
    if (auto error = Sessions::load_error(); !error.isEmpty())
        body += u"<div class=\"banner\">"_s + esc(error) + u"</div>"_s;
    if (!s_banner.isEmpty()) {
        body += u"<div class=\"banner\">"_s + esc(s_banner) + u"</div>"_s;
        s_banner.clear();
    }
    body += u"<div class=\"bar\"><form action=\"sessions-do\"><input type=\"hidden\" name=\"op\" value=\"save\">"
            "<input type=\"text\" name=\"name\" value=\""_s
        + esc(Sessions::default_name()) + u"\" title=\"Name\"> <button class=\"suggested\">Save open tabs</button></form>"_s
        + do_link(u"op=close-save"_s, u"Close all tabs and save"_s, u"button"_s);
    auto const& list = Sessions::all();
    if (!list.isEmpty() && !s_confirm_delete_all)
        body += do_link(u"op=delete-all-ask"_s, u"Delete all"_s, u"button destructive"_s);
    body += u"</div>"_s;
    if (s_confirm_delete_all && !list.isEmpty()) {
        body += u"<div class=\"note\"><span>Delete all "_s + esc(plural(list.size(), u"saved session"_s))
            + u"? This can't be undone.</span>"_s + do_link(u"op=delete-all"_s, u"Delete"_s, u"button destructive"_s)
            + do_link(u"op=cancel"_s, u"Cancel"_s, u"button"_s) + u"</div>"_s;
    }
    if (s_undo) {
        body += u"<div class=\"note\"><span>"_s + esc(s_undo_message) + u"</span>"_s + do_link(u"op=undo"_s, u"Undo"_s, u"button"_s)
            + do_link(u"op=dismiss"_s, u"×"_s, u"x"_s, u"Dismiss"_s) + u"</div>"_s;
    }
    if (list.isEmpty()) {
        body += u"<p class=\"empty\">No saved sessions. Save your open tabs above, or with \"Close all tabs and save as session\" on "
                "the toolbar. Closing the window saves its tabs here too.</p>"_s;
    } else {
        qsizetype total = 0;
        for (auto const& s : list)
            total += s.tabs.size();
        body += u"<p class=\"dim small\">Total: "_s + esc(plural(total, u"tab"_s)) + u" in "_s + esc(plural(list.size(), u"session"_s)) + u"</p>"_s;
    }
    for (auto const& s : list)
        body += session_group(s);
    return write_page(u"sessions.html"_s, u"Sessions"_s, body);
}

QString sessions_page_url() { return QUrl::fromLocalFile(Profile::dir() + u"/pages/sessions.html"_s).toString(QUrl::FullyEncoded); }

bool is_sessions_action(QString const& url)
{
    return is_own_page(url) && QUrl(url).path().endsWith(u"/sessions-do"_s);
}

static void set_undo(QString const& message, std::function<void()> action)
{
    s_undo_message = message;
    s_undo = std::move(action);
}

SessionsAction run_sessions_action(QString const& url)
{
    QUrlQuery q(QUrl(url).query());
    auto value = [&](QString const& key) { return q.queryItemValue(key, QUrl::FullyDecoded); };
    auto op = value(u"op"_s);
    auto id = value(u"id"_s);
    SessionsAction action;
    action.load = sessions_page_url();
    // Anything else done drops the offer to undo the last delete, as in the panel.
    if (op != u"undo" && op != u"rename-ask" && op != u"delete-all-ask")
        set_undo({}, {});
    if (op != u"rename-ask")
        s_renaming.clear();
    if (op != u"delete-all-ask")
        s_confirm_delete_all = false;

    if (op == u"save") {
        action.save = SessionsAction::Save::Keep;
        action.name = value(u"name"_s);
    } else if (op == u"close-save") {
        action.save = SessionsAction::Save::CloseAll;
    } else if (op == u"restore") {
        if (auto const* s = Sessions::find(id)) {
            action.open = s->tabs;
            action.front = s->active;
        }
        action.load = {};
    } else if (op == u"open") {
        auto const* s = Sessions::find(id);
        auto i = value(u"i"_s).toInt();
        if (s && i >= 0 && i < s->tabs.size())
            action.open = { s->tabs[i] };
        action.load = {};
    } else if (op == u"remove-tab") {
        Profile::SavedTab removed;
        Sessions::Session whole;
        int i = value(u"i"_s).toInt();
        if (Sessions::remove_tab(id, i, &removed, &whole))
            set_undo(u"Removed \""_s + (removed.title.isEmpty() ? removed.url : removed.title) + u'"',
                [whole, removed, i] { Sessions::restore_tab(whole, removed, i); });
    } else if (op == u"delete") {
        Sessions::Session deleted;
        if (Sessions::remove(id, &deleted))
            set_undo(u"Deleted \""_s + deleted.name + u'"', [deleted] { Sessions::restore_deleted(deleted); });
    } else if (op == u"undo") {
        auto undo = std::move(s_undo);
        set_undo({}, {});
        if (undo)
            undo();
    } else if (op == u"rename-ask") {
        s_renaming = id;
    } else if (op == u"rename") {
        Sessions::rename(id, value(u"name"_s));
    } else if (op == u"delete-all-ask") {
        s_confirm_delete_all = true;
    } else if (op == u"delete-all") {
        Sessions::remove_all();
    }
    return action;
}

void sessions_notice(QString const& error) { s_banner = error; }

}
