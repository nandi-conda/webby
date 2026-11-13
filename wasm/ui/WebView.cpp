/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// WebView in webby.wasm: the chrome's side of a page. When the host runs workers (EngineWorker.h), the page is an
// EngineView in the engine worker and this talks to it over the worker's channel (EngineProtocol.h); otherwise (an
// older latha-gui, or WEBBY_ENGINE_WORKER=0) the EngineView is right here and this only passes calls through.

#include "WebView.h"
#include "EngineProtocol.h"
#include "EngineView.h"
#include "ProcChannel.h"
#include "WebAuthn.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <optional>
#include <random>

#include <QAbstractEventDispatcher>
#include <QCoreApplication>

namespace WebbyUI {

using namespace EngineProtocol;

namespace {

std::vector<WebView::PageScriptHook>& page_script_hooks()
{
    static std::vector<WebView::PageScriptHook> hooks;
    return hooks;
}

bool s_prefers_dark = false;

// The engine worker, once started.
struct Worker {
    uint32_t channel { 0 };
    uint32_t pid { 0 };
    bool alive { true };
    uint64_t next_seq { 1 };
    uint32_t next_view { 1 };
    std::map<uint32_t, WebView*> views;
    // Messages that came while a request waited for its reply: delivered at the next pump.
    std::deque<Proc::Message> deferred;
};

Worker* s_worker;
bool s_tried_worker;
void deliver_now();

Worker* worker()
{
    if (!s_tried_worker) {
        s_tried_worker = true;
        auto const* env = getenv("WEBBY_ENGINE_WORKER");
        bool wanted = !env || strcmp(env, "0") != 0;
        if (wanted && Proc::workers_available()) {
            uint32_t pid = 0, channel = 0;
            std::string error;
            if (Proc::spawn_worker({ "webby-engine" }, pid, channel, error)) {
                s_worker = new Worker;
                s_worker->channel = channel;
                s_worker->pid = pid;
                Writer w { uint8_t(ToEngine::Hello) };
                w.u8(s_prefers_dark);
                Proc::send(channel, w.data());
                // The chrome's own requests (sync, Summarize) still go through a RequestServer of its own.
                EngineView::initialize_for_chrome();
                // What the worker sends wakes the host's loop (latha:proc rings the app), which calls into the app:
                // take it then, not at the chrome's next pump.
                if (auto* dispatcher = QAbstractEventDispatcher::instance())
                    QObject::connect(dispatcher, &QAbstractEventDispatcher::awake, dispatcher, [] { deliver_now(); });
                fprintf(stderr, "webby: the engine runs in worker %u\n", pid);
            } else {
                fprintf(stderr, "webby: the engine worker did not start (%s): the engine runs here\n", error.c_str());
            }
        }
    }
    return s_worker && s_worker->alive ? s_worker : nullptr;
}

std::string random_prefix()
{
    // As the Nim front end's randomPrefix: page scripts cannot guess another view's.
    static constexpr char chars[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    std::random_device rd;
    std::string prefix = "webby-msg-";
    for (int i = 0; i < 16; ++i)
        prefix += chars[rd() % (sizeof(chars) - 1)];
    prefix += ':';
    return prefix;
}

}

struct WebView::Impl {
    // In this instance:
    std::unique_ptr<EngineView> local;
    // In the worker:
    uint32_t id { 0 };
    int requested_width { 0 };
    int requested_height { 0 };
    bool can_go_back { false };
    bool can_go_forward { false };
    struct Buffer {
        uint8_t* pixels { nullptr };
    };
    Buffer buffers[2];
    size_t buffer_size { 0 };
    int shown { -1 }; // the buffer paint() last returned
    struct Frame {
        int buffer { 0 };
        int width { 0 };
        int height { 0 };
        PaintChange change;
        std::vector<Scrollbar> scrollbars;
    };
    std::optional<Frame> pending;
    WebAuthnFlow webauthn;
};

struct WebViewAccess {
    static void send(WebView& v, Writer& w)
    {
        if (auto* wk = worker())
            Proc::send(wk->channel, w.data());
        (void)v;
    }

