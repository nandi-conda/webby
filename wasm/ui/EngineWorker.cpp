/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The worker's side of EngineWorker.h: latha:proc/worker's run export serves the chrome's views.

#include "EngineWorker.h"
#include "EngineProtocol.h"
#include "EngineView.h"
#include "ProcChannel.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <memory>

#include "proc_guest.h"

namespace WebbyUI {

using namespace EngineProtocol;

namespace {

struct ServedView {
    uint32_t id { 0 };
    std::unique_ptr<EngineView> view;
    // Wants a paint (on_needs_paint, made visible).
    bool dirty { true };
    // A frame the chrome has not taken yet: no other one until it has (FrameDone).
    bool in_flight { false };
    // A paint whose frame was not sent (still render-blocked): the next frame's change is not relative to the last
    // sent one, so it goes as a whole frame.
    bool unsent_paint { false };
    // The last wheel event the engine took (its seq): frames say so, for the chrome's own scrolling.
    uint32_t wheel_seq { 0 };
    // The two buffers frames go through, mapped here; the chrome maps them too.
    uint8_t* buffers[2] { nullptr, nullptr };
    size_t buffer_size { 0 };
    int next_buffer { 0 };
    // Which frame each buffer holds (0: none), and what the last frames changed, so that a buffer two frames
    // behind needs only what changed since.
    uint64_t buffer_frame[2] { 0, 0 };
    uint64_t frame { 0 };
    std::map<uint64_t, PaintChange> changes;
    // What the chrome was last told (State).
    std::string url, title;
    bool loading { false }, can_go_back { false }, can_go_forward { false };
    bool state_sent { false };
};

class Server {
public:
    explicit Server(uint32_t channel)
        : m_channel(channel)
    {
    }

    int run()
    {
        for (;;) {
            Proc::Message message;
            // Everything that arrived, then the engine's due work, then frames.
            for (;;) {
                if (!m_deferred.empty()) {
                    message = std::move(m_deferred.front());
                    m_deferred.pop_front();
                } else {
                    auto r = Proc::receive(m_channel, 0, message);
                    if (r == Proc::Received::Closed)
                        return shutdown();
                    if (r == Proc::Received::Timeout)
                        break;
                }
                handle(message);
                if (m_quit)
                    return shutdown();
            }
            EngineView::pump();
            for (auto& [id, served] : m_views)
                send_frame(*served);
            Proc::wait(m_channel, EngineWorker::idle_wait_ms);
        }
    }

private:
    int shutdown()
    {
        // Each view's destructor writes localStorage out.
        m_views.clear();
        return 0;
    }

    void send(Writer& w, std::vector<uint32_t> const& handles = {})
    {
        Proc::send(m_channel, w.data(), handles);
    }

    ServedView* find(uint32_t id)
    {
        auto it = m_views.find(id);
        return it == m_views.end() ? nullptr : it->second.get();
    }

    // The chrome's copy of what the view says about itself, before any event that may read it.
    void send_state(ServedView& s)
    {
        auto& v = *s.view;
        if (s.state_sent && s.url == v.url() && s.title == v.title() && s.loading == v.is_loading()
            && s.can_go_back == v.can_go_back() && s.can_go_forward == v.can_go_forward())
            return;
        s.state_sent = true;
        s.url = v.url();
        s.title = v.title();
        s.loading = v.is_loading();
        s.can_go_back = v.can_go_back();
        s.can_go_forward = v.can_go_forward();
        Writer w { uint8_t(ToChrome::State) };
        w.u32(s.id).str(s.url).str(s.title).u8(s.loading).u8(s.can_go_back).u8(s.can_go_forward);
        send(w);
    }

    Writer event(ServedView& s, ToChrome kind)
    {
        send_state(s);
        Writer w { uint8_t(kind) };
        w.u32(s.id);
        return w;
    }

