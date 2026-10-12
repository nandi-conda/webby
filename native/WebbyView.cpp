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
#include <LibWebCommon/Geolocation/GeolocationPositionErrorCode.h>
#include <LibGfx/Bitmap.h>
#include <LibGfx/SharedImageBuffer.h>
#include <LibWebCommon/StorageAPI/StorageEndpoint.h>
#include <LibWebView/BrowsingSession.h>
#include <LibWebView/CookieJar.h>
#include <LibWebView/Menu.h>
#include <LibWebView/StorageJar.h>
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

// Whether a cookie for `domain` belongs to the site of `host`: the host itself, its parent domains (cookies such as
// ".google.com" that maps.google.com uses) and its subdomains.
static bool cookie_domain_matches(StringView domain, StringView host)
{
    auto is_suffix = [](StringView name, StringView suffix) {
        return name.length() > suffix.length() && name.ends_with(suffix, CaseSensitivity::CaseInsensitive)
            && name[name.length() - suffix.length() - 1] == '.';
    };
    if (domain.starts_with('.'))
        domain = domain.substring_view(1);
    if (domain.equals_ignoring_ascii_case(host))
        return true;
    // A bare TLD ("com") is never a site of its own.
    if (is_suffix(host, domain) && domain.contains('.'))
        return true;
    return is_suffix(domain, host);
}

void Application::clear_site_data(URL::Origin const& origin)
{
    if (origin.is_opaque())
        return;
    auto host = origin.host().serialize().to_byte_string();
    auto origin_string = origin.serialize();

    auto clear = [&](WebView::BrowsingSession& session) {
        for (auto const& cookie : session.cookie_jar->get_all_cookies()) {
            auto domain = cookie.domain.bytes_as_string_view();
            // Cookies a third-party frame set under this site's top level go too.
            auto partition = cookie.partition_key.to_utf8();
            bool partitioned_here = !cookie.partition_key.is_empty() && partition.bytes_as_string_view().ends_with(host, CaseSensitivity::CaseInsensitive);
            if (!cookie_domain_matches(domain, host) && !partitioned_here)
                continue;
            session.cookie_jar->delete_cookie({ cookie.name, cookie.domain, cookie.path, cookie.partition_key });
        }
        for (auto endpoint : { Web::StorageAPI::StorageEndpointType::LocalStorage, Web::StorageAPI::StorageEndpointType::IndexedDB, Web::StorageAPI::StorageEndpointType::Caches })
            session.storage_jar->clear_storage_key(endpoint, origin_string);
    };
    clear(default_session());

    WebView::ViewImplementation::for_each_view([&](WebView::ViewImplementation& view) {
        if (view.url().origin().is_same_origin(origin))
            view.clear_session_storage();
        return IterationDecision::Continue;
    });
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
    view->install_permission_checks();
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
        view->install_permission_checks();
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

void View::install_permission_checks()
{
    m_request_geolocation_position = move(on_request_geolocation_position);
    m_cancel_geolocation_position_request = move(on_cancel_geolocation_position_request);
    m_start_geolocation_position_watch = move(on_start_geolocation_position_watch);
    m_stop_geolocation_position_watch = move(on_stop_geolocation_position_watch);

    // Ladybird lets every secure page use the location (the engine-wide switch aside); like other browsers, ask the
    // user per site first. The UI remembers the answers.
    auto ask = [this](WebView::WebContentPage& page, u64 request_id, bool is_watch) {
        auto origin = url().origin();
        // Opaque origins (data:, sandboxed pages) have no site to remember an answer for.
        if (origin.is_opaque()) {
            page.async_geolocation_position_response(request_id, {}, to_underlying(Web::Geolocation::GeolocationPositionErrorCode::PermissionDenied));
            return;
        }
        m_pending_permissions.append({ ++m_next_permission_id, ByteString("geolocation"sv), origin.serialize().to_byte_string(), page, request_id, is_watch });
        update_permission_request();
    };
    on_request_geolocation_position = [ask](WebView::WebContentPage& page, u64 request_id) { ask(page, request_id, false); };
    on_start_geolocation_position_watch = [ask](WebView::WebContentPage& page, u64 request_id) { ask(page, request_id, true); };

    auto withdraw = [this](WebView::WebContentPage& page, u64 request_id, bool is_watch) {
        auto removed = m_pending_permissions.remove_all_matching([&](auto const& pending) {
            return pending.page.ptr() == &page && pending.request_id == request_id && pending.is_watch == is_watch;
        });
        if (removed) {
            update_permission_request();
            return true;
        }
        return false;
    };
    on_cancel_geolocation_position_request = [this, withdraw](WebView::WebContentPage& page, u64 request_id) {
        if (!withdraw(page, request_id, false) && m_cancel_geolocation_position_request)
            m_cancel_geolocation_position_request(page, request_id);
    };
    on_stop_geolocation_position_watch = [this, withdraw](WebView::WebContentPage& page, u64 request_id) {
        if (!withdraw(page, request_id, true) && m_stop_geolocation_position_watch)
            m_stop_geolocation_position_watch(page, request_id);
    };
}

void View::update_permission_request()
{
    m_pending_permissions.remove_all_matching([](auto const& pending) { return !pending.page->is_open(); });

    ByteString json;
    if (!m_pending_permissions.is_empty()) {
        auto const& pending = m_pending_permissions.first();
        JsonObject request;
        request.set("id"sv, pending.id);
        request.set("permission"sv, pending.permission.view());
        request.set("origin"sv, pending.origin.view());
        json = request.serialized().to_byte_string();
    }
    if (json != m_permission_request_json) {
        m_permission_request_json = move(json);
        state_changed();
    }
}

void View::respond_to_permission(u64 id, bool granted)
{
    auto first = m_pending_permissions.find_if([&](auto const& pending) { return pending.id == id; });
    if (first.is_end())
        return;
    auto permission = first->permission;
    auto origin = first->origin;

    Vector<PendingPermission> answered;
    m_pending_permissions.remove_all_matching([&](auto& pending) {
        if (pending.permission != permission || pending.origin != origin)
            return false;
        answered.append(move(pending));
        return true;
    });
    update_permission_request();

    for (auto& pending : answered) {
        if (!pending.page->is_open())
            continue;
        if (!granted) {
            pending.page->async_geolocation_position_response(pending.request_id, {}, to_underlying(Web::Geolocation::GeolocationPositionErrorCode::PermissionDenied));
            continue;
        }
        auto& handler = pending.is_watch ? m_start_geolocation_position_watch : m_request_geolocation_position;
        if (handler)
            handler(*pending.page, pending.request_id);
    }
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
    for (auto& pending : m_pending_permissions) {
        if (pending.page->is_open())
            pending.page->async_geolocation_position_response(pending.request_id, {}, to_underlying(Web::Geolocation::GeolocationPositionErrorCode::PermissionDenied));
    }
    m_pending_permissions.clear();
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
