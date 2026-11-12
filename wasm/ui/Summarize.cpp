/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Summarize.h"
#include "HttpClient.h"
#include "Profile.h"
#include "Resources.h"

#include <QDateTime>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QMap>
#include <QRegularExpression>
#include <QTimer>
#include <algorithm>

using namespace Qt::StringLiterals;

namespace WebbyUI::Summarize {

QString const deepseek_key_secret = u"deepseek-api-key"_s;
QString const provider_secret = u"summarize-provider"_s;
QString const web_search_tool = u"web_search"_s;

ProviderInfo const& info(Provider p)
{
    static ProviderInfo const providers[provider_count] = {
        { u"deepseek"_s, u"DeepSeek"_s, deepseek_key_secret, u"https://api.deepseek.com/chat/completions"_s,
            u"deepseek-flash"_s, u"platform.deepseek.com"_s, u"status.deepseek.com"_s, {} },
        // Pay-as-you-go keys (sk-...) on api.xiaomimimo.com, sent in an `api-key` header.
        { u"mimo"_s, u"Xiaomi MiMo"_s, u"mimo-api-key"_s, u"https://api.xiaomimimo.com/v1/chat/completions"_s,
            u"mimo-v2.6-flash"_s, u"platform.xiaomimimo.com"_s, {}, u"api-key"_s },
        { u"meta"_s, u"Meta"_s, u"meta-api-key"_s, u"https://api.meta.ai/v1/chat/completions"_s,
            u"muse-spark-1.3"_s, u"dev.meta.ai"_s, {}, {} },
    };
    return providers[qBound(0, int(p), provider_count - 1)];
}

Provider provider_by_id(QString const& id)
{
    for (int i = 0; i < provider_count; ++i) {
        if (info(Provider(i)).id == id)
            return Provider(i);
    }
    return Provider::DeepSeek;
}

// Secrets.

static SecretStore s_store;
static QMap<QString, QString> s_memory;
static QMap<QString, bool> s_memory_sync;

void set_secret_store(SecretStore store)
{
    s_store = std::move(store);
    // Keys entered before the vault opened go into it.
    if (s_store.set) {
        for (auto it = s_memory.begin(); it != s_memory.end(); ++it) {
            if (!it.value().isEmpty() && s_store.get && s_store.get(it.key()).isEmpty())
                s_store.set(it.key(), it.value(), s_memory_sync.value(it.key(), true));
        }
        s_memory.clear();
    }
}

bool has_vault() { return bool(s_store.get); }

QString secret(QString const& name)
{
    if (s_store.get)
        return s_store.get(name);
    return s_memory.value(name);
}

void store_secret(QString const& name, QString const& value, bool sync)
{
    if (s_store.set) {
        s_store.set(name, value, sync);
        return;
    }
    s_memory[name] = value;
    s_memory_sync[name] = sync;
}

bool secret_syncs(QString const& name)
{
    if (s_store.syncs)
        return s_store.syncs(name);
    return s_memory_sync.value(name, true);
}

Provider chosen_provider()
{
    auto chosen = provider_by_id(secret(provider_secret));
    if (!secret(info(chosen).key_secret).isEmpty())
        return chosen;
    for (int i = 0; i < provider_count; ++i) {
        if (!secret(info(Provider(i)).key_secret).isEmpty())
            return Provider(i);
    }
    return chosen;
}

QString api_key() { return secret(info(chosen_provider()).key_secret); }

// Page scripts.

static QString json_string(QString const& s)
{
    auto doc = QJsonDocument(QJsonArray { s }).toJson(QJsonDocument::Compact);
    return QString::fromUtf8(doc.mid(1, doc.size() - 2));
}

QString page_text_script(QString const& prefix, QString const& id, bool whole_page)
{
    QString s = QString::fromUtf8(webby_builtin_page_text_js);
    s.replace(u"${jsonEncode(prefix)}"_s, json_string(prefix));
    s.replace(u"${jsonEncode(id)}"_s, json_string(id));
    s.replace(u"$maxSummaryInputChars"_s, QString::number(max_input_chars));
    s.replace(u"$minSelection"_s, whole_page ? u"Infinity"_s : u"200"_s);
    return s;
}

QString jump_script(QString const& words)
{
    QString s = QString::fromUtf8(webby_builtin_jump_to_text_js);
    s.replace(u"${jsonEncode(words)}"_s, json_string(words));
    return s;
}

QString ask_selection_script(QString const& prefix)
{
    QString s = QString::fromUtf8(webby_builtin_ask_selection_js);
    s.replace(u"${jsonEncode(prefix)}"_s, json_string(prefix));
    return s;
}

QString cut_input(QString text)
{
    // Nim cuts bytes; this cuts UTF-16 units, never inside a surrogate pair.
    if (text.size() > max_input_chars) {
        int n = max_input_chars;
        if (n > 0 && text.at(n - 1).isHighSurrogate())
            --n;
        text.truncate(n);
    }
    return text;
}

// Prompts (nim/src/features/summarize/prompts.nim, word for word).

static QString const source_link_rule = u"End each bullet with a source link to the part of the page it comes from, written "
                                        "[§](#words), where words are 3 to 8 consecutive words copied exactly from the page text; a section heading "
                                        "(marked ## in the text) is best. Copy them character for character in the page's own language, even when it "
                                        "isn't English, without parentheses or brackets. No other links."_s;

static QString summary_prompt()
{
    return u"You summarize web pages for a browser's summary panel. This needs to be in English: write the "
           "summary in English whatever the language of the page. Start with one or two sentences saying what the "
           "page is about, then give the key points as a short markdown bullet list. Use markdown: **bold** for key "
           "names and figures, `code` for code, and a short ### heading only when the page covers clearly separate "
           "topics. No tables or images. "_s
        + source_link_rule;
}

static QString const question_prompt = u"You answer questions about a web page the user is reading, in a browser's side panel. Use "
                                       "the page text and your earlier summary. This needs to be in English: answer in English, concisely, in markdown "
                                       "(bullet lists, **bold**, `code`; no tables or images). If the page doesn't say, say so before adding what you "
                                       "know. Where a point comes from the page, you may end it with a source link written [§](#words), where words "
                                       "are 3 to 8 consecutive words copied exactly from the page text, in its own language."_s;

static QString const selection_prompt = u"You answer questions about a passage the user selected on a web page they are reading, "
                                        "in a browser's side panel. The rest of the page is there for context. This needs to be in English: answer in "
                                        "English, concisely, in markdown (bullet lists, **bold**, `code`; no tables or images). Explain terms, claims "
                                        "and references in the passage when asked; if the page doesn't say, say so before adding what you know. No links."_s;

QString busy_message(Provider p)
{
    auto const& i = info(p);
    return i.name + u" accepted the request but hasn't sent anything back in 90 seconds. It may be having an outage"_s
        + (i.status.isEmpty() ? QString() : u": see "_s + i.status) + u"."_s;
}

QString waiting_text(bool has_page, bool queued, Provider p)
{
    if (!has_page)
        return u"Reading the page…"_s;
    if (queued)
        return info(p).name + u" hasn't started answering yet…"_s;
    return u"Asking "_s + info(p).name + u"…"_s;
}

static QJsonObject message(QString const& role, QString const& content)
{
    return { { u"role"_s, role }, { u"content"_s, content } };
}

static QJsonObject with_provider(QJsonObject body, Provider p)
{
    body.insert(u"model"_s, info(p).model);
    switch (p) {
    case Provider::Mimo:
    case Provider::DeepSeek:
        // Answer at once; tool calls then need no reasoning_content.
        body.insert(u"thinking"_s, QJsonObject { { u"type"_s, u"disabled"_s } });
        break;
    case Provider::Meta:
        body.insert(u"reasoning_effort"_s, u"minimal"_s);
        break;
    }
    return body;
}

static QJsonObject chat_body(QJsonArray messages, Provider p)
{
    return with_provider({ { u"stream"_s, true }, { u"temperature"_s, 0.3 }, { u"messages"_s, messages } }, p);
}

QJsonObject summary_request(PageText const& page, Provider p)
{
    auto user = (page.selection ? u"Summarize this text selected on"_s : u"Summarize this page:"_s) + u" "_s
        + (page.title.isEmpty() ? QString() : u"\""_s + page.title + u"\" "_s) + u"("_s + page.url + u")\n\n"_s + page.text;
    return chat_body({ message(u"system"_s, summary_prompt()), message(u"user"_s, user) }, p);
}

QJsonObject question_request(bool has_page, PageText const& page, QString const& title, QString const& url, QString const& summary,
    QList<QA> const& earlier, QString const& question, Provider p)
{
    QString context = !has_page
        ? u"The page \""_s + title + u"\" ("_s + url + u"). Its text isn't available any more; go by your summary."_s
        : (page.selection ? u"Text selected on"_s : u"The page"_s) + u" \""_s + (page.title.isEmpty() ? title : page.title)
            + u"\" ("_s + page.url + u"):\n\n"_s + page.text;
    QJsonArray messages { message(u"system"_s, question_prompt), message(u"user"_s, context), message(u"assistant"_s, summary) };
    for (auto const& qa : earlier) {
        messages.append(message(u"user"_s, qa.question));
        messages.append(message(u"assistant"_s, qa.answer));
    }
    messages.append(message(u"user"_s, question));
    return chat_body(messages, p);
}

QJsonObject selection_question_request(QString const& selected, bool has_page, PageText const& page, QString const& title,
    QString const& url, QList<QA> const& earlier, QString const& question, Provider p)
{
    auto name = page.title.isEmpty() ? title : page.title;
    QString context = u"The page \""_s + name + u"\" ("_s + (page.url.isEmpty() ? url : page.url) + u")"_s;
    if (has_page && !page.text.trimmed().isEmpty())
        context += u":\n\n"_s + page.text + u"\n\n---\n\n"_s;
    else
        context += u". "_s;
    context += u"The user selected this passage:\n\n"_s + selected;
    QJsonArray messages { message(u"system"_s, selection_prompt), message(u"user"_s, context) };
    for (auto const& qa : earlier) {
        messages.append(message(u"user"_s, qa.question));
        messages.append(message(u"assistant"_s, qa.answer));
    }
    messages.append(message(u"user"_s, question));
    return chat_body(messages, p);
}

// Web search.

static QString today() { return QDateTime::currentDateTime().toString(u"yyyy-MM-dd"_s); }

static QString const web_search_rule = u" You can search the web with the web_search tool. Use it when the question needs what the "
                                       "page doesn't have: recent events, other sources, checking a claim, background on a name or term. When the page "
                                       "doesn't answer the question, search instead of answering from memory, and never say you can't search the web. "
                                       "Don't search for what the page already answers. Search queries are short keyword queries (at most 128 characters), in "
                                       "the language most likely to find good sources. When a point comes from a web result, end it with a link to "
                                       "that result written [site name](url), using the result's own url; such links are allowed even where other "
                                       "links are not."_s;

QJsonObject with_web_search(QJsonObject request)
{
    auto messages = request.value(u"messages"_s).toArray();
    if (!messages.isEmpty() && messages[0].toObject().value(u"role"_s).toString() == u"system"_s) {
        auto first = messages[0].toObject();
        first.insert(u"content"_s, first.value(u"content"_s).toString() + web_search_rule + u" Today is "_s + today() + u"."_s);
        messages[0] = first;
        request.insert(u"messages"_s, messages);
    }
    QJsonObject query {
        { u"type"_s, u"string"_s },
        { u"description"_s, u"The search query: a few keywords, at most 128 characters. Supports site:, -site:, \"exact phrase\", lang:en, after:2025-01-01 and before: operators."_s },
    };
    QJsonObject function {
        { u"name"_s, web_search_tool },
        { u"description"_s, u"Search the web. Returns the best results with title, url, site, date and a summary of each."_s },
        { u"parameters"_s, QJsonObject { { u"type"_s, u"object"_s }, { u"properties"_s, QJsonObject { { u"query"_s, query } } }, { u"required"_s, QJsonArray { u"query"_s } } } },
    };
    request.insert(u"tools"_s, QJsonArray { QJsonObject { { u"type"_s, u"function"_s }, { u"function"_s, function } } });
    return request;
}

QString search_query(QString const& arguments)
{
    auto doc = QJsonDocument::fromJson(arguments.toUtf8());
    return doc.isObject() ? doc.object().value(u"query"_s).toString().trimmed() : QString();
}

static QStringList const search_words { u"websearch"_s, u"web search"_s, u"search"_s, u"look up"_s, u"lookup"_s, u"look it up"_s,
    u"google"_s, u"internet"_s, u"on the web"_s, u"latest news"_s };

bool asks_for_search(QString const& question)
{
    auto q = u" "_s + question.toLower() + u" "_s;
    for (auto const& w : search_words) {
        if (q.contains(w))
            return true;
    }
    return false;
}

QString search_terms_for(QString const& question, QString const& quote, QString const& selected, QString const& title)
{
    auto q = u" "_s + question.toLower() + u" "_s;
    for (auto const& w : search_words)
        q.replace(w, u" "_s);
    for (auto w : { u" the "_s, u" web "_s, u" for "_s, u" about "_s, u" this "_s, u" please "_s, u" can you "_s, u" what "_s, u" is "_s, u" it "_s })
        q.replace(w, u" "_s);
    q = q.simplified();
    while (!q.isEmpty() && u" ?.!,"_s.contains(q.back()))
        q.chop(1);
    while (!q.isEmpty() && u" ?.!,"_s.contains(q.front()))
        q.remove(0, 1);
    auto about = (!quote.trimmed().isEmpty() ? quote : !selected.trimmed().isEmpty() ? selected : title).simplified();
    auto result = q.size() >= 4 ? q : about;
    if (result.isEmpty())
        result = question.trimmed();
    return result;
}

QJsonObject with_search_results(QJsonObject request, QString const& query, QString const& results)
{
    auto messages = request.value(u"messages"_s).toArray();
    if (messages.isEmpty())
        return request;
    auto last = messages.last().toObject();
    last.insert(u"content"_s, u"Web search results for \""_s + query + u"\" ("_s + today() + u"):\n\n"_s + results
            + u"\n---\n\nUse these results where they help, and end each point that comes from one with a link to it written [site name](url). The question:\n\n"_s
            + last.value(u"content"_s).toString());
    messages[messages.size() - 1] = last;
    request.insert(u"messages"_s, messages);
    return request;
}

QJsonObject search_decision_request(QString const& question, QString const& about, QString const& title, QString const& url, QString const& summary)
{
    auto cut = [](QString s, int n) {
        s = s.simplified();
        if (s.size() > n)
            s = s.left(n) + u"…"_s;
        return s;
    };
    static QString const prompt = u"You decide whether a question a user asks about a web page they are reading needs a "
                                  "web search. Search when the answer needs what the page itself is unlikely to say: recent or current events, "
                                  "facts to check, other sources or opinions, background on a person, project, product or term the page only "
                                  "names, or when the user asks for a search. Don't search for questions about the page's own content (explain, "
                                  "summarize, define something the page explains). Reply with JSON only: {\"search\": true or false, \"query\": "
                                  "\"a short keyword search query, at most 128 characters, or empty\"}."_s;
    QString context = u"The page: \""_s + title + u"\" ("_s + url + u")\n"_s;
    if (!summary.trimmed().isEmpty())
        context += u"Its summary: "_s + cut(summary, 1500) + u"\n"_s;
    if (!about.trimmed().isEmpty())
        context += u"The question is about this text: "_s + cut(about, 1000) + u"\n"_s;
    context += u"Today is "_s + today() + u".\n\nThe question: "_s + question;
    return with_provider({ { u"stream"_s, true }, { u"temperature"_s, 0 }, { u"max_tokens"_s, 80 },
                             { u"messages"_s, QJsonArray { message(u"system"_s, prompt), message(u"user"_s, context) } } },
        Provider::DeepSeek);
}

SearchDecision parse_search_decision(QString const& reply)
{
    auto a = reply.indexOf(u'{');
    auto b = reply.lastIndexOf(u'}');
    if (a < 0 || b <= a)
        return {};
    auto doc = QJsonDocument::fromJson(reply.mid(a, b - a + 1).toUtf8());
    if (!doc.isObject())
        return {};
    SearchDecision d;
    d.query = doc.object().value(u"query"_s).toString().trimmed();
    d.search = doc.object().value(u"search"_s).toBool() && !d.query.isEmpty();
    return d;
}

QString const quote_intro = u"About this part of the side panel (your summary, your answers or the passage):"_s;

QString message_with_quote(QString const& question, QString const& quote)
{
    if (quote.isEmpty())
        return question;
    QString result = quote_intro + u"\n"_s;
    for (auto const& line : quote.split(u'\n'))
        result += u"> "_s + line + u"\n"_s;
    return result + u"\n"_s + question;
}

void split_quote(QString const& message, QString& question, QString& quote)
{
    question = message;
    quote.clear();
    if (!message.startsWith(quote_intro + u"\n"_s))
        return;
    auto lines = message.mid(quote_intro.size() + 1).split(u'\n');
    QStringList quoted;
    int i = 0;
    while (i < lines.size() && lines[i].startsWith(u'>')) {
        quoted.append(lines[i].mid(qMin(2, int(lines[i].size()))));
        ++i;
    }
    if (i < lines.size() && lines[i].isEmpty() && !quoted.isEmpty()) {
        quote = quoted.join(u'\n');
        question = lines.mid(i + 1).join(u'\n');
    }
}

QString without_source_links(QString const& text)
{
    static QRegularExpression const link(u" ?\\[§\\]\\(#[^)\\n]*\\)"_s);
    return QString(text).remove(link).trimmed();
}

// The streaming client.

struct Chat::State {
    Chat* owner { nullptr };
    Provider provider { Provider::DeepSeek };
    std::function<void(QString const&)> on_piece;
    std::function<void(QString const&)> on_done;
    std::function<void()> on_queued;
    std::function<void(QList<ToolCall> const&)> on_tools;
    std::function<void(QByteArray const&)> on_body; // plain requests: the whole body of a 200 answer
    Http::StreamId id { 0 };
    int status { 0 };
    bool got_headers { false };
    bool got_piece { false };
    bool finished { false };
    bool sse_done { false };
    QByteArray events; // the body not yet split into lines
    QByteArray body;   // a failure's (or a plain request's) body
    QList<ToolCall> tool_calls;
    QElapsedTimer last_data;
    QElapsedTimer last_piece;
    QTimer* tick { nullptr };

