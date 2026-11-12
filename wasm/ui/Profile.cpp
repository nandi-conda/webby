/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Profile.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QSet>
#include <QUrl>
#include <algorithm>

using namespace Qt::StringLiterals;

namespace WebbyUI::Profile {

QString dir()
{
    static QString const path = [] {
        auto env = qEnvironmentVariable("WEBBY_DATA_DIR");
        if (!env.isEmpty())
            return env;
        auto data = qEnvironmentVariable("XDG_DATA_HOME");
        if (data.isEmpty()) {
            auto home = qEnvironmentVariable("HOME");
            data = (home.isEmpty() ? QStringLiteral("/tmp") : home) + QStringLiteral("/.local/share");
        }
        auto profile = qEnvironmentVariable("WEBBY_PROFILE");
        return data + QStringLiteral("/webby/profiles/") + (profile.isEmpty() ? QStringLiteral("default") : profile);
    }();
    return path;
}

QString file(QString const& name) { return dir() + u'/' + name; }

QJsonObject read_json(QString const& path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(f.readAll()).object();
}

bool write_atomic(QString const& path, QByteArray const& data)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    auto tmp = path + QStringLiteral(".tmp");
    QFile f(tmp);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning("webby: could not write %s", qPrintable(path));
        return false;
    }
    f.write(data);
    f.close();
    QFile::remove(path);
    if (!QFile::rename(tmp, path)) {
        qWarning("webby: could not write %s", qPrintable(path));
        return false;
    }
    return true;
}

qint64 now_seconds() { return QDateTime::currentSecsSinceEpoch(); }
qint64 now_ms() { return QDateTime::currentMSecsSinceEpoch(); }

QString new_id()
{
    static int counter = 0;
    return QString::number(now_ms(), 36) + QString::number(++counter, 36);
}

bool is_session_url(QString const& url)
{
    if (url.isEmpty() || url == u"about:blank")
        return false;
    // webby's generated pages (history, bookmarks) live in the profile folder.
    if (url.startsWith(QStringLiteral("file://") + dir() + QStringLiteral("/pages/")))
        return false;
    return true;
}

// Bookmarks.

static Bookmark bookmark_from_json(QJsonObject const& j, int index)
{
    Bookmark b;
    b.id = j.value(u"id").toString();
    b.title = j.value(u"title").toString();
    b.added_at = j.value(u"addedAt").toInteger();
    b.updated_at = j.value(u"updatedAt").toInteger(b.added_at);
    b.pos = j.value(u"pos").isDouble() ? j.value(u"pos").toDouble() : index;
    if (j.value(u"url").isString()) {
        b.url = j.value(u"url").toString();
        return b;
    }
    b.folder = true;
    int i = 0;
    for (auto const& child : j.value(u"children").toArray()) {
        auto o = child.toObject();
        if (o.isEmpty())
            continue;
        b.children.append(bookmark_from_json(o, ++i));
    }
    return b;
}

static QJsonObject bookmark_to_json(Bookmark const& b)
{
    QJsonObject j { { u"id"_s, b.id }, { u"title"_s, b.title } };
    if (!b.folder)
        j.insert(u"url"_s, b.url);
    j.insert(u"addedAt"_s, b.added_at);
    j.insert(u"updatedAt"_s, b.updated_at);
    j.insert(u"pos"_s, b.pos);
    if (b.folder) {
        QJsonArray kids;
        for (auto const& c : b.children)
            kids.append(bookmark_to_json(c));
        j.insert(u"children"_s, kids);
    }
    return j;
}

Bookmarks& Bookmarks::the()
{
    static Bookmarks bookmarks;
    return bookmarks;
}

Bookmarks::Bookmarks() { load(); }

void Bookmarks::load()
{
    m_bar = { QStringLiteral("bar"), QStringLiteral("Bookmarks bar"), {}, 0, 0, 0, true, {} };
    m_other = { QStringLiteral("other"), QStringLiteral("Other bookmarks"), {}, 0, 0, 0, true, {} };
    auto j = read_json(file(QStringLiteral("bookmarks.json")));
    if (j.isEmpty())
        return;
    m_show_bar = j.value(u"showBar").toBool(true);
    auto roots = j.value(u"roots").toObject();
    m_bar.children = bookmark_from_json(roots.value(u"bar").toObject(), 0).children;
    m_other.children = bookmark_from_json(roots.value(u"other").toObject(), 0).children;
    j.remove(u"showBar"_s);
    j.remove(u"roots"_s);
    j.remove(u"version"_s);
    m_rest = j;
}