    void create(uint32_t id, int width, int height, std::string prefix)
    {
        auto view = EngineView::create(width, height);
        if (!view)
            return;
        auto served = std::make_unique<ServedView>();
        served->id = id;
        served->view = std::move(view);
        auto* s = served.get();
        auto& v = *s->view;
        v.set_message_prefix(std::move(prefix));
        v.on_needs_paint = [s] { s->dirty = true; };
        v.on_title_change = [this, s](std::string const& t) { auto w = event(*s, ToChrome::TitleChanged); w.str(t); send(w); };
        v.on_url_change = [this, s](std::string const& u) { auto w = event(*s, ToChrome::UrlChanged); w.str(u); send(w); };
        v.on_loading_change = [this, s](bool l) { auto w = event(*s, ToChrome::LoadingChanged); w.u8(l); send(w); };
        v.on_link_hover = [this, s](std::string const& u) { auto w = event(*s, ToChrome::LinkHovered); w.str(u); send(w); };
        v.on_clipboard_write = [this, s](std::string const& t, bool sel) { auto w = event(*s, ToChrome::ClipboardWrite); w.str(t).u8(sel); send(w); };
        v.on_clipboard_request = [this, s](uint64_t r, bool sel) { auto w = event(*s, ToChrome::ClipboardRequest); w.u64(r).u8(sel); send(w); };
        v.on_context_menu = [this, s](ContextMenu const& m) {
            auto w = event(*s, ToChrome::ContextMenu);
            w.s32(m.x).s32(m.y).str(m.link).str(m.link_text).str(m.image).str(m.selection).u8(m.editable);
            send(w);
        };
        v.on_download = [this, s](Download const& d) {
            auto w = event(*s, ToChrome::Download);
            w.str(d.url).str(d.path).u64(d.size).str(d.mime).str(d.error);
            send(w);
        };
        v.on_pdf = [this, s](PdfDocument& pdf) {
            auto w = event(*s, ToChrome::Pdf);
            w.str(pdf.url).str(pdf.mime);
            // A message holds at most 16 MiB: a bigger PDF goes in a memory object of its own.
            std::vector<uint32_t> handles;
            if (pdf.data.size() > (8u << 20)) {
                auto size = Proc::round_to_pages(pdf.data.size());
                auto memory = Proc::create_memory(size);
                uint8_t* p = memory ? Proc::map(*memory, size) : nullptr;
                if (p) {
                    memcpy(p, pdf.data.data(), pdf.data.size());
                    Proc::unmap(p, size);
                    w.u8(1).u64(pdf.data.size());
                    handles.push_back(*memory);
                } else {
                    w.u8(0).bytes(nullptr, 0);
                }
            } else {
                w.u8(0).bytes(pdf.data.data(), pdf.data.size());
            }
            send(w, handles);
        };
        v.on_navigation_request = [this, s](std::string const& u) {
            auto w = event(*s, ToChrome::NavigationRequest);
            w.str(u);
            send(w);
            return true; // the chrome loads it (Load) unless it takes it itself
        };
        v.on_page_message = [this, s](std::string const& text, std::string const& document_url) {
            auto w = event(*s, ToChrome::PageMessage);
            w.str(text).str(document_url);
            send(w);
        };
        v.on_webauthn_request = [this, s](uint64_t r, std::string const& json) {
            auto w = event(*s, ToChrome::WebAuthnRequest);
            w.u64(r).str(json);
            send(w);
        };
        v.page_scripts = [this, s] { return page_scripts(*s); };
        m_views[id] = std::move(served);
    }

    // Asks the chrome for its page scripts for the document about to be parsed, and waits for them; whatever else
    // arrives meanwhile waits its turn.
    std::vector<std::string> page_scripts(ServedView& s)
    {
        auto seq = m_next_seq++;
        send_state(s);
        Writer w { uint8_t(ToChrome::PageScriptsRequest) };
        w.u64(seq).u32(s.id).str(s.view->url());
        send(w);
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        for (;;) {
            auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
            if (left <= 0) {
                fprintf(stderr, "webby engine: the chrome did not send its page scripts in time\n");
                return {};
            }
            Proc::Message m;
            auto r = Proc::receive(m_channel, int(left), m);
            if (r == Proc::Received::Closed) {
                m_quit = true;
                return {};
            }
            if (r == Proc::Received::Timeout)
                continue;
            Reader in(m.data.data(), m.data.size());
            if (in.u8() == uint8_t(ToEngine::PageScripts) && in.u64() == seq) {
                std::vector<std::string> sources(in.u32());
                for (auto& source : sources)
                    source = in.str();
                return sources;
            }
            m_deferred.push_back(std::move(m));
        }
    }

