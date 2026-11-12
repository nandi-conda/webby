/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Summarize and Ask AI in the window (Summarize.h has the rest): a job per tab, as the Nim front end's summarize.nim
// keeps them, and the side panel that shows the current tab's job. The panel is a page of its own
// (summary-panel.html) in a second WebView beside the page: right of it when the window is at least 720 pixels wide,
// under it otherwise, as the Flutter and Nim front ends lay it out.

#include "BrowserWindow.h"
#include "Pages.h"
#include "Profile.h"
#include "Resources.h"
#include "Summarize.h"
#include "Theme.h"

#include <QDateTime>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPainter>
#include <QRandomGenerator>
#include <QUrl>
#include <qt2wasm/gui.h>

using namespace Qt::StringLiterals;
using namespace WebbyUI;
namespace S = WebbyUI::Summarize;

struct SummaryQuestion {
    QString question, answer, error;
    QString quote;        // the panel text it asks about, or ""
    bool running { false };
    QStringList searches; // web searches made for the answer (shown above it; not saved)
    QString searching;    // the search running now
    QString notice;       // why a search asked for did not happen
};

struct SummaryJob {
    WebbyUI::WebView* view { nullptr };
    bool open { false };
    bool running { false };
    bool selection { false };
    bool asking { false };  // "Ask AI about this": questions about `selected`, no summary
    bool reading { false }; // the page's text is still being read for `asking`
    bool has_page { false };
    QString title, url, text, error, key, selected;
    QString quote; // text selected in the panel itself that the next question is about
    qint64 saved_at { 0 };
    qint64 made_at { 0 };
    QList<std::shared_ptr<SummaryQuestion>> questions;
    int generation { 0 };
    S::PageText page;
    std::shared_ptr<S::Chat> chat;
    S::Provider provider { S::Provider::DeepSeek };
    std::vector<std::function<void()>> after_read;
    bool start_after_key { false }; // Summarize was asked for before there was a key: it starts once one is saved

    bool answering() const { return !questions.isEmpty() && questions.last()->running; }
    void stop_chat()
    {
        if (chat)
            chat->cancel();
        chat.reset();
    }
};

namespace {

QString from_std(std::string const& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }
std::string to_std(QString const& s) { return s.toStdString(); }

constexpr int max_search_rounds = 3;
constexpr int panel_width = 380;
constexpr int max_quote = 4000;

QList<QPair<QString, QString>> const quick_questions {
    { u"Explain"_s, u"Explain this passage in plain words."_s },
    { u"Summarize"_s, u"Summarize this passage in a few bullets."_s },
    { u"Define terms"_s, u"Define the terms, names and references in this passage."_s },
};
QList<QPair<QString, QString>> const panel_questions {
    { u"Explain"_s, u"Explain this in plain words."_s },
    { u"Tell me more"_s, u"Tell me more about this, from what the page says."_s },
    { u"Define terms"_s, u"Define the terms, names and references in this."_s },
};

// Page-text reads waiting for their page message, by id.
QMap<QString, std::function<void(bool, S::PageText const&)>> s_reads;

QString random_id()
{
    QString id;
    for (int i = 0; i < 8; ++i)
        id += QString::number(QRandomGenerator::global()->bounded(256), 16).rightJustified(2, u'0');
    return id;
}

QString when_text(qint64 ms)
{
    auto t = QDateTime::fromMSecsSinceEpoch(ms);
    auto now = QDateTime::currentDateTime();
    if (t.date() == now.date())
        return u"today "_s + t.toString(u"HH:mm"_s);
    return t.toString(u"yyyy-MM-dd HH:mm"_s);
}

QString short_quote(QString const& text, int limit = 280)
{
    auto s = text.simplified();
    return s.size() > limit ? s.left(limit).trimmed() + u"…"_s : s;
}

QString panel_page_url()
{
    // Written once a run: the page is the same for every profile.
    static QString url;
    if (url.isEmpty()) {
        auto dir = Profile::file(u"pages"_s);
        QDir().mkpath(dir);
        auto path = dir + u"/summary-panel.html"_s;
        if (Profile::write_atomic(path, QByteArray(webby_builtin_summary_panel_html)))
            url = QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded);
    }
    return url;
}

}

// Layout.

bool BrowserWindow::panel_showing() const
{
    return panel_job() != nullptr;
}

SummaryJob* BrowserWindow::panel_job() const
{
    if (m_current < 0 || m_current >= int(m_tabs.size()) || !m_tabs[m_current].view)
        return nullptr;
    auto it = m_jobs.find(m_tabs[m_current].view.get());
    if (it == m_jobs.end() || !it->second->open)
        return nullptr;
    return it->second.get();
}

QRect BrowserWindow::panel_rect() const
{
    if (!panel_showing())
        return {};
    int top = chrome_height();
    int h = qMax(1, height() - top);
    if (width() >= 720)
        return { width() - panel_width, top, panel_width, h };
    int page = h / 2;
    return { 0, top + page, qMax(1, width()), qMax(1, h - page) };
}