void Bookmarks::save()
{
    QJsonObject j = m_rest;
    j.insert(u"version"_s, 1);
    j.insert(u"showBar"_s, m_show_bar);
    j.insert(u"roots"_s, QJsonObject { { u"bar"_s, bookmark_to_json(m_bar) }, { u"other"_s, bookmark_to_json(m_other) } });
    write_atomic(file(QStringLiteral("bookmarks.json")), QJsonDocument(j).toJson(QJsonDocument::Indented));
}

void Bookmarks::set_show_bar(bool on)
{
    if (on == m_show_bar)
        return;
    m_show_bar = on;
    save();
}

static Bookmark const* find_in(Bookmark const& folder, QString const& url)
{
    for (auto const& c : folder.children) {
        if (!c.folder && c.url == url)
            return &c;
        if (c.folder) {
            if (auto* found = find_in(c, url))
                return found;
        }
    }
    return nullptr;
}

Bookmark const* Bookmarks::find(QString const& url) const
{
    if (url.isEmpty())
        return nullptr;
    if (auto* b = find_in(m_bar, url))
        return b;
    return find_in(m_other, url);
}

void Bookmarks::add(QString const& url, QString const& title)
{
    if (url.isEmpty() || contains(url))
        return;
    Bookmark b;
    b.id = new_id();
    b.title = title;
    b.url = url;
    b.added_at = b.updated_at = now_seconds();
    b.pos = m_bar.children.isEmpty() ? 1 : m_bar.children.last().pos + 1;
    m_bar.children.append(b);
    save();
}

static bool remove_in(Bookmark& folder, QString const& url, QJsonObject& tombstones)
{
    bool removed = false;
    for (int i = folder.children.size() - 1; i >= 0; --i) {
        auto& c = folder.children[i];
        if (c.folder) {
            removed |= remove_in(c, url, tombstones);
        } else if (c.url == url) {
            // A tombstone, so that sync (Nim desktop) deletes it on other devices too.
            tombstones.insert(c.id, QJsonObject { { u"updatedAt"_s, now_seconds() }, { u"deleted"_s, true } });
            folder.children.removeAt(i);
            removed = true;
        }
    }
    return removed;
}

void Bookmarks::remove_url(QString const& url)
{
    auto tombstones = m_rest.value(u"deleted").toObject();
    bool removed = remove_in(m_bar, url, tombstones);
    removed |= remove_in(m_other, url, tombstones);
    if (!removed)
        return;
    m_rest.insert(u"deleted"_s, tombstones);
    save();
}

static void collect(Bookmark const& folder, QList<Bookmark const*>& out)
{
    for (auto const& c : folder.children) {
        if (c.folder)
            collect(c, out);
        else
            out.append(&c);
    }
}

QList<Bookmark const*> Bookmarks::all() const
{
    QList<Bookmark const*> out;
    collect(m_bar, out);
    collect(m_other, out);
    return out;
}

// History.

History& History::the()
{
    static History history;
    return history;
}

History::History()
{
    QFile f(file(QStringLiteral("history.jsonl")));
    if (!f.open(QIODevice::ReadOnly))
        return;
    while (!f.atEnd()) {
        auto line = f.readLine().trimmed();
        if (line.isEmpty())
            continue;
        auto j = QJsonDocument::fromJson(line).object();
        auto url = j.value(u"url").toString();
        if (url.isEmpty())
            continue;
        m_visits.append({ j.value(u"id").toString(), url, j.value(u"title").toString(), j.value(u"t").toInteger() });
    }
}

static QByteArray visit_line(Visit const& v)
{
    QJsonObject j { { u"id"_s, v.id }, { u"url"_s, v.url }, { u"title"_s, v.title }, { u"t"_s, v.time } };
    return QJsonDocument(j).toJson(QJsonDocument::Compact) + '\n';
}

void History::add(QString const& url, QString const& title)
{
    if (!is_session_url(url))
        return;
    // A reload or a redirect back to the same page is one visit.
    if (!m_visits.isEmpty() && m_visits.last().url == url && now_ms() - m_visits.last().time < 30000)
        return;
    Visit v { new_id(), url, title, now_ms() };
    m_visits.append(v);
    QDir().mkpath(dir());
    QFile f(file(QStringLiteral("history.jsonl")));
    if (f.open(QIODevice::WriteOnly | QIODevice::Append))
        f.write(visit_line(v));
}