    static Writer to(WebView& v, ToEngine kind)
    {
        Writer w { uint8_t(kind) };
        w.u32(v.m_impl->id);
        return w;
    }

    static std::vector<std::string> page_scripts(WebView& v)
    {
        std::vector<std::string> sources;
        for (auto& hook : page_script_hooks())
            sources.push_back(hook(v));
        return sources;
    }

    static void answer_page_scripts(Worker& wk, Reader& in)
    {
        auto seq = in.u64();
        auto id = in.u32();
        auto url = in.str();
        std::vector<std::string> sources;
        if (auto it = wk.views.find(id); it != wk.views.end()) {
            it->second->m_url = url;
            sources = page_scripts(*it->second);
        }
        Writer w { uint8_t(ToEngine::PageScripts) };
        w.u64(seq).u32(uint32_t(sources.size()));
        for (auto const& s : sources)
            w.str(s);
        Proc::send(wk.channel, w.data());
    }

    // Sends a request and waits for its reply (at most a few seconds: the worker may be busy in a page's script).
    // Page script requests are answered meanwhile (the worker may be waiting for one); anything else waits.
    static std::optional<Proc::Message> request(Writer& w, uint64_t seq)
    {
        auto* wk = worker();
        if (!wk)
            return {};
        Proc::send(wk->channel, w.data());
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        for (;;) {
            auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
            if (left <= 0) {
                fprintf(stderr, "webby: the engine did not answer in time\n");
                return {};
            }
            Proc::Message m;
            auto r = Proc::receive(wk->channel, int(left), m);
            if (r == Proc::Received::Closed) {
                died(*wk);
                return {};
            }
            if (r == Proc::Received::Timeout)
                continue;
            Reader in(m.data.data(), m.data.size());
            auto kind = ToChrome(in.u8());
            if (kind == ToChrome::Reply && in.u64() == seq)
                return m;
            if (kind == ToChrome::PageScriptsRequest) {
                answer_page_scripts(*wk, in);
                continue;
            }
            wk->deferred.push_back(std::move(m));
        }
    }

    static void died(Worker& wk)
    {
        if (!wk.alive)
            return;
        wk.alive = false;
        fprintf(stderr, "webby: the engine worker %u ended\n", wk.pid);
    }

    static FindResult find_reply(std::optional<Proc::Message> const& m)
    {
        if (!m)
            return {};
        Reader in(m->data.data(), m->data.size());
        in.u8();
        in.u64();
        FindResult r;
        r.index = in.u32();
        r.total = in.s32();
        return r;
    }

    static std::string text_reply(std::optional<Proc::Message> const& m)
    {
        if (!m)
            return {};
        Reader in(m->data.data(), m->data.size());
        in.u8();
        in.u64();
        return in.str();
    }

