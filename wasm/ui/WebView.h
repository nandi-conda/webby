/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// WebView: one page of Ladybird's LibWeb, hosted in this module, with no WebContent, Compositor or RequestServer
// process. The UI (Qt) side talks to it through this header only, which names no LibWeb or AK type, so Qt and
// Ladybird headers never meet in one file.
//
// A load parses the document right here (http(s) documents come from RequestServer, in this module: Network.h) and gives it a fresh Page (see WebView.cpp), as webby-render does. A paint
// lays the page out, records its display list and rasterizes it on the CPU with the Compositor's Skia player.

#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace WebbyUI {

struct LoadedDocument;

// Keyboard modifiers, as LibWeb's UIEvents::KeyModifier numbers them.
enum Modifier : unsigned {
    ModNone = 0,
    ModAlt = 1 << 0,
    ModCtrl = 1 << 1,
    ModShift = 1 << 2,
    ModSuper = 1 << 3,
    ModKeypad = 1 << 4,
};

// Mouse buttons, as LibWeb's UIEvents::MouseButton numbers them.
enum MouseButton : unsigned {
    ButtonNone = 0,
    ButtonPrimary = 1,
    ButtonSecondary = 2,
    ButtonMiddle = 4,
    ButtonBackward = 8,
    ButtonForward = 16,
};

// What a right-click (or Ctrl+click) hit, for the chrome's context menu. URLs are "" when there is none.
struct ContextMenu {
    int x { 0 }; // viewport coordinates of the click
    int y { 0 };
    std::string link;      // the link's URL
    std::string link_text; // its text
    std::string image;     // the image's URL
    std::string selection; // the selected text in the clicked frame
    bool editable { false }; // the click was in a text field or contenteditable
};

// A navigation saved as a file (see WebView::on_download).
struct Download {
    std::string url;
    std::string path;  // where it was saved, "" if it was not
    uint64_t size { 0 };
    std::string mime;
    std::string error; // why it was not saved, "" if it was
};

// A navigation whose response is a PDF (see WebView::on_pdf).
struct PdfDocument {
    std::string url;
    std::string mime;
    std::vector<uint8_t> data;
};

class WebView {
public:
    // The engine is set up the first time a view is made: LibWeb's JS VM, resource loader and fonts.
    static std::unique_ptr<WebView> create(int width, int height);
    ~WebView();

    // Runs the engine's event loop until nothing is due right now (timers, tasks, deferred work). Never blocks.
    static void pump();

    void load(std::string const& url);
    void reload();
    bool can_go_back() const;
    bool can_go_forward() const;
    void go_back();
    void go_forward();

    std::string const& url() const { return m_url; }
    std::string const& title() const { return m_title; }
    bool is_loading() const { return m_loading; }

    // The size of the page's viewport, in CSS pixels (device pixel ratio 1).
    void resize(int width, int height);
    int width() const { return m_width; }
    int height() const { return m_height; }

    // The page's pixels: premultiplied BGRA (Qt's ARGB32_Premultiplied on little endian), width() x height(), drawn
    // anew when the page changed since the last call. Null before the first load.
    uint8_t const* paint();
    bool needs_paint() const { return m_needs_paint; }

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
    using PageScriptHook = std::function<std::string(WebView&)>;
    static void add_page_script(PageScriptHook);
    std::string const& message_prefix() const { return m_message_prefix; }
    std::function<void(std::string const& text, std::string const& document_url)> on_page_message;
    // Runs `source` as a classic script in the current document, now.
    void run_javascript(std::string const& source);

    // Web Authentication (passkeys, ../../patches/0002): the page asked to create or use one. `prompt` is the JSON the
    // Nim front end's dialog gets (type "create" with rpId, userName, userDisplayName, alreadyRegistered; or "get"
    // with rpId and accounts [{userName, userDisplayName, createdAt}]). The UI answers with webauthn_respond: whether
    // the user agreed and, for "get", which account. A view handles one request at a time.
    std::function<void(std::string const& prompt)> on_webauthn_prompt;
    void webauthn_respond(bool accepted, int account_index);

    // Editing, for the context menu, in the focused frame.
    std::string selected_text() const;

    // Find in page (Ctrl+F): every match highlighted, the active one scrolled to. `index` counts from 0; `total` is -1
    // when unknown, 0 for no match.
    struct FindResult {
        unsigned index { 0 };
        int total { 0 };
    };
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

    // Implementation details, public for the page client in WebView.cpp.
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
    // The UI component's WebView (shell/WebViewRemote.cpp) only: the engine component's queued events, as the
    // callbacks above.
    void deliver_engine_events();

private:
    WebView(int width, int height);
    void navigate(std::string const& url, bool add_to_history);
    void set_location(std::string url, bool add_to_history);
    void show_document(LoadedDocument);
    void show_pdf(LoadedDocument); // the document's bytes are the PDF's

    std::unique_ptr<Impl> m_impl;
    int m_width { 0 };
    int m_height { 0 };
    std::string m_url;
    std::string m_title;
    bool m_loading { false };
    bool m_needs_paint { true };
    double m_zoom { 1.0 };
    std::vector<std::string> m_history;
    size_t m_history_index { 0 };
    uint64_t m_fetch_id { 0 }; // the http(s) document being downloaded, if any
    std::string m_message_prefix;
};

}
