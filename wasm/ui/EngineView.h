/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// EngineView: one page of Ladybird's LibWeb, hosted in this module, with no WebContent, Compositor or RequestServer
// process. The UI (Qt) side talks to it through this header only, which names no LibWeb or AK type, so Qt and
// Ladybird headers never meet in one file.
//
// A load parses the document right here (http(s) documents come from RequestServer, in this module: Network.h) and gives it a fresh Page (see EngineView.cpp), as webby-render does. A paint
// lays the page out, records its display list and rasterizes it on the CPU with the Compositor's Skia player.

#pragma once

#include "ViewTypes.h"

#include <array>
#include <vector>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace WebbyUI {

struct LoadedDocument;

class EngineView {
public:
    // The engine is set up the first time a view is made: LibWeb's JS VM, resource loader and fonts.
    static std::unique_ptr<EngineView> create(int width, int height);
    ~EngineView();

    // For the chrome when the pages run in the engine worker (EngineWorker.h): only the event loop and a RequestServer,
    // for the chrome's own requests (HttpClient.h). No view can be made in this instance after it.
    static void initialize_for_chrome();
    // Runs the engine's event loop until nothing is due right now (timers, tasks, deferred work). Never blocks.
    static void pump();
    // Pages' prefers-color-scheme for every view, now and later: the desktop's light or dark (BrowserWindow follows
    // it). Pages restyle at once.
    static void set_color_scheme(bool dark);

    void load(std::string const& url);
    void reload();
    bool can_go_back() const;
    bool can_go_forward() const;
    void go_back();
    void go_forward();

    std::string const& url() const { return m_url; }
    std::string const& title() const { return m_title; }
    bool is_loading() const { return m_loading; }

    // Whether the tab is in front. A hidden page's document is "hidden" (document.hidden, visibilitychange) and gets
    // no rendering updates: no style, layout, animations, intersection observers or requestAnimationFrame callbacks,
    // which in the background ate the one thread the UI and every tab share.
    void set_visible(bool visible);
    bool is_visible() const { return m_visible; }

    // The size of the page's viewport, in CSS pixels (device pixel ratio 1).
    void resize(int width, int height);
    int width() const { return m_width; }
    int height() const { return m_height; }

    // The page's pixels: premultiplied BGRA (Qt's ARGB32_Premultiplied on little endian), width() x height(), drawn
    // anew when the page changed since the last call. Null before the first load.
    uint8_t const* paint();
    bool needs_paint() const { return m_needs_paint; }
    using PaintChange = WebbyUI::PaintChange;
    PaintChange const& last_paint_change() const { return m_last_change; }
    using Scrollbar = WebbyUI::Scrollbar;
    std::vector<Scrollbar> const& scrollbars() const { return m_scrollbars; }

    // Input, in viewport coordinates. `button` is the one that changed, `buttons` those held after the event.
    void mouse_down(int x, int y, unsigned button, unsigned buttons, unsigned modifiers, int clicks);
    void mouse_up(int x, int y, unsigned button, unsigned buttons, unsigned modifiers);
    void mouse_move(int x, int y, unsigned buttons, unsigned modifiers);
    void mouse_leave();
    void wheel(int x, int y, double dx, double dy, unsigned modifiers);
    // `key` is a LibWeb UIEvents::KeyCode, `code_point` the text the key types (0 if none).
    void key_down(unsigned key, unsigned modifiers, uint32_t code_point, bool repeat);
    void key_up(unsigned key, unsigned modifiers, uint32_t code_point);

    // What the page did, for the chrome.
    std::function<void()> on_needs_paint;
    std::function<void(std::string const&)> on_title_change;
    std::function<void(std::string const&)> on_url_change;
    std::function<void(bool)> on_loading_change;
    std::function<void(std::string const&)> on_link_hover; // "" when the pointer leaves the link
    // The page copied text: to the clipboard, or (`selection`) to the X11 primary selection.
    std::function<void(std::string const&, bool selection)> on_clipboard_write;
    // The page pastes: the UI reads the clipboard (or the primary selection) and calls answer_clipboard with the
    // request and its text, now or later. Unanswered, the paste waits.
    std::function<void(uint64_t request, bool selection)> on_clipboard_request;
    void answer_clipboard(uint64_t request, std::string const& text);
    // The page's own context menu was not cancelled (Shift skips the page's handler): the chrome shows its menu.
    std::function<void(ContextMenu const&)> on_context_menu;
    // A navigation's response was saved to the downloads folder instead of shown ($WEBBY_DOWNLOAD_DIR, else
    // $XDG_DOWNLOAD_DIR, else ~/Downloads): Content-Disposition: attachment, or a type the engine cannot show.
    std::function<void(Download const&)> on_download;
    // A navigation's response is a PDF (application/pdf, not an attachment; or a .pdf file): the view keeps it in
    // its history and shows an empty page with the file's name as its title, and hands the bytes to the chrome,
    // whose PDF viewer shows it while the view's URL stays `url` (wasm/ui/PdfView.h). `data` may be moved from.
    std::function<void(PdfDocument&)> on_pdf;
    // A link, form or script of the page navigates it: return true to take the URL instead of loading it (the
    // chrome's own pages' actions, Pages::is_sync_action).
    std::function<bool(std::string const&)> on_navigation_request;

