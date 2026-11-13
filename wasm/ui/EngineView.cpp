/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "EngineView.h"
#include "WebAuthn.h"
#include "LocalWebGL.h"
#include "LocalMedia.h"
#include "Network.h"
#include "Resources.h"
#include "Storage.h"
#include <Authenticator.h>

#include <AK/JsonArray.h>
#include <AK/JsonObject.h>
#include <AK/JsonValue.h>
#include <AK/StringBuilder.h>
#include <AK/Time.h>
#include <AK/AnyOf.h>
#include <AK/LexicalPath.h>
#include <AK/Random.h>
#include <AK/Utf16String.h>
#include <Compositor/DisplayListPlayerSkia.h>
#include <Compositor/CanvasSurfaceRegistry.h>
#include <Compositor/DisplayListRasterCache.h>
#include <Compositor/PaintingSurface.h>
#include <Compositor/SkiaBackendContext.h>
#include <LibCompositing/DisplayList/DisplayListDamage.h>
#include <LibCompositing/DisplayList/DisplayListResourceStorage.h>
#include <LibCompositing/Scrolling/AsyncScrollingState.h>
#include <LibCore/ConfigFile.h>
#include <LibCore/EventLoop.h>
#include <LibCore/File.h>
#include <LibCore/MimeData.h>
#include <LibCore/ResourceImplementation.h>
#include <LibCore/ResourceImplementationFile.h>
#include <LibCore/System.h>
#include <LibCore/Timer.h>
#include <LibFileSystem/FileSystem.h>
#include <LibGC/MemoryPressure.h>
#include <LibGC/Root.h>
#include <LibGfx/Bitmap.h>
#include <LibGfx/Font/FontDatabase.h>
#include <LibGfx/Font/PathFontProvider.h>
#include <LibGfx/Font/Typeface.h>
#include <LibGfx/Palette.h>
#include <LibGfx/SystemTheme.h>
#include <LibAudio/OutputSession.h>
#include <LibMedia/Sinks/AudioOutputFactory.h>
#include <LibMediaClient/RemotePlaybackManager.h>
#include <LibTextCodec/Decoder.h>
#include <LibURL/Parser.h>
#include <LibWeb/Bindings/MainThreadVM.h>
#include <LibWeb/DOM/Document.h>
#include <LibWeb/DOM/DocumentObserver.h>
#include <LibWeb/DOM/Element.h>
#include <LibWeb/HTML/Scripting/TemporaryExecutionContext.h>
#include <LibWeb/HTML/BrowsingContext.h>
#include <LibWeb/HTML/WorkerDebugConsoleClient.h>
#include <LibJS/Runtime/ConsoleObject.h>
#include <LibWeb/HTML/CustomElements/CustomElementRegistry.h>
#include <LibWeb/HTML/DocumentState.h>
#include <LibWeb/HTML/EventLoop/EventLoop.h>
#include <LibWeb/Fetch/Infrastructure/HTTP/MIME.h>
#include <LibWeb/HTML/HTMLImageElement.h>
#include <LibWeb/HTML/HTMLInputElement.h>
#include <LibWeb/HTML/HTMLTextAreaElement.h>
#include <LibWeb/HTML/Scripting/ClassicScript.h>
#include <LibWeb/HTML/Scripting/Environments.h>
#include <LibWeb/HTML/LocalNavigable.h>
#include <LibWeb/HTML/LocalTraversableNavigable.h>
#include <LibWeb/HTML/Navigation.h>
#include <LibWeb/HTML/SessionHistoryEntry.h>
#include <LibWeb/HTML/Parser/HTMLEncodingDetection.h>
#include <LibWeb/HTML/Parser/HTMLParser.h>
#include <LibWeb/HTML/Parser/HTMLTokenizer.h>
#include <LibWeb/HTML/Window.h>
#include <LibWeb/HighResolutionTime/TimeOrigin.h>
#include <LibWeb/Layout/RenderDocument.h>
#include <LibWeb/Loader/FileRequest.h>
#include <LibWeb/Loader/ResourceLoader.h>
#include <LibWeb/Page/Page.h>
#include <LibWeb/Painting/DocumentPaintState.h>
#include <LibWeb/Layout/Viewport.h>
#include <LibWeb/Painting/Scrolling.h>
#include <LibWeb/Platform/EventLoopPlugin.h>
#include <LibWeb/Platform/FontPlugin.h>
#include <LibWebCommon/Clipboard/SystemClipboard.h>
#include <LibWebCommon/MimeSniff/MimeType.h>
#include <LibWebCommon/HTML/PreparedNavigationDescriptor.h>
#include <LibWebCommon/Page/ContextMenuForInputEventsTarget.h>
#include <LibWebCommon/Page/NavigationTarget.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <core/SkCanvas.h>
#include <core/SkRegion.h>
#include <math.h>

