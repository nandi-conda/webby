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

static QString write_page(QString const& name, QString const& title, QString const& body)
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
    return url;
}

}