void History::set_title(QString const& url, QString const& title)
{
    if (title.isEmpty())
        return;
    for (auto i = m_visits.size() - 1; i >= 0 && i >= m_visits.size() - 20; --i) {
        if (m_visits[i].url == url) {
            if (m_visits[i].title == title)
                return;
            m_visits[i].title = title;
            rewrite();
            return;
        }
    }
}

void History::rewrite()
{
    QByteArray data;
    for (auto const& v : m_visits)
        data += visit_line(v);
    write_atomic(file(QStringLiteral("history.jsonl")), data);
}

// Open tabs.

QList<SavedTab> read_open_tabs(int& active)
{
    QList<SavedTab> tabs;
    auto j = read_json(file(QStringLiteral("open_tabs.json")));
    for (auto const& t : j.value(u"tabs").toArray()) {
        auto o = t.toObject();
        auto url = o.value(u"url").toString();
        if (!is_session_url(url))
            continue;
        tabs.append({ o.value(u"title").toString(), url, o.value(u"created").toInteger() });
    }
    active = tabs.isEmpty() ? 0 : std::clamp(j.value(u"active").toInt(), 0, int(tabs.size()) - 1);
    return tabs;
}

void write_open_tabs(QList<SavedTab> const& tabs, int active)
{
    static QByteArray written;
    QJsonArray list;
    int front = 0;
    for (int i = 0; i < tabs.size(); ++i) {
        if (!is_session_url(tabs[i].url))
            continue;
        if (i <= active)
            front = int(list.size());
        QJsonObject o { { u"title"_s, tabs[i].title }, { u"url"_s, tabs[i].url } };
        if (tabs[i].created > 0)
            o.insert(u"created"_s, tabs[i].created);
        list.append(o);
    }
    QJsonObject j { { u"version"_s, 1 }, { u"active"_s, front }, { u"pinned"_s, 0 }, { u"tabs"_s, list } };
    auto data = QJsonDocument(j).toJson(QJsonDocument::Compact);
    if (data == written)
        return;
    if (write_atomic(file(QStringLiteral("open_tabs.json")), data))
        written = data;
}

// Downloads.

QList<DownloadRecord> read_downloads()
{
    QList<DownloadRecord> out;
    QFile f(file(QStringLiteral("download_history.jsonl")));
    if (!f.open(QIODevice::ReadOnly))
        return out;
    while (!f.atEnd()) {
        auto j = QJsonDocument::fromJson(f.readLine().trimmed()).object();
        if (j.isEmpty())
            continue;
        out.append({ j.value(u"url").toString(), j.value(u"path").toString(), j.value(u"size").toInteger(),
            j.value(u"mime").toString(), j.value(u"error").toString(), j.value(u"t").toInteger() });
    }
    return out;
}

void add_download(DownloadRecord const& d)
{
    QDir().mkpath(dir());
    QFile f(file(QStringLiteral("download_history.jsonl")));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Append))
        return;
    QJsonObject j { { u"url"_s, d.url }, { u"path"_s, d.path }, { u"size"_s, d.size }, { u"mime"_s, d.mime },
        { u"error"_s, d.error }, { u"t"_s, d.time } };
    f.write(QJsonDocument(j).toJson(QJsonDocument::Compact) + '\n');
}

// Settings.

static QJsonObject& ui_settings()
{
    static QJsonObject settings = read_json(file(QStringLiteral("wasm_ui.json")));
    return settings;
}

QJsonValue ui_setting(QString const& key) { return ui_settings().value(key); }

void set_ui_setting(QString const& key, QJsonValue const& value)
{
    ui_settings().insert(key, value);
    write_atomic(file(QStringLiteral("wasm_ui.json")), QJsonDocument(ui_settings()).toJson(QJsonDocument::Indented));
}

static int s_age_colors = -1;

bool age_colors()
{
    if (s_age_colors < 0) {
        auto v = read_json(file(QStringLiteral("tabs.json"))).value(u"ageColors");
        s_age_colors = v.isBool() ? v.toBool() : 1;
    }
    return s_age_colors;
}

void set_age_colors(bool on)
{
    s_age_colors = on;
    auto path = file(QStringLiteral("tabs.json"));
    auto j = read_json(path);
    j.insert(u"version"_s, 1);
    j.insert(u"ageColors"_s, on);
    write_atomic(path, QJsonDocument(j).toJson(QJsonDocument::Indented));
}

}
