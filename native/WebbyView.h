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
};

// A view with no native window: WebContent paints into shared CPU bitmaps, and each presented frame is copied into
// a buffer the Flutter side turns into an image.
class View final : public WebView::HeadlessWebView {
public:
    static NonnullOwnPtr<View> create(Core::AnonymousBuffer theme, Web::DevicePixelSize size, double device_pixel_ratio);
    virtual ~View() override;

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

    // prompt() calls whose text starts with this prefix are messages from the browser's own page scripts: they're
    // answered at once and queued here instead of being shown. See webby_view_set_message_prefix() in webby_ffi.h.
    void set_message_prefix(ByteString prefix) { m_message_prefix = move(prefix); }
    // The oldest queued message, removed from the queue (empty when there is none). Valid until the next call.
    ByteString const& take_message();

private:
    View(Core::AnonymousBuffer theme, Web::DevicePixelSize size);

    void copy_front_bitmap();
    void state_changed() { ++m_state_serial; }

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

    ByteString m_message_prefix;
    Vector<ByteString> m_messages;
    ByteString m_current_message;
};

}
