/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The address bar's logic, after the Nim front end's (nim/src/features/omnibox): typed text becomes an address when
// it looks like one and a search otherwise, and the suggestions under the field come from bookmarks and history.

#pragma once

#include <QList>
#include <QString>

namespace WebbyUI::Omnibox {

// The search engine's query URL, %s for the words: $WEBBY_SEARCH_URL, else Google (the Nim front end's default).
QString query_url();
// The engines the Settings menu offers (Ladybird's built-in ones), and the one chosen (wasm_ui.json searchEngine).
struct Engine {
    char const* name;
    char const* query_url;
};
QList<Engine> engines();
QString engine_name();
void set_engine(QString const& name);
bool looks_like_address(QString const& text);
// What the address bar loads for `input`.
QString address_to_url(QString const& input);

struct Suggestion {
    enum class Kind { Address, Search, Bookmark, History };
    Kind kind;
    QString title;
    QString url;
};

// At most `limit` suggestions for `input`: a search for the text first (or the address itself), then bookmarks and
// pages from history whose URL or title has every word, most visited first.
QList<Suggestion> suggestions(QString const& input, int limit = 8);

}