    void reply(uint64_t seq, Writer& w)
    {
        send(w);
        (void)seq;
    }

    void handle(Proc::Message& m)
    {
        Reader in(m.data.data(), m.data.size());
        auto kind = ToEngine(in.u8());
        switch (kind) {
        case ToEngine::Hello:
            EngineView::set_color_scheme(in.u8());
            return;
        case ToEngine::SetColorScheme:
            EngineView::set_color_scheme(in.u8());
            return;
        case ToEngine::Create: {
            auto id = in.u32();
            int width = in.s32(), height = in.s32();
            auto prefix = in.str();
            create(id, width, height, std::move(prefix));
            return;
        }
        case ToEngine::Destroy: {
            auto id = in.u32();
            auto it = m_views.find(id);
            if (it == m_views.end())
                return;
            auto served = std::move(it->second);
            m_views.erase(it);
            for (auto*& p : served->buffers) {
                Proc::unmap(p, served->buffer_size);
                p = nullptr;
            }
            served.reset();
            // A request: the chrome waits when it closes its last view (the app may be quitting).
            if (in.u8()) {
                Writer w { uint8_t(ToChrome::Reply) };
                w.u64(in.u64());
                send(w);
            }
            return;
        }
        case ToEngine::PageScripts:
            return; // an answer that came too late
        default:
            break;
        }

        // Requests (seq first) and view messages.
        uint64_t seq = 0;
        bool request = kind >= ToEngine::SelectedText;
        if (request)
            seq = in.u64();
        auto* s = find(in.u32());
        if (!s) {
            if (request) {
                Writer w { uint8_t(ToChrome::Reply) };
                w.u64(seq);
                if (kind == ToEngine::SelectedText || kind == ToEngine::CutSelection)
                    w.str({});
                else
                    w.u32(0).s32(0);
                send(w);
            }
            return;
        }
        auto& v = *s->view;
        switch (kind) {
        case ToEngine::Load: v.load(in.str()); break;
        case ToEngine::Reload: v.reload(); break;
        case ToEngine::GoBack: v.go_back(); break;
        case ToEngine::GoForward: v.go_forward(); break;
        case ToEngine::SetVisible: {
            bool visible = in.u8();
            v.set_visible(visible);
            if (visible)
                s->dirty = true;
            break;
        }
        case ToEngine::Resize: {
            int width = in.s32(), height = in.s32();
            v.resize(width, height);
            break;
        }
        case ToEngine::MouseDown: {
            int x = in.s32(), y = in.s32();
            unsigned button = in.u32(), buttons = in.u32(), mods = in.u32();
            int clicks = in.s32();
            v.mouse_down(x, y, button, buttons, mods, clicks);
            break;
        }
        case ToEngine::MouseUp: {
            int x = in.s32(), y = in.s32();
            unsigned button = in.u32(), buttons = in.u32(), mods = in.u32();
            v.mouse_up(x, y, button, buttons, mods);
            break;
        }
        case ToEngine::MouseMove: {
            int x = in.s32(), y = in.s32();
            unsigned buttons = in.u32(), mods = in.u32();
            v.mouse_move(x, y, buttons, mods);
            break;
        }
        case ToEngine::MouseLeave: v.mouse_leave(); break;
        case ToEngine::Wheel: {
            int x = in.s32(), y = in.s32();
            double dx = in.f64(), dy = in.f64();
            unsigned mods = in.u32();
            s->wheel_seq = in.u32();
            v.wheel(x, y, dx, dy, mods);
            break;
        }
        case ToEngine::KeyDown: {
            unsigned key = in.u32(), mods = in.u32();
            uint32_t cp = in.u32();
            bool repeat = in.u8();
            v.key_down(key, mods, cp, repeat);
            break;
        }
        case ToEngine::KeyUp: {
            unsigned key = in.u32(), mods = in.u32();
            uint32_t cp = in.u32();
            v.key_up(key, mods, cp);
            break;
        }
        case ToEngine::AnswerClipboard: {
            auto request_id = in.u64();
            v.answer_clipboard(request_id, in.str());
            break;
        }
        case ToEngine::RunJavaScript: v.run_javascript(in.str()); break;
        case ToEngine::SetZoom: v.set_zoom(in.f64()); break;
        case ToEngine::SelectAll: v.select_all(); break;
        case ToEngine::InsertText: v.insert_text(in.str()); break;
        case ToEngine::FindEnd: v.find_end(); break;
        case ToEngine::WebAuthnReply: {
            auto request_id = in.u64();
            v.webauthn_reply(request_id, in.str());
            break;
        }
        case ToEngine::WebAuthnRespond: {
            bool accepted = in.u8();
            v.webauthn_respond(accepted, in.s32());
            break;
        }
        case ToEngine::FrameDone: {
            s->in_flight = false;
            break;
        }
        case ToEngine::SelectedText:
        case ToEngine::CutSelection: {
            auto text = kind == ToEngine::SelectedText ? v.selected_text() : v.cut_selection();
            send_state(*s);
            Writer w { uint8_t(ToChrome::Reply) };
            w.u64(seq).str(text);
            send(w);
            break;
        }
        case ToEngine::Find:
        case ToEngine::FindNext:
        case ToEngine::FindPrevious: {
            FindResult r;
            if (kind == ToEngine::Find) {
                auto query = in.str();
                r = v.find(query, in.u8());
            } else {
                r = kind == ToEngine::FindNext ? v.find_next() : v.find_previous();
            }
            Writer w { uint8_t(ToChrome::Reply) };
            w.u64(seq).u32(r.index).s32(r.total);
            send(w);
            break;
        }
        default:
            break;
        }
        // Whatever the message changed (a load, history) before the chrome next asks.
        send_state(*s);
    }

