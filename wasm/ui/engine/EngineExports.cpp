/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The engine component's exports (wit/engine/engine.wit, world `engine`): webby:engine's views over WebbyUI::WebView
// (../WebView.cpp), so that the Qt UI can live in a component of its own (../shell) and be composed with this one.
// The callbacks WebView fires become events the UI takes with take-events.

#include "WebView.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "engine.h"

struct EventRecord {
    uint8_t tag;
    std::string text;
    bool flag { false };
    uint64_t id { 0 };
    WebbyUI::ContextMenu menu {};
    WebbyUI::Download download {};
    WebbyUI::PdfDocument pdf {};
};

struct exports_webby_engine_views_view_t {
    std::unique_ptr<WebbyUI::WebView> view;
    std::vector<EventRecord> events;
    bool painted { false };
};

using View = exports_webby_engine_views_view_t;
using Borrow = exports_webby_engine_views_borrow_view_t;

static std::string take_string(engine_string_t* s)
{
    std::string result(reinterpret_cast<char const*>(s->ptr), s->len);
    engine_string_free(s);
    return result;
}

static void give_string(engine_string_t* ret, std::string const& s)
{
    ret->len = s.size();
    ret->ptr = static_cast<uint8_t*>(malloc(s.size() ? s.size() : 1));
    memcpy(ret->ptr, s.data(), s.size());
}

exports_webby_engine_views_own_view_t exports_webby_engine_views_constructor_view(uint32_t width, uint32_t height)
{
    auto* record = new View;
    record->view = WebbyUI::WebView::create(int(width), int(height));
    auto& events = record->events;
    auto& view = *record->view;
    view.on_needs_paint = [&events] {
        // One is enough until the UI takes them.
        for (auto const& e : events) {
            if (e.tag == EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_NEEDS_PAINT)
                return;
        }
        events.push_back({ EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_NEEDS_PAINT, {} });
    };
    view.on_title_change = [&events](std::string const& t) { events.push_back({ EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_TITLE_CHANGED, t }); };
    view.on_url_change = [&events](std::string const& u) { events.push_back({ EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_URL_CHANGED, u }); };
    view.on_loading_change = [&events](bool l) { events.push_back({ EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_LOADING_CHANGED, {}, l }); };
    view.on_link_hover = [&events](std::string const& u) { events.push_back({ EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_LINK_HOVERED, u }); };
    view.on_clipboard_write = [&events](std::string const& t, bool selection) {
        events.push_back({ EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_CLIPBOARD_WRITTEN, t, selection });
    };
    view.on_clipboard_request = [&events](uint64_t id, bool selection) {
        events.push_back({ EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_CLIPBOARD_REQUESTED, {}, selection, id });
    };
    view.on_context_menu = [&events](WebbyUI::ContextMenu const& menu) {
        events.push_back({ EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_CONTEXT_MENU_REQUESTED, {}, false, 0, menu });
    };
    view.on_download = [&events](WebbyUI::Download const& d) {
        EventRecord e { EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_DOWNLOAD_FINISHED, {} };
        e.download = d;
        events.push_back(std::move(e));
    };
    view.on_pdf = [&events](WebbyUI::PdfDocument& pdf) {
        EventRecord e { EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_PDF_RECEIVED, {} };
        e.pdf = std::move(pdf);
        events.push_back(std::move(e));
    };
    return exports_webby_engine_views_view_new(record);
}

void exports_webby_engine_views_view_destructor(View* record) { delete record; }

void exports_webby_engine_views_method_view_load(Borrow self, engine_string_t* url) { self->view->load(take_string(url)); }
void exports_webby_engine_views_method_view_reload(Borrow self) { self->view->reload(); }
bool exports_webby_engine_views_method_view_can_go_back(Borrow self) { return self->view->can_go_back(); }
bool exports_webby_engine_views_method_view_can_go_forward(Borrow self) { return self->view->can_go_forward(); }
void exports_webby_engine_views_method_view_go_back(Borrow self) { self->view->go_back(); }
void exports_webby_engine_views_method_view_go_forward(Borrow self) { self->view->go_forward(); }
void exports_webby_engine_views_method_view_url(Borrow self, engine_string_t* ret) { give_string(ret, self->view->url()); }
void exports_webby_engine_views_method_view_title(Borrow self, engine_string_t* ret) { give_string(ret, self->view->title()); }
bool exports_webby_engine_views_method_view_is_loading(Borrow self) { return self->view->is_loading(); }
bool exports_webby_engine_views_method_view_needs_paint(Borrow self) { return self->view->needs_paint(); }

void exports_webby_engine_views_method_view_resize(Borrow self, uint32_t width, uint32_t height)
{
    self->view->resize(int(width), int(height));
}

bool exports_webby_engine_views_method_view_paint(Borrow self, engine_list_u8_t* ret)
{
    if (self->painted && !self->view->needs_paint())
        return false;
    auto const* pixels = self->view->paint();
    if (!pixels)
        return false;
    self->painted = true;
    size_t size = size_t(self->view->width()) * size_t(self->view->height()) * 4;
    // Freed by the bindings' post-return once the pixels are copied out.
    ret->ptr = static_cast<uint8_t*>(malloc(size));
    ret->len = size;
    memcpy(ret->ptr, pixels, size);
    return true;
}

void exports_webby_engine_views_method_view_mouse_down(Borrow self, int32_t x, int32_t y, uint8_t button, uint8_t held, uint8_t mods, uint32_t clicks)
{
    self->view->mouse_down(x, y, button, held, mods, int(clicks));
}

