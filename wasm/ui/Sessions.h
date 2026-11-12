/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Saved sessions, as the Nim front end keeps them (nim/src/features/tabs/store.nim, sessions.nim): named lists of
// tabs in <profile>/sessions.json ({"version":1, "sessions":[{id,name,savedAt,active,tabs:[{title,url}],updatedAt}],
// "deleted":{id: seconds}}), newest first, the same file the desktop webby reads. Closing the window saves its tabs
// as one; the Sessions page (SessionsPage.cpp) saves, restores, renames and deletes them. They sync as the
// "sessions" section of their own blob (Sync.h Blob::Sessions): one record per session plus tombstones.

#pragma once

#include "Profile.h"

#include <QJsonObject>
#include <QList>
#include <QString>
#include <functional>

namespace WebbyUI::Sessions {

struct Session {
    QString id;
    QString name;
    qint64 saved_at { 0 }; // seconds since the epoch
    QList<Profile::SavedTab> tabs;
    int active { 0 };        // the tab that was in front
    qint64 updated_at { 0 }; // seconds, so sync keeps the newest version
};

// Newest first.
QList<Session> const& all();
Session const* find(QString const& id);
// Why sessions.json couldn't be read (it was set aside), or "".
QString load_error();

// "Nov 12, 14:05": the name a session gets when none is given.
QString default_name();
// "Created Nov 12, 2026, 14:05".
QString created_text(qint64 seconds);

// Saves `tabs` (blank ones and webby's own pages left out) as a session called `name` (the date when empty); `active`
// is the index in `tabs` of the front one. The new session's id, or "" when there was nothing to save.
QString save(QList<Profile::SavedTab> const& tabs, QString const& name = {}, int active = 0);
// How many of `tabs` a session would keep.
int savable(QList<Profile::SavedTab> const& tabs);
void rename(QString const& id, QString const& name);
// Takes a tab out of a session (the session goes with its last tab); false if there was no such tab.
bool remove_tab(QString const& id, int index, Profile::SavedTab* removed = nullptr, Session* whole = nullptr);
// Undo of remove_tab: puts it back, bringing the session back if it had gone (`whole` as it was before).
void restore_tab(Session const& whole, Profile::SavedTab const& tab, int index);
// Deletes one; `deleted` gets it as it was, for undo.
bool remove(QString const& id, Session* deleted = nullptr);
// Undo of remove.
void restore_deleted(Session const&);
void remove_all();

// Sync: the "sessions" section ({id: {name, savedAt, active, tabs, updatedAt}} plus {id: {updatedAt, deleted: true}}),
// and taking a merged one back. True if anything changed.
QJsonObject to_sync_doc();
bool apply_sync_doc(QJsonObject const& section);

// Called after every change, here or from sync.
void on_change(std::function<void()>);

}