namespace WebbyUI {

namespace {

std::string to_std(ByteString const& s) { return std::string(s.characters(), s.length()); }

// The desktop's light or dark, for pages' prefers-color-scheme (EngineView::set_color_scheme).
bool s_prefers_dark = false;
// Live views, so that a color scheme change reaches every page.
std::vector<WebbyUI::EngineView*> s_views;

// The start page, and the page a load shows when it cannot fetch what it was asked for.
constexpr char start_page_html[] = R"html(<!doctype html>
<html><head><title>New Tab</title><meta name="color-scheme" content="light dark"><style>
body { font-family: sans-serif; margin: 0; background: #f4f1ea; color: #222; }
main { max-width: 640px; margin: 80px auto; padding: 0 24px; }
h1 { color: #2d5a88; font-size: 40px; margin-bottom: 8px; }
p { line-height: 1.5; }
code { background: #e8e2d6; padding: 1px 4px; border-radius: 4px; }
@media (prefers-color-scheme: dark) {
body { background: #1f1e1b; color: #e6e1d6; }
h1 { color: #8ab4f8; }
code { background: #3a362f; }
}
</style></head><body><main>
<h1>webby</h1>
<p>This browser runs entirely in WebAssembly: Ladybird's LibWeb lays out and paints the page, and the window around it
is Qt, in the same module.</p>
<p>Type a web address or a <code>file://</code> path in the address bar to open a page.</p>
</main></body></html>)html";

ByteString error_page_html(StringView url, StringView reason)
{
    auto escape = [](StringView s) {
        return s.replace("&"sv, "&amp;"sv, ReplaceMode::All).replace("<"sv, "&lt;"sv, ReplaceMode::All);
    };
    return ByteString::formatted(R"html(<!doctype html><html><head><title>Can't open this page</title><meta name="color-scheme" content="light dark"><style>
body {{ font-family: sans-serif; margin: 0; background: #f6f6f6; color: #333; }}
@media (prefers-color-scheme: dark) {{ body {{ background: #202124; color: #e8eaed; }} }}
main {{ max-width: 640px; margin: 80px auto; padding: 0 24px; }}
h1 {{ font-size: 28px; }} code {{ word-break: break-all; }}
</style></head><body><main><h1>Can't open this page</h1><p><code>{}</code></p><p>{}</p></main></body></html>)html",
        escape(url), escape(reason));
}

}

class BrowserPageClient final : public Web::PageClient {
    GC_CELL(BrowserPageClient, Web::PageClient);
    GC_DECLARE_ALLOCATOR(BrowserPageClient);

public:
    static GC::Ref<BrowserPageClient> create(EngineView& view, Gfx::IntSize viewport, NonnullRefPtr<Gfx::PaletteImpl> palette_impl)
    {
        return GC::Heap::the().allocate<BrowserPageClient>(view, viewport, move(palette_impl));
    }

    void set_page(Web::Page& page) { m_page = &page; }
    void set_viewport(Gfx::IntSize size) { m_viewport = size; }
    void set_zoom(double zoom) { m_zoom = zoom; }
    void detach() { m_view = nullptr; }

    virtual Web::PageId id() const override { return 1; }
    virtual Web::Page& page() override { return *m_page; }
    virtual Web::Page const& page() const override { return *m_page; }
    // Page::did_request_alert/confirm/prompt end the process when this is false (WebContent's "client disconnected").
    virtual bool is_connection_open() const override { return true; }
    virtual Gfx::Palette palette() const override { return Gfx::Palette { *m_palette_impl }; }
    virtual Web::DevicePixelRect screen_rect() const override { return { { 0, 0 }, m_viewport.to_type<Web::DevicePixels>() }; }
    // Page zoom (Ctrl +/-): the viewport's device pixels stay the window's, its CSS pixels grow or shrink.
    virtual double zoom_level() const override { return m_zoom; }
    virtual double device_pixel_ratio() const override { return 1.0; }
    virtual double device_pixels_per_css_pixel() const override { return m_zoom; }
    virtual Web::CSS::PreferredColorScheme preferred_color_scheme() const override { return s_prefers_dark ? Web::CSS::PreferredColorScheme::Dark : Web::CSS::PreferredColorScheme::Light; }
    virtual Web::CSS::PreferredContrast preferred_contrast() const override { return Web::CSS::PreferredContrast::NoPreference; }
    virtual Web::CSS::PreferredMotion preferred_motion() const override { return Web::CSS::PreferredMotion::NoPreference; }
    virtual size_t screen_count() const override { return 1; }
    virtual Queue<Web::QueuedInputEvent>& input_event_queue() override { return m_input_event_queue; }
    virtual void report_finished_handling_input_event(Web::PageId, u64, Web::EventResult) override { }
    virtual bool is_headless() const override { return false; }
    // One module holds every navigable, so one id namespace covers them.
    virtual Web::HTML::CrossProcessId allocate_cross_process_id() override { return m_cross_process_ids.allocate(); }

    virtual void request_frame() override
    {
        if (m_view)
            m_view->did_request_frame();
        schedule_rendering_opportunity();
    }

    // The engine's rendering update (animation frame callbacks, canvases presenting, observers) runs on a rendering
    // opportunity, which Ladybird's Compositor hands out at vsync. There is none here: a frame request gives one
    // after a frame's time, at most 60 a second, so requestAnimationFrame animations (WebGL demos) run.
    void schedule_rendering_opportunity()
    {
        if (!m_rendering_timer) {
            m_rendering_timer = Core::Timer::create_single_shot(AK::Duration::from_milliseconds(16), [] {
                Web::HTML::main_thread_event_loop().rendering_opportunity(Web::HighResolutionTime::unsafe_shared_current_time(),
                    Web::HTML::EventLoop::RenderingOpportunitySource::LocalTimer);
            });
        }
        if (!m_rendering_timer->is_active())
            m_rendering_timer->start();
    }

    virtual void page_did_change_title(Utf16String const& title) override
    {
        if (m_view)
            m_view->did_change_title(to_std(title.to_utf8().to_byte_string()));
    }

    virtual void page_did_finish_loading(Web::HTML::CrossProcessId, Web::HTML::CrossProcessId) override
    {
        if (m_view)
            m_view->did_finish_loading();
    }

    virtual void page_did_hover_link(URL::URL const& url) override
    {
        if (m_view)
            m_view->did_hover_link(to_std(url.serialize().to_byte_string()));
    }

    virtual void page_did_unhover_link() override
    {
        if (m_view)
            m_view->did_hover_link({});
    }

    // Copy and cut (keys, the context menu, document.execCommand, navigator.clipboard.write*): the host clipboard
    // holds text only, so the item's text/plain representation goes there.
    virtual void page_did_insert_clipboard_item(Web::Clipboard::SystemClipboardItem const& item, StringView) override
    {
        if (!m_view)
            return;
        for (auto const& representation : item.system_clipboard_representations) {
            if (representation.name != "text/plain"sv || !representation.data.has<ByteString>())
                continue;
            m_view->did_write_clipboard(to_std(representation.data.get<ByteString>()), false);
            return;
        }
    }

    // Paste (keys, navigator.clipboard.read*): the UI answers with the host clipboard's text (answer_clipboard).
    // Requests are numbered: even ones are the page's, odd ones a middle click's primary-selection paste.
    virtual void page_did_request_clipboard_entries(u64 request_id) override
    {
        if (m_view)
            m_view->did_request_clipboard(request_id << 1, false);
    }

    // X11's primary selection: a middle click in an editable pastes it.
    virtual void page_did_request_primary_paste() override
    {
        if (m_view)
            m_view->did_request_clipboard((m_next_primary_paste++ << 1) | 1, true);
    }

    virtual void page_did_update_primary_selection(Utf16String const& text) override
    {
        if (m_view)
            m_view->did_write_clipboard(to_std(text.to_utf8().to_byte_string()), true);
    }

    // Right-click (the page did not cancel its contextmenu event): what was hit goes to the chrome's menu.
    virtual void page_did_request_context_menu(Web::HTML::CrossProcessId, Web::CSSPixelPoint position, Web::ContextMenuForInputEventsTarget input_target, Optional<Utf16String>, GC::Ptr<Web::DOM::Range>) override
    {
        auto menu = context_menu_at(position);
        menu.editable = input_target == Web::ContextMenuForInputEventsTarget::Yes;
        // The click's mousedown focuses a text field only after this, so look at what was hit as well.
        if (auto request = m_page->take_context_menu_request(); request.has_value()) {
            auto& target = *request->target;
            if (auto* input = as_if<Web::HTML::HTMLInputElement>(target)) {
                using Type = Web::HTML::HTMLInputElement::TypeAttributeState;
                if (input->is_single_line() || input->type_state() == Type::URL)
                    menu.editable = true;
                // A password's text is not offered for copying.
                if (input->type_state() == Type::Password)
                    menu.selection.clear();
            } else if (is<Web::HTML::HTMLTextAreaElement>(target) || target.is_editable_or_editing_host()) {
                menu.editable = true;
            }
        }
        send_context_menu(move(menu));
    }

    virtual void page_did_request_link_context_menu(Web::HTML::CrossProcessId, Web::CSSPixelPoint position, Web::HTML::PreparedNavigationDescriptor navigation, ByteString const&, unsigned, GC::Ptr<Web::DOM::Range>) override
    {
        auto menu = context_menu_at(position);
        menu.link = to_std(navigation.url.serialize().to_byte_string());
        if (auto request = m_page->take_context_menu_request(); request.has_value())
            menu.link_text = to_std(request->target->descendant_text_content().to_utf8().to_byte_string());
        // A linked image: the image's rows too.
        if (auto* image = image_under(position))
            menu.image = *image;
        send_context_menu(move(menu));
    }

    virtual void page_did_request_image_context_menu(Web::HTML::CrossProcessId, Web::CSSPixelPoint position, Web::HTML::PreparedNavigationDescriptor navigation, ByteString const&, unsigned, Optional<Gfx::Bitmap const*>) override
    {
        auto menu = context_menu_at(position);
        menu.image = to_std(navigation.url.serialize().to_byte_string());
        send_context_menu(move(menu));
    }

    virtual void page_did_request_media_context_menu(Web::HTML::CrossProcessId, Web::CSSPixelPoint position, ByteString const&, unsigned, Web::Page::MediaContextMenu const&, Optional<Web::HTML::PreparedNavigationDescriptor>) override
    {
        send_context_menu(context_menu_at(position));
    }

    // Dialogs. The browser's page scripts send their messages as prompt(prefix + text) (patches/0040 marks the ones from
    // a page whose CSP sandbox forbids dialogs): those are answered at once and handed to the UI after this task.
    // The UI has no dialogs for pages yet, so alert() returns, confirm() is false and prompt() null, straight away.
    virtual void page_did_request_alert(Utf16String const&) override { m_page->alert_closed(); }
    virtual void page_did_request_confirm(Utf16String const&) override { m_page->confirm_closed(false); }
    virtual void page_did_request_prompt(Utf16String const& message, Utf16String const&) override
    {
        auto text = message.to_utf8().to_byte_string();
        if (text.starts_with("\x01webby-sandboxed\x01"sv))
            text = text.substring(strlen("\x01webby-sandboxed\x01"));
        m_page->prompt_closed({});
        if (!m_view || m_view->message_prefix().empty() || !text.starts_with(StringView { m_view->message_prefix().data(), m_view->message_prefix().size() }))
            return;
        // The view may be gone by then (its tab closed): the client, kept alive, knows.
        std::string document_url;
        if (m_page->has_local_traversable()) {
            if (auto document = m_page->local_traversable()->active_document())
                document_url = to_std(document->url().serialize().to_byte_string());
        }
        Core::deferred_invoke([client = GC::make_root(*this), message = to_std(text.substring(m_view->message_prefix().size())), document_url = move(document_url)]() mutable {
            if (client->m_view)
                client->m_view->did_send_page_message(move(message), move(document_url));
        });
    }

    // navigator.credentials.create/get with publicKey (patches/0002): the view asks the UI, which answers later.
    virtual void page_did_request_webauthn(u64 request_id, String const& request) override
    {
        if (!m_view) {
            m_page->webauthn_response(request_id, Webby::error_reply("NotAllowedError"sv, "The page is gone"sv));
            return;
        }
        m_view->did_request_webauthn(request_id, to_std(request.to_byte_string()));
    }

    // <video>/<audio> and AudioContext, played by the MediaServer and AudioServer in this module (LocalMedia.cpp) as
    // playback group 1. Without them (a build with no threads for media) a media element gets a playback manager
    // without a server, which reports MEDIA_ERR and fires "error", and Web Audio renders into a null output that drops
    // samples at device pace.
    virtual NonnullOwnPtr<MediaClient::RemotePlaybackManager> create_media_playback_manager() override
    {
        return MediaClient::RemotePlaybackManager::create(Audio::PlaybackGroupId { 1 });
    }
    virtual void rebind_media_playback_manager(MediaClient::RemotePlaybackManager& playback_manager) override
    {
        playback_manager.set_audio_group(Audio::PlaybackGroupId { 1 });
    }
    virtual NonnullRefPtr<Media::AudioOutputFactory> create_audio_output_factory() override
    {
        if (!LocalMedia::is_available())
            return Media::AudioOutputFactory::create_null();
        return Media::AudioOutputFactory::create(Audio::OutputSession::create(Audio::PlaybackGroupId { 1 }));
    }

    // The page's own loads of file: URLs (style sheets, images, scripts) open the file right here.
    virtual void request_file(Web::FileRequest request) override
    {
        auto fd = Core::System::open(request.path(), O_RDONLY | O_CLOEXEC);
        request.on_file_request_finish(move(fd));
    }

    // A link, a form or a script navigates the top-level page: the view loads the new URL as a new document. Frames
    // inside the page do not navigate yet.
    virtual void request_navigation_start(Web::HTML::LocalNavigable& navigable, Web::NavigationTarget target, URL::URL const& url, Utf16String, Optional<Web::HTML::NavigationStartRequest>) override
    {
        if (!m_view || target != Web::NavigationTarget::TopLevel || !navigable.is_top_level_traversable())
            return;
        m_view->did_request_navigation(to_std(url.serialize().to_byte_string()));
    }

private:
    WebbyUI::ContextMenu context_menu_at(Web::CSSPixelPoint position)
    {
        WebbyUI::ContextMenu menu;
        menu.x = position.x().to_int();
        menu.y = position.y().to_int();
        if (auto navigable = m_page->hosted_focused_navigable())
            menu.selection = to_std(navigable->selected_text().to_utf8().to_byte_string());
        return menu;
    }

    // The <img> at `position` in the top-level document, if any (Ladybird reports a linked image as a link).
    std::string const* image_under(Web::CSSPixelPoint position)
    {
        m_image_under.clear();
        if (!m_page->has_local_traversable())
            return nullptr;
        auto document = m_page->local_traversable()->active_document();
        if (!document)
            return nullptr;
        for (GC::Ptr<Web::DOM::Element const> element = document->element_from_point(position.x().to_double(), position.y().to_double()); element; element = element->parent_element()) {
            if (auto const* image = as_if<Web::HTML::HTMLImageElement>(*element)) {
                if (auto url = image->document().encoding_parse_url(image->current_src()); url.has_value())
                    m_image_under = to_std(url->serialize().to_byte_string());
                break;
            }
            if (element->is_html_anchor_element())
                break;
        }
        return m_image_under.empty() ? nullptr : &m_image_under;
    }

    void send_context_menu(WebbyUI::ContextMenu menu)
    {
        if (!m_view)
            return;
        // After the input event, as a menu from the UI process would open.
        Core::deferred_invoke([view = m_view, menu = move(menu)]() mutable { view->did_request_context_menu(move(menu)); });
    }

    std::string m_image_under;

    BrowserPageClient(EngineView& view, Gfx::IntSize viewport, NonnullRefPtr<Gfx::PaletteImpl> palette_impl)
        : m_view(&view)
        , m_viewport(viewport)
        , m_palette_impl(move(palette_impl))
    {
    }

    virtual void visit_edges(Visitor& visitor) override
    {
        Base::visit_edges(visitor);
        visitor.visit(m_page);
    }

    EngineView* m_view { nullptr };
    GC::Ptr<Web::Page> m_page;
    Gfx::IntSize m_viewport;
    double m_zoom { 1.0 };
    NonnullRefPtr<Gfx::PaletteImpl> m_palette_impl;
    Queue<Web::QueuedInputEvent> m_input_event_queue;
    u64 m_next_primary_paste { 0 };
    Web::HTML::CrossProcessIdAllocator m_cross_process_ids { .namespace_id = 1 };
    RefPtr<Core::Timer> m_rendering_timer;
};

GC_DEFINE_ALLOCATOR(BrowserPageClient);

struct EngineView::Impl {
    GC::Root<BrowserPageClient> client;
    GC::Root<Web::Page> page;
    GC::Root<Web::DOM::Document> document;
    GC::Root<Web::DOM::DocumentObserver> observer;
    RefPtr<Gfx::Bitmap> bitmap;
    RefPtr<Core::Timer> render_block_timer;
    // The Web Authentication request waiting for the user (see did_request_webauthn).
    WebAuthnFlow webauthn;
    // What `bitmap` shows, so that the next frame repaints only what changed (and moves the pixels of a scroll).
    struct RasterizedFrame {
        NonnullRefPtr<Compositing::DisplayList> display_list;
        Compositing::AccumulatedVisualContextTree visual_context_tree;
        Compositing::ScrollStateSnapshot scroll_state;
        Web::DOM::Document const* document;
    };
    Optional<RasterizedFrame> last_frame;
    Compositor::DisplayListRasterCache raster_cache;
    // The scrollbars of the last recorded display list, which Ladybird's Compositor process presents, hovers and drags
    // (ScrollbarController). Here the view takes their pointer input and the chrome draws the viewport's (scrollbars()).
    struct Scrollbars {
        Vector<Compositing::AsyncScrollbar> bars;
        Vector<Compositing::AsyncScrollNode> nodes;
        Optional<Compositing::AccumulatedVisualContextTree> visual_context_tree;
        Compositing::ScrollStateSnapshot scroll_state;
        float device_pixels_per_css_pixel { 1 };
        Optional<size_t> hovered;
        struct Drag {
            size_t index { 0 };
            float grab { 0 }; // where on the (expanded) thumb it was taken, along the bar
        };
        Optional<Drag> drag;
    } scrollbars;
};

namespace {

Core::EventLoop* s_event_loop;
RefPtr<Gfx::PaletteImpl> s_palette;

// The theme: Base/res's file when the host opens one to the module, else the one built in.
static ErrorOr<Core::AnonymousBuffer> load_theme(StringView resources)
{
    auto path = ByteString::formatted("{}/themes/Default.ini", resources);
    if (FileSystem::exists(path))
        return Gfx::load_system_theme(path);
    auto config = TRY(Core::ConfigFile::open_from_text("Default.ini", { reinterpret_cast<char const*>(webby_builtin_theme.data), webby_builtin_theme.size }));
    return Gfx::load_system_theme(*config);
}

ErrorOr<void> initialize_engine()
{
    if (s_event_loop)
        return {};
    s_event_loop = new Core::EventLoop;
    Web::Platform::EventLoopPlugin::install(*new Web::Platform::EventLoopPlugin);
    // Ladybird's Base/res: the theme, and resources pages name with resource:// URLs.
    StringView resources = getenv("WEBBY_RESOURCES") ? StringView { getenv("WEBBY_RESOURCES"), strlen(getenv("WEBBY_RESOURCES")) } : "/res"sv;
    Core::ResourceImplementation::install(make<Core::ResourceImplementationFile>(MUST(String::from_utf8(resources))));
    Web::Bindings::initialize_main_thread_vm(Web::HTML::AgentType::SimilarOriginWindow);
    Web::ResourceLoader::initialize(Web::Bindings::main_thread_vm().heap());
    // localStorage and sessionStorage: LibWeb's mirrors need an owner, which is the browser process natively.
    Storage::initialize();
    // WebGL on the host's GPU, when the host has latha:gui's gl (wasm/gl).
    WebbyUI::install_local_webgl();
    // Fonts: the built-in Liberation faces, so there are always some (a host with no /usr/share/fonts, such as NixOS,
    // or nothing opened to the module), then whatever the system font directories hold.
    auto& font_provider = static_cast<Gfx::PathFontProvider&>(Gfx::FontDatabase::the().install_system_font_provider(make<Gfx::PathFontProvider>()));
    for (size_t i = 0; i < webby_builtin_font_count; ++i) {
        auto const& font = webby_builtin_fonts[i];
        auto typeface = Gfx::Typeface::try_load_from_temporary_memory({ font.data, font.size });
        if (typeface.is_error()) {
            warnln("webby: built-in font {}: {}", font.name, typeface.error());
            continue;
        }
        font_provider.add_typeface(typeface.release_value());
    }
    Web::Platform::FontPlugin::install(*new Web::Platform::FontPlugin(false, &font_provider));
    s_palette = Gfx::PaletteImpl::create_with_anonymous_buffer(TRY(load_theme(resources)));
    // http(s) pages and their subresources go through RequestServer, in this module. Without it, file: pages still open.
    if (auto result = Network::initialize(); result.is_error())
        warnln("webby: the network could not start: {}", result.error());
    // <video>, <audio> and Web Audio: MediaServer and AudioServer, in this module. Without them media fails to load.
    if (auto result = LocalMedia::initialize(); result.is_error())
        warnln("webby: media could not start: {}", result.error());
    LocalMedia::set_new_frame_handler([] {
        for (auto* view : s_views)
            view->did_request_frame();
    });
    return {};
}

}

void EngineView::initialize_for_chrome()
{
    if (s_event_loop)
        return;
    s_event_loop = new Core::EventLoop;
    Web::Platform::EventLoopPlugin::install(*new Web::Platform::EventLoopPlugin);
    Web::Bindings::initialize_main_thread_vm(Web::HTML::AgentType::SimilarOriginWindow);
    Web::ResourceLoader::initialize(Web::Bindings::main_thread_vm().heap());
    if (auto result = Network::initialize(); result.is_error())
        warnln("webby: the network could not start: {}", result.error());
}

void EngineView::pump()
{
    if (s_event_loop)
        s_event_loop->pump(Core::EventLoop::WaitMode::PollForEvents);
}

std::unique_ptr<EngineView> EngineView::create(int width, int height)
{
    if (auto result = initialize_engine(); result.is_error()) {
        warnln("webby: the engine could not start: {}", result.error());
        return nullptr;
    }
    return std::unique_ptr<EngineView>(new EngineView(width, height));
}

EngineView::EngineView(int width, int height)
    : m_impl(std::make_unique<Impl>())
    , m_width(max(width, 1))
    , m_height(max(height, 1))
{
    // As the Nim front end's randomPrefix: page scripts cannot guess another view's.
    static constexpr char chars[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    m_message_prefix = "webby-msg-";
    for (int i = 0; i < 16; ++i)
        m_message_prefix += chars[get_random_uniform(sizeof(chars) - 1)];
    m_message_prefix += ':';
    s_views.push_back(this);
}

EngineView::MemoryPressure EngineView::take_memory_pressure()
{
    static size_t s_reserve_releases = 0;
    MemoryPressure result;
    result.pressure = GC::take_memory_pressure();
    auto releases = GC::memory_stats().reserve_releases;
    result.critical = releases != s_reserve_releases;
    s_reserve_releases = releases;
    // Most of the memory is malloc's, not the GC's (13 tabs: 300 MiB of GC chunks in 3 GiB), and linear memory never
    // shrinks: what is freed is used again before memory grows. So memory that still grows once it is past
    // s_pressure_bytes means the pages awake need more than is left, and some of them should be put away.
    static constexpr u64 s_pressure_bytes = 2816ull * MiB;
    static u64 s_last_linear = 0;
    auto linear = static_cast<u64>(__builtin_wasm_memory_size(0)) * 64 * KiB;
    if (linear > s_last_linear && linear >= s_pressure_bytes)
        result.pressure = true;
    s_last_linear = linear;
    result.pressure = result.pressure || result.critical;
    return result;
}

void EngineView::collect_garbage()
{
    if (!s_event_loop)
        return;
    Web::Bindings::main_thread_vm().heap().collect_garbage();
}

std::string EngineView::memory_report()
{
    auto stats = GC::memory_stats();
    auto mib = [](u64 bytes) { return bytes / MiB; };
    auto line = ByteString::formatted("memory: linear {} MiB, GC chunks {} MiB (spare {} MiB, free blocks {} MiB), reserve released {}x, {} views",
        mib(stats.linear_memory_bytes), mib(stats.chunk_bytes), mib(stats.spare_chunk_bytes), mib(stats.free_block_bytes),
        stats.reserve_releases, s_views.size());
    return std::string(line.characters(), line.length());
}

void EngineView::set_color_scheme(bool dark)
{
    if (dark == s_prefers_dark)
        return;
    s_prefers_dark = dark;
    for (auto* view : s_views) {
        if (view->m_impl->page)
            view->m_impl->page->invalidate_style_for_preference_change();
    }
}

EngineView::~EngineView()
{
    std::erase(s_views, this);
    if (m_fetch_id)
        Network::cancel(m_fetch_id);
    m_impl->webauthn.cancel();
    if (m_impl->client)
        m_impl->client->detach();
    // A tab closing may be the app quitting: localStorage is otherwise written half a second after a change.
    Storage::flush();
}

void EngineView::load(std::string const& url)
{
    navigate(url, true);
}

void EngineView::reload()
{
    if (!m_url.empty())
        navigate(m_url, false);
}

bool EngineView::can_go_back() const { return m_history_index > 0; }
bool EngineView::can_go_forward() const { return m_history_index + 1 < m_history.size(); }

void EngineView::go_back()
{
    if (!can_go_back())
        return;
    --m_history_index;
    navigate(m_history[m_history_index], false);
}

void EngineView::go_forward()
{
    if (!can_go_forward())
        return;
    ++m_history_index;
    navigate(m_history[m_history_index], false);
}

struct LoadedDocument {
    URL::URL url;
    ByteBuffer html;
    Optional<Web::MimeSniff::MimeType> mime_type;
};

// Downloads. A response is saved rather than shown when its Content-Disposition says attachment, or its type is one
// the engine has no way to show (not HTML, XML, text, an image, JSON or JavaScript), as Ladybird's navigation does.

static bool is_attachment(Network::Document const& document)
{
    if (!document.content_disposition.has_value())
        return false;
    auto disposition = document.content_disposition->view().trim_whitespace();
    return disposition.starts_with("attachment"sv, CaseSensitivity::CaseInsensitive);
}

static bool is_download(Network::Document const& document, Optional<Web::MimeSniff::MimeType> const& type)
{
    if (is_attachment(document))
        return true;
    if (!type.has_value())
        return false;
    auto essence = type->essence();
    if (type->is_html() || type->is_xml() || type->is_image() || type->is_javascript() || type->is_json())
        return false;
    if (essence.bytes_as_string_view().starts_with("text/"sv))
        return false;
    return true;
}

static ByteString download_dir()
{
    for (auto const* name : { "WEBBY_DOWNLOAD_DIR", "XDG_DOWNLOAD_DIR" }) {
        if (auto const* value = getenv(name); value && *value)
            return ByteString { value };
    }
    auto const* home = getenv("HOME");
    return ByteString::formatted("{}/Downloads", home && *home ? home : "/tmp");
}

// The file name: Content-Disposition's filename* (RFC 5987, UTF-8'') or filename, else the URL's last path segment.
static ByteString download_name(Network::Document const& document)
{
    ByteString name;
    if (document.content_disposition.has_value()) {
        auto value = document.content_disposition->view();
        for (auto part : value.split_view(';')) {
            part = part.trim_whitespace();
            if (part.starts_with("filename*="sv, CaseSensitivity::CaseInsensitive)) {
                auto v = part.substring_view(10).trim("\""sv);
                if (auto quote = v.find("''"sv); quote.has_value())
                    v = v.substring_view(*quote + 2);
                name = URL::percent_decode(v);
                break;
            }
            if (part.starts_with("filename="sv, CaseSensitivity::CaseInsensitive))
                name = ByteString { part.substring_view(9).trim("\" "sv) };
        }
    }
    if (name.is_empty()) {
        auto path = URL::percent_decode(document.url.serialize_path());
        if (auto slash = path.find_last('/'); slash.has_value())
            path = path.substring(*slash + 1);
        name = path;
    }
    // No folders, no hidden or empty names.
    name = name.replace("/"sv, "_"sv, ReplaceMode::All).replace("\\"sv, "_"sv, ReplaceMode::All);
    while (name.starts_with('.'))
        name = name.substring(1);
    if (name.is_empty())
        name = "download";
    return name;
}

static bool make_dirs(ByteString const& path)
{
    for (size_t i = 1; i <= path.length(); ++i) {
        if (i == path.length() || path[i] == '/') {
            auto prefix = path.substring(0, i);
            if (mkdir(prefix.characters(), 0755) < 0 && errno != EEXIST)
                return false;
        }
    }
    return true;
}

static Download save_download(Network::Document const& document, Optional<Web::MimeSniff::MimeType> const& type)
{
    Download download;
    download.url = to_std(document.url.serialize().to_byte_string());
    download.size = document.body.size();
    if (type.has_value())
        download.mime = to_std(type->essence().to_byte_string());
    auto dir = download_dir();
    if (!make_dirs(dir)) {
        download.error = to_std(ByteString::formatted("cannot make {}: {}", dir, strerror(errno)));
        return download;
    }
    auto name = download_name(document);
    // "name.ext", then "name (1).ext", "name (2).ext", ... so nothing is overwritten.
    auto stem = name;
    ByteString ext;
    if (auto dot = name.find_last('.'); dot.has_value() && *dot > 0) {
        stem = name.substring(0, *dot);
        ext = name.substring(*dot);
    }
    for (int i = 0; i < 1000; ++i) {
        auto path = i == 0 ? ByteString::formatted("{}/{}", dir, name) : ByteString::formatted("{}/{} ({}){}", dir, stem, i, ext);
        int fd = open(path.characters(), O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd < 0) {
            if (errno == EEXIST)
                continue;
            download.error = to_std(ByteString::formatted("cannot write {}: {}", path, strerror(errno)));
            return download;
        }
        auto bytes = document.body.bytes();
        size_t written = 0;
        while (written < bytes.size()) {
            auto n = write(fd, bytes.data() + written, bytes.size() - written);
            if (n <= 0)
                break;
            written += size_t(n);
        }
        close(fd);
        if (written != bytes.size()) {
            download.error = to_std(ByteString::formatted("cannot write {}: {}", path, strerror(errno)));
            unlink(path.characters());
            return download;
        }
        download.path = to_std(path);
        return download;
    }
    download.error = "too many files with that name";
    return download;
}

// PDFs are shown by the chrome's PDF viewer (wasm/ui/PdfView.cpp, MuPDF in the webby-pdf component), as the Nim
// front end shows them with MuPDF rather than Ladybird's pdf.js viewer: application/pdf, or a file that starts as
// one where the server gives no type or a generic one.
static bool is_pdf(Optional<Web::MimeSniff::MimeType> const& type, ReadonlyBytes body)
{
    if (type.has_value() && type->essence() == "application/pdf"sv)
        return true;
    bool generic = !type.has_value() || type->essence() == "application/octet-stream"sv
        || type->essence() == "binary/octet-stream"sv || type->essence() == "application/x-pdf"sv;
    return generic && body.size() >= 5 && memcmp(body.data(), "%PDF-", 5) == 0;
}

// The page under the PDF viewer: empty, the viewer's grey, titled with the file's name (the viewer names the tab
// after the document's own title once it has it).
void EngineView::show_pdf(LoadedDocument loaded)
{
    auto const& url = loaded.url;
    auto const& body = loaded.html;
    auto path = URL::percent_decode(url.serialize_path());
    if (auto slash = path.find_last('/'); slash.has_value())
        path = path.substring(*slash + 1);
    if (path.is_empty())
        path = "PDF";
    auto name = path.replace("&"sv, "&amp;"sv, ReplaceMode::All).replace("<"sv, "&lt;"sv, ReplaceMode::All);
    auto html = ByteString::formatted("<!doctype html><meta charset=utf-8><title>{}</title><style>html{{background:#525659}}</style>", name);
    PdfDocument pdf;
    pdf.url = to_std(url.serialize().to_byte_string());
    pdf.mime = "application/pdf";
    pdf.data.assign(body.data(), body.data() + body.size());
    show_document({ url, MUST(ByteBuffer::copy(html.bytes())), {} });
    did_receive_pdf(move(pdf));
}

void EngineView::did_receive_pdf(PdfDocument pdf)
{
    if (on_pdf)
        on_pdf(pdf);
}

// A load makes a new Page with a new top-level traversable, and parses the document into it directly, in this module
// (the document a navigation would have made, as webby-render and SVGDecodedImageData make theirs).
void EngineView::navigate(std::string const& requested_url, bool add_to_history)
{
    auto input = StringView { requested_url.data(), requested_url.size() }.trim_whitespace();
    Optional<URL::URL> url;
    if (input.is_empty() || input == "about:blank"sv || input == "webby:start"sv)
        url = URL::Parser::basic_parse("about:blank"sv);
    else if (input.starts_with('/'))
        url = URL::create_with_file_scheme(input);
    else
        url = URL::Parser::basic_parse(input);
    if (!url.has_value() && !input.contains("://"sv))
        url = URL::Parser::basic_parse(ByteString::formatted("https://{}", input));

    if (m_fetch_id) {
        Network::cancel(m_fetch_id);
        m_fetch_id = 0;
    }

    ByteString html;
    Optional<ByteBuffer> file_body;
    Optional<Web::MimeSniff::MimeType> file_type;
    URL::URL document_url = url.has_value() ? *url : URL::Parser::basic_parse("about:blank"sv).value();
    if (!url.has_value()) {
        html = error_page_html(input, "This is not a URL."sv);
    } else if (url->scheme() == "about"sv) {
        html = start_page_html;
    } else if (url->scheme() == "file"sv) {
        auto path = URL::percent_decode(url->serialize_path());
        auto file = Core::File::open(path, Core::File::OpenMode::Read);
        auto contents = file.is_error() ? ErrorOr<ByteBuffer> { file.release_error() } : file.value()->read_until_eof();
        if (contents.is_error())
            html = error_page_html(url->serialize(), ByteString::formatted("{}", contents.error()));
        else if (FileSystem::is_directory(path))
            html = error_page_html(url->serialize(), "This is a folder."sv);
        else {
            // A file's type comes from its name, as Ladybird's file: loads do (a .txt shows as text, not as HTML).
            file_type = Web::MimeSniff::MimeType::parse(Core::guess_mime_type_based_on_filename(path));
            file_body = contents.release_value();
        }
    } else if (url->scheme() == "http"sv || url->scheme() == "https"sv) {
        // The old page stays up while the document downloads; the new one replaces it when it arrives.
        auto previous_url = m_url;
        auto previous_history = m_history;
        auto previous_index = m_history_index;
        set_location(to_std(url->serialize().to_byte_string()), add_to_history);
        m_fetch_id = Network::fetch_document(*url, [this, requested = *url, previous_url = move(previous_url), previous_history = move(previous_history), previous_index](ErrorOr<Network::Document> result) mutable {
            m_fetch_id = 0;
            if (result.is_error()) {
                auto html = error_page_html(requested.serialize(), ByteString::formatted("{}", result.error()));
                show_document({ requested, MUST(ByteBuffer::copy(html.bytes())), {} });
                return;
            }
            auto document = result.release_value();
            Optional<Web::MimeSniff::MimeType> mime_type;
            if (document.content_type.has_value())
                mime_type = Web::MimeSniff::MimeType::parse(*document.content_type);
            if (!is_attachment(document) && is_pdf(mime_type, document.body.bytes())) {
                if (document.url != requested) {
                    m_url = to_std(document.url.serialize().to_byte_string());
                    if (m_history_index < m_history.size())
                        m_history[m_history_index] = m_url;
                    if (on_url_change)
                        on_url_change(m_url);
                }
                show_pdf({ document.url, move(document.body), move(mime_type) });
                return;
            }
            if (is_download(document, mime_type)) {
                // Saved, not shown: the page, the address and the history stay as they were.
                m_url = move(previous_url);
                m_history = move(previous_history);
                m_history_index = previous_index;
                if (on_url_change)
                    on_url_change(m_url);
                did_finish_loading();
                did_download(save_download(document, mime_type));
                return;
            }
            if (document.url != requested) {
                // After a redirect the address bar and history show where the page came from.
                m_url = to_std(document.url.serialize().to_byte_string());
                if (m_history_index < m_history.size())
                    m_history[m_history_index] = m_url;
                if (on_url_change)
                    on_url_change(m_url);
            }
            show_document({ document.url, move(document.body), move(mime_type) });
        });
        return;
    } else {
        html = error_page_html(url->serialize(), ByteString::formatted("webby cannot open {}: URLs yet.", url->scheme()));
    }

    set_location(to_std(document_url.serialize().to_byte_string()), add_to_history);
    if (url.has_value() && url->scheme() == "about"sv) {
        m_url = "";
        if (add_to_history)
            m_history[m_history_index] = m_url;
        if (on_url_change)
            on_url_change(m_url);
    }
    if (file_body.has_value() && is_pdf(file_type, file_body->bytes()))
        show_pdf({ document_url, file_body.release_value(), move(file_type) });
    else if (file_body.has_value())
        show_document({ document_url, file_body.release_value(), move(file_type) });
    else
        show_document({ document_url, MUST(ByteBuffer::copy(html.bytes())), {} });
}

void EngineView::did_download(Download download)
{
    if (on_download)
        on_download(download);
}

void EngineView::set_location(std::string url, bool add_to_history)
{
    m_url = move(url);
    if (add_to_history) {
        if (!m_history.empty())
            m_history.resize(m_history_index + 1);
        m_history.push_back(m_url);
        m_history_index = m_history.size() - 1;
    }
    m_loading = true;
    if (on_url_change)
        on_url_change(m_url);
    if (on_loading_change)
        on_loading_change(true);
}

// The types a navigation loads as a text document (HTML's "load a text document"): shown as they are in a <pre>.
static bool is_text_document_type(Web::MimeSniff::MimeType const& type)
{
    return type.is_javascript() || type.is_json() || type.essence() == "text/css"sv || type.essence() == "text/plain"sv
        || type.essence() == "text/vtt"sv;
}

// What DocumentLoading.cpp's load_text_document does with a navigation's body: the parser is fed "<pre>\n", then the
// body decoded as one run of text in the PLAINTEXT state, so none of it is markup and its line breaks stay.
static void parse_text_document(Web::DOM::Document& document, ByteBuffer const& body, Web::MimeSniff::MimeType const& type, URL::URL const& url)
{
    document.set_parser_cannot_change_the_mode(true);
    document.set_quirks_mode(Web::DOM::QuirksMode::No);

    // JSON is UTF-8 unless a BOM or the charset parameter says otherwise; other text sniffs as HTML does.
    ByteString encoding;
    if (type.is_json())
        encoding = Web::HTML::run_bom_sniff(body).value_or(Web::Fetch::Infrastructure::legacy_extract_an_encoding(type, "UTF-8"sv));
    else
        encoding = Web::HTML::run_encoding_sniffing_algorithm(document, body, type).encoding;
    auto decoder = TextCodec::decoder_for(encoding);
    if (!decoder.has_value())
        decoder = TextCodec::decoder_for("UTF-8"sv);

    auto parser = Web::HTML::HTMLParser::create_with_open_input_stream(document);
    parser->tokenizer().update_insertion_point();
    parser->tokenizer().insert_input_at_insertion_point(u"<pre>\n"sv);
    parser->run();
    parser->tokenizer().switch_to(Web::HTML::HTMLTokenizer::State::PLAINTEXT);
    auto decoded = TextCodec::decode_to_utf16(body, *decoder).release_value_but_fixme_should_propagate_errors();
    parser->tokenizer().insert_input_at_insertion_point(decoded);
    parser->tokenizer().insert_eof();
    parser->run(url);
    document.set_encoding(Utf16String::from_ascii_without_validation(encoding.bytes()));
}

// An image opened on its own: a page that shows it, as Ladybird's media documents do.
static ByteString image_document_html(URL::URL const& url)
{
    auto src = url.serialize().to_byte_string().replace("&"sv, "&amp;"sv, ReplaceMode::All).replace("\""sv, "&quot;"sv, ReplaceMode::All);
    return ByteString::formatted(R"html(<!doctype html><html><head><meta name="color-scheme" content="light dark"></head>
<body style="margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #0e0e0e">
<img src="{}" style="max-width: 100%; max-height: 100vh; display: block; margin: auto"></body></html>)html",
        src);
}

// The document's bytes are decoded as for a navigation: Content-Type's charset, a BOM or a <meta charset>, else UTF-8.
// Text types (text/plain, JSON, JavaScript, CSS) are shown as text and images on a page of their own, as a navigation
// would load them; everything else is parsed as HTML.
static void attach_debug_console(Web::DOM::Document&);

void EngineView::show_document(LoadedDocument loaded)
{
    auto const& document_url = loaded.url;
    bool as_text = loaded.mime_type.has_value() && is_text_document_type(*loaded.mime_type);
    if (loaded.mime_type.has_value() && loaded.mime_type->is_image()) {
        auto html = image_document_html(document_url);
        loaded.html = MUST(ByteBuffer::copy(html.bytes()));
        loaded.mime_type = Web::MimeSniff::MimeType::parse("text/html"sv);
    }
    if (m_impl->client)
        m_impl->client->detach();

    Gfx::IntSize viewport { m_width, m_height };
    auto client = BrowserPageClient::create(*this, viewport, *s_palette);
    client->set_zoom(m_zoom);
    auto page = Web::Page::create(*client);
    client->set_page(*page);
    // A hidden document gets no rendering updates (no requestAnimationFrame callbacks), and document.hidden is true.
    page->set_system_visibility_state(m_visible ? Web::HTML::VisibilityState::Visible : Web::HTML::VisibilityState::Hidden);
    page->set_top_level_traversable(Web::HTML::LocalTraversableNavigable::create_a_new_top_level_traversable(page, nullptr, {}));
    auto& navigable = *page->local_traversable();
    auto& window = *navigable.active_window();
    navigable.set_viewport_size(page->device_to_css_size(viewport.to_type<Web::DevicePixels>()));

    auto document = Web::DOM::Document::create(*page, window, document_url);
    document->set_id(client->allocate_cross_process_id());
    document->set_origin(document_url.origin());
    // The window's settings object still describes the initial about:blank: its top-level origin is what WebAuthn
    // (and blob URL checks) compare against, and an opaque one made every page a "cross-origin frame".
    {
        auto& settings = Web::HTML::relevant_settings_object(window);
        settings.creation_url = document_url;
        settings.top_level_creation_url = document_url;
        settings.top_level_origin = document_url.origin();
    }
    // As a navigation's "create and initialize a Document object" does: the document is visible when its page is.
    document->set_initial_visibility_state(page->system_visibility_state());
    // What a navigation's "create and initialize a Document object" also gives it: customElements reads the registry
    // (and traps without one), and the parser reads the declarative shadow root flag.
    document->set_allow_declarative_shadow_roots(Web::HTML::HTMLParser::AllowDeclarativeShadowRoots::Yes);
    document->set_custom_element_registry(Web::HTML::CustomElementRegistry::create_global(*document));
    document->set_document_type(Web::DOM::Document::Type::HTML);
    document->set_content_type(as_text ? Utf16FlyString::from_utf8(loaded.mime_type->essence()) : "text/html"_utf16_fly_string);
    document->set_browsing_context(navigable.active_browsing_context());
    document->set_window(window);
    window.set_associated_document(*document);
    navigable.set_active_document(*document);
    // The browsing context keeps its own active document, which Location and the cross-origin checks read: without
    // this it stays the initial about:blank, whose opaque origin matches no page (every location access threw).
    navigable.active_browsing_context()->set_active_document(*document);
    document->set_ready_to_run_scripts();

    // The session history entry and the Navigation API's entries, as activating a navigated-to document sets them:
    // the traversable's one entry still names the initial about:blank, and with no Navigation API entries
    // history.pushState/replaceState trapped (Navigation.cpp's current entry index VERIFY).
    if (auto entry = navigable.active_session_history_entry()) {
        entry->set_url(document_url);
        if (auto state = entry->document_state())
            state->set_origin(document_url.origin());
        Vector<NonnullRefPtr<Web::HTML::SessionHistoryEntry>> entries { *entry };
        window.navigation()->initialize_the_navigation_api_entries_for_reconstructed_session_history(entries, *entry);
    }

    auto observer = Web::DOM::DocumentObserver::create(*document);
    observer->set_document_completely_loaded([this] { did_finish_loading(); });

    if (m_impl->render_block_timer)
        m_impl->render_block_timer->stop();
    m_impl->render_block_timer = nullptr;
    m_impl->client = client;
    m_impl->page = page;
    m_impl->document = document;
    m_impl->observer = observer;
    attach_debug_console(*document);

    m_title.clear();
    if (on_link_hover)
        on_link_hover({});

    run_page_scripts();

    if (as_text) {
        parse_text_document(*document, loaded.html, *loaded.mime_type, document_url);
    } else {
        auto parser = Web::HTML::HTMLParser::create_with_uncertain_encoding(*document, loaded.html, loaded.mime_type);
        parser->run(document_url);
    }
    did_request_frame();
}

void EngineView::set_visible(bool visible)
{
    if (m_visible == visible)
        return;
    m_visible = visible;
    auto state = visible ? Web::HTML::VisibilityState::Visible : Web::HTML::VisibilityState::Hidden;
    if (!m_impl->page)
        return;
    m_impl->page->set_system_visibility_state(state);
    if (!m_impl->page->has_local_traversable())
        return;
    auto document = m_impl->page->local_traversable()->active_document();
    if (!document)
        return;
    // As WebContent's update_visibility_state: a task updates the document's visibility state, which fires
    // visibilitychange and starts or stops its rendering updates.
    Web::HTML::queue_global_task(Web::HTML::Task::Source::UserInteraction, Web::HTML::relevant_global_object(*document),
        GC::create_function(GC::Heap::the(), [state, document = GC::Root<Web::DOM::Document>(*document)] {
            document->update_the_visibility_state(state);
        }));
    if (visible)
        m_needs_paint = true;
}

void EngineView::resize(int width, int height)
{
    width = max(width, 1);
    height = max(height, 1);
    if (width == m_width && height == m_height)
        return;
    m_width = width;
    m_height = height;
    if (m_impl->client)
        m_impl->client->set_viewport({ width, height });
    if (m_impl->page && m_impl->page->has_local_traversable())
        m_impl->page->local_traversable()->set_viewport_size(m_impl->page->device_to_css_size(Gfx::IntSize { width, height }.to_type<Web::DevicePixels>()));
    did_request_frame();
}

static void fill_white(Gfx::Bitmap& bitmap)
{
    memset(bitmap.scanline_u8(0), 0xff, bitmap.size_in_bytes());
}

// Compositor::rasterize_display_list with the page's scroll offsets: in Ladybird the Compositor process owns them (it
// scrolls by wheel events itself); here the document's own snapshot is the truth. `damage`: repaint only that (the
// rest of `target` already shows the list), else everything.
static ErrorOr<void> rasterize(Compositing::DisplayList const& display_list, Compositing::AccumulatedVisualContextTree const& visual_context_tree,
    Compositing::ScrollStateSnapshot const& scroll_state, Compositing::DisplayListResourceStorage const& resource_storage,
    Compositor::DisplayListRasterCache& raster_cache, Gfx::Bitmap& target, Vector<Gfx::IntRect> const* damage = nullptr)
{
    auto surface = Gfx::PaintingSurface::wrap_bitmap(target);
    auto& canvas = surface->canvas();
    Compositor::DisplayListPlayerSkia player { RefPtr<Gfx::SkiaBackendContext> {} };
    auto play = [&] {
        player.execute(display_list, visual_context_tree, resource_storage, raster_cache, scroll_state, surface, WebbyUI::local_canvas_surfaces(), nullptr);
    };
    if (!damage) {
        __builtin_memset(target.scanline_u8(0), 0xff, target.size_in_bytes());
        play();
        player.flush(*surface);
        return {};
    }
    // One pass per area apart from the others, not one pass clipped to all of them: a layer (opacity, a filter, a
    // blend) is as big as the clip's bounds, and the strip a scroll uncovers plus the rows along the other edge span the
    // whole frame, so all of a page drawn in a layer was drawn again on every scroll step.
    Vector<Gfx::IntRect> areas;
    for (auto const& rect : *damage)
        areas.append(rect);
    for (bool merged = true; merged;) {
        merged = false;
        for (size_t i = 0; i < areas.size() && !merged; ++i) {
            for (size_t j = i + 1; j < areas.size(); ++j) {
                auto both = areas[i].united(areas[j]);
                auto apart = static_cast<i64>(areas[i].width()) * areas[i].height() + static_cast<i64>(areas[j].width()) * areas[j].height();
                if (static_cast<i64>(both.width()) * both.height() <= apart + apart / 4 + 64 * 64) {
                    areas[i] = both;
                    areas.remove(j);
                    merged = true;
                    break;
                }
            }
        }
    }
    // Each pass draws a margin around its area too, and then puts the margin's pixels back: a blur (a filter, a
    // backdrop filter, a shadow) in a layer cut to the pass's clip reads nothing past the clip, so the pixels near the
    // clip's edge come out darker than the whole frame's.
    constexpr int margin = 64;
    Gfx::IntRect const frame { {}, target.size() };
    Vector<u32> saved;
    auto const pitch = target.pitch() / sizeof(u32);
    auto* pixels = reinterpret_cast<u32*>(target.scanline_u8(0));
    for (auto const& area : areas) {
        auto pass = area.inflated(2 * margin, 2 * margin).intersected(frame);
        saved.resize(static_cast<size_t>(pass.width()) * pass.height());
        for (int y = 0; y < pass.height(); ++y)
            __builtin_memcpy(&saved[size_t(y) * pass.width()], pixels + size_t(pass.y() + y) * pitch + pass.x(), size_t(pass.width()) * 4);
        canvas.save();
        canvas.clipRect(SkRect::MakeXYWH(pass.x(), pass.y(), pass.width(), pass.height()));
        // White below the page, as a browser's canvas is: a page with no background of its own is not see-through.
        canvas.clear(SK_ColorWHITE);
        play();
        canvas.restore();
        player.flush(*surface);
        auto put_back = [&](int y, int x0, int x1) {
            if (x1 > x0)
                __builtin_memcpy(pixels + size_t(y) * pitch + x0, &saved[size_t(y - pass.y()) * pass.width() + (x0 - pass.x())], size_t(x1 - x0) * 4);
        };
        for (int y = pass.top(); y < pass.bottom(); ++y) {
            if (y < area.top() || y >= area.bottom()) {
                put_back(y, pass.left(), pass.right());
            } else {
                put_back(y, pass.left(), area.left());
                put_back(y, area.right(), pass.right());
            }
        }
    }
    return {};
}

// Moves the bitmap's rows by `dy` (down when positive); the rows it uncovers keep what they had.
static void move_rows(Gfx::Bitmap& bitmap, int dy)
{
    auto const pitch = bitmap.pitch();
    auto const rows = bitmap.height() - abs(dy);
    if (rows <= 0 || dy == 0)
        return;
    auto* base = bitmap.scanline_u8(0);
    if (dy < 0)
        memmove(base, base + size_t(-dy) * pitch, size_t(rows) * pitch);
    else
        memmove(base + size_t(dy) * pitch, base, size_t(rows) * pitch);
}

// Scrollbars, as Ladybird's Compositor (Services/Compositor/ScrollbarController.cpp) presents and drags them: a bar is
// recorded at scroll offset 0, and its thumb moves by the scroller's device offset times the bar's scroll size.
static Gfx::IntRect scrollbar_thumb(Compositing::AsyncScrollbar const& bar, Compositing::ScrollStateSnapshot const& scroll_state, bool expanded)
{
    auto thumb = expanded ? bar.expanded_thumb_rect : bar.thumb_rect;
    auto scroll_size = expanded ? bar.expanded_scroll_size : bar.scroll_size;
    auto offset = scroll_state.device_offset_for_index(bar.scroll_node_index);
    if (bar.vertical)
        thumb.translate_by(0, static_cast<int>(-offset.y() * scroll_size));
    else
        thumb.translate_by(static_cast<int>(-offset.x() * scroll_size), 0);
    // Past an end of the scroll range (an overscroll) the thumb is cut short at its track's end.
    auto track = expanded && !bar.expanded_gutter_rect.is_empty() ? bar.expanded_gutter_rect : bar.track_rect;
    if (bar.vertical) {
        auto top = max(thumb.top(), track.top());
        auto bottom = min(thumb.bottom(), track.bottom());
        thumb.set_y(top);
        thumb.set_height(max(0, bottom - top));
    } else {
        auto left = max(thumb.left(), track.left());
        auto right = min(thumb.right(), track.right());
        thumb.set_x(left);
        thumb.set_width(max(0, right - left));
    }
    return thumb;
}

static float along(Gfx::FloatPoint point, bool vertical) { return vertical ? point.y() : point.x(); }
static int start_along(Gfx::IntRect const& rect, bool vertical) { return vertical ? rect.y() : rect.x(); }
static int end_along(Gfx::IntRect const& rect, bool vertical) { return vertical ? rect.bottom() : rect.right(); }

// The pointer in the space a bar's rects are in: the viewport's for the viewport's bars, else its context's.
static Optional<Gfx::FloatPoint> point_in_scrollbar_space(EngineView::Impl const& impl, Compositing::AsyncScrollbar const& bar, Gfx::FloatPoint point,
    Compositing::AccumulatedVisualContextTree::ClipBehavior clip = Compositing::AccumulatedVisualContextTree::ClipBehavior::Respect)
{
    if (bar.is_painted_by_compositor)
        return point;
    auto const& tree = impl.scrollbars.visual_context_tree;
    if (!tree.has_value() || !tree->context_is_valid(bar.context))
        return {};
    return tree->transform_point_for_hit_test(bar.context, point, impl.scrollbars.scroll_state, clip);
}

// The bar under the pointer: the last painted of those it is over (Ladybird hit tests them with a few pixels' slop).
static Optional<size_t> scrollbar_at(EngineView::Impl const& impl, Gfx::FloatPoint point)
{
    auto const& state = impl.scrollbars;
    for (size_t i = state.bars.size(); i-- > 0;) {
        auto const& bar = state.bars[i];
        auto position = point_in_scrollbar_space(impl, bar, point);
        if (!position.has_value())
            continue;
        auto rect = scrollbar_thumb(bar, state.scroll_state, false).united(scrollbar_thumb(bar, state.scroll_state, true));
        rect.unite(bar.track_rect);
        if (!bar.expanded_gutter_rect.is_empty())
            rect.unite(bar.expanded_gutter_rect);
        rect.inflate(4, 4);
        if (rect.to_type<float>().contains(*position))
            return i;
    }
    return {};
}

// Scrolls a bar's scroller to `offset` device pixels along the bar (0 at the start of its scroll range).
static void scroll_scrollbar_to(EngineView::Impl& impl, Compositing::AsyncScrollbar const& bar, float offset)
{
    auto const& state = impl.scrollbars;
    offset = clamp(offset, min(bar.min_scroll_offset, bar.max_scroll_offset), max(bar.min_scroll_offset, bar.max_scroll_offset));
    double css = offset / (state.device_pixels_per_css_pixel > 0 ? state.device_pixels_per_css_pixel : 1.0f);
    if (bar.is_painted_by_compositor) {
        if (!impl.document || !impl.document->window())
            return;
        auto& window = *impl.document->window();
        Web::HTML::TemporaryExecutionContext context(Web::HTML::relevant_realm(window));
        if (bar.vertical)
            window.scroll(window.scroll_x(), css, nullptr);
        else
            window.scroll(css, window.scroll_y(), nullptr);
        return;
    }
    for (auto const& node : state.nodes) {
        if (node.scroll_node_index != bar.scroll_node_index)
            continue;
        if (node.stable_node_id.kind != Web::AsyncScrollNodeKind::Element)
            return;
        auto* dom_node = Web::DOM::Node::from_unique_id(node.stable_node_id.node_id);
        if (auto* element = as_if<Web::DOM::Element>(dom_node)) {
            // An element's scroll makes a promise, which needs a realm to run in (none is current outside a task).
            Web::HTML::TemporaryExecutionContext context(Web::HTML::relevant_realm(*element));
            if (bar.vertical)
                element->set_scroll_top(css);
            else
                element->set_scroll_left(css);
        }
        return;
    }
}

static float scrollbar_offset(EngineView::Impl const& impl, Compositing::AsyncScrollbar const& bar)
{
    return -along(impl.scrollbars.scroll_state.device_offset_for_index(bar.scroll_node_index), bar.vertical);
}

// Takes the scrollbars of a newly recorded display list (keeping the hovered and the dragged one where the list still
// has them), and gives the chrome the viewport's as it draws them.
static void update_scrollbars(EngineView::Impl& impl, Compositing::DisplayList const* display_list,
    Compositing::AccumulatedVisualContextTree const* visual_context_tree, Compositing::ScrollStateSnapshot const* scroll_state,
    std::vector<EngineView::Scrollbar>& presented)
{
    auto& state = impl.scrollbars;
    auto identity = [&](Optional<size_t> index) -> Optional<Compositing::AsyncScrollbar> {
        if (!index.has_value() || *index >= state.bars.size())
            return {};
        return state.bars[*index];
    };
    auto find = [&](Optional<Compositing::AsyncScrollbar> const& old) -> Optional<size_t> {
        if (!old.has_value())
            return {};
        for (size_t i = 0; i < state.bars.size(); ++i) {
            if (state.bars[i].scroll_node_index == old->scroll_node_index && state.bars[i].vertical == old->vertical
                && state.bars[i].is_painted_by_compositor == old->is_painted_by_compositor)
                return i;
        }
        return {};
    };
    auto hovered = identity(state.hovered);
    auto dragged = identity(state.drag.has_value() ? Optional<size_t> { state.drag->index } : Optional<size_t> {});
    if (!display_list) {
        state.bars.clear();
        state.nodes.clear();
        state.visual_context_tree.clear();
    } else {
        auto async_state = Compositing::async_scrolling_state_from_display_list(*display_list);
        state.bars = move(async_state.scrollbars);
        state.nodes = move(async_state.scroll_nodes);
        state.device_pixels_per_css_pixel = static_cast<float>(async_state.device_pixels_per_css_pixel);
        state.visual_context_tree = *visual_context_tree;
        state.scroll_state = *scroll_state;
    }
    state.hovered = find(hovered);
    if (auto index = find(dragged); index.has_value())
        state.drag->index = *index;
    else
        state.drag.clear();

    presented.clear();
    for (size_t i = 0; i < state.bars.size(); ++i) {
        auto const& bar = state.bars[i];
        if (!bar.is_painted_by_compositor)
            continue;
        bool expanded = (state.hovered.has_value() && *state.hovered == i) || (state.drag.has_value() && state.drag->index == i);
        auto thumb = scrollbar_thumb(bar, state.scroll_state, expanded);
        auto gutter = expanded && !bar.expanded_gutter_rect.is_empty() ? bar.expanded_gutter_rect : bar.track_rect;
        presented.push_back({
            .vertical = bar.vertical,
            .expanded = expanded,
            .gutter = { gutter.x(), gutter.y(), gutter.width(), gutter.height() },
            .thumb = { thumb.x(), thumb.y(), thumb.width(), thumb.height() },
            .thumb_color = bar.thumb_color.value(),
            .track_color = bar.track_color.value(),
        });
    }
}

// WEBBY_CONSOLE=1: the page's console on stderr (tests read it), as a worker's goes to the debug log.
static void attach_debug_console(Web::DOM::Document& document)
{
    static bool const enabled = [] {
        auto const* value = getenv("WEBBY_CONSOLE");
        return value && *value && strcmp(value, "0") != 0;
    }();
    if (!enabled || document.console_client())
        return;
    auto& console = document.relevant_settings_object().realm().intrinsics().console_object()->console();
    auto client = GC::Heap::the().allocate<Web::HTML::WorkerDebugConsoleClient>(console);
    console.set_client(*client);
    document.set_console_client(client);
}

static bool env_flag(char const* name)
{
    auto const* value = getenv(name);
    return value && *value && strcmp(value, "0") != 0;
}

uint8_t const* EngineView::paint()
{
    if (!m_impl->document)
        return nullptr;
    if (!m_needs_paint && m_impl->bitmap) {
        m_last_change = { .known = true, .moved = 0, .rects = {} };
        return m_impl->bitmap->scanline_u8(0);
    }
    m_needs_paint = false;
    m_last_change = {};

    Gfx::IntSize size { m_width, m_height };
    if (!m_impl->bitmap || m_impl->bitmap->size() != size) {
        auto bitmap = Gfx::Bitmap::create(Gfx::BitmapFormat::BGRA8888, Gfx::AlphaType::Premultiplied, size);
        if (bitmap.is_error())
            return nullptr;
        m_impl->bitmap = bitmap.release_value();
        fill_white(*m_impl->bitmap);
        m_impl->last_frame.clear();
    }

    auto& document = *m_impl->document;
    auto* navigable = document.navigable().ptr();
    if (!navigable)
        return m_impl->bitmap->scanline_u8(0);

    // A render-blocked document (its <head> style sheets and blocking scripts still loading) is not painted, as
    // Ladybird's update-the-rendering skips it: the last frame (the previous page's) stays up, so a page never shows
    // unstyled before its CSS arrives. The last blocking load ending requests a frame; the engine's 30 s cap on
    // blocking does not, so a timer asks again then.
    if (document.is_render_blocked()) {
        m_needs_paint = true;
        if (!m_impl->render_block_timer) {
            m_impl->render_block_timer = Core::Timer::create_single_shot(AK::Duration::from_milliseconds(30100), [this] { did_request_frame(); });
            m_impl->render_block_timer->start();
        }
        return m_impl->bitmap->scanline_u8(0);
    }
    auto& resource_storage = navigable->display_list_resource_storage();

    // Canvases present what they drew (WebGL contexts run their commands and read the frame back), as Ladybird's
    // update-the-rendering does before it records: the display list then draws the presented frames.
    document.page().prepare_canvas_contexts_for_compositing();

    Web::Layout::ForcedReadScope read { document };
    document.update_layout(Web::DOM::UpdateLayoutReason::SVGDecodedImageDataRender);
    // With the overlay phase, as Ladybird's own frames: it paints inner scroll containers' scrollbars and resizers.
    auto display_list = document.record_display_list(read, { .paint_overlay = true }, resource_storage, Web::Painting::PaintCommandCacheMode::ReadWrite);
    if (!display_list) {
        fill_white(*m_impl->bitmap);
        m_impl->last_frame.clear();
        update_scrollbars(*m_impl, nullptr, nullptr, nullptr, m_scrollbars);
        return m_impl->bitmap->scanline_u8(0);
    }
    document.update_paint_and_hit_testing_properties_if_needed();
    auto& paint_state = document.paint_state();
    auto visual_context_tree = paint_state.visual_context_tree(document);
    auto const& scroll_state = paint_state.scroll_state_snapshot();
    update_scrollbars(*m_impl, display_list.ptr(), &visual_context_tree, &scroll_state, m_scrollbars);
    auto transaction = resource_storage.create_self_contained_transaction(*display_list, visual_context_tree);
    Compositing::DisplayListResourceStorage frame_resources;
    if (transaction.is_error()) {
        fill_white(*m_impl->bitmap);
        m_impl->last_frame.clear();
        return m_impl->bitmap->scanline_u8(0);
    }
    frame_resources.apply_transaction(transaction.release_value());
    // The videos it draws, each the frame its sink shows now.
    LocalMedia::resolve_video_sinks(frame_resources);
    if (frame_resources.validate_for_replay(*display_list, visual_context_tree).is_error()) {
        fill_white(*m_impl->bitmap);
        m_impl->last_frame.clear();
        return m_impl->bitmap->scanline_u8(0);
    }

    // Repaint only what changed since the frame the bitmap shows, moving its pixels when the viewport scrolled, as
    // the Compositor process repaints only its damage (it repaints all of a scroll, which here is most of the time).
    static bool const debug = env_flag("WEBBY_RASTER_DEBUG");
    static bool const verify = env_flag("WEBBY_RASTER_VERIFY");
    static bool const always_full = env_flag("WEBBY_RASTER_FULL");
    Gfx::IntRect const viewport { 0, 0, size.width(), size.height() };
    Optional<Vector<Gfx::IntRect>> damage;
    Optional<Gfx::IntRect> unscrolled; // what does not move with the viewport, when the change says
    int moved = 0;
    auto& last = m_impl->last_frame;
    if (!always_full && last.has_value() && last->document == &document && !visual_context_tree.has_visual_animations()
        && last->display_list->surface_clear_color() == display_list->surface_clear_color()) {
        // Canvases and videos change without their commands changing: repaint wherever they are drawn.
        Vector<Compositing::CanvasId> canvases;
        for (auto id : display_list->referenced_resource_ids().canvases)
            canvases.append(Compositing::CanvasId { id });
        Vector<Compositing::VideoSinkResourceId> video_sinks;
        for (auto id : display_list->referenced_resource_ids().video_sinks)
            video_sinks.append(Compositing::VideoSinkResourceId { id });
        auto change = Compositing::compute_viewport_scroll_damage(*last->display_list, last->visual_context_tree, last->scroll_state,
            *display_list, visual_context_tree, scroll_state, viewport, { .canvases = canvases, .video_sinks = video_sinks });
        auto const dy = change.has_value() ? change->scroll.y() : 0.f;
        // Only a frame that scrolled tells what stays put: one that did not (a busy page's script, a caret) says
        // nothing moved, and taking its answer would have the chrome move a fixed header with its next wheel.
        if (change.has_value() && (change->scroll.x() != 0 || change->scroll.y() != 0))
            unscrolled = change->unscrolled_new;
        if (debug) {
            if (!change.has_value())
                warnln("webby raster: no scroll damage (an unbounded change)");
            else
                warnln("webby raster: scroll {} content {} in {} pieces, unscrolled {} / {}", change->scroll, change->content, change->content_pieces.size(), change->unscrolled_new, change->unscrolled_old);
        }
        // Smooth scroll steps land on whole device pixels; at a fractional scale a CSS offset (1/64 px) is a hair off.
        if (change.has_value() && change->scroll.x() == 0 && fabsf(dy - roundf(dy)) < 0.05f && fabsf(dy) < size.height()) {
            moved = static_cast<int>(roundf(dy));
            Vector<Gfx::IntRect> rects;
            auto add = [&](Gfx::IntRect rect) {
                rect.intersect(viewport);
                if (!rect.is_empty())
                    rects.append(rect);
            };
            // The rows the move uncovers, and a few rows along both edges: the recording leaves out what lies off the
            // frame, ink of text whose box is off it included, so the rows near an edge differ from the same content
            // drawn away from it.
            constexpr int edge = 16;
            if (moved < 0)
                add({ 0, size.height() + moved - edge, size.width(), -moved + edge });
            else if (moved > 0)
                add({ 0, 0, size.width(), moved + edge });
            if (moved != 0) {
                add({ 0, 0, size.width(), edge });
                add({ 0, size.height() - edge, size.width(), edge });
            }
            // With a margin: the damage of some changes comes out a few pixels short of what they draw (Wikipedia's
            // pulsing "watch" dot, a ring around a dot, left its old ring a few rows above the damage).
            for (auto const& piece : change->content_pieces)
                add(piece.inflated(32, 32));
            add(change->unscrolled_new);
            add(change->unscrolled_old);
            // Everything to repaint anyway (a page under a fixed full-window layer): no move, no clip.
            if (!any_of(rects, [&](auto const& rect) { return rect == viewport; }))
                damage = move(rects);
        }
    }

    if (debug && !damage.has_value() && last.has_value())
        warnln("webby raster: whole frame (same document {}, visual animations {}, same clear color {})", last->document == &document,
            visual_context_tree.has_visual_animations(), last->display_list->surface_clear_color() == display_list->surface_clear_color());
    auto const start = debug ? AK::MonotonicTime::now() : AK::MonotonicTime {};
    if (damage.has_value()) {
        move_rows(*m_impl->bitmap, moved);
        if (!damage->is_empty() && rasterize(*display_list, visual_context_tree, scroll_state, frame_resources, m_impl->raster_cache, *m_impl->bitmap, &*damage).is_error())
            damage.clear();
    }
    if (!damage.has_value() && rasterize(*display_list, visual_context_tree, scroll_state, frame_resources, m_impl->raster_cache, *m_impl->bitmap).is_error()) {
        fill_white(*m_impl->bitmap);
        last.clear();
        return m_impl->bitmap->scanline_u8(0);
    }
    if (debug) {
        auto ms = (AK::MonotonicTime::now() - start).to_microseconds() / 1000.0;
        if (!damage.has_value()) {
            warnln("webby raster: full {:.1} ms", ms);
        } else {
            StringBuilder rects;
            for (auto const& rect : *damage)
                rects.appendff(" {}", rect);
            warnln("webby raster: move {} damage{} {:.1} ms", moved, rects.string_view(), ms);
        }
    }
    // Check the partial raster against a whole one, and show the whole one.
    if (verify && damage.has_value()) {
        auto full = Gfx::Bitmap::create(Gfx::BitmapFormat::BGRA8888, Gfx::AlphaType::Premultiplied, size);
        if (!full.is_error() && !rasterize(*display_list, visual_context_tree, scroll_state, frame_resources, m_impl->raster_cache, *full.value()).is_error()) {
            Gfx::IntRect wrong;
            size_t wrong_pixels = 0;
            for (int y = 0; y < size.height(); ++y) {
                auto const* a = m_impl->bitmap->scanline(y);
                auto const* b = full.value()->scanline(y);
                for (int x = 0; x < size.width(); ++x) {
                    // Skia's clipped and whole rasters round some blends differently, by a level or two.
                    auto const near = [](u32 p, u32 q) {
                        for (int shift = 0; shift < 32; shift += 8) {
                            if (abs(int((p >> shift) & 0xff) - int((q >> shift) & 0xff)) > 4)
                                return false;
                        }
                        return true;
                    };
                    if (near(a[x], b[x]))
                        continue;
                    if (wrong_pixels < 4)
                        warnln("webby raster verify: ({},{}) partial {:08x} whole {:08x}", x, y, a[x], b[x]);
                    ++wrong_pixels;
                    wrong = wrong.united({ x, y, 1, 1 });
                }
            }
            if (wrong_pixels) {
                // Whether a second whole raster agrees with the first (content sampled at raster time).
                auto again = Gfx::Bitmap::create(Gfx::BitmapFormat::BGRA8888, Gfx::AlphaType::Premultiplied, size);
                size_t unstable = 0;
                if (!again.is_error() && !rasterize(*display_list, visual_context_tree, scroll_state, frame_resources, m_impl->raster_cache, *again.value()).is_error())
                    unstable = memcmp(again.value()->scanline_u8(0), full.value()->scanline_u8(0), m_impl->bitmap->size_in_bytes()) != 0;
                warnln("webby raster verify: {} pixels differ in {} (move {}{})", wrong_pixels, wrong, moved, unstable ? ", whole rasters differ too" : "");
            }
            memcpy(m_impl->bitmap->scanline_u8(0), full.value()->scanline_u8(0), m_impl->bitmap->size_in_bytes());
        }
    }
    if (damage.has_value() && !verify) {
        m_last_change.known = true;
        m_last_change.moved = moved;
        for (auto const& rect : *damage)
            m_last_change.rects.push_back({ rect.x(), rect.y(), rect.width(), rect.height() });
    }
    // Where this frame is scrolled to. What stays put is known from a comparison with the last frame; without one (a
    // whole raster) the last answer holds for the same document.
    {
        auto& vs = m_viewport_scroll;
        if (unscrolled.has_value()) {
            auto r = unscrolled->intersected(viewport);
            vs.fixed = { r.x(), r.y(), r.width(), r.height() };
            vs.known = true;
        } else if (!last.has_value() || last->document != &document) {
            vs.known = false;
        }
        vs.y = static_cast<int>(round(document.viewport_rect().y().to_double() * m_zoom));
        auto const* layout_node = document.layout_node(read);
        vs.max_y = layout_node ? max(0, static_cast<int>(Web::Painting::maximum_scroll_offset(*layout_node).y().to_double() * m_zoom)) : vs.y;
    }
    last = Impl::RasterizedFrame { display_list.release_nonnull(), move(visual_context_tree), scroll_state, &document };
    return m_impl->bitmap->scanline_u8(0);
}

static Web::DevicePixelPoint point(int x, int y) { return { x, y }; }

// A press on a thumb takes it (a drag moves the scroller with it); a press beside the thumb pages toward the pointer.
bool EngineView::scrollbar_mouse_down(int x, int y, unsigned button)
{
    auto& state = m_impl->scrollbars;
    if (button != ButtonPrimary)
        return false;
    Gfx::FloatPoint pointer { static_cast<float>(x), static_cast<float>(y) };
    auto index = scrollbar_at(*m_impl, pointer);
    if (!index.has_value())
        return false;
    auto const bar = state.bars[*index];
    auto position = point_in_scrollbar_space(*m_impl, bar, pointer);
    if (!position.has_value())
        return false;
    auto primary = along(*position, bar.vertical);
    auto thumb = scrollbar_thumb(bar, state.scroll_state, true);
    auto thin_thumb = scrollbar_thumb(bar, state.scroll_state, false);
    auto const lo = min(start_along(thumb, bar.vertical), start_along(thin_thumb, bar.vertical));
    auto const hi = max(end_along(thumb, bar.vertical), end_along(thin_thumb, bar.vertical));
    if (primary >= lo && primary <= hi) {
        state.drag = Impl::Scrollbars::Drag { .index = *index, .grab = primary - start_along(thumb, bar.vertical) };
    } else {
        // A page is most of the scroller's visible length, as in Ladybird.
        float page = 0;
        for (auto const& node : state.nodes) {
            if (node.scroll_node_index == bar.scroll_node_index)
                page = bar.vertical ? node.scrollport_rect.height() : node.scrollport_rect.width();
        }
        if (page <= 0)
            page = bar.vertical ? m_height : m_width;
        page *= 0.875f;
        scroll_scrollbar_to(*m_impl, bar, scrollbar_offset(*m_impl, bar) + (primary < lo ? -page : page));
    }
    state.hovered = index;
    did_request_frame();
    return true;
}

bool EngineView::scrollbar_mouse_move(int x, int y)
{
    auto& state = m_impl->scrollbars;
    Gfx::FloatPoint pointer { static_cast<float>(x), static_cast<float>(y) };
    if (state.drag.has_value() && state.drag->index < state.bars.size()) {
        auto const bar = state.bars[state.drag->index];
        auto position = point_in_scrollbar_space(*m_impl, bar, pointer, Compositing::AccumulatedVisualContextTree::ClipBehavior::Ignore);
        if (position.has_value() && bar.expanded_scroll_size > 0) {
            auto thumb_start = along(*position, bar.vertical) - state.drag->grab;
            auto offset = (thumb_start - start_along(bar.expanded_thumb_rect, bar.vertical)) / static_cast<float>(bar.expanded_scroll_size);
            scroll_scrollbar_to(*m_impl, bar, offset);
            did_request_frame();
        }
        return true;
    }
    auto hovered = scrollbar_at(*m_impl, pointer);
    if (hovered != state.hovered) {
        state.hovered = hovered;
        did_request_frame();
    }
    // Over the viewport's bars the page gets no move (it would hover what is under them); over an inner bar it does.
    return hovered.has_value() && state.bars[*hovered].is_painted_by_compositor;
}

bool EngineView::scrollbar_mouse_up(unsigned button)
{
    auto& state = m_impl->scrollbars;
    if (button != ButtonPrimary || !state.drag.has_value())
        return false;
    state.drag.clear();
    did_request_frame();
    return true;
}

void EngineView::mouse_down(int x, int y, unsigned button, unsigned buttons, unsigned modifiers, int clicks)
{
    if (scrollbar_mouse_down(x, y, button))
        return;
    if (m_impl->page)
        m_impl->page->handle_mousedown(point(x, y), point(x, y), button, buttons, modifiers, clicks);
    did_request_frame();
}

void EngineView::mouse_up(int x, int y, unsigned button, unsigned buttons, unsigned modifiers)
{
    if (scrollbar_mouse_up(button))
        return;
    if (m_impl->page)
        m_impl->page->handle_mouseup(point(x, y), point(x, y), button, buttons, modifiers);
    did_request_frame();
}

void EngineView::mouse_move(int x, int y, unsigned buttons, unsigned modifiers)
{
    if (scrollbar_mouse_move(x, y))
        return;
    if (m_impl->page)
        m_impl->page->handle_mousemove(point(x, y), point(x, y), buttons, modifiers);
    did_request_frame();
}

void EngineView::mouse_leave()
{
    if (m_impl->scrollbars.hovered.has_value() && !m_impl->scrollbars.drag.has_value()) {
        m_impl->scrollbars.hovered.clear();
        did_request_frame();
    }
    if (m_impl->page)
        m_impl->page->handle_mouseleave();
}

void EngineView::wheel(int x, int y, double dx, double dy, unsigned modifiers)
{
    if (!m_impl->page)
        return;
    auto result = m_impl->page->handle_mousewheel(point(x, y), point(x, y), 0, 0, modifiers, dx, dy,
        Web::wheel_tick_120ths_from_pixel_delta(dx, Web::WheelDeltaPrecision::Discrete),
        Web::wheel_tick_120ths_from_pixel_delta(dy, Web::WheelDeltaPrecision::Discrete));
    // Ladybird scrolls by a wheel event in its Compositor process, and there is none here: unless the page cancelled
    // the event, scroll the viewport on this thread. (Inner scroll containers do not scroll by the wheel yet.)
    if (result != Web::EventResult::Cancelled && m_impl->document && m_impl->document->window())
        m_impl->document->window()->scroll_by(dx / m_zoom, dy / m_zoom, nullptr);
    did_request_frame();
}

void EngineView::key_down(unsigned key, unsigned modifiers, uint32_t code_point, bool repeat)
{
    if (m_impl->page)
        m_impl->page->handle_keydown(static_cast<Web::UIEvents::KeyCode>(key), modifiers, code_point, repeat, code_point != 0);
    did_request_frame();
}

void EngineView::key_up(unsigned key, unsigned modifiers, uint32_t code_point)
{
    if (m_impl->page)
        m_impl->page->handle_keyup(static_cast<Web::UIEvents::KeyCode>(key), modifiers, code_point, false);
    did_request_frame();
}

void EngineView::did_request_frame()
{
    m_needs_paint = true;
    if (on_needs_paint)
        on_needs_paint();
}

void EngineView::did_change_title(std::string title)
{
    m_title = move(title);
    if (on_title_change)
        on_title_change(m_title);
}

void EngineView::did_request_navigation(std::string url)
{
    // Not inside the old page's own call stack: the load replaces that page.
    Core::deferred_invoke([this, url = move(url)] {
        if (on_navigation_request && on_navigation_request(url))
            return;
        load(url);
    });
}

void EngineView::did_finish_loading()
{
    if (!m_loading)
        return;
    m_loading = false;
    if (on_loading_change)
        on_loading_change(false);
    did_request_frame();
}

void EngineView::did_write_clipboard(std::string text, bool selection)
{
    if (on_clipboard_write)
        on_clipboard_write(text, selection);
}

void EngineView::did_request_clipboard(uint64_t request, bool selection)
{
    if (on_clipboard_request)
        on_clipboard_request(request, selection);
    else
        answer_clipboard(request, {});
}

void EngineView::answer_clipboard(uint64_t request, std::string const& text)
{
    if (!m_impl->page)
        return;
    // After the current task, as an answer from a UI process would come (the UI may answer inside the request).
    Core::deferred_invoke([page = m_impl->page, request, text] {
        if (request & 1) {
            if (text.empty())
                return;
            auto utf16 = Utf16String::from_utf8_with_replacement_character(StringView { text.data(), text.size() });
            if (auto navigable = page->hosted_focused_navigable())
                navigable->paste(utf16);
            return;
        }
        Vector<Web::Clipboard::SystemClipboardItem> items;
        if (!text.empty()) {
            Web::Clipboard::SystemClipboardItem item;
            item.system_clipboard_representations.append({ "text/plain"_string, ByteString(text.data(), text.size()) });
            items.append(move(item));
        }
        page->retrieved_clipboard_entries(request >> 1, move(items));
    });
}

void EngineView::did_hover_link(std::string url)
{
    if (on_link_hover)
        on_link_hover(url);
}

void EngineView::did_request_context_menu(ContextMenu menu)
{
    if (on_context_menu)
        on_context_menu(menu);
}

static GC::Ptr<Web::HTML::LocalNavigable> focused_navigable(GC::Root<Web::Page> const& page)
{
    return page ? page->hosted_focused_navigable() : nullptr;
}

std::string EngineView::selected_text() const
{
    auto navigable = focused_navigable(m_impl->page);
    return navigable ? to_std(navigable->selected_text().to_utf8().to_byte_string()) : std::string {};
}

void EngineView::select_all()
{
    if (auto navigable = focused_navigable(m_impl->page))
        navigable->select_all();
    did_request_frame();
}

std::string EngineView::cut_selection()
{
    auto navigable = focused_navigable(m_impl->page);
    auto text = navigable ? to_std(navigable->cut_selected_text().to_utf8().to_byte_string()) : std::string {};
    did_request_frame();
    return text;
}

void EngineView::insert_text(std::string const& text)
{
    if (text.empty())
        return;
    if (auto navigable = focused_navigable(m_impl->page)) {
        auto utf16 = Utf16String::from_utf8_with_replacement_character(StringView { text.data(), text.size() });
        navigable->paste(utf16);
    }
    did_request_frame();
}


void EngineView::set_zoom(double zoom)
{
    zoom = clamp(zoom, 0.25, 5.0);
    if (zoom == m_zoom)
        return;
    m_zoom = zoom;
    if (m_impl->client)
        m_impl->client->set_zoom(zoom);
    if (m_impl->page && m_impl->page->has_local_traversable()) {
        m_impl->page->local_traversable()->set_viewport_size(
            m_impl->page->device_to_css_size(Gfx::IntSize { m_width, m_height }.to_type<Web::DevicePixels>()),
            Web::InvalidateDisplayList::PaintCommandsAndHitTestList);
    }
    did_request_frame();
}

static EngineView::FindResult find_result(Web::Page::FindInPageResult const& result)
{
    return { unsigned(result.current_match_index), result.total_match_count.has_value() ? int(*result.total_match_count) : -1 };
}

EngineView::FindResult EngineView::find(std::string const& query, bool case_sensitive)
{
    if (!m_impl->page || !m_impl->document)
        return { 0, 0 };
    Web::Page::FindInPageQuery q;
    q.string = Utf16String::from_utf8(StringView { query.data(), query.size() });
    q.case_sensitivity = case_sensitive ? CaseSensitivity::CaseSensitive : CaseSensitivity::CaseInsensitive;
    q.highlight_all_matches = true;
    auto result = m_impl->page->find_in_page(q);
    did_request_frame();
    return find_result(result);
}

EngineView::FindResult EngineView::find_next()
{
    if (!m_impl->page || !m_impl->document)
        return { 0, 0 };
    auto result = m_impl->page->find_in_page_next_match();
    did_request_frame();
    return find_result(result);
}

EngineView::FindResult EngineView::find_previous()
{
    if (!m_impl->page || !m_impl->document)
        return { 0, 0 };
    auto result = m_impl->page->find_in_page_previous_match();
    did_request_frame();
    return find_result(result);
}

void EngineView::find_end()
{
    if (m_impl->page && m_impl->document)
        m_impl->page->find_in_page_end();
    did_request_frame();
}

}

namespace WebbyUI {

void EngineView::run_page_scripts()
{
    if (!page_scripts)
        return;
    for (auto const& source : page_scripts()) {
        if (!source.empty())
            run_javascript(source);
    }
}

void EngineView::run_javascript(std::string const& source)
{
    auto document = m_impl->document;
    if (!document || !document->browsing_context())
        return;
    auto& settings = document->relevant_settings_object();
    auto script = Web::HTML::ClassicScript::create("(webby page script)", Utf16String::from_utf8(StringView { source.data(), source.size() }), settings, settings.api_base_url());
    if (script->run().is_error())
        dbgln("webby: a page script threw");
}

void EngineView::did_send_page_message(std::string message, std::string document_url)
{
    if (on_page_message)
        on_page_message(message, document_url);
}

void EngineView::did_request_webauthn(uint64_t request_id, std::string request_json)
{
    if (on_webauthn_request) {
        on_webauthn_request(request_id, request_json);
        return;
    }
    auto& flow = m_impl->webauthn;
    flow.reply = [page = m_impl->page](uint64_t id, std::string const& json) {
        if (page)
            page->webauthn_response(id, MUST(String::from_utf8(StringView { json.data(), json.size() })));
    };
    flow.prompt = [this](std::string const& prompt) {
        if (on_webauthn_prompt)
            on_webauthn_prompt(prompt);
    };
    flow.request(request_id, request_json, bool(on_webauthn_prompt));
}

void EngineView::webauthn_respond(bool accepted, int account_index)
{
    m_impl->webauthn.respond(accepted, account_index);
}

void EngineView::webauthn_reply(uint64_t request_id, std::string const& reply)
{
    // The page may have navigated meanwhile; Ladybird drops a reply for a request it no longer has.
    if (m_impl->page)
        m_impl->page->webauthn_response(request_id, MUST(String::from_utf8(StringView { reply.data(), reply.size() })));
}

}
