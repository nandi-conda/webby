/*
 * Webby: LibWebView embedding for Flutter.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/ByteString.h>
#include <AK/Vector.h>
#include <LibWebView/Application.h>
#include <LibWebView/HeadlessWebView.h>
#include <LibWebView/Menu.h>

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

private:
    View(Core::AnonymousBuffer theme, Web::DevicePixelSize size);

    void copy_front_bitmap();
    void state_changed() { ++m_state_serial; }

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
};

}