    // Copies `rect` (x, y, w, h) of a width-wide frame from src to dst.
    static void copy_rect(uint8_t* dst, uint8_t const* src, int width, int height, std::array<int, 4> r)
    {
        int x0 = std::clamp(r[0], 0, width), y0 = std::clamp(r[1], 0, height);
        int x1 = std::clamp(r[0] + r[2], 0, width), y1 = std::clamp(r[1] + r[3], 0, height);
        if (x1 <= x0 || y1 <= y0)
            return;
        size_t stride = size_t(width) * 4;
        for (int y = y0; y < y1; ++y)
            memcpy(dst + y * stride + x0 * 4, src + y * stride + x0 * 4, size_t(x1 - x0) * 4);
    }

    void send_frame(ServedView& s)
    {
        auto& v = *s.view;
        // needs_paint() too: a frame painted while the document was render-blocked leaves it set without asking
        // again (the chrome's in-process view is polled for it the same way, BrowserWindow.cpp).
        if (!v.is_visible() || s.in_flight || (!s.dirty && !v.needs_paint()))
            return;
        s.dirty = false;
        auto const* pixels = v.paint();
        if (!pixels)
            return;
        // Still render-blocked (its style sheets loading): the last frame stays; the engine asks again.
        if (v.needs_paint() && !v.last_paint_change().known && s.frame > 0) {
            s.unsent_paint = true;
            return;
        }
        int width = v.width(), height = v.height();
        size_t bytes = size_t(width) * size_t(height) * 4;
        std::vector<uint32_t> handles;
        bool new_buffers = false;
        if (bytes > s.buffer_size) {
            auto size = Proc::round_to_pages(bytes + bytes / 4);
            uint32_t memories[2];
            uint8_t* mapped[2] { nullptr, nullptr };
            for (int i = 0; i < 2; ++i) {
                auto memory = Proc::create_memory(size);
                if (!memory)
                    return;
                memories[i] = *memory;
                mapped[i] = Proc::map(*memory, size);
                if (!mapped[i]) {
                    fprintf(stderr, "webby engine: mapping a %zu byte frame buffer failed\n", size);
                    return;
                }
            }
            for (int i = 0; i < 2; ++i) {
                Proc::unmap(s.buffers[i], s.buffer_size);
                s.buffers[i] = mapped[i];
                s.buffer_frame[i] = 0;
                handles.push_back(memories[i]);
            }
            s.buffer_size = size;
            s.next_buffer = 0;
            new_buffers = true;
        }
        auto change = v.last_paint_change();
        if (s.unsent_paint) {
            s.unsent_paint = false;
            change = {};
        }
        auto frame = ++s.frame;
        s.changes[frame] = change;
        while (!s.changes.empty() && s.changes.begin()->first + 2 < frame)
            s.changes.erase(s.changes.begin());
        int b = s.next_buffer;
        s.next_buffer ^= 1;
        auto* dst = s.buffers[b];
        // The buffer has frame - 2 when both changes since are known and moved nothing: only those rects.
        bool partial = false;
        if (s.buffer_frame[b] && s.buffer_frame[b] + 2 == frame && s.changes.count(frame - 1)) {
            auto const& previous = s.changes[frame - 1];
            if (previous.known && change.known && previous.moved == 0 && change.moved == 0) {
                partial = true;
                for (auto const& r : previous.rects)
                    copy_rect(dst, pixels, width, height, r);
                for (auto const& r : change.rects)
                    copy_rect(dst, pixels, width, height, r);
            }
        }
        if (!partial)
            memcpy(dst, pixels, bytes);
        s.buffer_frame[b] = frame;
        s.in_flight = true;
        if (getenv("WEBBY_ENGINE_DEBUG")) {
            uint64_t a = 0, d = 0;
            for (size_t i = 0; i < bytes; i += 4096) {
                a += pixels[i];
                d += dst[i];
            }
            fprintf(stderr, "webby engine: frame %llu %dx%d buffer %d partial %d sums %llu %llu\n", (unsigned long long)frame,
                width, height, b, int(partial), (unsigned long long)a, (unsigned long long)d);
        }

        send_state(s);
        Writer w { uint8_t(ToChrome::Frame) };
        w.u32(s.id).u32(b).s32(width).s32(height).u8(change.known).s32(change.moved);
        w.u32(uint32_t(change.rects.size()));
        for (auto const& r : change.rects)
            w.s32(r[0]).s32(r[1]).s32(r[2]).s32(r[3]);
        auto const& bars = v.scrollbars();
        w.u32(uint32_t(bars.size()));
        for (auto const& bar : bars) {
            w.u8(bar.vertical).u8(bar.expanded);
            for (int i = 0; i < 4; ++i)
                w.s32(bar.gutter[i]);
            for (int i = 0; i < 4; ++i)
                w.s32(bar.thumb[i]);
            w.u32(bar.thumb_color).u32(bar.track_color);
        }
        auto const& vs = v.viewport_scroll();
        w.u8(vs.known).s32(vs.y).s32(vs.max_y);
        for (int i = 0; i < 4; ++i)
            w.s32(vs.fixed[i]);
        w.u32(s.wheel_seq);
        w.u8(new_buffers);
        if (new_buffers)
            w.u64(s.buffer_size);
        send(w, handles);
    }

    uint32_t m_channel { 0 };
    std::map<uint32_t, std::unique_ptr<ServedView>> m_views;
    std::deque<Proc::Message> m_deferred;
    uint64_t m_next_seq { 1 };
    bool m_quit { false };
};

}

}

extern "C" int32_t exports_latha_proc_worker_run(proc_guest_list_string_t* args)
{
    proc_guest_list_string_free(args);
    auto channel = WebbyUI::Proc::parent();
    if (!channel) {
        fprintf(stderr, "webby engine: started without a parent channel\n");
        return 1;
    }
    WebbyUI::Server server(*channel);
    return server.run();
}
