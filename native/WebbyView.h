/*
 * Webby: LibWebView embedding for Flutter.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/ByteString.h>
#include <AK/JsonObject.h>
#include <AK/Optional.h>
#include <AK/Vector.h>
#include <Authenticator.h>
#include <LibWebCommon/HTML/FileFilter.h>
#include <LibWebCommon/HTML/SelectedFile.h>
#include <LibWebView/Application.h>
#include <LibWebView/HeadlessWebView.h>
#include <LibWebView/Menu.h>
#include <LibWebView/WebContentPage.h>

namespace Webby {

class Application final : public WebView::Application {
    WEB_VIEW_APPLICATION(Application)

public:
    explicit Application(Optional<ByteString> ladybird_binary_path)
        : WebView::Application(move(ladybird_binary_path))
    {
    }

private:
    virtual void create_platform_options(WebView::BrowserOptions&, WebView::RequestServerOptions&, WebView::WebContentOptions&) override;
    virtual bool should_coordinate_browser_process() const override { return false; }

public:
    // Ladybird's clipboard, which pages copy into and paste from. The system clipboard lives on the Flutter side, so
    // the UI copies out what pages copy (clipboard_serial() changes) and hands in the system clipboard's text before a
    // paste. See webby_clipboard_*() in webby_ffi.h.
    virtual void insert_clipboard_item(Web::Clipboard::SystemClipboardItem) override;
    void set_clipboard_from_system(String);
    u64 clipboard_serial() const { return m_clipboard_serial; }

    // A site's cookies and stored data (see webby_clear_site_data() in webby_ffi.h).
    void clear_site_data(URL::Origin const&);

private:
    u64 m_clipboard_serial { 0 };
};

// A view with no native window: WebContent paints into shared CPU bitmaps, and each presented frame is copied into
// a buffer the Flutter side turns into an image.
class View final : public WebView::HeadlessWebView {
public:
    static NonnullOwnPtr<View> create(Core::AnonymousBuffer theme, Web::DevicePixelSize size, double device_pixel_ratio);
    virtual ~View() override;

    // A view the page opened (target=_blank, window.open()) waiting for the UI to show it as a tab, oldest first;
    // the caller owns it. Null when there is none. See webby_view_take_new_view() in webby_ffi.h.
    OwnPtr<View> take_new_view();
    // Whether the page asked to close its view (window.close()).
    bool close_requested() const { return m_close_requested; }

    void resize(Web::DevicePixelSize, double device_pixel_ratio);

    u64 frame_serial() const { return m_frame_serial; }
    u8 const* frame_pixels() const { return m_frame.data(); }
    int frame_width() const { return m_frame_width; }
    int frame_height() const { return m_frame_height; }

    u64 state_serial() const { return m_state_serial; }
    ByteString const& url_string() const { return m_url_string; }
    ByteString const& title_string() const { return m_title_string; }
    ByteString const& hovered_link() const { return m_hovered_link; }
    bool loading() const { return m_loading; }
    bool can_go_back() { return navigate_back_action().enabled(); }
    bool can_go_forward() { return navigate_forward_action().enabled(); }
    int cursor() const { return m_cursor; }

    // A passkey request waiting for the user, as JSON for the UI (empty when there is none). See webby_ffi.h.
    ByteString const& webauthn_prompt() const { return m_webauthn_prompt; }
    void respond_to_webauthn(bool accepted, int account_index);

    // An <input type=file> waiting for the user to pick files, as JSON for the UI (empty when there is none). See
    // webby_view_file_picker_request() in webby_ffi.h.
    ByteString const& file_picker_request() const { return m_file_picker_request; }
    // Hands the page the files at `paths` (none cancels the picker).
    void respond_to_file_picker(Vector<ByteString> const& paths);

    // A site asking to use a permission-gated feature (only "geolocation" so far), as JSON for the UI (empty when
    // nothing is waiting). See webby_view_permission_request() in webby_ffi.h.
    ByteString const& permission_request() const { return m_permission_request_json; }
    // Answers the request with that id, and any others waiting from the same site for the same permission.
    void respond_to_permission(u64 id, bool granted);

    // A page's alert(), confirm() or prompt() waiting for the user, as JSON for the UI (empty when there is none).
    // See webby_view_dialog() in webby_ffi.h.
    ByteString const& dialog() const { return m_dialog_json; }
    void respond_to_dialog(u64 id, bool accepted, Optional<Utf16String> text);

    // prompt() calls whose text starts with this prefix are messages from the browser's own page scripts: they're
    // answered at once and queued here instead of being shown. See webby_view_set_message_prefix() in webby_ffi.h.
    void set_message_prefix(ByteString prefix) { m_message_prefix = move(prefix); }
    // The oldest queued message, removed from the queue (empty when there is none). Valid until the next call.
    ByteString const& take_message();

    // The focused text field's state for an on-screen keyboard, as JSON (see webby_view_ime_state() in webby_ffi.h).
    ByteString const& input_method_state_json();

private:
    View(Core::AnonymousBuffer theme, Web::DevicePixelSize size);

    // HeadlessWebView would keep these as invisible child views that live (with their WebContent process) until the
    // page closes them; queue them for the UI instead.
    virtual ViewImplementation* create_view_for_new_tab_or_window(WebView::IsPrivate) override;
    View& queue_new_view(NonnullOwnPtr<View>);

    void copy_front_bitmap();
    void state_changed() { ++m_state_serial; }

    // Puts the site-permission check in front of Ladybird's geolocation handlers. Call after initialize_tab(), which
    // installs them.
    void install_permission_checks();
    void update_permission_request();

    void handle_webauthn_request(WebView::WebContentPage&, u64 request_id, String const& request);

    Vector<u8> m_frame;
    int m_frame_width { 0 };
    int m_frame_height { 0 };
    u64 m_frame_serial { 0 };

    u64 m_state_serial { 0 };
    ByteString m_url_string;
    ByteString m_title_string;
    ByteString m_hovered_link;
    bool m_loading { false };
    int m_cursor { 0 };

    struct PendingWebAuthn {
        RefPtr<WebView::WebContentPage> page;
        u64 request_id { 0 };
        JsonObject request;
        Vector<Passkey> accounts;
        bool already_registered { false };
    };
    Optional<PendingWebAuthn> m_pending_webauthn;
    ByteString m_webauthn_prompt;

    struct PendingPermission {
        u64 id { 0 };
        ByteString permission;
        ByteString origin;
        // Geolocation requests, so a cancelled one can be withdrawn; null for others.
        RefPtr<WebView::WebContentPage> page;
        u64 request_id { 0 };
        bool is_watch { false };
        Function<void(bool granted)> answer;
    };
    void ask_permission(StringView permission, Function<void(bool granted)> answer, RefPtr<WebView::WebContentPage> = {}, u64 request_id = 0, bool is_watch = false);
    Vector<PendingPermission> m_pending_permissions;
    u64 m_next_permission_id { 0 };
    ByteString m_permission_request_json;
    Function<void(WebView::WebContentPage&, u64)> m_request_geolocation_position;
    Function<void(WebView::WebContentPage&, u64)> m_cancel_geolocation_position_request;
    Function<void(WebView::WebContentPage&, u64)> m_start_geolocation_position_watch;
    Function<void(WebView::WebContentPage&, u64)> m_stop_geolocation_position_watch;

    enum class DialogType : u8 {
        None,
        Alert,
        Confirm,
        Prompt,
    };
    void show_dialog(DialogType, Utf16String const& message, Utf16String const& default_ = {});
    DialogType m_dialog_type { DialogType::None };
    u64 m_dialog_id { 0 };
    ByteString m_dialog_json;

    ByteString m_file_picker_request;
    u64 m_file_picker_id { 0 };

    Vector<NonnullOwnPtr<View>> m_new_views;
    bool m_close_requested { false };

    ByteString m_message_prefix;
    Vector<ByteString> m_messages;
    ByteString m_current_message;

    ByteString m_input_method_state_json;
};

}
