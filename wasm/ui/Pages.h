/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// webby's own pages (History, Bookmarks), as the Nim front end has them: written as HTML files into the profile's
// pages/ folder and opened as file:// URLs, since the engine component takes URLs, not HTML.

#pragma once

#include <QString>

namespace WebbyUI::Pages {

// The file:// URL of a freshly written History page (newest visits first, by day), or "" if it could not be written.
QString history_page();
// The file:// URL of a freshly written Bookmarks page (bar, then other bookmarks).
QString bookmarks_page();
// The file:// URL of a freshly written Downloads page (newest first, each a link to the saved file).
QString downloads_page();
// Whether `url` is one of these pages, and so is written again when reloaded.
bool is_own_page(QString const& url);
QString refresh(QString const& url);

}
