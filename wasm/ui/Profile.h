/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Where webby keeps a profile's data, and the stores the chrome keeps there: bookmarks, history and the open tabs.
// The files are the Nim front end's (nim/src/features/{bookmarks,history,tabs}/store.nim), in the same place
// ($XDG_DATA_HOME/webby/profiles/$WEBBY_PROFILE, else ~/.local/share/webby/profiles/default), so wasm webby and
// the desktop webby share bookmarks and history. WEBBY_DATA_DIR names the profile folder outright. Under
// `latha-gui --no-root` with no --dir for it nothing is kept, and the stores work in memory.

#pragma once

#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>

namespace WebbyUI::Profile {

QString dir();
QString file(QString const& name);
QJsonObject read_json(QString const& path);
bool write_atomic(QString const& path, QByteArray const& data);
qint64 now_seconds();
qint64 now_ms();
QString new_id();

// Bookmarks: <profile>/bookmarks.json, {"version":1, "showBar":…, "roots":{"bar":folder,"other":folder}}.
struct Bookmark {
    QString id;
    QString title;
    QString url;
    qint64 added_at { 0 };
    qint64 updated_at { 0 };
    double pos { 0 };
    bool folder { false };
    QList<Bookmark> children;
    QString label() const { return title.isEmpty() ? url : title; }
};

class Bookmarks {
public:
    static Bookmarks& the();
    Bookmark const& bar() const { return m_bar; }
    Bookmark const& other() const { return m_other; }
    bool show_bar() const { return m_show_bar; }
    void set_show_bar(bool);
    // The first bookmark (anywhere) for `url`, or null.
    Bookmark const* find(QString const& url) const;
    bool contains(QString const& url) const { return find(url) != nullptr; }
    // Adds `url` to the end of the bookmarks bar.
    void add(QString const& url, QString const& title);
    void remove_url(QString const& url);
    // Every bookmarked page, depth first.
    QList<Bookmark const*> all() const;

private:
    Bookmarks();
    void load();
    void save();
    QJsonObject m_rest; // fields this UI does not use ("deleted" sync tombstones), kept as they were
    Bookmark m_bar;
    Bookmark m_other;
    bool m_show_bar { true };
};

// History: <profile>/history.jsonl, one {"id","url","title","t"} visit per line, oldest first.
struct Visit {
    QString id;
    QString url;
    QString title;
    qint64 time { 0 }; // ms since the epoch
};

class History {
public:
    static History& the();
    QList<Visit> const& visits() const { return m_visits; }
    void add(QString const& url, QString const& title);
    // A later title for the newest visit of `url`.
    void set_title(QString const& url, QString const& title);

private:
    History();
    void rewrite();
    QList<Visit> m_visits;
};

// The open tabs, for the next start: <profile>/open_tabs.json, {"version":1,"active":i,"pinned":0,"tabs":[{title,url,created}]}.
struct SavedTab {
    QString title;
    QString url;
    qint64 created { 0 };
};
QList<SavedTab> read_open_tabs(int& active);
void write_open_tabs(QList<SavedTab> const& tabs, int active);

// Whether `url` is worth keeping in history or the open tabs (not blank, not webby's own pages).
bool is_session_url(QString const& url);

}
