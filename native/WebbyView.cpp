/*
 * Webby: LibWebView embedding for Flutter.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <LibGfx/Bitmap.h>
#include <LibGfx/SharedImageBuffer.h>
#include <LibWebView/Menu.h>
#include <WebbyView.h>

namespace Webby {

void Application::create_platform_options(WebView::BrowserOptions&, WebView::RequestServerOptions&, WebView::WebContentOptions& web_content_options)
{
    // Frames are read back on the CPU and handed to Flutter as pixels, so WebContent must paint into shared memory
    // bitmaps rather than GPU-only images.
    web_content_options.force_cpu_painting = WebView::ForceCPUPainting::Yes;
}

static int cursor_to_int(Gfx::Cursor const& cursor)
{
    return cursor.visit(
        [](Gfx::StandardCursor standard_cursor) { return static_cast<int>(standard_cursor); },
        [](Gfx::ImageCursor const&) { return static_cast<int>(Gfx::StandardCursor::Arrow); });
}

NonnullOwnPtr<View> View::create(Core::AnonymousBuffer theme, Web::DevicePixelSize size, double device_pixel_ratio)
{
    auto view = adopt_own(*new View(move(theme), size));
    view->m_device_pixel_ratio = device_pixel_ratio;
    view->initialize_tab(Web::HTML::VisibilityState::Visible);
    return view;
}

View::View(Core::AnonymousBuffer theme, Web::DevicePixelSize size)
    : HeadlessWebView(move(theme), size)
{
    on_ready_to_paint = [this] {
        copy_front_bitmap();
    };

    on_url_change = [this](URL::URL const& url) {
        m_url_string = ByteString::formatted("{}", url);
        state_changed();
    };

    on_title_change = [this](Utf16String const& title) {
        m_title_string = ByteString::formatted("{}", title);
        state_changed();
    };

    on_load_start = [this] {
        m_loading = true;
        state_changed();
    };

    on_load_finish = [this](URL::URL const& url) {
        m_url_string = ByteString::formatted("{}", url);
        m_loading = false;
        state_changed();
    };

    on_loading_state_change = [this](bool loading) {
        m_loading = loading;
        state_changed();
    };

    on_browser_history_traversal_complete = [this] {
        state_changed();
    };

    on_top_level_navigation_commit = [this] {
        state_changed();
    };

    on_link_hover = [this](URL::URL const& url) {
        m_hovered_link = ByteString::formatted("{}", url);
        state_changed();
    };

    on_link_unhover = [this] {
        m_hovered_link = {};
        state_changed();
    };

    on_cursor_change = [this](Gfx::Cursor const& cursor) {
        m_cursor = cursor_to_int(cursor);
        state_changed();
    };
}

void View::resize(Web::DevicePixelSize size, double device_pixel_ratio)
{
    m_device_pixel_ratio = device_pixel_ratio;
    reset_viewport_size(size);
}

void View::copy_front_bitmap()
{
    if (!m_has_usable_bitmap || !m_front_bitmap.shared_image_buffer)
        return;

    auto bitmap = m_front_bitmap.shared_image_buffer->bitmap_if_present();
    if (!bitmap)
        return;

    auto size = m_front_bitmap.last_painted_size.to_type<int>();
    auto width = min(size.width(), bitmap->width());
    auto height = min(size.height(), bitmap->height());
    if (width <= 0 || height <= 0)
        return;

    auto row_bytes = static_cast<size_t>(width) * 4;
    m_frame.resize(row_bytes * height);

    bool swap_red_blue = bitmap->format() == Gfx::BitmapFormat::RGBA8888 || bitmap->format() == Gfx::BitmapFormat::RGBx8888;
    bool force_opaque = bitmap->format() == Gfx::BitmapFormat::BGRx8888 || bitmap->format() == Gfx::BitmapFormat::RGBx8888;

    for (int y = 0; y < height; ++y) {
        auto const* source = bitmap->scanline_u8(y);
        auto* destination = m_frame.data() + (row_bytes * y);

        if (!swap_red_blue && !force_opaque) {
            __builtin_memcpy(destination, source, row_bytes);
            continue;
        }

        for (int x = 0; x < width; ++x) {
            auto const* in = source + (x * 4);
            auto* out = destination + (x * 4);
            out[0] = swap_red_blue ? in[2] : in[0];
            out[1] = in[1];
            out[2] = swap_red_blue ? in[0] : in[2];
            out[3] = force_opaque ? 0xff : in[3];
        }
    }

    m_frame_width = width;
    m_frame_height = height;
    ++m_frame_serial;
}

}