void BrowserWindow::relayout_panel()
{
    // The page shrinks or grows to make room for the panel.
    resizeEvent(nullptr);
    if (m_panel && panel_showing()) {
        auto r = panel_rect();
        if (m_panel->width() != r.width() || m_panel->height() != r.height())
            m_panel->resize(r.width(), r.height());
    }
    update();
}

void BrowserWindow::paint_panel(QPainter& p)
{
    if (!panel_showing())
        return;
    auto r = panel_rect();
    if (!needs_paint(r))
        return;
    uint8_t const* pixels = m_panel && m_panel_ready ? m_panel->paint() : nullptr;
    if (!pixels) {
        p.fillRect(r, WebbyUI::theme().page_blank);
        return;
    }
    QImage image(pixels, m_panel->width(), m_panel->height(), m_panel->width() * 4, QImage::Format_ARGB32_Premultiplied);
    p.save();
    p.setCompositionMode(QPainter::CompositionMode_Source);
    p.drawImage(r.topLeft(), image);
    p.restore();
    if (image.width() < r.width() || image.height() < r.height()) {
        p.fillRect(QRect(r.left() + image.width(), r.top(), r.width() - image.width(), r.height()), WebbyUI::theme().page_blank);
        p.fillRect(QRect(r.left(), r.top() + image.height(), r.width(), r.height() - image.height()), WebbyUI::theme().page_blank);
    }
}

// The panel's own view.

void BrowserWindow::ensure_panel()
{
    if (m_panel)
        return;
    auto r = panel_rect();
    m_panel = WebbyUI::WebView::create(qMax(1, r.width()), qMax(1, r.height()));
    if (!m_panel)
        return;
    auto* raw = m_panel.get();
    raw->on_needs_paint = [this] {
        if (panel_showing())
            update(panel_rect());
    };
    raw->on_loading_change = [this, raw](bool loading) {
        if (loading || m_panel_ready)
            return;
        m_panel_ready = true;
        auto prefix = QString::fromStdString(raw->message_prefix());
        raw->run_javascript(to_std(u"window.webbyPanel && webbyPanel.init("_s + QString::fromUtf8(QJsonDocument(QJsonArray { prefix }).toJson(QJsonDocument::Compact)).mid(1).chopped(1) + u")"_s));
        render_panel();
        if (panel_showing())
            update(panel_rect());
    };
    raw->on_page_message = [this](std::string const& text, std::string const&) { panel_message(from_std(text)); };
    raw->on_clipboard_write = [](std::string const& text, bool selection) {
        auto q = from_std(text);
        selection ? qt2wasm::gui::setPrimaryText(q) : qt2wasm::gui::setClipboardText(q);
    };
    raw->on_clipboard_request = [raw](uint64_t request, bool selection) {
        raw->answer_clipboard(request, to_std(selection ? qt2wasm::gui::primaryText() : qt2wasm::gui::clipboardText()));
    };
    // Links in the panel are handled by its page (op "open", "jump"); nothing else navigates it.
    raw->on_navigation_request = [](std::string const&) { return true; };
    raw->on_link_hover = [this](std::string const& link) {
        auto was = status_rect();
        m_hovered_link = from_std(link);
        update(QRegion(was) | status_rect());
    };
    m_panel_ready = false;
    raw->load(to_std(panel_page_url()));
}

void BrowserWindow::render_panel()
{
    if (m_panel_render_queued)
        return;
    m_panel_render_queued = true;
    // At most every 50 ms while text streams in.
    QTimer::singleShot(50, this, [this] {
        m_panel_render_queued = false;
        send_panel_state();
    });
}

