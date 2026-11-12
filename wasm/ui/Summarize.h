/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Summarize and Ask AI for the wasm UI, as the Nim front end's nim/src/features/summarize.nim (and summarize/
// prompts.nim, deepseek.nim, cache.nim): the page's text is read by the same page script, a chat completions request
// to DeepSeek, Xiaomi MiMo or Meta streams the summary into the side panel (SummaryPanel.cpp), follow-up questions
// may search the web with DeepSeek's Search API, and summaries are saved in the profile's summaries.json (synced as the
// Summaries blob). Each provider's API key is a secret in the password vault (synced unless unticked), as on the
// desktop; without a vault they are kept in memory until webby quits.
//
// This file has the parts with no window: providers and keys, the prompts and requests, the streaming chat client
// (over Http::stream, Network.cpp), the web search and the saved summaries.

#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>
#include <functional>
#include <memory>

namespace WebbyUI::Summarize {

// Providers.

enum class Provider {
    DeepSeek,
    Mimo,
    Meta,
};
constexpr int provider_count = 3;

struct ProviderInfo {
    QString id, name, key_secret, endpoint, model, site;
    QString status;     // the status page named when a request hangs, or ""
    QString key_header; // the header the key goes in bare; "" means Authorization: Bearer
};
ProviderInfo const& info(Provider);
Provider provider_by_id(QString const&);

extern QString const deepseek_key_secret;
extern QString const provider_secret;
constexpr int max_input_chars = 40000;

// Secrets (the vault's, once it is open: PasswordManager sets the store; until then, and without one, memory).
struct SecretStore {
    std::function<QString(QString const&)> get;
    std::function<void(QString const&, QString const&, bool sync)> set;
    std::function<bool(QString const&)> syncs;
};
void set_secret_store(SecretStore);
bool has_vault();
QString secret(QString const& name);
void store_secret(QString const& name, QString const& value, bool sync);
bool secret_syncs(QString const& name);
// The chosen provider (its secret), unless only another one has a key.
Provider chosen_provider();
QString api_key(); // the chosen provider's key, or ""

// The page scripts (nim/src/scripts): the page's text, posted as {"type": "pagetext", "id", "selection", "title",
// "url", "lang", "text"}; the scroll to a source link's words; the "Ask AI about this" pill, which posts
// {"type": "askselection", "text", "title", "url"}.
QString page_text_script(QString const& prefix, QString const& id, bool whole_page);
QString jump_script(QString const& words);
QString ask_selection_script(QString const& prefix);

struct PageText {
    QString title, url, text;
    bool selection { false };
};
// A page message's text cut to max_input_chars.
QString cut_input(QString text);

// Requests (chat completions bodies).

struct QA {
    QString question, answer;
};
QJsonObject summary_request(PageText const&, Provider);
QJsonObject question_request(bool has_page, PageText const&, QString const& title, QString const& url, QString const& summary,
    QList<QA> const& earlier, QString const& question, Provider);
QJsonObject selection_question_request(QString const& selected, bool has_page, PageText const&, QString const& title,
    QString const& url, QList<QA> const& earlier, QString const& question, Provider);
QString waiting_text(bool has_page, bool queued, Provider);
QString busy_message(Provider);

// Web search.
extern QString const web_search_tool;
QJsonObject with_web_search(QJsonObject request);
QString search_query(QString const& arguments);
bool asks_for_search(QString const& question);
QString search_terms_for(QString const& question, QString const& quote, QString const& selected, QString const& title);
QJsonObject with_search_results(QJsonObject request, QString const& query, QString const& results);
QJsonObject search_decision_request(QString const& question, QString const& about, QString const& title, QString const& url, QString const& summary);
struct SearchDecision {
    bool search { false };
    QString query;
};
SearchDecision parse_search_decision(QString const& reply);

// A question and the panel text it is about, as one message (and back).
extern QString const quote_intro;
QString message_with_quote(QString const& question, QString const& quote);
void split_quote(QString const& message, QString& question, QString& quote);

// The summary without its " [§](#words)" source links (Copy).
QString without_source_links(QString const& text);

// The streaming client. `on_piece` gets each piece of the reply, then `on_done` "" or an error, once. A reply that
// ends in tool calls goes to `on_tools` instead (when set). DeepSeek's ": keep-alive" lines before the first piece
// make it `queued` (on_queued); 90 s of that, or 60 s with no data at all, ends it with an error.
struct SearchResult {
    QString title, url, snippet, summary, site, date;
};
struct ToolCall {
    QString id, name, arguments;
};
class Chat {
public:
    static std::shared_ptr<Chat> start(Provider, QString const& key, QJsonObject const& body,
        std::function<void(QString const&)> on_piece, std::function<void(QString const&)> on_done,
        std::function<void()> on_queued = {}, std::function<void(QList<ToolCall> const&)> on_tools = {});
    // Stops the request; nothing is called any more.
    void cancel();
    bool queued() const { return m_queued; }
    ~Chat();

    struct State;

private:
    std::shared_ptr<State> m_state;
    bool m_queued { false };
    friend struct State;
    friend std::shared_ptr<Chat> search_web(QString const&, QString const&, QString const&,
        std::function<void(QList<SearchResult> const&, QString const&)>);
};

// DeepSeek's Search API (the DeepSeek key as Bearer). `on_done` runs once, with the results or an error.
std::shared_ptr<Chat> search_web(QString const& key, QString const& query, QString const& question,
    std::function<void(QList<SearchResult> const&, QString const& error)> on_done);
QString search_results_text(QList<SearchResult> const&);

// Saved summaries: <profile>/summaries.json (WEBBY_SUMMARIES_FILE), the Nim front end's format, newest last, 300 kept.
struct Saved {
    QString title, url, text;
    qint64 at { 0 }; // made, ms
    bool selection { false };
    QList<QA> questions;
    qint64 updated_at { 0 }; // seconds; the newest copy wins in sync
};
QString summary_key(QString const& url, QString const& selection = {});
bool lookup(QString const& key, Saved&);
void store(QString const& key, Saved);
void clear_saved(qint64 since_ms = 0);
QJsonObject to_sync_records();
bool apply_sync_records(QJsonObject const&);
void on_saved_change(std::function<void()>);

}