    void finish(QString const& error)
    {
        if (finished)
            return;
        finished = true;
        if (tick) {
            tick->stop();
            tick->deleteLater();
            tick = nullptr;
        }
        Http::cancel(id);
        auto done = std::move(on_done);
        on_piece = {};
        on_tools = {};
        if (done)
            done(error);
    }

    void handle_events()
    {
        while (!finished && !sse_done) {
            auto nl = events.indexOf('\n');
            if (nl < 0)
                return;
            auto line = events.left(nl);
            events.remove(0, nl + 1);
            if (line.endsWith('\r'))
                line.chop(1);
            if (line.startsWith(':')) {
                // DeepSeek sends ": keep-alive" every few seconds while it holds a request without answering.
                if (!got_piece) {
                    if (owner && !owner->m_queued) {
                        owner->m_queued = true;
                        if (on_queued)
                            on_queued();
                    }
                    if (last_piece.elapsed() > 90000) {
                        finish(busy_message(provider));
                        return;
                    }
                }
                continue;
            }
            if (!line.startsWith("data:"))
                continue;
            auto data = line.mid(5).trimmed();
            if (data == "[DONE]") {
                sse_done = true;
                return;
            }
            auto choices = QJsonDocument::fromJson(data).object().value(u"choices"_s).toArray();
            if (choices.isEmpty())
                continue;
            auto delta = choices[0].toObject().value(u"delta"_s).toObject();
            // Tool calls come in pieces: the first piece of each (by index) has its id and name, the arguments follow.
            auto calls = delta.value(u"tool_calls"_s).toArray();
            for (auto const& v : calls) {
                auto call = v.toObject();
                int i = call.value(u"index"_s).toInt(int(tool_calls.size()));
                if (i < 0 || i > 16)
                    continue;
                while (tool_calls.size() <= i)
                    tool_calls.append(ToolCall {});
                if (!call.value(u"id"_s).toString().isEmpty())
                    tool_calls[i].id = call.value(u"id"_s).toString();
                auto f = call.value(u"function"_s).toObject();
                if (!f.value(u"name"_s).toString().isEmpty())
                    tool_calls[i].name = f.value(u"name"_s).toString();
                tool_calls[i].arguments += f.value(u"arguments"_s).toString();
            }
            if (!calls.isEmpty())
                got_some();
            auto content = delta.value(u"content"_s).toString();
            if (!content.isEmpty()) {
                got_some();
                if (on_piece)
                    on_piece(content);
            }
        }
    }