void BrowserWindow::send_panel_state()
{
    auto* job = panel_job();
    if (!job || !m_panel || !m_panel_ready)
        return;
    auto key = S::api_key();
    bool busy = job->running || job->answering();
    QJsonObject s;
    s.insert(u"heading"_s, job->asking ? u"Ask AI"_s : job->selection ? u"Summary of selection"_s : u"Summary"_s);
    s.insert(u"busy"_s, busy ? (job->answering() ? u"Answering…"_s : u"Summarizing…"_s) : QString());
    QString copyable;
    if (!job->asking) {
        copyable = S::without_source_links(job->text);
    } else {
        for (auto i = job->questions.size() - 1; i >= 0; --i) {
            if (!job->questions[i]->answer.trimmed().isEmpty()) {
                copyable = job->questions[i]->answer.trimmed();
                break;
            }
        }
    }
    s.insert(u"copyable"_s, !copyable.isEmpty());
    s.insert(u"asking"_s, job->asking);
    s.insert(u"canRedo"_s, !busy && !key.isEmpty());
    s.insert(u"hasKey"_s, !key.isEmpty());
    s.insert(u"title"_s, job->title);
    s.insert(u"url"_s, job->url);
    s.insert(u"selected"_s, job->selected);
    auto pairs = [](QList<QPair<QString, QString>> const& list) {
        QJsonArray a;
        for (auto const& [label, question] : list)
            a.append(QJsonArray { label, question });
        return a;
    };
    s.insert(u"quick"_s, pairs(quick_questions));
    s.insert(u"panelQuick"_s, pairs(panel_questions));
    if (job->saved_at != 0 && !job->running)
        s.insert(u"saved"_s, u"Saved summary from "_s + when_text(job->saved_at) + u". Summarize again for a new one."_s);
    s.insert(u"error"_s, job->error);
    if (!job->asking && job->text.isEmpty() && job->running)
        s.insert(u"waiting"_s, S::waiting_text(job->has_page, job->chat && job->chat->queued(), job->provider));
    s.insert(u"text"_s, job->text.trimmed());
    QJsonArray questions;
    for (auto const& qa : job->questions) {
        QJsonArray searches;
        for (int i = 0; i < qa->searches.size(); ++i) {
            bool now = i == qa->searches.size() - 1 && !qa->searching.isEmpty();
            searches.append((now ? u"Searching the web for “"_s : u"Searched the web for “"_s) + qa->searches[i] + (now ? u"”…"_s : u"”"_s));
        }
        questions.append(QJsonObject {
            { u"quote"_s, qa->quote.isEmpty() ? QString() : short_quote(qa->quote) },
            { u"question"_s, qa->question },
            { u"searches"_s, searches },
            { u"notice"_s, qa->notice },
            { u"answer"_s, qa->answer.trimmed() },
            { u"thinking"_s, qa->running && qa->searching.isEmpty() },
            { u"error"_s, qa->error },
        });
    }
    s.insert(u"questions"_s, questions);
    s.insert(u"quote"_s, job->quote.isEmpty() ? QString() : short_quote(job->quote));
    bool can_ask = !key.isEmpty() && (!job->text.trimmed().isEmpty() || job->asking) && !job->running && job->error.isEmpty();
    s.insert(u"canAsk"_s, can_ask);
    s.insert(u"answering"_s, job->answering());
    QJsonArray providers;
    for (int i = 0; i < S::provider_count; ++i) {
        auto const& info = S::info(S::Provider(i));
        providers.append(QJsonObject { { u"id"_s, info.id }, { u"name"_s, info.name }, { u"site"_s, info.site },
            { u"hasKey"_s, !S::secret(info.key_secret).isEmpty() }, { u"syncs"_s, S::secret_syncs(info.key_secret) } });
    }
    s.insert(u"settings"_s, QJsonObject { { u"providers"_s, providers }, { u"chosen"_s, S::info(S::chosen_provider()).id }, { u"vault"_s, S::has_vault() } });
    if (m_panel_open_settings) {
        s.insert(u"openSettings"_s, true);
        m_panel_open_settings = false;
        m_panel_focused = true; // the key field has the focus
    }
    if (m_panel_scroll_to_end) {
        s.insert(u"scrollToEnd"_s, true);
        m_panel_scroll_to_end = false;
    }
    auto json = QString::fromUtf8(QJsonDocument(s).toJson(QJsonDocument::Compact));
    m_panel->run_javascript(to_std(u"window.webbyPanel && webbyPanel.render("_s + json + u")"_s));
    if (m_panel_focus_entry) {
        m_panel_focus_entry = false;
        m_panel->run_javascript("window.webbyPanel && webbyPanel.focusEntry()");
        m_panel_focused = true;
    }
}

void BrowserWindow::job_changed(SummaryJob& job)
{
    if (panel_job() == &job)
        render_panel();
}

// Reading the page.

void BrowserWindow::read_page_text(WebbyUI::WebView* view, bool whole_page, std::function<void(bool, S::PageText const&)> done)
{
    // A PDF's text comes from the viewer (PdfView), a selection of 200 characters or more first, like a page's.
    for (auto& t : m_tabs) {
        if (t.view.get() != view || !t.pdf || t.pdf->url() != from_std(view->url()))
            continue;
        S::PageText page;
        page.title = t.pdf->title();
        page.url = t.pdf->url();
        auto selected = t.pdf->selected_text().trimmed();
        if (!whole_page && selected.size() >= 200) {
            page.text = S::cut_input(selected);
            page.selection = true;
        } else {
            page.text = S::cut_input(t.pdf->document_text(S::max_input_chars));
        }
        bool ok = !t.pdf->failed();
        QTimer::singleShot(0, this, [done = std::move(done), ok, page] { done(ok, page); });
        return;
    }
    auto id = random_id();
    s_reads.insert(id, std::move(done));
    view->run_javascript(to_std(S::page_text_script(from_std(view->message_prefix()), id, whole_page)));
    QTimer::singleShot(8000, this, [id] {
        auto cb = s_reads.take(id);
        if (cb)
            cb(false, {});
    });
}

