/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// WebbyUI::WebView (../WebView.h) for the UI component: every call goes to the engine component's webby:engine views
// (../wit/engine/engine.wit), and the events the engine queued are taken after each call and turned back into the
// header's callbacks, so BrowserWindow works the same over either.

#include "WebView.h"

#include <algorithm>
#include <cstring>

#include "gui.h"

namespace WebbyUI {

struct WebView::Impl {
    webby_engine_views_own_view_t handle;
    // The last frame, as the bindings lifted it (kept, not copied again: a frame is megabytes).
    gui_list_u8_t pixels {};
    webby_engine_views_borrow_view_t borrow() const { return webby_engine_views_borrow_view(handle); }
    ~Impl() { gui_list_u8_free(&pixels); }
};

// Live views, for pump: the event loop's work can change any of them.
static std::vector<WebView*> s_views;

static gui_string_t borrow_string(std::string const& s)
{
    return gui_string_t { reinterpret_cast<uint8_t*>(const_cast<char*>(s.data())), s.size() };
}

std::unique_ptr<WebView> WebView::create(int width, int height)
{
    return std::unique_ptr<WebView>(new WebView(width, height));
}

WebView::WebView(int width, int height)
    : m_impl(std::make_unique<Impl>())
    , m_width(width)
    , m_height(height)
{
    m_impl->handle = webby_engine_views_constructor_view(uint32_t(width), uint32_t(height));
    s_views.push_back(this);
}

WebView::~WebView()
{
    std::erase(s_views, this);
    webby_engine_views_view_drop_own(m_impl->handle);
}

std::string const& WebView::url() const { return m_url; }
std::string const& WebView::title() const { return m_title; }
bool WebView::is_loading() const { return m_loading; }
bool WebView::needs_paint() const { return m_needs_paint; }

void WebView::pump()
{
    webby_engine_views_pump();
    // A callback may close a tab (and so drop its view): walk a copy.
    auto views = s_views;
    for (auto* view : views) {
        if (std::find(s_views.begin(), s_views.end(), view) != s_views.end())
            view->deliver_engine_events();
    }
}

void WebView::set_color_scheme(bool dark)
{
    webby_engine_views_set_color_scheme(dark);
}

void WebView::load(std::string const& url)
{
    auto s = borrow_string(url);
    webby_engine_views_method_view_load(m_impl->borrow(), &s);
    deliver_engine_events();
}

void WebView::reload()
{
    webby_engine_views_method_view_reload(m_impl->borrow());
    deliver_engine_events();
}

bool WebView::can_go_back() const { return webby_engine_views_method_view_can_go_back(m_impl->borrow()); }
bool WebView::can_go_forward() const { return webby_engine_views_method_view_can_go_forward(m_impl->borrow()); }

void WebView::go_back()
{
    webby_engine_views_method_view_go_back(m_impl->borrow());
    deliver_engine_events();
}

void WebView::go_forward()
{
    webby_engine_views_method_view_go_forward(m_impl->borrow());
    deliver_engine_events();
}

// The engine's WIT has no visibility call yet, so a background tab of the split build keeps rendering.
void WebView::set_visible(bool visible)
{
    if (m_visible == visible)
        return;
    m_visible = visible;
    if (visible)
        m_needs_paint = true;
}

void WebView::resize(int width, int height)
{
    m_width = width;
    m_height = height;
    webby_engine_views_method_view_resize(m_impl->borrow(), uint32_t(width), uint32_t(height));
    m_needs_paint = true;
    deliver_engine_events();
}

uint8_t const* WebView::paint()
{
    gui_list_u8_t list {};
    if (webby_engine_views_method_view_paint(m_impl->borrow(), &list)) {
        gui_list_u8_free(&m_impl->pixels);
        m_impl->pixels = list;
    }
    m_needs_paint = false;
    deliver_engine_events();
    // The engine draws width x height; until it has, there is nothing to show.
    if (m_impl->pixels.len != size_t(m_width) * size_t(m_height) * 4)
        return nullptr;
    return m_impl->pixels.ptr;
}

void WebView::mouse_down(int x, int y, unsigned button, unsigned buttons, unsigned modifiers, int clicks)
{
    webby_engine_views_method_view_mouse_down(m_impl->borrow(), x, y, uint8_t(button), uint8_t(buttons), uint8_t(modifiers), uint32_t(clicks));
    deliver_engine_events();
}

void WebView::mouse_up(int x, int y, unsigned button, unsigned buttons, unsigned modifiers)
{
    webby_engine_views_method_view_mouse_up(m_impl->borrow(), x, y, uint8_t(button), uint8_t(buttons), uint8_t(modifiers));
    deliver_engine_events();
}

void WebView::mouse_move(int x, int y, unsigned buttons, unsigned modifiers)
{
    webby_engine_views_method_view_mouse_move(m_impl->borrow(), x, y, uint8_t(buttons), uint8_t(modifiers));
    deliver_engine_events();
}

void WebView::mouse_leave()
{
    webby_engine_views_method_view_mouse_leave(m_impl->borrow());
    deliver_engine_events();
}

void WebView::wheel(int x, int y, double dx, double dy, unsigned modifiers)
{
    webby_engine_views_method_view_wheel(m_impl->borrow(), x, y, dx, dy, uint8_t(modifiers));
    deliver_engine_events();
}

void WebView::key_down(unsigned key, unsigned modifiers, uint32_t code_point, bool repeat)
{
    webby_engine_views_method_view_key_down(m_impl->borrow(), key, uint8_t(modifiers), code_point, repeat);
    deliver_engine_events();
}

void WebView::key_up(unsigned key, unsigned modifiers, uint32_t code_point)
{
    webby_engine_views_method_view_key_up(m_impl->borrow(), key, uint8_t(modifiers), code_point);
    deliver_engine_events();
}

// The engine side of these runs in the engine component; the header declares them for WebView.cpp's page client.
void WebView::did_request_frame()
{
    m_needs_paint = true;
    if (on_needs_paint)
        on_needs_paint();
}

void WebView::did_change_title(std::string title)
{
    m_title = std::move(title);
    if (on_title_change)
        on_title_change(m_title);
}

void WebView::did_request_navigation(std::string url) { load(url); }

void WebView::did_finish_loading()
{
    m_loading = false;
    if (on_loading_change)
        on_loading_change(false);
}

void WebView::did_hover_link(std::string url)
{
    if (on_link_hover)
        on_link_hover(url);
}

void WebView::did_write_clipboard(std::string text, bool selection)
{
    if (on_clipboard_write)
        on_clipboard_write(text, selection);
}

void WebView::did_request_clipboard(uint64_t request, bool selection)
{
    if (on_clipboard_request)
        on_clipboard_request(request, selection);
    else
        answer_clipboard(request, {});
}

void WebView::answer_clipboard(uint64_t request, std::string const& text)
{
    auto s = borrow_string(text);
    webby_engine_views_method_view_answer_clipboard(m_impl->borrow(), request, &s);
    deliver_engine_events();
}

void WebView::did_download(Download download)
{
    if (on_download)
        on_download(download);
}

void WebView::did_receive_pdf(PdfDocument pdf)
{
    if (on_pdf)
        on_pdf(pdf);
}

void WebView::did_request_context_menu(ContextMenu menu)
{
    if (on_context_menu)
        on_context_menu(menu);
}

static std::string take_gui_string(gui_string_t& s)
{
    std::string result(reinterpret_cast<char const*>(s.ptr), s.len);
    gui_string_free(&s);
    return result;
}

WebView::FindResult WebView::find(std::string const& query, bool case_sensitive)
{
    auto s = borrow_string(query);
    webby_engine_views_find_result_t r {};
    webby_engine_views_method_view_find(m_impl->borrow(), &s, case_sensitive, &r);
    deliver_engine_events();
    return { r.index, r.total };
}

WebView::FindResult WebView::find_next()
{
    webby_engine_views_find_result_t r {};
    webby_engine_views_method_view_find_next(m_impl->borrow(), &r);
    deliver_engine_events();
    return { r.index, r.total };
}

WebView::FindResult WebView::find_previous()
{
    webby_engine_views_find_result_t r {};
    webby_engine_views_method_view_find_previous(m_impl->borrow(), &r);
    deliver_engine_events();
    return { r.index, r.total };
}

void WebView::find_end()
{
    webby_engine_views_method_view_find_end(m_impl->borrow());
    deliver_engine_events();
}

void WebView::set_zoom(double zoom)
{
    zoom = std::clamp(zoom, 0.25, 5.0);
    m_zoom = zoom;
    webby_engine_views_method_view_set_zoom(m_impl->borrow(), zoom);
    m_needs_paint = true;
    deliver_engine_events();
}

std::string WebView::selected_text() const
{
    gui_string_t s {};
    webby_engine_views_method_view_selected_text(m_impl->borrow(), &s);
    return take_gui_string(s);
}

void WebView::select_all()
{
    webby_engine_views_method_view_select_all(m_impl->borrow());
    deliver_engine_events();
}

std::string WebView::cut_selection()
{
    gui_string_t s {};
    webby_engine_views_method_view_cut_selection(m_impl->borrow(), &s);
    auto text = take_gui_string(s);
    deliver_engine_events();
    return text;
}

void WebView::insert_text(std::string const& text)
{
    auto s = borrow_string(text);
    webby_engine_views_method_view_insert_text(m_impl->borrow(), &s);
    deliver_engine_events();
}

// The engine's events since the last call, delivered as the callbacks would have been.
void WebView::deliver_engine_events()
{
    webby_engine_views_list_event_t events {};
    webby_engine_views_method_view_take_events(m_impl->borrow(), &events);
    // Strings out first, so the list can be freed before any callback runs (one may drop this view).
    struct Event {
        uint8_t tag;
        std::string text;
        bool flag;
        uint64_t id { 0 };
        ContextMenu menu {};
        Download download {};
        PdfDocument pdf {};
    };
    std::vector<Event> list;
    for (size_t i = 0; i < events.len; ++i) {
        auto& e = events.ptr[i];
        Event out { e.tag, {}, false };
        switch (e.tag) {
        case WEBBY_ENGINE_VIEWS_EVENT_TITLE_CHANGED:
            out.text.assign(reinterpret_cast<char const*>(e.val.title_changed.ptr), e.val.title_changed.len);
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_URL_CHANGED:
            out.text.assign(reinterpret_cast<char const*>(e.val.url_changed.ptr), e.val.url_changed.len);
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_LINK_HOVERED:
            out.text.assign(reinterpret_cast<char const*>(e.val.link_hovered.ptr), e.val.link_hovered.len);
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_LOADING_CHANGED:
            out.flag = e.val.loading_changed;
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_CLIPBOARD_WRITTEN:
            out.text.assign(reinterpret_cast<char const*>(e.val.clipboard_written.text.ptr), e.val.clipboard_written.text.len);
            out.flag = e.val.clipboard_written.selection;
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_CLIPBOARD_REQUESTED:
            out.id = e.val.clipboard_requested.id;
            out.flag = e.val.clipboard_requested.selection;
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_CONTEXT_MENU_REQUESTED: {
            auto const& m = e.val.context_menu_requested;
            auto str = [](gui_string_t const& s) { return std::string(reinterpret_cast<char const*>(s.ptr), s.len); };
            out.menu = { m.x, m.y, str(m.link), str(m.link_text), str(m.image), str(m.selection), m.editable };
            break;
        }
        case WEBBY_ENGINE_VIEWS_EVENT_DOWNLOAD_FINISHED: {
            auto const& d = e.val.download_finished;
            auto str = [](gui_string_t const& s) { return std::string(reinterpret_cast<char const*>(s.ptr), s.len); };
            out.download = { str(d.url), str(d.path), d.size, str(d.mime), str(d.error) };
            break;
        }
        case WEBBY_ENGINE_VIEWS_EVENT_PDF_RECEIVED: {
            auto const& d = e.val.pdf_received;
            auto str = [](gui_string_t const& s) { return std::string(reinterpret_cast<char const*>(s.ptr), s.len); };
            out.pdf.url = str(d.url);
            out.pdf.mime = str(d.mime);
            out.pdf.data.assign(d.data.ptr, d.data.ptr + d.data.len);
            break;
        }
        default:
            break;
        }
        list.push_back(std::move(out));
    }
    webby_engine_views_list_event_free(&events);
    for (auto& e : list) {
        switch (e.tag) {
        case WEBBY_ENGINE_VIEWS_EVENT_NEEDS_PAINT:
            did_request_frame();
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_TITLE_CHANGED:
            did_change_title(std::move(e.text));
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_URL_CHANGED:
            m_url = std::move(e.text);
            if (on_url_change)
                on_url_change(m_url);
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_LOADING_CHANGED:
            if (e.flag) {
                m_loading = true;
                if (on_loading_change)
                    on_loading_change(true);
            } else {
                did_finish_loading();
            }
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_LINK_HOVERED:
            did_hover_link(std::move(e.text));
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_CLIPBOARD_WRITTEN:
            did_write_clipboard(std::move(e.text), e.flag);
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_CLIPBOARD_REQUESTED:
            did_request_clipboard(e.id, e.flag);
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_CONTEXT_MENU_REQUESTED:
            did_request_context_menu(std::move(e.menu));
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_DOWNLOAD_FINISHED:
            did_download(std::move(e.download));
            break;
        case WEBBY_ENGINE_VIEWS_EVENT_PDF_RECEIVED:
            did_receive_pdf(std::move(e.pdf));
            break;
        }
    }
}

}
