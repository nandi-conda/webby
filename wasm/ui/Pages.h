/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// webby's own pages (History, Bookmarks), as the Nim front end has them: written as HTML files into the profile's
// pages/ folder and opened as file:// URLs, since the engine component takes URLs, not HTML.

#pragma once

#include "Profile.h"

#include <QString>
#include <QStringList>

namespace WebbyUI::Pages {

// The file:// URL of a freshly written History page (newest visits first, by day), or "" if it could not be written.
QString history_page();
// The file:// URL of a freshly written Bookmarks page (bar, then other bookmarks).
QString bookmarks_page();
// The file:// URL of a freshly written Downloads page (newest first, each a link to the saved file).
QString downloads_page();
// The file:// URL of the Keyboard shortcuts page.
QString shortcuts_page();
// The file:// URL of the Passwords and passkeys page (no secrets in the file: Passwords.cpp sends them to the page).
QString passwords_page();
// The file:// URL of the About Webby page.
QString about_page();
// The Sync page and Tabs from other devices (SyncPages.cpp), freshly written; and where they are.
QString sync_page();
QString devices_page();
QString sync_page_url();
QString devices_page_url();
// A link or form on those pages: <pages>/sync-do?op=…, which the chrome runs instead of loading.
bool is_sync_action(QString const& url);
struct SyncAction {
    QString load;       // the page to show next in that tab ("" for none)
    QStringList open;   // URLs to open in new tabs
    QString copy;       // text for the clipboard
};
SyncAction run_sync_action(QString const& url);

// The Sessions page (SessionsPage.cpp, Sessions.h), freshly written; and where it is. Its links and forms go to
// <pages>/sessions-do?op=…, which the chrome runs instead of loading.
QString sessions_page();
QString sessions_page_url();
bool is_sessions_action(QString const& url);
struct SessionsAction {
    QString load;                     // the page to show next in that tab ("" for none)
    QList<Profile::SavedTab> open;    // tabs to open next to the current one (a restore), `front` the one to show
    int front { 0 };
    enum class Save { None, Keep, CloseAll } save { Save::None }; // save the open tabs as a session (and close them)
    QString name;                     // for Save::Keep ("" for the date)
};
SessionsAction run_sessions_action(QString const& url);
// An error for the top of the next Sessions page.
void sessions_notice(QString const& error);

// Writes pages/<name> with the own pages' look and returns its file:// URL ("" if it could not be written).
QString write_page(QString const& name, QString const& title, QString const& body);

// Whether `url` is one of these pages, and so is written again when reloaded.
bool is_own_page(QString const& url);
QString refresh(QString const& url);

}