void BrowserWindow::hook_summarize(WebbyUI::WebView& view)
{
    static bool scripts = false;
    if (!scripts) {
        scripts = true;
        // "Ask AI about this" by text selected on any page (not the panel's own).
        WebbyUI::WebView::add_page_script([this](WebbyUI::WebView& v) -> std::string {
            if (&v == m_panel.get() || from_std(v.url()).endsWith(u"/summary-panel.html"_s))
                return {};
            return to_std(S::ask_selection_script(from_std(v.message_prefix())));
        });
    }
    auto* raw = &view;
    auto passwords = std::move(view.on_page_message);
    view.on_page_message = [this, raw, passwords](std::string const& message, std::string const& document_url) {
        auto text = from_std(message);
        if (text.startsWith(u'{') && (text.contains(u"\"pagetext\""_s) || text.contains(u"\"askselection\""_s) || text.contains(u"\"summaryjumpmiss\""_s))) {
            auto j = QJsonDocument::fromJson(text.toUtf8()).object();
            auto type = j.value(u"type"_s).toString();
            if (type == u"pagetext"_s) {
                auto cb = s_reads.take(j.value(u"id"_s).toString());
                if (cb) {
                    S::PageText page;
                    page.title = j.value(u"title"_s).toString();
                    page.url = j.contains(u"url"_s) ? j.value(u"url"_s).toString() : from_std(raw->url());
                    page.text = S::cut_input(j.value(u"text"_s).toString());
                    page.selection = j.value(u"selection"_s).toBool();
                    cb(true, page);
                }
                return;
            }
            if (type == u"askselection"_s) {
                if (current() && current()->view.get() == raw)
                    ask_about_selection(raw, j.value(u"text"_s).toString().trimmed());
                return;
            }
            if (type == u"summaryjumpmiss"_s) {
                auto it = m_jobs.find(raw);
                if (it != m_jobs.end())
                    summary_jump_elsewhere(*it->second, j.value(u"words"_s).toString());
                return;
            }
        }
        if (passwords)
            passwords(message, document_url);
    };
    auto loading = std::move(view.on_loading_change);
    view.on_loading_change = [this, raw, loading](bool is_loading) {
        if (loading)
            loading(is_loading);
        // The page a source link needs has loaded again: jump now and twice more (the jump script skips a page that
        // already jumped).
        if (!is_loading && m_pending_jump.first == raw) {
            auto words = m_pending_jump.second;
            m_pending_jump = { nullptr, {} };
            run_summary_jump(raw, words, 10, false);
            for (int ms : { 1000, 2500 }) {
                QTimer::singleShot(ms, this, [this, raw, words] {
                    for (auto const& t : m_tabs) {
                        if (t.view.get() == raw)
                            run_summary_jump(raw, words, 4, false);
                    }
                });
            }
        }
    };
}

void BrowserWindow::forget_summary(WebbyUI::WebView* view)
{
    if (m_pending_jump.first == view)
        m_pending_jump = { nullptr, {} };
    auto it = m_jobs.find(view);
    if (it == m_jobs.end())
        return;
    it->second->stop_chat();
    ++it->second->generation;
    m_jobs.erase(it);
}

// Jobs.

static void save_job(SummaryJob& job)
{
    if (job.asking || job.key.isEmpty() || job.text.trimmed().isEmpty())
        return;
    if (job.made_at == 0)
        job.made_at = Profile::now_ms();
    S::Saved s;
    s.title = job.title;
    s.url = job.url;
    s.text = job.text;
    s.at = job.made_at;
    s.selection = job.selection;
    for (auto const& qa : job.questions) {
        if (!qa->running && qa->error.isEmpty() && !qa->answer.trimmed().isEmpty())
            s.questions.append({ S::message_with_quote(qa->question, qa->quote), qa->answer });
    }
    S::store(job.key, s);
}

static void show_saved(SummaryJob& job, QString const& key, S::Saved const& saved)
{
    ++job.generation;
    job.asking = false;
    job.key = key;
    job.questions.clear();
    job.quote.clear();
    for (auto const& qa : saved.questions) {
        auto q = std::make_shared<SummaryQuestion>();
        S::split_quote(qa.question, q->question, q->quote);
        q->answer = qa.answer;
        job.questions.append(q);
    }
    job.open = true;
    job.running = false;
    job.error.clear();
    job.title = saved.title;
    job.url = saved.url;
    job.text = saved.text;
    job.selection = saved.selection;
    job.saved_at = saved.at;
    job.made_at = saved.at;
}

std::shared_ptr<SummaryJob> BrowserWindow::job_for(WebbyUI::WebView* view)
{
    auto& job = m_jobs[view];
    if (!job) {
        job = std::make_shared<SummaryJob>();
        job->view = view;
    }
    return job;
}