    void got_some()
    {
        got_piece = true;
        if (owner)
            owner->m_queued = false;
        last_piece.restart();
    }

    QString describe_failure() const
    {
        auto const& name = info(provider).name;
        auto detail = QJsonDocument::fromJson(body).object().value(u"error"_s).toObject().value(u"message"_s).toString();
        switch (status) {
        case 401:
            return name + u" didn't accept the API key. Check it under Summarize settings."_s;
        case 402:
            return u"The "_s + name + u" account is out of balance."_s;
        case 429:
            return name + u" is rate limiting requests; try again in a moment."_s;
        default:
            return name + u" answered with an error ("_s + QString::number(status) + u")"_s + (detail.isEmpty() ? QString() : u": "_s + detail) + u"."_s;
        }
    }

    void ended(QString const& error)
    {
        if (finished)
            return;
        auto const& name = info(provider).name;
        if (!error.isEmpty()) {
            finish(got_headers ? u"The answer from "_s + name + u" broke off ("_s + error + u")."_s
                               : u"Couldn't reach "_s + name + u" ("_s + error + u")."_s);
            return;
        }
        if (!got_headers) {
            finish(u"Couldn't reach "_s + name + u" (the connection closed)."_s);
            return;
        }
        if (status != 200) {
            finish(describe_failure());
            return;
        }
        if (on_body) {
            auto cb = std::move(on_body);
            auto b = body;
            cb(b);
            finish({});
            return;
        }
        if (!sse_done)
            events.append('\n');
        handle_events();
        if (finished)
            return;
        QList<ToolCall> calls;
        for (auto const& t : tool_calls) {
            if (!t.name.isEmpty())
                calls.append(t);
        }
        if (!calls.isEmpty() && on_tools) {
            auto cb = std::move(on_tools);
            on_done = {};
            finish({});
            cb(calls);
            return;
        }
        finish({});
    }
};

static QString endpoint_override(char const* name)
{
    return qEnvironmentVariable(name);
}

static Http::Headers key_header(Provider p, QString const& key)
{
    auto const& i = info(p);
    if (!i.key_header.isEmpty())
        return { { i.key_header.toStdString(), key.toStdString() } };
    return { { "Authorization", ("Bearer " + key).toStdString() } };
}

static void send(std::shared_ptr<Chat::State> const& state, QString const& endpoint, QString const& key, QByteArray const& payload, char const* accept)
{
    auto headers = key_header(state->provider, key);
    headers.emplace_back("Content-Type", "application/json");
    headers.emplace_back("Accept", accept);
    state->last_data.start();
    state->last_piece.start();
    std::weak_ptr<Chat::State> weak = state;
    // Timeouts: 60 s with no data at all (connecting, headers, between pieces); 90 s queued.
    state->tick = new QTimer;
    state->tick->setInterval(1000);
    QObject::connect(state->tick, &QTimer::timeout, [weak] {
        auto s = weak.lock();
        if (!s || s->finished)
            return;
        if (s->last_data.elapsed() > 60000)
            s->finish(info(s->provider).name + u" took too long to answer."_s);
        else if (s->owner && s->owner->queued() && s->last_piece.elapsed() > 90000)
            s->finish(busy_message(s->provider));
    });
    state->tick->start();
    state->id = Http::stream("POST", endpoint.toStdString(), headers, payload.toStdString(),
        [weak](int status, Http::Headers const&) {
            auto s = weak.lock();
            if (!s || s->finished)
                return;
            s->got_headers = true;
            s->status = status;
            s->last_data.restart();
        },
        [weak](std::string const& data) {
            auto s = weak.lock();
            if (!s || s->finished)
                return;
            s->last_data.restart();
            auto bytes = QByteArray::fromStdString(data);
            if (s->status == 200 && !s->on_body) {
                s->events.append(bytes);
                s->handle_events();
            } else {
                s->body.append(bytes);
            }
        },
        [weak](std::string const& error) {
            auto s = weak.lock();
            if (!s)
                return;
            s->ended(QString::fromStdString(error));
        });
}

std::shared_ptr<Chat> Chat::start(Provider provider, QString const& key, QJsonObject const& body,
    std::function<void(QString const&)> on_piece, std::function<void(QString const&)> on_done,
    std::function<void()> on_queued, std::function<void(QList<ToolCall> const&)> on_tools)
{
    auto chat = std::make_shared<Chat>();
    auto state = std::make_shared<State>();
    state->owner = chat.get();
    state->provider = provider;
    state->on_piece = std::move(on_piece);
    state->on_done = std::move(on_done);
    state->on_queued = std::move(on_queued);
    state->on_tools = std::move(on_tools);
    chat->m_state = state;
    auto e = endpoint_override("WEBBY_DEEPSEEK_ENDPOINT");
    send(state, e.isEmpty() ? info(provider).endpoint : e, key, QJsonDocument(body).toJson(QJsonDocument::Compact), "text/event-stream");
    return chat;
}

void Chat::cancel()
{
    if (!m_state)
        return;
    m_state->on_done = {};
    m_state->finish({});
    m_state->owner = nullptr;
}

Chat::~Chat()
{
    if (m_state) {
        m_state->owner = nullptr;
        // A chat nobody holds any more stops; its callbacks are gone with its owner.
        if (!m_state->finished) {
            m_state->on_done = {};
            m_state->finish({});
        }
    }
}

static QString clip(QString const& s, int n)
{
    auto t = s.trimmed();
    return t.size() > n ? t.left(n) : t;
}

std::shared_ptr<Chat> search_web(QString const& key, QString const& query, QString const& question,
    std::function<void(QList<SearchResult> const&, QString const& error)> on_done)
{
    QJsonObject body { { u"query"_s, clip(query, 128) }, { u"count"_s, 6 } };
    if (!question.trimmed().isEmpty())
        body.insert(u"ori_question"_s, clip(question, 128));
    auto chat = std::make_shared<Chat>();
    auto state = std::make_shared<Chat::State>();
    state->owner = chat.get();
    state->provider = Provider::DeepSeek;
    auto results = std::make_shared<QList<SearchResult>>();
    state->on_body = [results](QByteArray const& b) {
        for (auto const& v : QJsonDocument::fromJson(b).object().value(u"results"_s).toArray()) {
            auto r = v.toObject();
            if (r.value(u"url"_s).toString().isEmpty())
                continue;
            results->append({ r.value(u"title"_s).toString(), r.value(u"url"_s).toString(), r.value(u"snippet"_s).toString(),
                r.value(u"summary"_s).toString(), r.value(u"site_name"_s).toString(), r.value(u"date"_s).toString() });
        }
    };
    state->on_done = [results, on_done = std::move(on_done)](QString const& error) {
        on_done(*results, error.isEmpty() ? QString() : u"Web search failed: "_s + error);
    };
    chat->m_state = state;
    auto e = endpoint_override("WEBBY_DEEPSEEK_SEARCH_ENDPOINT");
    send(state, e.isEmpty() ? u"https://api.deepseek.com/v1/tools/search"_s : e, key, QJsonDocument(body).toJson(QJsonDocument::Compact), "application/json");
    return chat;
}

QString search_results_text(QList<SearchResult> const& results)
{
    if (results.isEmpty())
        return u"No results."_s;
    QString out;
    for (int i = 0; i < results.size(); ++i) {
        auto const& r = results[i];
        out += QString::number(i + 1) + u". "_s + r.title + u"\n   url: "_s + r.url + u"\n"_s;
        if (!r.site.isEmpty())
            out += u"   site: "_s + r.site + u"\n"_s;
        if (r.date.size() >= 10)
            out += u"   date: "_s + r.date.left(10) + u"\n"_s;
        out += u"   "_s + (r.summary.isEmpty() ? r.snippet : r.summary).simplified() + u"\n\n"_s;
    }
    return out;
}

// Saved summaries (nim/src/features/summarize/cache.nim).

namespace {

constexpr int summary_limit = 300;

struct Cache {
    QList<QPair<QString, Saved>> entries; // oldest first
    QList<QPair<QString, qint64>> deleted;
    bool loaded { false };
    QString path;
    std::vector<std::function<void()>> listeners;