    static void deliver(Worker& wk, Proc::Message& m)
    {
        Reader in(m.data.data(), m.data.size());
        auto kind = ToChrome(in.u8());
        if (kind == ToChrome::PageScriptsRequest) {
            answer_page_scripts(wk, in);
            return;
        }
        if (kind == ToChrome::Reply)
            return; // a request that gave up waiting
        auto it = wk.views.find(in.u32());
        if (it == wk.views.end()) {
            for (auto h : m.handles)
                Proc::close(h);
            return;
        }
        auto& v = *it->second;
        auto& impl = *v.m_impl;
        switch (kind) {
        case ToChrome::State:
            v.m_url = in.str();
            v.m_title = in.str();
            v.m_loading = in.u8();
            impl.can_go_back = in.u8();
            impl.can_go_forward = in.u8();
            break;
        case ToChrome::TitleChanged:
            v.m_title = in.str();
            if (v.on_title_change)
                v.on_title_change(v.m_title);
            break;
        case ToChrome::UrlChanged: {
            v.m_url = in.str();
            auto url = v.m_url;
            if (v.on_url_change)
                v.on_url_change(url);
            break;
        }
        case ToChrome::LoadingChanged:
            v.m_loading = in.u8();
            if (v.on_loading_change)
                v.on_loading_change(v.m_loading);
            break;
        case ToChrome::LinkHovered: {
            auto url = in.str();
            if (v.on_link_hover)
                v.on_link_hover(url);
            break;
        }
        case ToChrome::ClipboardWrite: {
            auto text = in.str();
            bool selection = in.u8();
            if (v.on_clipboard_write)
                v.on_clipboard_write(text, selection);
            break;
        }
        case ToChrome::ClipboardRequest: {
            auto request_id = in.u64();
            bool selection = in.u8();
            if (v.on_clipboard_request)
                v.on_clipboard_request(request_id, selection);
            else
                v.answer_clipboard(request_id, {});
            break;
        }
        case ToChrome::ContextMenu: {
            ContextMenu menu;
            menu.x = in.s32();
            menu.y = in.s32();
            menu.link = in.str();
            menu.link_text = in.str();
            menu.image = in.str();
            menu.selection = in.str();
            menu.editable = in.u8();
            if (v.on_context_menu)
                v.on_context_menu(menu);
            break;
        }
        case ToChrome::Download: {
            Download d;
            d.url = in.str();
            d.path = in.str();
            d.size = in.u64();
            d.mime = in.str();
            d.error = in.str();
            if (v.on_download)
                v.on_download(d);
            break;
        }
        case ToChrome::Pdf: {
            PdfDocument pdf;
            pdf.url = in.str();
            pdf.mime = in.str();
            if (in.u8()) {
                auto length = in.u64();
                if (!m.handles.empty()) {
                    auto size = Proc::round_to_pages(length);
                    if (auto* p = Proc::map(m.handles[0], size)) {
                        pdf.data.assign(p, p + length);
                        Proc::unmap(p, size);
                    }
                    Proc::close(m.handles[0]);
                }
            } else {
                pdf.data = in.bytes();
            }
            if (v.on_pdf)
                v.on_pdf(pdf);
            break;
        }
        case ToChrome::PageMessage: {
            auto text = in.str();
            auto document_url = in.str();
            if (v.on_page_message)
                v.on_page_message(text, document_url);
            break;
        }
        case ToChrome::NavigationRequest: {
            auto url = in.str();
            if (v.on_navigation_request && v.on_navigation_request(url))
                break;
            v.load(url);
            break;
        }
        case ToChrome::WebAuthnRequest: {
            auto request_id = in.u64();
            auto json = in.str();
            v.did_request_webauthn(request_id, json);
            break;
        }
        case ToChrome::Frame: {
            WebView::Impl::Frame f;
            f.buffer = int(in.u32()) & 1;
            f.width = in.s32();
            f.height = in.s32();
            f.change.known = in.u8();
            f.change.moved = in.s32();
            f.change.rects.resize(in.u32());
            for (auto& r : f.change.rects)
                r = { in.s32(), in.s32(), in.s32(), in.s32() };
            f.scrollbars.resize(in.u32());
            for (auto& bar : f.scrollbars) {
                bar.vertical = in.u8();
                bar.expanded = in.u8();
                for (int i = 0; i < 4; ++i)
                    bar.gutter[i] = in.s32();
                for (int i = 0; i < 4; ++i)
                    bar.thumb[i] = in.s32();
                bar.thumb_color = in.u32();
                bar.track_color = in.u32();
            }
            if (in.u8()) {
                auto size = in.u64();
                for (auto& b : impl.buffers) {
                    Proc::unmap(b.pixels, impl.buffer_size);
                    b.pixels = nullptr;
                }
                impl.buffer_size = size;
                impl.shown = -1;
                for (size_t i = 0; i < 2 && i < m.handles.size(); ++i) {
                    impl.buffers[i].pixels = Proc::map(m.handles[i], size);
                    Proc::close(m.handles[i]);
                }
            }
            // A frame the buffers cannot hold (they failed to map) is dropped, and taken at once.
            if (!impl.buffers[f.buffer].pixels || size_t(f.width) * size_t(f.height) * 4 > impl.buffer_size) {
                auto w = to(v, ToEngine::FrameDone);
                w.u32(f.buffer);
                send(v, w);
                break;
            }
            impl.pending = std::move(f);
            v.m_needs_paint = true;
            if (v.on_needs_paint)
                v.on_needs_paint();
            break;
        }
        default:
            break;
        }
    }