void BrowserWindow::start_summary(std::shared_ptr<SummaryJob> const& job, bool fresh)
{
    auto key = S::api_key();
    auto provider = S::chosen_provider();
    job->stop_chat();
    int generation = ++job->generation;
    auto* tab = current();
    job->open = true;
    job->asking = false;
    job->running = true;
    job->start_after_key = false;
    job->error.clear();
    job->text.clear();
    job->title = tab ? tab->title : QString();
    job->url = from_std(job->view->url());
    job->saved_at = 0;
    job->questions.clear();
    job->quote.clear();
    job->key.clear();
    job->has_page = false;
    job->made_at = 0;
    job->provider = provider;
    job_changed(*job);
    std::weak_ptr<SummaryJob> weak = job;
    auto fail = [this, weak, generation](QString const& message) {
        auto j = weak.lock();
        if (!j || j->generation != generation)
            return;
        j->error = message;
        j->running = false;
        job_changed(*j);
    };
    read_page_text(job->view, false, [this, weak, generation, fresh, fail, key, provider](bool ok, S::PageText const& page) {
        auto j = weak.lock();
        if (!j || j->generation != generation)
            return;
        if (!ok) {
            fail(u"Couldn't read the text of this page."_s);
            return;
        }
        auto k = S::summary_key(page.url, page.selection ? page.text : QString());
        S::Saved saved;
        j->page = page;
        j->has_page = true;
        if (!fresh && S::lookup(k, saved)) {
            show_saved(*j, k, saved);
            job_changed(*j);
            return;
        }
        j->key = k;
        if (!page.title.isEmpty())
            j->title = page.title;
        j->url = page.url;
        j->selection = page.selection;
        if (page.text.trimmed().size() < 40) {
            fail(u"This page has no text to summarize."_s);
            return;
        }
        job_changed(*j);
        j->chat = S::Chat::start(provider, key, S::summary_request(page, provider),
            [this, weak, generation](QString const& piece) {
                auto j = weak.lock();
                if (!j || j->generation != generation)
                    return;
                j->text += piece;
                job_changed(*j);
            },
            [this, weak, generation, fail, provider](QString const& error) {
                auto j = weak.lock();
                if (!j || j->generation != generation)
                    return;
                j->chat.reset();
                if (!error.isEmpty()) {
                    fail(error);
                    return;
                }
                if (j->text.trimmed().isEmpty()) {
                    fail(S::info(provider).name + u" sent back an empty summary."_s);
                    return;
                }
                save_job(*j);
                j->running = false;
                job_changed(*j);
            },
            [this, weak, generation] {
                auto j = weak.lock();
                if (j && j->generation == generation)
                    job_changed(*j);
            });
    });
}

