/*
 * Webby: C ABI over LibWebView for dart:ffi.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/JsonValue.h>
#include <AK/LexicalPath.h>
#include <AK/Utf16String.h>
#include <AK/Vector.h>
#include <LibCore/EventLoop.h>
#include <LibGfx/SystemTheme.h>
#include <LibMain/Main.h>
#include <LibWebCommon/CSS/PreferredColorScheme.h>
#include <LibWebCommon/Page/InputEvent.h>
#include <LibRequests/RequestControlClient.h>
#include <LibURL/Parser.h>
#include <LibWebView/Application.h>
#include <LibWebView/Menu.h>
#include <LibWebView/Utilities.h>
#include <WebbyGeolocation.h>
#include <WebbyView.h>
#include <webby_ffi.h>

#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

struct WebbyView {
    NonnullOwnPtr<Webby::View> view;
};

// Deliberately leaked: destroying it from exit()'s static destructors runs after the event loop is gone, and
// ~Process -> did_lose_process -> deferred_invoke then VERIFY-crashes (SIGILL core dump on every quit).
static Webby::Application* s_application;
static Optional<Core::AnonymousBuffer> s_theme;

static Web::DevicePixelSize to_device_size(int width, int height)
{
    return { max(width, 1), max(height, 1) };
}

static Web::UIEvents::KeyModifier to_modifiers(int modifiers)
{
    return static_cast<Web::UIEvents::KeyModifier>(modifiers & Web::UIEvents::Mod_Mask);
}

extern "C" {

int webby_init(char const* prefix)
{
    if (s_application)
        return 0;

    // Helper processes are found relative to the "binary" directory: <prefix>/bin -> <prefix>/libexec.
    auto binary_directory = LexicalPath::join(StringView { prefix, strlen(prefix) }, "bin"sv).string();

    // Extra Ladybird command-line flags come from $WEBBY_LADYBIRD_ARGS, e.g. "--disable-sandbox" on kernels without
    // Landlock. They are kept alive for the whole process, as Ladybird's argument parser expects.
    static Vector<ByteString> arg_storage;
    static Vector<char*> argv;
    static Vector<StringView> strings;
    arg_storage.append("webby"sv);
    if (auto const* extra = getenv("WEBBY_LADYBIRD_ARGS")) {
        for (auto arg : StringView { extra, strlen(extra) }.split_view(' '))
            arg_storage.append(arg);
    }
    for (auto& arg : arg_storage) {
        argv.append(const_cast<char*>(arg.characters()));
        strings.append(arg.view());
    }
    argv.append(nullptr);
    Main::Arguments arguments { static_cast<int>(strings.size()), argv.data(), strings.span() };

    // Pages' navigator.geolocation gets positions from the UI; turn on Ladybird's engine-wide switch for it (off by
    // default), as sites are asked about one by one instead (see View::install_permission_checks()).
    Webby::GeolocationProvider::install();

    auto application = Webby::Application::create(arguments, binary_directory);
    if (application.is_error()) {
        warnln("webby: Unable to create application: {}", application.error());
        return -1;
    }
    s_application = application.release_value().leak_ptr();
    if (!WebView::Application::settings().geolocation_enabled())
        WebView::Application::settings().set_geolocation_enabled(true);

    auto theme_path = LexicalPath::join(WebView::s_ladybird_resource_root, "themes"sv, "Default.ini"sv);
    auto theme = Gfx::load_system_theme(theme_path.string());
    if (theme.is_error()) {
        warnln("webby: Unable to load theme {}: {}", theme_path, theme.error());
        return -2;
    }
    s_theme = theme.release_value();
    return 0;
}

int webby_pump(void)
{
    if (!s_application)
        return 0;
    return static_cast<int>(Core::EventLoop::current().pump(Core::EventLoop::WaitMode::PollForEvents));
}

WebbyView* webby_view_create(int width, int height, double device_pixel_ratio)
{
    if (!s_application || !s_theme.has_value())
        return nullptr;
    auto view = Webby::View::create(*s_theme, to_device_size(width, height), device_pixel_ratio);
    return new WebbyView { move(view) };
}

void webby_view_destroy(WebbyView* handle)
{
    delete handle;
}

void webby_view_load(WebbyView* handle, char const* url_or_search)
{
    handle->view->load_from_user_input(StringView { url_or_search, strlen(url_or_search) });
}

void webby_view_go_back(WebbyView* handle)
{
    handle->view->traverse_the_history_by_delta(-1);
}

void webby_view_go_forward(WebbyView* handle)
{
    handle->view->traverse_the_history_by_delta(1);
}

void webby_view_set_color_scheme(WebbyView* handle, int scheme)
{
    auto preferred = Web::CSS::PreferredColorScheme::Auto;
    if (scheme == WEBBY_COLOR_SCHEME_LIGHT)
        preferred = Web::CSS::PreferredColorScheme::Light;
    else if (scheme == WEBBY_COLOR_SCHEME_DARK)
        preferred = Web::CSS::PreferredColorScheme::Dark;
    // The application's colour scheme is what Ladybird gives every new WebContent page (cross-site navigations get
    // one), so set it there too, or such loads fall back to Auto. Its menu holds Auto, Dark, Light in that order.
    if (s_application) {
        auto index = preferred == Web::CSS::PreferredColorScheme::Dark ? 1 : preferred == Web::CSS::PreferredColorScheme::Light ? 2 : 0;
        auto items = s_application->color_scheme_menu().items();
        if (static_cast<size_t>(index) < items.size()) {
            if (auto* action = items[index].get_pointer<NonnullRefPtr<WebView::Action>>()) {
                (*action)->set_checked(true);
                (*action)->activate();
                return;
            }
        }
    }
    handle->view->set_preferred_color_scheme(preferred);
}

void webby_view_set_visible(WebbyView* handle, int visible)
{
    handle->view->set_system_visibility_state(visible ? Web::HTML::VisibilityState::Visible : Web::HTML::VisibilityState::Hidden);
}

WebbyView* webby_view_take_new_view(WebbyView* handle)
{
    auto view = handle->view->take_new_view();
    if (!view)
        return nullptr;
    return new WebbyView { view.release_nonnull() };
}

int webby_view_close_requested(WebbyView* handle)
{
    return handle->view->close_requested() ? 1 : 0;
}

void webby_view_reload(WebbyView* handle)
{
    handle->view->reload();
}

void webby_view_stop(WebbyView* handle)
{
    handle->view->stop_loading();
}

void webby_view_resize(WebbyView* handle, int width, int height, double device_pixel_ratio)
{
    handle->view->resize(to_device_size(width, height), device_pixel_ratio);
}

void webby_view_set_focus(WebbyView* handle, int focused)
{
    handle->view->set_has_system_focus(focused != 0);
}

void webby_view_run_javascript(WebbyView* handle, char const* source)
{
    auto string = String::from_utf8(StringView { source, strlen(source) });
    if (string.is_error())
        return;
    handle->view->run_javascript(string.release_value());
}

uint64_t webby_view_frame_serial(WebbyView* handle) { return handle->view->frame_serial(); }
uint8_t const* webby_view_frame_pixels(WebbyView* handle) { return handle->view->frame_pixels(); }
int webby_view_frame_width(WebbyView* handle) { return handle->view->frame_width(); }
int webby_view_frame_height(WebbyView* handle) { return handle->view->frame_height(); }

uint64_t webby_view_state_serial(WebbyView* handle) { return handle->view->state_serial(); }
char const* webby_view_url(WebbyView* handle) { return handle->view->url_string().characters(); }
char const* webby_view_title(WebbyView* handle) { return handle->view->title_string().characters(); }
char const* webby_view_hovered_link(WebbyView* handle) { return handle->view->hovered_link().characters(); }
int webby_view_is_loading(WebbyView* handle) { return handle->view->loading() ? 1 : 0; }
int webby_view_can_go_back(WebbyView* handle) { return handle->view->can_go_back() ? 1 : 0; }
int webby_view_can_go_forward(WebbyView* handle) { return handle->view->can_go_forward() ? 1 : 0; }
int webby_view_cursor(WebbyView* handle) { return handle->view->cursor(); }

char const* webby_view_webauthn_prompt(WebbyView* handle) { return handle->view->webauthn_prompt().characters(); }

void webby_view_webauthn_respond(WebbyView* handle, int accepted, int account_index)
{
    handle->view->respond_to_webauthn(accepted != 0, account_index);
}

char const* webby_view_file_picker_request(WebbyView* handle) { return handle->view->file_picker_request().characters(); }

void webby_view_file_picker_respond(WebbyView* handle, char const* paths_json)
{
    Vector<ByteString> paths;
    if (paths_json) {
        auto parsed = JsonValue::from_string(StringView { paths_json, strlen(paths_json) });
        if (!parsed.is_error() && parsed.value().is_array()) {
            parsed.value().as_array().for_each([&](JsonValue const& value) {
                if (value.is_string())
                    paths.append(value.as_string().to_byte_string());
            });
        }
    }
    handle->view->respond_to_file_picker(paths);
}

void webby_view_set_message_prefix(WebbyView* handle, char const* prefix)
{
    handle->view->set_message_prefix(ByteString { prefix, strlen(prefix) });
}

char const* webby_view_next_message(WebbyView* handle) { return handle->view->take_message().characters(); }

uint64_t webby_clipboard_serial(void) { return s_application ? s_application->clipboard_serial() : 0; }

char const* webby_clipboard_text(void)
{
    static ByteString text;
    text = s_application ? s_application->clipboard_text().to_utf8().to_byte_string() : ByteString {};
    return text.characters();
}

void webby_clipboard_set_text(char const* text)
{
    if (!s_application)
        return;
    auto string = String::from_utf8(StringView { text, strlen(text) });
    if (!string.is_error())
        s_application->set_clipboard_from_system(string.release_value());
}

void webby_clear_site_data(char const* url)
{
    if (!s_application)
        return;
    auto parsed = URL::Parser::basic_parse(StringView { url, strlen(url) });
    if (parsed.has_value())
        s_application->clear_site_data(parsed->origin());
}

void webby_clear_browsing_data(int64_t since_ms, int what)
{
    if (!s_application)
        return;
    using Delete = WebView::Application::ClearBrowsingDataOptions::Delete;
    WebView::Application::ClearBrowsingDataOptions options;
    options.since = UnixDateTime::from_milliseconds_since_epoch(since_ms);
    options.delete_cached_files = (what & WEBBY_BROWSING_DATA_CACHE) ? Delete::Yes : Delete::No;
    options.delete_history = (what & WEBBY_BROWSING_DATA_HISTORY) ? Delete::Yes : Delete::No;
    options.delete_site_data = (what & WEBBY_BROWSING_DATA_SITE_DATA) ? Delete::Yes : Delete::No;
    (void)s_application->clear_browsing_data(options);
}

char const* webby_view_permission_request(WebbyView* handle) { return handle->view->permission_request().characters(); }

void webby_view_permission_respond(WebbyView* handle, uint64_t id, int granted)
{
    handle->view->respond_to_permission(id, granted != 0);
}

int webby_geolocation_wanted(void)
{
    auto* provider = Webby::GeolocationProvider::the();
    return provider ? provider->wanted() : 0;
}

static Optional<double> optional_coordinate(double value)
{
    if (__builtin_isnan(value))
        return {};
    return value;
}

void webby_geolocation_set_position(double latitude, double longitude, double accuracy, double altitude, double altitude_accuracy, double heading, double speed)
{
    auto* provider = Webby::GeolocationProvider::the();
    if (!provider)
        return;
    provider->did_update_position({
        .latitude = latitude,
        .longitude = longitude,
        .accuracy = accuracy,
        .altitude = optional_coordinate(altitude),
        .altitude_accuracy = optional_coordinate(altitude_accuracy),
        .heading = optional_coordinate(heading),
        .speed = optional_coordinate(speed),
    });
}

void webby_geolocation_set_error(int code, char const* message)
{
    auto* provider = Webby::GeolocationProvider::the();
    if (!provider)
        return;
    auto type = Core::GeolocationError::Type::PositionUnavailable;
    if (code == WEBBY_GEOLOCATION_ERROR_PERMISSION_DENIED)
        type = Core::GeolocationError::Type::PermissionDenied;
    else if (code == WEBBY_GEOLOCATION_ERROR_TIMEOUT)
        type = Core::GeolocationError::Type::Timeout;
    auto text = String::from_utf8(message ? StringView { message, strlen(message) } : ""sv);
    provider->did_error({ type, text.is_error() ? String {} : text.release_value() });
}

char const* webby_view_ime_state(WebbyView* handle) { return handle->view->input_method_state_json().characters(); }

void webby_view_ime_commit(WebbyView* handle, char const* text, int replacement_start, int replacement_length)
{
    auto string = Utf16String::from_utf8_with_replacement_character(StringView { text, strlen(text) });
    handle->view->commit_text_from_input_method(string, replacement_start, replacement_length);
}

void webby_view_ime_set_marked(WebbyView* handle, char const* text)
{
    handle->view->set_marked_text_from_input_method(Utf16String::from_utf8_with_replacement_character(StringView { text, strlen(text) }));
}

static Webby::VaultCredentialStore* s_vault_store;

void webby_set_offline(int offline)
{
    if (!s_application || !WebView::Application::has_request_server_control_client())
        return;
    WebView::Application::request_server_control_client().async_set_offline_mode(offline != 0);
}

int webby_passkeys_use_vault(char const* json)
{
    auto parsed = JsonValue::from_string(StringView { json, strlen(json) });
    if (parsed.is_error() || !parsed.value().is_array())
        return -1;
    auto passkeys = Webby::passkeys_from_json(parsed.value().as_array());
    // Bring over passkeys the vault doesn't have yet, such as ones still in the old file.
    for (auto& passkey : Webby::credential_store().all()) {
        if (!passkeys.find_if([&](auto const& existing) { return existing.credential_id == passkey.credential_id; }).is_end())
            continue;
        passkeys.append(move(passkey));
    }
    auto store = make<Webby::VaultCredentialStore>(move(passkeys));
    s_vault_store = store.ptr();
    Webby::set_credential_store(move(store));
    return 0;
}

uint64_t webby_passkeys_serial(void) { return s_vault_store ? s_vault_store->serial() : 0; }

char const* webby_passkeys_export(void)
{
    static ByteString exported;
    exported = Webby::passkeys_to_json(Webby::credential_store().all()).serialized().to_byte_string();
    return exported.characters();
}

int webby_passkeys_remove(char const* credential_id)
{
    return Webby::credential_store().remove(StringView { credential_id, strlen(credential_id) }).is_error() ? -1 : 0;
}

int webby_passkeys_delete_file(void)
{
    if (!s_vault_store)
        return -1;
    auto path = Webby::passkeys_file_path();
    if (unlink(path.characters()) < 0 && errno != ENOENT)
        return -1;
    return 0;
}

void webby_view_mouse_event(WebbyView* handle, int type, int x, int y, int button, int buttons, int modifiers, int click_count)
{
    Web::MouseEvent::Type event_type;
    switch (type) {
    case WEBBY_MOUSE_DOWN:
        event_type = Web::MouseEvent::Type::MouseDown;
        break;
    case WEBBY_MOUSE_UP:
        event_type = Web::MouseEvent::Type::MouseUp;
        break;
    case WEBBY_MOUSE_LEAVE:
        event_type = Web::MouseEvent::Type::MouseLeave;
        break;
    default:
        event_type = Web::MouseEvent::Type::MouseMove;
        break;
    }

    Web::DevicePixelPoint position { x, y };
    handle->view->enqueue_input_event(Web::MouseEvent {
        .type = event_type,
        .position = position,
        .screen_position = position,
        .button = static_cast<Web::UIEvents::MouseButton>(button),
        .buttons = static_cast<Web::UIEvents::MouseButton>(buttons),
        .modifiers = to_modifiers(modifiers),
        .click_count = click_count,
        .browser_data = nullptr,
    });
}

void webby_view_wheel_event(WebbyView* handle, int x, int y, double delta_x, double delta_y, int precise, int modifiers)
{
    Web::DevicePixelPoint position { x, y };
    handle->view->enqueue_input_event(Web::MouseEvent {
        .type = Web::MouseEvent::Type::MouseWheel,
        .position = position,
        .screen_position = position,
        .modifiers = to_modifiers(modifiers),
        .wheel_delta_x = delta_x,
        .wheel_delta_y = delta_y,
        .wheel_delta_precision = precise ? Web::WheelDeltaPrecision::Precise : Web::WheelDeltaPrecision::Discrete,
        .browser_data = nullptr,
    });
}

void webby_view_key_event(WebbyView* handle, int is_down, int key_code, int modifiers, uint32_t code_point, int repeat)
{
    auto type = is_down ? Web::KeyEvent::Type::KeyDown : Web::KeyEvent::Type::KeyUp;
    handle->view->enqueue_input_event(Web::KeyEvent {
        .type = type,
        .key = static_cast<Web::UIEvents::KeyCode>(key_code),
        .modifiers = to_modifiers(modifiers),
        .code_point = code_point,
        .repeat = repeat != 0,
        .should_insert_text = is_down && code_point != 0,
        .browser_data = nullptr,
    });
}

}