    // The browser's own page scripts. Every hook runs for every document the view shows, before the document is
    // parsed (a hook returns "" to skip it); the scripts talk back with prompt(message_prefix() + text), which never
    // shows anything and reaches on_page_message (text without the prefix, and the URL of the document that sent it,
    // which can differ from url() while a navigation's document downloads) after the script's task.
    // `page_scripts` gives them (WebView.cpp runs the chrome's hooks).
    std::function<std::vector<std::string>()> page_scripts;
    std::string const& message_prefix() const { return m_message_prefix; }
    void set_message_prefix(std::string prefix) { m_message_prefix = std::move(prefix); }
    std::function<void(std::string const& text, std::string const& document_url)> on_page_message;
    // Runs `source` as a classic script in the current document, now.
    void run_javascript(std::string const& source);

    // Web Authentication (passkeys, ../../patches/0002): the page asked to create or use one. `prompt` is the JSON the
    // Nim front end's dialog gets (type "create" with rpId, userName, userDisplayName, alreadyRegistered; or "get"
    // with rpId and accounts [{userName, userDisplayName, createdAt}]). The UI answers with webauthn_respond: whether
    // the user agreed and, for "get", which account. A view handles one request at a time.
    std::function<void(std::string const& prompt)> on_webauthn_prompt;
    void webauthn_respond(bool accepted, int account_index);
    // Or the request as the page made it (JSON), for a WebAuthnFlow elsewhere (WebView.cpp: the chrome's instance,
    // whose passkey store is the vault's), which answers with webauthn_reply.
    std::function<void(uint64_t request_id, std::string const& request)> on_webauthn_request;
    void webauthn_reply(uint64_t request_id, std::string const& reply);

    // Editing, for the context menu, in the focused frame.
    std::string selected_text() const;

    // Find in page (Ctrl+F): every match highlighted, the active one scrolled to. `index` counts from 0; `total` is -1
    // when unknown, 0 for no match.
    using FindResult = WebbyUI::FindResult;
    FindResult find(std::string const& query, bool case_sensitive);
    FindResult find_next();
    FindResult find_previous();
    void find_end();

    // Page zoom, 1 for 100% (0.25 to 5). Kept across this view's navigations.
    void set_zoom(double);
    double zoom() const { return m_zoom; }
    void select_all();
    std::string cut_selection(); // removes the selected text (in an editable) and returns it
    void insert_text(std::string const& text); // a paste of `text` at the caret

    // Implementation details, public for the page client in EngineView.cpp.
    struct Impl;
    void did_request_frame();
    void did_change_title(std::string title);
    void did_request_navigation(std::string url);
    void did_finish_loading();
    void did_hover_link(std::string url);
    void did_write_clipboard(std::string text, bool selection);
    void did_request_clipboard(uint64_t request, bool selection);
    void did_request_context_menu(ContextMenu);
    void did_download(Download);
    void did_receive_pdf(PdfDocument);
    void did_send_page_message(std::string text, std::string document_url);
    void did_request_webauthn(uint64_t request_id, std::string request);
    void run_page_scripts();

private:
    EngineView(int width, int height);
    void navigate(std::string const& url, bool add_to_history);
    void set_location(std::string url, bool add_to_history);
    void show_document(LoadedDocument);
    void show_pdf(LoadedDocument); // the document's bytes are the PDF's
    // A press, drag or release the viewport's or an inner scroll container's scrollbar takes (not the page).
    bool scrollbar_mouse_down(int x, int y, unsigned button);
    bool scrollbar_mouse_move(int x, int y);
    bool scrollbar_mouse_up(unsigned button);

    std::unique_ptr<Impl> m_impl;
    int m_width { 0 };
    int m_height { 0 };
    std::string m_url;
    std::string m_title;
    bool m_visible { true };
    bool m_loading { false };
    bool m_needs_paint { true };
    PaintChange m_last_change;
    std::vector<Scrollbar> m_scrollbars;
    double m_zoom { 1.0 };
    std::vector<std::string> m_history;
    size_t m_history_index { 0 };
    uint64_t m_fetch_id { 0 }; // the http(s) document being downloaded, if any
    std::string m_message_prefix;
};

}