void BrowserWindow::ask_question(std::shared_ptr<SummaryJob> const& job, QString const& text)
{
    auto question = text.trimmed();
    auto key = S::api_key();
    auto provider = S::chosen_provider();
    if (question.isEmpty() || key.isEmpty() || job->running || job->answering() || (job->text.trimmed().isEmpty() && !job->asking))
        return;
    int generation = job->generation;
    QList<S::QA> earlier;
    for (auto const& qa : job->questions) {
        if (qa->error.isEmpty() && !qa->answer.trimmed().isEmpty())
            earlier.append({ S::message_with_quote(qa->question, qa->quote), qa->answer });
    }
    auto entry = std::make_shared<SummaryQuestion>();
    entry->question = question;
    entry->quote = job->quote;
    entry->running = true;
    job->quote.clear();
    job->questions.append(entry);
    m_panel_scroll_to_end = true;
    job_changed(*job);
    std::weak_ptr<SummaryJob> weak = job;

    auto send = [this, weak, generation, entry, earlier, key, provider] {
        auto job = weak.lock();
        if (!job || job->generation != generation)
            return;
        auto message = S::message_with_quote(entry->question, entry->quote);
        auto request = std::make_shared<QJsonObject>(job->asking
                ? S::selection_question_request(job->selected, job->has_page, job->page, job->title, job->url, earlier, message, provider)
                : S::question_request(job->has_page, job->page, job->title, job->url, job->text, earlier, message, provider));
        bool explicit_search = S::asks_for_search(entry->question);
        auto search_key = S::secret(S::deepseek_key_secret);
        if (explicit_search && search_key.isEmpty())
            entry->notice = u"Web search needs a DeepSeek API key (Summarize settings, the gear in this panel)."_s;
        bool tools = !search_key.isEmpty() && provider == S::Provider::DeepSeek;
        if (tools) {
            *request = S::with_web_search(*request);
            if (explicit_search)
                request->insert(u"tool_choice"_s, u"required"_s); // asked to search: search first
        }
        auto rounds = std::make_shared<int>(0);
        auto stream = std::make_shared<std::function<void()>>();
        auto on_piece = [this, weak, generation, entry](QString const& piece) {
            auto j = weak.lock();
            if (!j || j->generation != generation)
                return;
            entry->answer += piece;
            job_changed(*j);
        };
        auto on_done = [this, weak, generation, entry, provider](QString const& error) {
            auto j = weak.lock();
            if (!j || j->generation != generation)
                return;
            j->chat.reset();
            entry->running = false;
            entry->searching.clear();
            entry->error = !error.isEmpty() ? error
                : entry->answer.trimmed().isEmpty()    ? S::info(provider).name + u" sent back an empty answer."_s
                                                       : QString();
            if (entry->error.isEmpty())
                save_job(*j);
            job_changed(*j);
        };
        // The model wants web searches: run them one after another, hand back the results, and ask again.
        auto on_tools = [this, weak, generation, entry, request, rounds, stream, search_key](QList<S::ToolCall> const& calls) {
            auto j = weak.lock();
            if (!j || j->generation != generation)
                return;
            j->chat.reset();
            ++*rounds;
            request->insert(u"tool_choice"_s, *rounds >= max_search_rounds ? u"none"_s : u"auto"_s);
            auto said = entry->answer; // what it wrote before the calls ("Let me look that up"): not part of the answer
            entry->answer.clear();
            QJsonArray tool_calls;
            for (auto const& c : calls)
                tool_calls.append(QJsonObject { { u"id"_s, c.id }, { u"type"_s, u"function"_s },
                    { u"function"_s, QJsonObject { { u"name"_s, c.name }, { u"arguments"_s, c.arguments } } } });
            auto messages = request->value(u"messages"_s).toArray();
            messages.append(QJsonObject { { u"role"_s, u"assistant"_s }, { u"content"_s, said }, { u"tool_calls"_s, tool_calls } });
            request->insert(u"messages"_s, messages);
            auto next = std::make_shared<std::function<void(int)>>();
            *next = [this, weak, generation, entry, request, stream, search_key, calls, next](int i) {
                auto j = weak.lock();
                if (!j || j->generation != generation)
                    return;
                if (i >= calls.size()) {
                    entry->searching.clear();
                    (*stream)();
                    return;
                }
                auto const& call = calls[i];
                auto answer = [request, id = call.id](QString const& content) {
                    auto messages = request->value(u"messages"_s).toArray();
                    messages.append(QJsonObject { { u"role"_s, u"tool"_s }, { u"tool_call_id"_s, id }, { u"content"_s, content } });
                    request->insert(u"messages"_s, messages);
                };
                auto query = S::search_query(call.arguments);
                if (call.name != S::web_search_tool || query.isEmpty()) {
                    answer(u"Error: unknown tool or empty query."_s);
                    (*next)(i + 1);
                    return;
                }
                entry->searching = query;
                entry->searches.append(query);
                job_changed(*j);
                j->chat = S::search_web(search_key, query, entry->question, [this, weak, generation, answer, next, i](QList<S::SearchResult> const& results, QString const& error) {
                    auto j = weak.lock();
                    if (!j || j->generation != generation)
                        return;
                    answer(!error.isEmpty() ? error : S::search_results_text(results));
                    // Later: this chat is still finishing.
                    QTimer::singleShot(0, this, [next, i] { (*next)(i + 1); });
                });
            };
            (*next)(0);
        };
        *stream = [weak, request, on_piece, on_done, on_tools, tools, provider, key] {
            auto j = weak.lock();
            if (!j)
                return;
            j->chat = S::Chat::start(provider, key, *request, on_piece, on_done, {},
                tools ? std::function<void(QList<S::ToolCall> const&)>(on_tools) : std::function<void(QList<S::ToolCall> const&)>());
        };
        auto search = [this, weak, generation, entry, request, stream, search_key](QString const& query) {
            // Another provider: webby searches and hands it the results with the question.
            auto j = weak.lock();
            if (!j)
                return;
            entry->searching = query;
            entry->searches.append(query);
            job_changed(*j);
            j->chat = S::search_web(search_key, query, entry->question, [this, weak, generation, entry, request, stream, query](QList<S::SearchResult> const& results, QString const& error) {
                auto j = weak.lock();
                if (!j || j->generation != generation)
                    return;
                entry->searching.clear();
                if (!error.isEmpty())
                    entry->notice = error;
                else
                    *request = S::with_search_results(*request, query, S::search_results_text(results));
                QTimer::singleShot(0, this, [stream] { (*stream)(); });
            });
        };
        if (!search_key.isEmpty() && !tools) {
            // DeepSeek decides whether the question needs the web (and the query); a failed decision just answers.
            auto reply = std::make_shared<QString>();
            auto about = !entry->quote.isEmpty() ? entry->quote : job->asking ? job->selected : QString();
            job->chat = S::Chat::start(S::Provider::DeepSeek, search_key,
                S::search_decision_request(entry->question, about, job->title, job->url, job->text),
                [reply](QString const& piece) { *reply += piece; },
                [this, weak, generation, reply, explicit_search, entry, search, stream](QString const&) {
                    auto j = weak.lock();
                    if (!j || j->generation != generation)
                        return;
                    auto decision = S::parse_search_decision(*reply);
                    if (explicit_search && decision.query.isEmpty())
                        decision.query = S::search_terms_for(entry->question, entry->quote, j->selected, j->title);
                    QTimer::singleShot(0, this, [decision, explicit_search, search, stream] {
                        if ((decision.search || explicit_search) && !decision.query.isEmpty())
                            search(decision.query);
                        else
                            (*stream)();
                    });
                });
        } else {
            (*stream)();
        }
    };

    if (job->asking) {
        if (job->reading)
            job->after_read.push_back(send); // the page's text comes first, for context
        else
            send();
    } else if (!job->has_page && !job->selection && S::summary_key(from_std(job->view->url())) == S::summary_key(job->url)) {
        // A saved summary has no page text with it: read the page again while the tab still shows it.
        read_page_text(job->view, false, [weak, send](bool ok, S::PageText const& page) {
            if (auto j = weak.lock(); j && ok) {
                j->page = page;
                j->has_page = true;
            }
            send();
        });
    } else {
        send();
    }
}

static void close_job(SummaryJob& job)
{
    job.stop_chat();
    ++job.generation;
    if (job.answering()) {
        job.questions.last()->running = false;
        if (job.questions.last()->error.isEmpty())
            job.questions.last()->error = u"Stopped."_s;
    }
    job.open = false;
    job.running = false;
    job.start_after_key = false;
}

