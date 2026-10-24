/*
 * Webby: C ABI over LibWebView for dart:ffi.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <AK/JsonArray.h>
#include <AK/JsonObject.h>
#include <AK/JsonValue.h>
#include <AK/LexicalPath.h>
#include <AK/Utf16String.h>
#include <AK/Vector.h>
#include <LibCore/EventLoop.h>
#include <LibCore/EventLoopImplementationUnix.h>
#include <LibGfx/SystemTheme.h>
#include <LibMain/Main.h>
#include <LibWebCommon/CSS/PreferredColorScheme.h>
#include <LibWebCommon/Page/InputEvent.h>
#include <LibRequests/RequestControlClient.h>
#include <LibURL/Parser.h>
#include <LibWebView/Application.h>
#include <LibWebView/Menu.h>
#include <LibWebView/RequestServerManager.h>
#include <LibWebView/Utilities.h>
#include <WebbyGeolocation.h>
#include <WebbyView.h>
#include <webby_ffi.h>

#include <condition_variable>
#include <errno.h>
#include <fcntl.h>
#include <mutex>
#include <poll.h>
#include <stdlib.h>
#include <sys/eventfd.h>
#include <thread>
#include <unistd.h>

struct WebbyView {
    NonnullOwnPtr<Webby::View> view;
};

// Deliberately leaked: destroying it from exit()'s static destructors runs after the event loop is gone, and
// ~Process -> did_lose_process -> deferred_invoke then VERIFY-crashes (SIGILL core dump on every quit).
static Webby::Application* s_application;
static Optional<Core::AnonymousBuffer> s_theme;
static Webby::DownloadsObserver* s_downloads_observer;

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

    // Ladybird has mimalloc purge freed memory with MADV_FREE, which Linux keeps counting as resident until it runs
    // short: a busy page's WebContent then holds on to hundreds of MB it no longer uses. Decommit (MADV_DONTNEED)
    // instead, in the helper processes this starts (patches/0016 lets the variable through); a value already in the
    // environment wins.
    setenv("MIMALLOC_PURGE_DECOMMITS", "1", 0);

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
    s_downloads_observer = new Webby::DownloadsObserver;
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

// webby_wake_fd(): the front end pumps from a timer, so a page waiting on a synchronous request to the UI process
// (localStorage, document.cookie = ...) used to wait for the next tick, 4-100 ms, for every single call. A watcher
// thread polls what the UI event loop would wait on (patches/0030) and signals an eventfd the front end watches.
namespace {

struct Waker {
    int event_fd { -1 };
    int control_pipe[2] { -1, -1 }; // a new wait set interrupts the watcher's poll
    std::mutex mutex;
    std::condition_variable armed_changed;
    bool armed { false };
    u64 generation { 0 };
    Vector<int> fds;
    int timeout_ms { -1 };
};

Waker* s_waker;

void watch_for_work(Waker& waker)
{
    Vector<pollfd> poll_fds;
    for (;;) {
        u64 generation;
        int timeout_ms;
        {
            std::unique_lock lock(waker.mutex);
            waker.armed_changed.wait(lock, [&] { return waker.armed; });
            generation = waker.generation;
            timeout_ms = waker.timeout_ms;
            poll_fds.clear_with_capacity();
            poll_fds.append({ .fd = waker.control_pipe[0], .events = POLLIN, .revents = 0 });
            for (int fd : waker.fds)
                poll_fds.append({ .fd = fd, .events = POLLIN, .revents = 0 });
        }
        int marked = ::poll(poll_fds.data(), poll_fds.size(), timeout_ms);
        if (marked < 0 && errno != EINTR)
            marked = 1; // a closed fd, say: let the pump sort it out, it re-arms with the current set
        if (marked < 0)
            continue;
        if (poll_fds[0].revents & POLLIN) {
            char buf[64];
            while (::read(waker.control_pipe[0], buf, sizeof(buf)) > 0) { }
            continue; // re-armed with a newer set
        }
        std::lock_guard lock(waker.mutex);
        if (!waker.armed || waker.generation != generation)
            continue;
        waker.armed = false;
        u64 one = 1;
        (void)!::write(waker.event_fd, &one, sizeof(one));
    }
}

void arm_waker()
{
    auto& waker = *s_waker;
    Vector<int> fds;
    int timeout_ms = Core::EventLoopManagerUnix::current_thread_wait_set(fds);
    {
        std::lock_guard lock(waker.mutex);
        waker.fds = move(fds);
        waker.timeout_ms = timeout_ms;
        waker.armed = true;
        ++waker.generation;
    }
    waker.armed_changed.notify_one();
    char byte = 0;
    (void)!::write(waker.control_pipe[1], &byte, 1);
}

}

int webby_pump(void)
{
    if (!s_application)
        return 0;
    auto events = static_cast<int>(Core::EventLoop::current().pump(Core::EventLoop::WaitMode::PollForEvents));
    if (s_waker)
        arm_waker();
    return events;
}

int webby_wake_fd(void)
{
    if (!s_application)
        return -1;
    if (s_waker)
        return s_waker->event_fd;
    auto* waker = new Waker;
    waker->event_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (waker->event_fd < 0 || pipe2(waker->control_pipe, O_CLOEXEC | O_NONBLOCK) < 0) {
        if (waker->event_fd >= 0)
            close(waker->event_fd);
        delete waker;
        return -1;
    }
    // Deliberately leaked, like s_application: the thread runs until the process exits.
    s_waker = waker;
    std::thread([waker] { watch_for_work(*waker); }).detach();
    arm_waker();
    return waker->event_fd;
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

void webby_view_collect_garbage(WebbyView* handle)
{
    handle->view->debug_request("collect-garbage");
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

void webby_view_find(WebbyView* handle, char const* query, int case_sensitive)
{
    auto string = Utf16String::from_utf8_with_replacement_character(StringView { query, strlen(query) });
    if (string.is_empty())
        handle->view->reset_find_result();
    handle->view->find_in_page(string, case_sensitive ? CaseSensitivity::CaseSensitive : CaseSensitivity::CaseInsensitive, true);
}

void webby_view_find_next(WebbyView* handle) { handle->view->find_in_page_next_match(); }
void webby_view_find_previous(WebbyView* handle) { handle->view->find_in_page_previous_match(); }

void webby_view_find_end(WebbyView* handle)
{
    handle->view->find_in_page_end();
    handle->view->reset_find_result();
}

int webby_view_find_current(WebbyView* handle) { return handle->view->find_current(); }
int webby_view_find_total(WebbyView* handle) { return handle->view->find_total(); }

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

void webby_downloads_set_directory(char const* path)
{
    setenv("XDG_DOWNLOAD_DIR", path, 1);
}

uint64_t webby_downloads_serial(void) { return s_downloads_observer ? s_downloads_observer->serial() : 0; }

static StringView download_status_name(WebView::FileDownloader::DownloadStatus status)
{
    switch (status) {
    case WebView::FileDownloader::DownloadStatus::InProgress:
        return "in_progress"sv;
    case WebView::FileDownloader::DownloadStatus::Paused:
        return "paused"sv;
    case WebView::FileDownloader::DownloadStatus::Completed:
        return "completed"sv;
    case WebView::FileDownloader::DownloadStatus::Canceled:
        return "canceled"sv;
    case WebView::FileDownloader::DownloadStatus::Failed:
        return "failed"sv;
    }
    VERIFY_NOT_REACHED();
}

char const* webby_downloads_json(void)
{
    static ByteString json;
    JsonArray array;
    if (s_application) {
        for (auto const& download : s_application->file_downloader().downloads()) {
            JsonObject object;
            object.set("id"sv, download.id);
            object.set("url"sv, download.url.serialize());
            object.set("path"sv, download.destination.string().view());
            object.set("status"sv, download_status_name(download.status));
            object.set("received"sv, download.downloaded_size);
            object.set("total"sv, download.total_size.has_value() ? static_cast<i64>(*download.total_size) : -1);
            object.set("rate"sv, download.bytes_per_second.has_value() ? static_cast<i64>(*download.bytes_per_second) : -1);
            auto remaining = download.estimated_time_remaining();
            object.set("remaining"sv, remaining.has_value() ? remaining->to_seconds() : -1);
            object.set("error"sv, download.error.value_or(String {}));
            object.set("canResume"sv, download.can_resume);
            object.set("private"sv, download.is_private == WebView::IsPrivate::Yes);
            object.set("created"sv, download.created_time.milliseconds_since_epoch());
            array.must_append(move(object));
        }
    }
    json = array.serialized().to_byte_string();
    return json.characters();
}

uint64_t webby_downloads_start(char const* url, int is_private)
{
    if (!s_application)
        return 0;
    auto parsed = URL::Parser::basic_parse(StringView { url, strlen(url) });
    if (!parsed.has_value())
        return 0;
    // URLs with an opaque path (data:) have no usable filename; Ladybird then picks a default one.
    auto filename = parsed->has_an_opaque_path() ? ByteString {} : parsed->basename();
    auto destination = s_application->default_path_for_downloaded_file(filename);
    if (destination.is_error())
        return 0;
    return s_application->file_downloader().download_file(is_private ? WebView::IsPrivate::Yes : WebView::IsPrivate::No, *parsed, destination.release_value());
}

void webby_downloads_cancel(uint64_t id)
{
    if (s_application)
        s_application->file_downloader().cancel_download(id);
}

void webby_downloads_pause(uint64_t id)
{
    if (s_application)
        s_application->file_downloader().pause_download(id);
}

void webby_downloads_resume(uint64_t id)
{
    if (s_application)
        s_application->file_downloader().resume_download(id);
}

void webby_downloads_clear(void)
{
    if (s_application)
        (void)s_application->file_downloader().prune_inactive_downloads(WebView::IsPrivate::No);
}

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

void webby_clipboard_set_image(char const* mime, uint8_t const* data, size_t size)
{
    if (!s_application || !data)
        return;
    auto name = String::from_utf8(StringView { mime, strlen(mime) });
    if (!name.is_error())
        s_application->set_clipboard_image_from_system(name.release_value(), ByteString { ReadonlyBytes { data, size } });
}

char const* webby_view_dialog(WebbyView* handle) { return handle->view->dialog().characters(); }

void webby_view_dialog_respond(WebbyView* handle, uint64_t id, int accepted, char const* text)
{
    Optional<Utf16String> response;
    if (text)
        response = Utf16String::from_utf8_with_replacement_character(StringView { text, strlen(text) });
    handle->view->respond_to_dialog(id, accepted != 0, move(response));
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

void webby_set_content_blocking(int enabled)
{
    if (!s_application)
        return;
    auto& settings = WebView::Application::settings();
    if (enabled) {
        settings.set_content_blocker_list_enabled("easyList"sv, true);
        settings.set_content_blocker_list_enabled("easyPrivacy"sv, true);
    }
    settings.set_content_blocker_enabled(enabled != 0);
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
    if (!s_application)
        return;
    // Every RequestServer running now. With top-level site isolation on, one launched later for a new site starts
    // online; the front ends turn site isolation off, so there is only the browser's.
    WebView::Application::request_server_manager().for_each_instance([&](auto& instance) {
        instance.control_client().async_set_offline_mode(offline != 0);
        return IterationDecision::Continue;
    });
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