    int index_of(QString const& key) const
    {
        for (int i = 0; i < entries.size(); ++i) {
            if (entries[i].first == key)
                return i;
        }
        return -1;
    }
    qint64 deleted_at(QString const& key) const
    {
        for (auto const& [k, at] : deleted) {
            if (k == key)
                return at;
        }
        return 0;
    }
    void undelete(QString const& key)
    {
        deleted.removeIf([&](auto const& d) { return d.first == key; });
    }
};

Cache& cache()
{
    static Cache c;
    return c;
}

Saved from_json(QJsonObject const& j)
{
    Saved s;
    s.title = j.value(u"title"_s).toString();
    s.url = j.value(u"url"_s).toString();
    s.text = j.value(u"text"_s).toString();
    s.at = qint64(j.value(u"at"_s).toDouble());
    s.selection = j.value(u"selection"_s).toBool();
    s.updated_at = j.contains(u"updatedAt"_s) ? qint64(j.value(u"updatedAt"_s).toDouble()) : s.at / 1000;
    for (auto const& v : j.value(u"questions"_s).toArray()) {
        auto qa = v.toObject();
        if (qa.value(u"q"_s).isString() && qa.value(u"a"_s).isString())
            s.questions.append({ qa.value(u"q"_s).toString(), qa.value(u"a"_s).toString() });
    }
    return s;
}

QJsonObject to_json(Saved const& s)
{
    QJsonObject j { { u"title"_s, s.title }, { u"url"_s, s.url }, { u"text"_s, s.text }, { u"at"_s, double(s.at) } };
    if (s.selection)
        j.insert(u"selection"_s, true);
    if (!s.questions.isEmpty()) {
        QJsonArray qs;
        for (auto const& qa : s.questions)
            qs.append(QJsonObject { { u"q"_s, qa.question }, { u"a"_s, qa.answer } });
        j.insert(u"questions"_s, qs);
    }
    j.insert(u"updatedAt"_s, double(s.updated_at));
    return j;
}

void load()
{
    auto& c = cache();
    if (c.loaded)
        return;
    c.loaded = true;
    auto o = qEnvironmentVariable("WEBBY_SUMMARIES_FILE");
    c.path = o.isEmpty() ? Profile::file(u"summaries.json"_s) : o;
    auto j = Profile::read_json(c.path);
    auto summaries = j.value(u"summaries"_s).toObject();
    // Qt's QJsonObject sorts its keys: the order is the saved one only by `at`, which the Nim cache keeps anyway.
    QList<QPair<QString, Saved>> all;
    for (auto it = summaries.begin(); it != summaries.end(); ++it) {
        if (it.value().isObject())
            all.append({ it.key(), from_json(it.value().toObject()) });
    }
    std::stable_sort(all.begin(), all.end(), [](auto const& a, auto const& b) { return a.second.updated_at < b.second.updated_at; });
    c.entries = all;
    auto deleted = j.value(u"deleted"_s).toObject();
    for (auto it = deleted.begin(); it != deleted.end(); ++it)
        c.deleted.append({ it.key(), qint64(it.value().toDouble()) });
}

void save()
{
    auto& c = cache();
    if (c.path.isEmpty())
        return;
    // Written by hand to keep the order (newest last), as the Nim front end's file has it.
    QByteArray out = "{\"version\":1,\"summaries\":{";
    bool first = true;
    for (auto const& [k, v] : c.entries) {
        if (!first)
            out += ',';
        first = false;
        out += json_string(k).toUtf8() + ':' + QJsonDocument(to_json(v)).toJson(QJsonDocument::Compact);
    }
    out += '}';
    if (!c.deleted.isEmpty()) {
        out += ",\"deleted\":{";
        first = true;
        for (auto const& [k, at] : c.deleted) {
            if (!first)
                out += ',';
            first = false;
            out += json_string(k).toUtf8() + ':' + QByteArray::number(at);
        }
        out += '}';
    }
    out += "}\n";
    Profile::write_atomic(c.path, out);
    auto listeners = c.listeners;
    for (auto const& l : listeners)
        l();
}

QString fnv1a(QByteArray const& text)
{
    quint64 h = 0xcbf29ce484222325ULL;
    for (char ch : text)
        h = (h ^ quint64(quint8(ch))) * 0x100000001b3ULL;
    auto s = QString::number(h, 16);
    return s.isEmpty() ? u"0"_s : s;
}

}

QString summary_key(QString const& url, QString const& selection)
{
    auto hash = url.indexOf(u'#');
    auto page = hash >= 0 ? url.left(hash) : url;
    return selection.isEmpty() ? page : page + u"\n"_s + fnv1a(selection.toUtf8());
}

bool lookup(QString const& key, Saved& out)
{
    load();
    auto i = cache().index_of(key);
    if (i < 0)
        return false;
    out = cache().entries[i].second;
    return true;
}

void store(QString const& key, Saved summary)
{
    load();
    auto& c = cache();
    auto previous = c.deleted_at(key);
    if (auto i = c.index_of(key); i >= 0) {
        previous = c.entries[i].second.updated_at;
        c.entries.removeAt(i);
    }
    summary.updated_at = qMax(Profile::now_seconds(), previous + 1);
    c.entries.append({ key, summary });
    c.undelete(key);
    while (c.entries.size() > summary_limit)
        c.entries.removeFirst();
    save();
}

void clear_saved(qint64 since_ms)
{
    load();
    auto& c = cache();
    auto now = Profile::now_seconds();
    for (int i = int(c.entries.size()) - 1; i >= 0; --i) {
        auto const& [k, v] = c.entries[i];
        if (since_ms == 0 || v.at >= since_ms) {
            c.undelete(k);
            c.deleted.append({ k, qMax(now, v.updated_at + 1) });
            c.entries.removeAt(i);
        }
    }
    save();
}

QJsonObject to_sync_records()
{
    load();
    QJsonObject result;
    for (auto const& [k, at] : cache().deleted)
        result.insert(k, QJsonObject { { u"updatedAt"_s, double(at) }, { u"deleted"_s, true } });
    for (auto const& [k, v] : cache().entries)
        result.insert(k, to_json(v));
    return result;
}

bool apply_sync_records(QJsonObject const& records)
{
    load();
    if (records == to_sync_records())
        return false;
    auto& c = cache();
    QList<QPair<QString, Saved>> live;
    c.deleted.clear();
    for (auto it = records.begin(); it != records.end(); ++it) {
        if (!it.value().isObject())
            continue;
        auto r = it.value().toObject();
        if (r.value(u"deleted"_s).toBool())
            c.deleted.append({ it.key(), qint64(r.value(u"updatedAt"_s).toDouble()) });
        else
            live.append({ it.key(), from_json(r) });
    }
    std::stable_sort(live.begin(), live.end(), [](auto const& a, auto const& b) { return a.second.updated_at < b.second.updated_at; });
    c.entries = live;
    while (c.entries.size() > summary_limit)
        c.entries.removeFirst();
    save();
    return true;
}

void on_saved_change(std::function<void()> f)
{
    cache().listeners.push_back(std::move(f));
}

}