// Entry points.

void BrowserWindow::summarize_page()
{
    auto* tab = current();
    if (!tab || !tab->view || from_std(tab->view->url()).isEmpty())
        return;
    bool was_showing = panel_showing();
    auto job = job_for(tab->view.get());
    auto url = from_std(tab->view->url());
    // The saved page summary wins over a selection here; redo reads the page again and summarizes the selection.
    auto k = S::summary_key(url);
    S::Saved saved;
    ensure_panel();
    if (S::lookup(k, saved)) {
        job->stop_chat();
        job->has_page = false;
        show_saved(*job, k, saved);
    } else if (S::api_key().isEmpty()) {
        // The panel opens on its settings; the summary starts once a key is saved.
        job->stop_chat();
        ++job->generation;
        job->open = true;
        job->asking = false;
        job->running = false;
        job->error.clear();
        job->text.clear();
        job->questions.clear();
        job->saved_at = 0;
        job->title = tab->title;
        job->url = url;
        job->start_after_key = true;
        m_panel_open_settings = true;
    } else {
        start_summary(job, false);
    }
    if (!was_showing)
        relayout_panel();
    render_panel();
}

void BrowserWindow::toggle_summary()
{
    auto* job = panel_job();
    if (job && !job->asking) {
        close_summary();
        return;
    }
    summarize_page();
}

void BrowserWindow::close_summary()
{
    auto* job = panel_job();
    if (!job)
        return;
    close_job(*job);
    m_panel_focused = false;
    m_panel_has_mouse = false;
    relayout_panel();
}

void BrowserWindow::open_summarize_settings()
{
    auto* tab = current();
    if (!tab || !tab->view)
        return;
    auto job = job_for(tab->view.get());
    if (!job->open) {
        job->open = true;
        job->asking = false;
        job->running = false;
        job->title = tab->title;
        job->url = from_std(tab->view->url());
        relayout_panel();
    }
    ensure_panel();
    m_panel_open_settings = true;
    render_panel();
}

void BrowserWindow::ask_about_selection(WebbyUI::WebView* view, QString const& text)
{
    if (!view || text.isEmpty())
        return;
    bool was_showing = panel_showing();
    auto job = job_for(view);
    job->stop_chat();
    int generation = ++job->generation;
    job->asking = true;
    job->selected = text.left(8000);
    job->open = true;
    job->running = false;
    job->start_after_key = false;
    job->error.clear();
    job->text.clear();
    job->title = current() ? current()->title : QString();
    job->url = from_std(view->url());
    job->saved_at = 0;
    job->questions.clear();
    job->quote.clear();
    job->key.clear();
    job->selection = true;
    job->provider = S::chosen_provider();
    job->has_page = false;
    job->reading = true;
    job->after_read.clear();
    std::weak_ptr<SummaryJob> weak = job;
    read_page_text(view, true, [this, weak, generation](bool ok, S::PageText const& page) {
        auto j = weak.lock();
        if (!j || j->generation != generation)
            return;
        j->reading = false;
        if (ok) {
            j->page = page;
            j->has_page = true;
            if (!page.title.isEmpty())
                j->title = page.title;
        }
        auto waiting = std::move(j->after_read);
        j->after_read.clear();
        for (auto const& send : waiting)
            send();
        job_changed(*j);
    });
    ensure_panel();
    if (S::api_key().isEmpty())
        m_panel_open_settings = true;
    else
        m_panel_focus_entry = true;
    if (!was_showing)
        relayout_panel();
    render_panel();
}

// What the panel's page asks for.

void BrowserWindow::panel_message(QString const& text)
{
    auto m = QJsonDocument::fromJson(text.toUtf8()).object();
    auto op = m.value(u"op"_s).toString();
    auto* raw = panel_job();
    if (!raw)
        return;
    auto job = job_for(raw->view);
    if (op == u"close"_s) {
        close_summary();
    } else if (op == u"copy"_s) {
        QString copyable = job->asking ? QString() : S::without_source_links(job->text);
        if (job->asking) {
            for (auto i = job->questions.size() - 1; i >= 0 && copyable.isEmpty(); --i)
                copyable = job->questions[i]->answer.trimmed();
        }
        if (!copyable.isEmpty()) {
            qt2wasm::gui::setClipboardText(copyable);
            show_toast(u"Copied"_s);
        }
    } else if (op == u"redo"_s) {
        if (!job->running && !job->answering() && !S::api_key().isEmpty())
            start_summary(job, true);
    } else if (op == u"ask"_s) {
        ask_question(job, m.value(u"question"_s).toString());
    } else if (op == u"quote"_s) {
        auto quote = m.value(u"text"_s).toString().trimmed();
        job->quote = quote.left(max_quote);
        m_panel_focus_entry = true;
        job_changed(*job);
    } else if (op == u"unquote"_s) {
        job->quote.clear();
        job_changed(*job);
    } else if (op == u"jump"_s) {
        summary_jump(*job, m.value(u"words"_s).toString());
    } else if (op == u"open"_s) {
        auto url = m.value(u"url"_s).toString();
        if (url.startsWith(u"http://"_s) || url.startsWith(u"https://"_s))
            open_in_new_tab(url, true);
    } else if (op == u"settings"_s) {
        auto action = m.value(u"action"_s).toString();
        if (action == u"cancel"_s) {
            if (job->start_after_key && job->text.isEmpty() && !job->asking)
                close_summary();
            return;
        }
        auto p = S::provider_by_id(m.value(u"provider"_s).toString());
        auto const& name = S::info(p).key_secret;
        bool syncs = m.value(u"sync"_s).toBool(true);
        auto key = m.value(u"key"_s).toString().trimmed();
        if (action == u"save"_s) {
            // With a key saved, Save with the field empty just switches to the provider and changes whether it syncs.
            S::store_secret(name, key.isEmpty() ? S::secret(name) : key, syncs);
        } else {
            S::store_secret(name, {}, syncs);
        }
        // The choice travels with the key: a device that gets the key also switches to it.
        if (S::secret(S::provider_secret) != S::info(p).id || S::secret_syncs(S::provider_secret) != syncs)
            S::store_secret(S::provider_secret, S::info(p).id, syncs);
        if (action == u"save"_s && job->start_after_key && !S::api_key().isEmpty())
            start_summary(job, false);
        job_changed(*job);
    }
}