void exports_webby_engine_views_method_view_mouse_up(Borrow self, int32_t x, int32_t y, uint8_t button, uint8_t held, uint8_t mods)
{
    self->view->mouse_up(x, y, button, held, mods);
}

void exports_webby_engine_views_method_view_mouse_move(Borrow self, int32_t x, int32_t y, uint8_t held, uint8_t mods)
{
    self->view->mouse_move(x, y, held, mods);
}

void exports_webby_engine_views_method_view_mouse_leave(Borrow self) { self->view->mouse_leave(); }

void exports_webby_engine_views_method_view_wheel(Borrow self, int32_t x, int32_t y, double dx, double dy, uint8_t mods)
{
    self->view->wheel(x, y, dx, dy, mods);
}

void exports_webby_engine_views_method_view_key_down(Borrow self, uint32_t key, uint8_t mods, uint32_t code_point, bool repeat)
{
    self->view->key_down(key, mods, code_point, repeat);
}

void exports_webby_engine_views_method_view_key_up(Borrow self, uint32_t key, uint8_t mods, uint32_t code_point)
{
    self->view->key_up(key, mods, code_point);
}

void exports_webby_engine_views_method_view_take_events(Borrow self, exports_webby_engine_views_list_event_t* ret)
{
    auto events = std::move(self->events);
    self->events.clear();
    ret->len = events.size();
    ret->ptr = static_cast<exports_webby_engine_views_event_t*>(calloc(events.size() ? events.size() : 1, sizeof(*ret->ptr)));
    for (size_t i = 0; i < events.size(); ++i) {
        auto& out = ret->ptr[i];
        out.tag = events[i].tag;
        switch (events[i].tag) {
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_TITLE_CHANGED:
            give_string(&out.val.title_changed, events[i].text);
            break;
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_URL_CHANGED:
            give_string(&out.val.url_changed, events[i].text);
            break;
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_LINK_HOVERED:
            give_string(&out.val.link_hovered, events[i].text);
            break;
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_LOADING_CHANGED:
            out.val.loading_changed = events[i].flag;
            break;
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_CLIPBOARD_WRITTEN:
            give_string(&out.val.clipboard_written.text, events[i].text);
            out.val.clipboard_written.selection = events[i].flag;
            break;
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_CLIPBOARD_REQUESTED:
            out.val.clipboard_requested.id = events[i].id;
            out.val.clipboard_requested.selection = events[i].flag;
            break;
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_CONTEXT_MENU_REQUESTED: {
            auto const& m = events[i].menu;
            auto& o = out.val.context_menu_requested;
            o.x = m.x;
            o.y = m.y;
            give_string(&o.link, m.link);
            give_string(&o.link_text, m.link_text);
            give_string(&o.image, m.image);
            give_string(&o.selection, m.selection);
            o.editable = m.editable;
            break;
        }
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_DOWNLOAD_FINISHED: {
            auto const& d = events[i].download;
            auto& o = out.val.download_finished;
            give_string(&o.url, d.url);
            give_string(&o.path, d.path);
            o.size = d.size;
            give_string(&o.mime, d.mime);
            give_string(&o.error, d.error);
            break;
        }
        case EXPORTS_WEBBY_ENGINE_VIEWS_EVENT_PDF_RECEIVED: {
            auto const& d = events[i].pdf;
            auto& o = out.val.pdf_received;
            give_string(&o.url, d.url);
            give_string(&o.mime, d.mime);
            o.data.len = d.data.size();
            o.data.ptr = static_cast<uint8_t*>(malloc(d.data.size() ? d.data.size() : 1));
            memcpy(o.data.ptr, d.data.data(), d.data.size());
            break;
        }
        default:
            break;
        }
    }
}

void exports_webby_engine_views_method_view_answer_clipboard(Borrow self, uint64_t id, engine_string_t* text)
{
    self->view->answer_clipboard(id, take_string(text));
}

void exports_webby_engine_views_method_view_selected_text(Borrow self, engine_string_t* ret) { give_string(ret, self->view->selected_text()); }
void exports_webby_engine_views_method_view_select_all(Borrow self) { self->view->select_all(); }
void exports_webby_engine_views_method_view_cut_selection(Borrow self, engine_string_t* ret) { give_string(ret, self->view->cut_selection()); }
void exports_webby_engine_views_method_view_insert_text(Borrow self, engine_string_t* text) { self->view->insert_text(take_string(text)); }

static void give_find(exports_webby_engine_views_find_result_t* ret, WebbyUI::WebView::FindResult r)
{
    ret->index = r.index;
    ret->total = r.total;
}

void exports_webby_engine_views_method_view_find(Borrow self, engine_string_t* query, bool case_sensitive, exports_webby_engine_views_find_result_t* ret)
{
    give_find(ret, self->view->find(take_string(query), case_sensitive));
}
void exports_webby_engine_views_method_view_find_next(Borrow self, exports_webby_engine_views_find_result_t* ret) { give_find(ret, self->view->find_next()); }
void exports_webby_engine_views_method_view_find_previous(Borrow self, exports_webby_engine_views_find_result_t* ret) { give_find(ret, self->view->find_previous()); }
void exports_webby_engine_views_method_view_find_end(Borrow self) { self->view->find_end(); }
void exports_webby_engine_views_method_view_set_zoom(Borrow self, double level) { self->view->set_zoom(level); }

void exports_webby_engine_views_pump(void) { WebbyUI::WebView::pump(); }
