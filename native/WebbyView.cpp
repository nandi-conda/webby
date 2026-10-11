/*
 * Webby: LibWebView embedding for Flutter.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/JsonArray.h>
#include <AK/JsonValue.h>
#include <AK/LexicalPath.h>
#include <LibCore/System.h>
#include <LibIPC/File.h>
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

void Application::insert_clipboard_item(Web::Clipboard::SystemClipboardItem item)
{
    WebView::Application::insert_clipboard_item(move(item));
    ++m_clipboard_serial;
}

void Application::set_clipboard_from_system(String text)
{
    // While the system clipboard still holds what a page copied, keep the page's copy: it may carry more than plain
    // text (text/html).
    if (clipboard_text().to_utf8() == text)
        return;
    WebView::Application::set_clipboard_text(move(text));
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

    // window.open() with an opener: the new view displays the traversable the page's WebContent already made.
    on_new_web_view = [this](auto, auto, WebView::CanonicalTraversable& traversable) {
        auto view = adopt_own(*new View(m_theme, m_viewport_size));
        view->m_device_pixel_ratio = m_device_pixel_ratio;
        view->initialize_tab(Web::HTML::VisibilityState::Visible, traversable);
        return queue_new_view(move(view)).handle();
    };

    on_close = [this] {
        m_close_requested = true;
        state_changed();
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

    on_request_webauthn = [this](WebView::WebContentPage& page, u64 request_id, String const& request) {
        handle_webauthn_request(page, request_id, request);
    };

    on_request_file_picker = [this](Web::HTML::FileFilter const& accepted_file_types, Web::HTML::AllowMultipleFiles allow_multiple_files) {
        JsonArray accept;
        for (auto const& filter : accepted_file_types.filters) {
            filter.visit(
                [&](Web::HTML::FileFilter::FileType type) {
                    switch (type) {
                    case Web::HTML::FileFilter::FileType::Audio:
                        accept.must_append("audio/*"sv);
                        break;
                    case Web::HTML::FileFilter::FileType::Image:
                        accept.must_append("image/*"sv);
                        break;
                    case Web::HTML::FileFilter::FileType::Video:
                        accept.must_append("video/*"sv);
                        break;
                    }
                },
                [&](Web::HTML::FileFilter::MimeType const& mime_type) { accept.must_append(mime_type.value.to_utf8()); },
                [&](Web::HTML::FileFilter::Extension const& extension) { accept.must_append(extension.value.to_utf8()); });
        }
        JsonObject request;
        request.set("id"sv, ++m_file_picker_id);
        request.set("multiple"sv, allow_multiple_files == Web::HTML::AllowMultipleFiles::Yes);
        request.set("accept"sv, move(accept));
        m_file_picker_request = request.serialized().to_byte_string();
        state_changed();
    };

    on_input_method_state_change = [this] {
        state_changed();
    };

    // Messages from the browser's page scripts arrive as prompt() calls; everything else keeps HeadlessWebView's
    // handling.
    on_request_prompt = [this, headless_prompt = move(on_request_prompt)](Utf16String const& message, Utf16String const& default_) {
        auto text = message.to_utf8();
        if (!m_message_prefix.is_empty() && text.bytes_as_string_view().starts_with(m_message_prefix)) {
            // Don't let a page grow the queue without bound while the UI isn't reading it.
            if (m_messages.size() >= 64)
                m_messages.take_first();
            m_messages.append(text.bytes_as_string_view().substring_view(m_message_prefix.length()));
            prompt_closed({});
            return;
        }
        if (headless_prompt)
            headless_prompt(message, default_);
    };
}

WebView::ViewImplementation* View::create_view_for_new_tab_or_window(WebView::IsPrivate)
{
    return &queue_new_view(View::create(m_theme, m_viewport_size, m_device_pixel_ratio));
}

View& View::queue_new_view(NonnullOwnPtr<View> view)
{
    m_new_views.append(move(view));
    state_changed();
    return *m_new_views.last();
}

OwnPtr<View> View::take_new_view()
{
    if (m_new_views.is_empty())
        return {};
    return m_new_views.take_first();
}

ByteString const& View::take_message()
{
    m_current_message = m_messages.is_empty() ? ByteString {} : m_messages.take_first();
    return m_current_message;
}

void View::respond_to_file_picker(Vector<ByteString> const& paths)
{
    if (m_file_picker_request.is_empty())
        return;
    m_file_picker_request = {};
    state_changed();

    Vector<Web::HTML::SelectedFile> files;
    for (auto const& path : paths) {
        // Hand WebContent an open descriptor rather than the bytes, so big files aren't copied through this process.
        auto fd = Core::System::open(path, O_RDONLY | O_CLOEXEC);
        if (fd.is_error()) {
            warnln("Webby: can't open picked file {}: {}", path, fd.error());
            continue;
        }
        auto name = Utf16String::from_utf8_with_replacement_character(LexicalPath::basename(path));
        files.empend(move(name), IPC::File::adopt_fd(fd.value()));
    }
    file_picker_closed(move(files));
}

ByteString const& View::input_method_state_json()
{
    auto const& state = input_method_state();
    JsonObject object;
    object.set("enabled"sv, state.is_enabled);
    object.set("before"sv, state.text_before_cursor.to_utf8());
    object.set("after"sv, state.text_after_cursor.to_utf8());
    object.set("cursor"sv, state.cursor_position);
    object.set("anchor"sv, state.anchor_position);
    m_input_method_state_json = object.serialized().to_byte_string();
    return m_input_method_state_json;
}

View::~View()
{
    respond_to_file_picker({});
    respond_to_webauthn(false, -1);
}

void View::resize(Web::DevicePixelSize size, double device_pixel_ratio)
{
    m_device_pixel_ratio = device_pixel_ratio;
    reset_viewport_size(size);
}

static Vector<String> string_array(JsonObject const& object, StringView key)
{
    Vector<String> strings;
    if (auto array = object.get_array(key); array.has_value()) {
        array->for_each([&](JsonValue const& value) {
            if (value.is_string())
                strings.append(value.as_string());
        });
    }
    return strings;
}

static String string_member(JsonObject const& object, StringView key)
{
    if (auto value = object.get_string(key); value.has_value())
        return *value;
    return {};
}

void View::handle_webauthn_request(WebView::WebContentPage& page, u64 request_id, String const& request_json)
{
    auto reply = [&](String const& json) { page.async_webauthn_response(request_id, json); };

    auto parsed = JsonValue::from_string(request_json);
    if (parsed.is_error() || !parsed.value().is_object()) {
        reply(error_reply("UnknownError"sv, "Malformed request"sv));
        return;
    }
    // One dialog at a time; a page that asks again while the user is deciding is turned away.
    if (m_pending_webauthn.has_value()) {
        reply(error_reply("NotAllowedError"sv, "Another passkey request is waiting for the user"sv));
        return;
    }

    auto request = move(parsed.value().as_object());
    auto type = string_member(request, "type"sv);
    auto rp_id = string_member(request, "rpId"sv);

    PendingWebAuthn pending { page, request_id, {}, {}, false };
    JsonObject prompt;
    prompt.set("type"sv, type);
    prompt.set("rpId"sv, rp_id);
    prompt.set("origin"sv, string_member(request, "origin"sv));

    if (type == "create"sv) {
        bool supports_es256 = false;
        if (auto algorithms = request.get_array("algorithms"sv); algorithms.has_value()) {
            algorithms->for_each([&](JsonValue const& value) {
                if (value.get_i64() == -7)
                    supports_es256 = true;
            });
        }
        if (!supports_es256) {
            reply(error_reply("NotSupportedError"sv, "This browser's passkeys only support ES256"sv));
            return;
        }
        // An empty exclude list means "exclude nothing", not "any passkey for this site".
        if (auto excluded = string_array(request, "excludeCredentials"sv); !excluded.is_empty())
            pending.already_registered = !credential_store().list(rp_id, excluded).is_empty();
        prompt.set("rpName"sv, string_member(request, "rpName"sv));
        prompt.set("userName"sv, string_member(request, "userName"sv));
        prompt.set("userDisplayName"sv, string_member(request, "userDisplayName"sv));
        prompt.set("alreadyRegistered"sv, pending.already_registered);
    } else if (type == "get"sv) {
        pending.accounts = credential_store().list(rp_id, string_array(request, "allowCredentials"sv));
        JsonArray accounts;
        for (auto const& passkey : pending.accounts) {
            JsonObject account;
            account.set("userName"sv, passkey.user_name);
            account.set("userDisplayName"sv, passkey.user_display_name);
            account.set("createdAt"sv, passkey.created_at);
            accounts.must_append(move(account));
        }
        prompt.set("accounts"sv, move(accounts));
    } else {
        reply(error_reply("NotSupportedError"sv, "Unknown request"sv));
        return;
    }

    pending.request = move(request);
    m_pending_webauthn = move(pending);
    m_webauthn_prompt = prompt.serialized().to_byte_string();
    state_changed();
}

void View::respond_to_webauthn(bool accepted, int account_index)
{
    if (!m_pending_webauthn.has_value())
        return;
    auto pending = m_pending_webauthn.release_value();
    m_webauthn_prompt = {};
    state_changed();

    String reply;
    auto type = string_member(pending.request, "type"sv);
    if (!accepted) {
        reply = error_reply("NotAllowedError"sv, "The user cancelled the request"sv);
    } else if (type == "create"sv) {
        // https://w3c.github.io/webauthn/#sctn-op-make-cred step 3: after the user consents, report that one of the
        // excluded credentials is already here.
        if (pending.already_registered)
            reply = error_reply("InvalidStateError"sv, "A passkey for this account already exists in this browser"sv);
        else
            reply = make_credential(pending.request);
    } else if (account_index < 0 || static_cast<size_t>(account_index) >= pending.accounts.size()) {
        reply = error_reply("NotAllowedError"sv, "No passkey was chosen"sv);
    } else {
        reply = get_assertion(pending.request, pending.accounts[account_index]);
    }

    if (pending.page && pending.page->is_open())
        pending.page->async_webauthn_response(pending.request_id, reply);
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