// Source links.

void BrowserWindow::run_summary_jump(WebbyUI::WebView* view, QString const& words, int retries, bool click)
{
    // In a PDF: the viewer finds the words and scrolls to them.
    for (auto& t : m_tabs) {
        if (t.view.get() == view && t.pdf) {
            t.pdf->find(words);
            return;
        }
    }
    // Tried again every half second (up to `retries` times) while a page that just loaded hasn't put the words on
    // screen yet. A page that already jumped to these words isn't scrolled again by the reruns after a load, but a
    // click always scrolls and highlights again.
    auto marker = QString::fromUtf8(QJsonDocument(QJsonArray { u"webby-jump:"_s + words }).toJson(QJsonDocument::Compact)).mid(1).chopped(1);
    auto script = S::jump_script(words).trimmed();
    while (!script.isEmpty() && (script.back() == u';' || script.back() == u'\n'))
        script.chop(1);
    view->run_javascript(to_std((click ? u"delete window.__webbyJump; "_s : QString())
        + u"(function retry(n) { if (window.__webbyJump === "_s + marker + u") return; if ("_s + script
        + u") window.__webbyJump = "_s + marker + u"; else if (n > 0) setTimeout(() => retry(n - 1), 500); })("_s
        + QString::number(retries) + u");"_s));
}

void BrowserWindow::summary_jump(SummaryJob& job, QString const& words)
{
    auto* view = job.view;
    if (S::summary_key(from_std(view->url())) == S::summary_key(job.url)) {
        run_summary_jump(view, words, 0, true);
        return;
    }
    // The tab's URL doesn't look like the summarized page's: the page itself decides (its location can be spelled
    // differently) and reports a miss as a "summaryjumpmiss" page message.
    auto json = [](QString const& s) { return QString::fromUtf8(QJsonDocument(QJsonArray { s }).toJson(QJsonDocument::Compact)).mid(1).chopped(1); };
    view->run_javascript(to_std(u"(() => { const norm = (u) => { try { u = new URL(u); u.hash = ''; return decodeURI(u.href).replace(/\\/+$/, ''); } catch (e) { return u; } }; if (norm(location.href) === norm("_s
        + json(job.url) + u")) { delete window.__webbyJump; "_s + S::jump_script(words)
        + u" return; } if (document.readyState !== 'loading') { const p = window.prompt, m = "_s + json(from_std(view->message_prefix()))
        + u" + JSON.stringify({ type: 'summaryjumpmiss', words: "_s + json(words) + u" }); setTimeout(() => { try { p.call(window, m); } catch (e) {} }, 0); } })();"_s));
}

void BrowserWindow::summary_jump_elsewhere(SummaryJob& job, QString const& words)
{
    // Another tab still showing the page comes forward and scrolls; otherwise the summary's tab goes back to the page
    // and scrolls once it has loaded.
    auto want = S::summary_key(job.url);
    for (int i = 0; i < int(m_tabs.size()); ++i) {
        auto& t = m_tabs[i];
        if (t.view.get() == job.view)
            continue;
        auto url = t.view ? from_std(t.view->url()) : t.url;
        if (S::summary_key(url) != want)
            continue;
        bool asleep = !t.view || t.loading;
        activate_tab(i);
        auto* view = m_tabs[i].view.get();
        if (!view)
            return;
        S::Saved saved;
        if (!panel_showing() && S::lookup(want, saved))
            summarize_page(); // keep the summary beside it
        if (asleep)
            m_pending_jump = { view, words };
        else
            run_summary_jump(view, words, 10, true);
        return;
    }
    m_pending_jump = { job.view, words };
    job.view->load(to_std(job.url));
}

// The vault's secrets and the Summaries sync blob are wired by Passwords.cpp and Sync.cpp.
