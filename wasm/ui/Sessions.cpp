/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A port of the session half of nim/src/features/tabs/store.nim.

#include "Sessions.h"

#include <QDateTime>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <algorithm>

using namespace Qt::StringLiterals;

namespace WebbyUI::Sessions {

static constexpr qint64 tombstone_lifetime = 180 * 24 * 3600; // as sync/doc.nim

static QList<Session> s_list;                // newest first
static QList<QPair<QString, qint64>> s_deleted; // tombstones: id, when (seconds)
static bool s_loaded = false;
static QString s_load_error;
static QList<std::function<void()>> s_listeners;

static QString file_path()
{
    auto o = qEnvironmentVariable("WEBBY_SESSIONS_FILE");
    return o.isEmpty() ? Profile::file(u"sessions.json"_s) : o;
}

static qint64 number(QJsonValue const& v, qint64 fallback = 0)
{
    return v.isDouble() ? qint64(v.toDouble()) : fallback;
}

static QJsonObject tab_json(Profile::SavedTab const& t)
{
    QJsonObject o { { u"title"_s, t.title }, { u"url"_s, t.url } };
    if (t.created > 0)
        o.insert(u"created"_s, t.created);
    return o;
}

static QJsonObject to_json(Session const& s, bool with_id)
{
    QJsonArray tabs;
    for (auto const& t : s.tabs)
        tabs.append(tab_json(t));
    QJsonObject o { { u"name"_s, s.name }, { u"savedAt"_s, s.saved_at }, { u"active"_s, s.active }, { u"tabs"_s, tabs },
        { u"updatedAt"_s, s.updated_at } };
    if (with_id)
        o.insert(u"id"_s, s.id);
    return o;
}

// Nothing unless it has an id and at least one tab.
static std::optional<Session> from_json(QJsonObject const& j, QString id)
{
    if (id.isEmpty())
        id = j.value(u"id").toString();
    if (id.isEmpty())
        return {};
    Session s;
    s.id = id;
    for (auto const& e : j.value(u"tabs").toArray()) {
        auto o = e.toObject();
        auto url = o.value(u"url").toString();
        if (url.isEmpty())
            continue;
        s.tabs.append({ o.value(u"title").toString(), url, number(o.value(u"created")) });
    }
    if (s.tabs.isEmpty())
        return {};
    s.name = j.value(u"name").toString();
    s.saved_at = number(j.value(u"savedAt"));
    s.active = std::clamp(int(number(j.value(u"active"))), 0, int(s.tabs.size()) - 1);
    s.updated_at = number(j.value(u"updatedAt"), s.saved_at);
    return s;
}

static void sort_list()
{
    std::stable_sort(s_list.begin(), s_list.end(), [](Session const& a, Session const& b) { return a.saved_at > b.saved_at; });
}

static void load()
{
    if (s_loaded)
        return;
    s_loaded = true;
    auto path = file_path();
    QFile f(path);
    if (!f.exists() || !f.open(QIODevice::ReadOnly))
        return;
    QJsonParseError error;
    auto doc = QJsonDocument::fromJson(f.readAll(), &error);
    f.close();
    if (!doc.isObject()) {
        // Kept for the user rather than overwritten by the next save.
        auto aside = path + u".corrupt-"_s + QString::number(Profile::now_ms());
        QFile::rename(path, aside);
        s_load_error = u"Could not read "_s + path + u" ("_s + (error.error ? error.errorString() : u"not a JSON object"_s)
            + u"); it was moved to "_s + aside + u'.';
        return;
    }
    auto j = doc.object();
    for (auto const& e : j.value(u"sessions").toArray()) {
        if (auto s = from_json(e.toObject(), {}))
            s_list.append(*s);
    }
    sort_list();
    auto deleted = j.value(u"deleted").toObject();
    for (auto it = deleted.begin(); it != deleted.end(); ++it) {
        if (it.value().isDouble())
            s_deleted.append({ it.key(), qint64(it.value().toDouble()) });
    }
}

static void write()
{
    auto expire_before = Profile::now_seconds() - tombstone_lifetime;
    s_deleted.removeIf([&](auto const& d) { return d.second < expire_before; });
    QJsonArray list;
    for (auto const& s : s_list)
        list.append(to_json(s, true));
    QJsonObject j { { u"version"_s, 1 }, { u"sessions"_s, list } };
    if (!s_deleted.isEmpty()) {
        QJsonObject d;
        for (auto const& [id, at] : s_deleted)
            d.insert(id, at);
        j.insert(u"deleted"_s, d);
    }
    Profile::write_atomic(file_path(), QJsonDocument(j).toJson(QJsonDocument::Indented));
}

static void changed()
{
    write();
    for (auto const& l : s_listeners)
        l();
}

static int index_of(QString const& id)
{
    for (int i = 0; i < s_list.size(); ++i) {
        if (s_list[i].id == id)
            return i;
    }
    return -1;
}

static void touch(Session& s) { s.updated_at = std::max(Profile::now_seconds(), s.updated_at + 1); }

static int tombstone_index(QString const& id)
{
    for (int i = 0; i < s_deleted.size(); ++i) {
        if (s_deleted[i].first == id)
            return i;
    }
    return -1;
}

static void tombstone(Session const& s)
{
    if (auto i = tombstone_index(s.id); i >= 0)
        s_deleted.removeAt(i);
    s_deleted.append({ s.id, std::max(Profile::now_seconds(), s.updated_at + 1) });
}

QList<Session> const& all()
{
    load();
    return s_list;
}

Session const* find(QString const& id)
{
    load();
    auto i = index_of(id);
    return i < 0 ? nullptr : &s_list[i];
}

QString load_error()
{
    load();
    return s_load_error;
}

static char const* const months[] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

static QString name_for(QDateTime const& t)
{
    return QString::fromLatin1(months[t.date().month() - 1]) + u' ' + QString::number(t.date().day()) + u", "_s
        + t.time().toString(u"HH:mm"_s);
}

QString default_name() { return name_for(QDateTime::currentDateTime()); }

QString created_text(qint64 seconds)
{
    auto t = QDateTime::fromSecsSinceEpoch(seconds);
    auto name = name_for(t);
    auto comma = name.indexOf(u',');
    return u"Created "_s + name.left(comma) + u", "_s + QString::number(t.date().year()) + name.mid(comma);
}

static bool keeps(QString const& url) { return Profile::is_session_url(url); }

int savable(QList<Profile::SavedTab> const& tabs)
{
    return int(std::count_if(tabs.begin(), tabs.end(), [](auto const& t) { return keeps(t.url); }));
}

QString save(QList<Profile::SavedTab> const& tabs, QString const& name, int active)
{
    load();
    Session s;
    for (int i = 0; i < tabs.size(); ++i) {
        if (!keeps(tabs[i].url))
            continue;
        if (i <= active)
            s.active = int(s.tabs.size());
        // The open-tab age (created) stays with open_tabs.json, as on the desktop.
        s.tabs.append({ tabs[i].title, tabs[i].url, 0 });
    }
    if (s.tabs.isEmpty())
        return {};
    auto micros = QDateTime::currentMSecsSinceEpoch() * 1000;
    static int counter = 0;
    s.id = QString::number(micros, 36) + QString::number(counter++, 36);
    auto trimmed = name.trimmed();
    s.name = trimmed.isEmpty() ? default_name() : trimmed;
    s.saved_at = micros / 1'000'000;
    s.updated_at = s.saved_at;
    s_list.prepend(s);
    changed();
    return s.id;
}

void rename(QString const& id, QString const& name)
{
    load();
    auto trimmed = name.trimmed();
    auto i = index_of(id);
    if (i < 0 || trimmed.isEmpty() || trimmed == s_list[i].name)
        return;
    s_list[i].name = trimmed;
    touch(s_list[i]);
    changed();
}

bool remove_tab(QString const& id, int index, Profile::SavedTab* removed, Session* whole)
{
    load();
    auto i = index_of(id);
    if (i < 0 || index < 0 || index >= s_list[i].tabs.size())
        return false;
    auto& s = s_list[i];
    if (whole)
        *whole = s;
    if (removed)
        *removed = s.tabs[index];
    s.tabs.removeAt(index);
    if (s.tabs.isEmpty()) {
        tombstone(s);
        s_list.removeAt(i);
    } else {
        s.active = std::min(s.active, int(s.tabs.size()) - 1);
        touch(s);
    }
    changed();
    return true;
}

void restore_tab(Session const& whole, Profile::SavedTab const& tab, int index)
{
    load();
    auto i = index_of(whole.id);
    if (i < 0) {
        auto s = whole;
        restore_deleted(s);
        return;
    }
    auto& s = s_list[i];
    s.tabs.insert(std::clamp(index, 0, int(s.tabs.size())), tab);
    touch(s);
    changed();
}

bool remove(QString const& id, Session* deleted)
{
    load();
    auto i = index_of(id);
    if (i < 0)
        return false;
    if (deleted)
        *deleted = s_list[i];
    tombstone(s_list[i]);
    s_list.removeAt(i);
    changed();
    return true;
}

void restore_deleted(Session const& session)
{
    load();
    if (index_of(session.id) >= 0)
        return;
    auto s = session;
    if (auto i = tombstone_index(s.id); i >= 0) {
        s.updated_at = std::max(s.updated_at, s_deleted[i].second);
        s_deleted.removeAt(i);
    }
    touch(s);
    s_list.append(s);
    sort_list();
    changed();
}

void remove_all()
{
    load();
    if (s_list.isEmpty())
        return;
    for (auto const& s : s_list)
        tombstone(s);
    s_list.clear();
    changed();
}

QJsonObject to_sync_doc()
{
    load();
    QJsonObject result;
    for (auto const& [id, at] : s_deleted)
        result.insert(id, QJsonObject { { u"updatedAt"_s, at }, { u"deleted"_s, true } });
    for (auto const& s : s_list)
        result.insert(s.id, to_json(s, false));
    return result;
}

bool apply_sync_doc(QJsonObject const& section)
{
    load();
    if (section == to_sync_doc())
        return false;
    QList<Session> next;
    QList<QPair<QString, qint64>> tombs;
    for (auto it = section.begin(); it != section.end(); ++it) {
        if (!it.value().isObject())
            continue;
        auto rec = it.value().toObject();
        if (rec.value(u"deleted").toBool()) {
            tombs.append({ it.key(), number(rec.value(u"updatedAt")) });
            continue;
        }
        if (auto s = from_json(rec, it.key()))
            next.append(*s);
    }
    s_list = next;
    sort_list();
    s_deleted = tombs;
    changed();
    return true;
}

void on_change(std::function<void()> listener) { s_listeners.append(std::move(listener)); }

}