    static void pump(Worker& wk)
    {
        // At most a few hundred at a time, so that input keeps coming through.
        for (int n = 0; n < 512; ++n) {
            Proc::Message m;
            if (!wk.deferred.empty()) {
                m = std::move(wk.deferred.front());
                wk.deferred.pop_front();
            } else {
                auto r = Proc::receive(wk.channel, 0, m);
                if (r == Proc::Received::Closed) {
                    died(wk);
                    return;
                }
                if (r == Proc::Received::Timeout)
                    return;
            }
            deliver(wk, m);
            if (!wk.alive)
                return;
        }
    }
};

namespace {

void deliver_now()
{
    static bool delivering;
    if (delivering || !s_worker || !s_worker->alive)
        return;
    delivering = true;
    WebViewAccess::pump(*s_worker);
    delivering = false;
}

}

std::unique_ptr<WebView> WebView::create(int width, int height)
{
    auto* wk = worker();
    if (!wk) {
        auto local = EngineView::create(width, height);
        if (!local)
            return nullptr;
        auto view = std::unique_ptr<WebView>(new WebView(width, height));
        auto* raw = view.get();
        auto& l = *local;
        view->m_impl->local = std::move(local);
        view->m_message_prefix = l.message_prefix();
        l.on_needs_paint = [raw] { raw->m_needs_paint = true; if (raw->on_needs_paint) raw->on_needs_paint(); };
        l.on_title_change = [raw](std::string const& t) { if (raw->on_title_change) raw->on_title_change(t); };
        l.on_url_change = [raw](std::string const& u) { if (raw->on_url_change) raw->on_url_change(u); };
        l.on_loading_change = [raw](bool b) { if (raw->on_loading_change) raw->on_loading_change(b); };
        l.on_link_hover = [raw](std::string const& u) { if (raw->on_link_hover) raw->on_link_hover(u); };
        l.on_clipboard_write = [raw](std::string const& t, bool s) { if (raw->on_clipboard_write) raw->on_clipboard_write(t, s); };
        l.on_clipboard_request = [raw](uint64_t r, bool s) {
            if (raw->on_clipboard_request)
                raw->on_clipboard_request(r, s);
            else
                raw->answer_clipboard(r, {});
        };
        l.on_context_menu = [raw](ContextMenu const& m) { if (raw->on_context_menu) raw->on_context_menu(m); };
        l.on_download = [raw](Download const& d) { if (raw->on_download) raw->on_download(d); };
        l.on_pdf = [raw](PdfDocument& p) { if (raw->on_pdf) raw->on_pdf(p); };
        l.on_navigation_request = [raw](std::string const& u) { return raw->on_navigation_request && raw->on_navigation_request(u); };
        l.on_page_message = [raw](std::string const& t, std::string const& u) { if (raw->on_page_message) raw->on_page_message(t, u); };
        l.on_webauthn_request = [raw](uint64_t r, std::string const& json) { raw->did_request_webauthn(r, json); };
        l.page_scripts = [raw] { return WebViewAccess::page_scripts(*raw); };
        return view;
    }
    auto view = std::unique_ptr<WebView>(new WebView(width, height));
    auto& impl = *view->m_impl;
    impl.id = wk->next_view++;
    impl.requested_width = view->m_width;
    impl.requested_height = view->m_height;
    view->m_message_prefix = random_prefix();
    wk->views[impl.id] = view.get();
    Writer w { uint8_t(ToEngine::Create) };
    w.u32(impl.id).s32(view->m_width).s32(view->m_height).str(view->m_message_prefix);
    Proc::send(wk->channel, w.data());
    return view;
}

WebView::WebView(int width, int height)
    : m_impl(std::make_unique<Impl>())
    , m_width(std::max(width, 1))
    , m_height(std::max(height, 1))
{
    m_impl->webauthn.reply = [this](uint64_t id, std::string const& json) {
        if (m_impl->local) {
            m_impl->local->webauthn_reply(id, json);
            return;
        }
        auto w = WebViewAccess::to(*this, ToEngine::WebAuthnReply);
        w.u64(id).str(json);
        WebViewAccess::send(*this, w);
    };
    m_impl->webauthn.prompt = [this](std::string const& prompt) {
        if (on_webauthn_prompt)
            on_webauthn_prompt(prompt);
    };
}

WebView::~WebView()
{
    m_impl->webauthn.cancel();
    if (m_impl->local)
        return;
    for (auto& b : m_impl->buffers)
        Proc::unmap(b.pixels, m_impl->buffer_size);
    auto* wk = worker();
    if (!wk)
        return;
    wk->views.erase(m_impl->id);
    // The last view going may be the app quitting: wait until the worker has written localStorage out.
    bool last = wk->views.empty();
    auto w = WebViewAccess::to(*this, ToEngine::Destroy);
    if (!last) {
        w.u8(0);
        Proc::send(wk->channel, w.data());
        return;
    }
    auto seq = wk->next_seq++;
    w.u8(1).u64(seq);
    // Not a regular request (its reply has no view): wait for it by hand.
    Proc::send(wk->channel, w.data());
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    for (;;) {
        auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
        if (left <= 0)
            return;
        Proc::Message m;
        auto r = Proc::receive(wk->channel, int(left), m);
        if (r == Proc::Received::Closed)
            return;
        if (r == Proc::Received::Timeout)
            continue;
        Reader in(m.data.data(), m.data.size());
        auto kind = ToChrome(in.u8());
        if (kind == ToChrome::Reply && in.u64() == seq)
            return;
        if (kind == ToChrome::PageScriptsRequest)
            WebViewAccess::answer_page_scripts(*wk, in);
        else
            wk->deferred.push_back(std::move(m));
    }
}

void WebView::pump()
{
    EngineView::pump();
    if (worker())
        deliver_now();
}

void WebView::set_color_scheme(bool dark)
{
    s_prefers_dark = dark;
    if (s_worker && s_worker->alive) {
        Writer w { uint8_t(ToEngine::SetColorScheme) };
        w.u8(dark);
        Proc::send(s_worker->channel, w.data());
        return;
    }
    EngineView::set_color_scheme(dark);
}

#define LOCAL_OR_SEND(call, kind)                     \
    do {                                               \
        if (m_impl->local) {                           \
            m_impl->local->call;                       \
            return;                                    \
        }                                              \
        auto w = WebViewAccess::to(*this, kind);       \
        WebViewAccess::send(*this, w);                 \
    } while (0)

void WebView::load(std::string const& url)
{
    if (m_impl->local)
        return m_impl->local->load(url);
    auto w = WebViewAccess::to(*this, ToEngine::Load);
    w.str(url);
    WebViewAccess::send(*this, w);
}

void WebView::reload() { LOCAL_OR_SEND(reload(), ToEngine::Reload); }
void WebView::go_back() { LOCAL_OR_SEND(go_back(), ToEngine::GoBack); }
void WebView::go_forward() { LOCAL_OR_SEND(go_forward(), ToEngine::GoForward); }
void WebView::mouse_leave() { LOCAL_OR_SEND(mouse_leave(), ToEngine::MouseLeave); }
void WebView::select_all() { LOCAL_OR_SEND(select_all(), ToEngine::SelectAll); }
void WebView::find_end() { LOCAL_OR_SEND(find_end(), ToEngine::FindEnd); }

std::string const& WebView::url() const { return m_impl->local ? m_impl->local->url() : m_url; }
std::string const& WebView::title() const { return m_impl->local ? m_impl->local->title() : m_title; }
bool WebView::is_loading() const { return m_impl->local ? m_impl->local->is_loading() : m_loading; }
bool WebView::needs_paint() const { return m_impl->local ? m_impl->local->needs_paint() : m_needs_paint; }

bool WebView::can_go_back() const
{
    return m_impl->local ? m_impl->local->can_go_back() : m_impl->can_go_back;
}

bool WebView::can_go_forward() const
{
    return m_impl->local ? m_impl->local->can_go_forward() : m_impl->can_go_forward;
}

void WebView::set_visible(bool visible)
{
    m_visible = visible;
    if (m_impl->local)
        return m_impl->local->set_visible(visible);
    auto w = WebViewAccess::to(*this, ToEngine::SetVisible);
    w.u8(visible);
    WebViewAccess::send(*this, w);
}

void WebView::resize(int width, int height)
{
    width = std::max(width, 1);
    height = std::max(height, 1);
    if (m_impl->local) {
        m_impl->local->resize(width, height);
        m_width = width;
        m_height = height;
        return;
    }
    if (width == m_impl->requested_width && height == m_impl->requested_height)
        return;
    m_impl->requested_width = width;
    m_impl->requested_height = height;
    // Until a frame of the new size comes, width() and height() stay those of the frame paint() returns.
    if (m_impl->shown < 0 && !m_impl->pending) {
        m_width = width;
        m_height = height;
    }
    auto w = WebViewAccess::to(*this, ToEngine::Resize);
    w.s32(width).s32(height);
    WebViewAccess::send(*this, w);
}

uint8_t const* WebView::paint()
{
    auto& impl = *m_impl;
    if (impl.local) {
        auto const* pixels = impl.local->paint();
        m_width = impl.local->width();
        m_height = impl.local->height();
        m_last_change = impl.local->last_paint_change();
        m_scrollbars = impl.local->scrollbars();
        m_needs_paint = impl.local->needs_paint();
        return pixels;
    }
    m_needs_paint = false;
    if (!impl.pending) {
        m_last_change = { .known = true, .moved = 0, .rects = {} };
        return impl.shown >= 0 ? impl.buffers[impl.shown].pixels : nullptr;
    }
    auto frame = std::move(*impl.pending);
    impl.pending.reset();
    impl.shown = frame.buffer;
    m_width = frame.width;
    m_height = frame.height;
    m_last_change = std::move(frame.change);
    m_scrollbars = std::move(frame.scrollbars);
    // The other buffer is free for the engine's next frame.
    auto w = WebViewAccess::to(*this, ToEngine::FrameDone);
    w.u32(uint32_t(frame.buffer));
    WebViewAccess::send(*this, w);
    return impl.buffers[impl.shown].pixels;
}

void WebView::mouse_down(int x, int y, unsigned button, unsigned buttons, unsigned modifiers, int clicks)
{
    if (m_impl->local)
        return m_impl->local->mouse_down(x, y, button, buttons, modifiers, clicks);
    auto w = WebViewAccess::to(*this, ToEngine::MouseDown);
    w.s32(x).s32(y).u32(button).u32(buttons).u32(modifiers).s32(clicks);
    WebViewAccess::send(*this, w);
}

void WebView::mouse_up(int x, int y, unsigned button, unsigned buttons, unsigned modifiers)
{
    if (m_impl->local)
        return m_impl->local->mouse_up(x, y, button, buttons, modifiers);
    auto w = WebViewAccess::to(*this, ToEngine::MouseUp);
    w.s32(x).s32(y).u32(button).u32(buttons).u32(modifiers);
    WebViewAccess::send(*this, w);
}

void WebView::mouse_move(int x, int y, unsigned buttons, unsigned modifiers)
{
    if (m_impl->local)
        return m_impl->local->mouse_move(x, y, buttons, modifiers);
    auto w = WebViewAccess::to(*this, ToEngine::MouseMove);
    w.s32(x).s32(y).u32(buttons).u32(modifiers);
    WebViewAccess::send(*this, w);
}

void WebView::wheel(int x, int y, double dx, double dy, unsigned modifiers)
{
    if (m_impl->local)
        return m_impl->local->wheel(x, y, dx, dy, modifiers);
    auto w = WebViewAccess::to(*this, ToEngine::Wheel);
    w.s32(x).s32(y).f64(dx).f64(dy).u32(modifiers);
    WebViewAccess::send(*this, w);
}

void WebView::key_down(unsigned key, unsigned modifiers, uint32_t code_point, bool repeat)
{
    if (m_impl->local)
        return m_impl->local->key_down(key, modifiers, code_point, repeat);
    auto w = WebViewAccess::to(*this, ToEngine::KeyDown);
    w.u32(key).u32(modifiers).u32(code_point).u8(repeat);
    WebViewAccess::send(*this, w);
}

void WebView::key_up(unsigned key, unsigned modifiers, uint32_t code_point)
{
    if (m_impl->local)
        return m_impl->local->key_up(key, modifiers, code_point);
    auto w = WebViewAccess::to(*this, ToEngine::KeyUp);
    w.u32(key).u32(modifiers).u32(code_point);
    WebViewAccess::send(*this, w);
}

void WebView::answer_clipboard(uint64_t request, std::string const& text)
{
    if (m_impl->local)
        return m_impl->local->answer_clipboard(request, text);
    auto w = WebViewAccess::to(*this, ToEngine::AnswerClipboard);
    w.u64(request).str(text);
    WebViewAccess::send(*this, w);
}

void WebView::add_page_script(PageScriptHook hook)
{
    page_script_hooks().push_back(std::move(hook));
}

void WebView::run_javascript(std::string const& source)
{
    if (m_impl->local)
        return m_impl->local->run_javascript(source);
    auto w = WebViewAccess::to(*this, ToEngine::RunJavaScript);
    w.str(source);
    WebViewAccess::send(*this, w);
}

void WebView::did_request_webauthn(uint64_t request_id, std::string request)
{
    m_impl->webauthn.request(request_id, request, bool(on_webauthn_prompt));
}

void WebView::webauthn_respond(bool accepted, int account_index)
{
    m_impl->webauthn.respond(accepted, account_index);
}

static uint64_t next_seq()
{
    auto* wk = worker();
    return wk ? wk->next_seq++ : 0;
}

std::string WebView::selected_text() const
{
    if (m_impl->local)
        return m_impl->local->selected_text();
    auto seq = next_seq();
    Writer w { uint8_t(ToEngine::SelectedText) };
    w.u64(seq).u32(m_impl->id);
    return WebViewAccess::text_reply(WebViewAccess::request(w, seq));
}

std::string WebView::cut_selection()
{
    if (m_impl->local)
        return m_impl->local->cut_selection();
    auto seq = next_seq();
    Writer w { uint8_t(ToEngine::CutSelection) };
    w.u64(seq).u32(m_impl->id);
    return WebViewAccess::text_reply(WebViewAccess::request(w, seq));
}

void WebView::insert_text(std::string const& text)
{
    if (m_impl->local)
        return m_impl->local->insert_text(text);
    auto w = WebViewAccess::to(*this, ToEngine::InsertText);
    w.str(text);
    WebViewAccess::send(*this, w);
}

void WebView::set_zoom(double zoom)
{
    if (m_impl->local) {
        m_impl->local->set_zoom(zoom);
        m_zoom = m_impl->local->zoom();
        return;
    }
    m_zoom = std::clamp(zoom, 0.25, 5.0);
    auto w = WebViewAccess::to(*this, ToEngine::SetZoom);
    w.f64(zoom);
    WebViewAccess::send(*this, w);
}

WebView::FindResult WebView::find(std::string const& query, bool case_sensitive)
{
    if (m_impl->local)
        return m_impl->local->find(query, case_sensitive);
    auto seq = next_seq();
    Writer w { uint8_t(ToEngine::Find) };
    w.u64(seq).u32(m_impl->id).str(query).u8(case_sensitive);
    return WebViewAccess::find_reply(WebViewAccess::request(w, seq));
}

WebView::FindResult WebView::find_next()
{
    if (m_impl->local)
        return m_impl->local->find_next();
    auto seq = next_seq();
    Writer w { uint8_t(ToEngine::FindNext) };
    w.u64(seq).u32(m_impl->id);
    return WebViewAccess::find_reply(WebViewAccess::request(w, seq));
}

WebView::FindResult WebView::find_previous()
{
    if (m_impl->local)
        return m_impl->local->find_previous();
    auto seq = next_seq();
    Writer w { uint8_t(ToEngine::FindPrevious) };
    w.u64(seq).u32(m_impl->id);
    return WebViewAccess::find_reply(WebViewAccess::request(w, seq));
}

}
