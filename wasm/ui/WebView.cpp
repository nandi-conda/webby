/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "WebView.h"
#include "Resources.h"

#include <AK/LexicalPath.h>
#include <AK/Utf16String.h>
#include <Compositor/DisplayListPlayerSkia.h>
#include <Compositor/DisplayListRasterCache.h>
#include <Compositor/PaintingSurface.h>
#include <Compositor/SkiaBackendContext.h>
#include <LibCompositing/DisplayList/DisplayListResourceStorage.h>
#include <LibCore/ConfigFile.h>
#include <LibCore/EventLoop.h>
#include <LibCore/File.h>
#include <LibCore/ResourceImplementation.h>
#include <LibCore/ResourceImplementationFile.h>
#include <LibCore/System.h>
#include <LibFileSystem/FileSystem.h>
#include <LibGC/Root.h>
#include <LibGfx/Bitmap.h>
#include <LibGfx/Font/FontDatabase.h>
#include <LibGfx/Font/PathFontProvider.h>
#include <LibGfx/Font/Typeface.h>
#include <LibGfx/Palette.h>
#include <LibGfx/SystemTheme.h>
#include <LibURL/Parser.h>
#include <LibWeb/Bindings/MainThreadVM.h>
#include <LibWeb/DOM/Document.h>
#include <LibWeb/DOM/DocumentObserver.h>
#include <LibWeb/HTML/LocalTraversableNavigable.h>
#include <LibWeb/HTML/Parser/HTMLParser.h>
#include <LibWeb/HTML/Window.h>
#include <LibWeb/Layout/RenderDocument.h>
#include <LibWeb/Loader/FileRequest.h>
#include <LibWeb/Loader/ResourceLoader.h>
#include <LibWeb/Page/Page.h>
#include <LibWeb/Painting/DocumentPaintState.h>
#include <LibWeb/Platform/EventLoopPlugin.h>
#include <LibWeb/Platform/FontPlugin.h>
#include <LibWebCommon/Page/NavigationTarget.h>
#include <fcntl.h>
#include <stdlib.h>

namespace WebbyUI {

namespace {

std::string to_std(ByteString const& s) { return std::string(s.characters(), s.length()); }

// The start page, and the page a load shows when it cannot fetch what it was asked for.
constexpr char start_page_html[] = R"html(<!doctype html>
<html><head><title>New Tab</title><style>
body { font-family: sans-serif; margin: 0; background: #f4f1ea; color: #222; }
main { max-width: 640px; margin: 80px auto; padding: 0 24px; }
h1 { color: #2d5a88; font-size: 40px; margin-bottom: 8px; }
p { line-height: 1.5; }
code { background: #e8e2d6; padding: 1px 4px; border-radius: 4px; }
</style></head><body><main>
<h1>webby</h1>
<p>This browser runs entirely in WebAssembly: Ladybird's LibWeb lays out and paints the page, and the window around it
is Qt, in the same module.</p>
<p>Type a <code>file://</code> path in the address bar to open a page.</p>
</main></body></html>)html";

ByteString error_page_html(StringView url, StringView reason)
{
    auto escape = [](StringView s) {
        return s.replace("&"sv, "&amp;"sv, ReplaceMode::All).replace("<"sv, "&lt;"sv, ReplaceMode::All);
    };
    return ByteString::formatted(R"html(<!doctype html><html><head><title>Can't open this page</title><style>
body {{ font-family: sans-serif; margin: 0; background: #f6f6f6; color: #333; }}
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
    static GC::Ref<BrowserPageClient> create(WebView& view, Gfx::IntSize viewport, NonnullRefPtr<Gfx::PaletteImpl> palette_impl)
    {
        return GC::Heap::the().allocate<BrowserPageClient>(view, viewport, move(palette_impl));
    }

    void set_page(Web::Page& page) { m_page = &page; }
    void set_viewport(Gfx::IntSize size) { m_viewport = size; }
    void detach() { m_view = nullptr; }

    virtual Web::PageId id() const override { return 1; }
    virtual Web::Page& page() override { return *m_page; }
    virtual Web::Page const& page() const override { return *m_page; }
    virtual bool is_connection_open() const override { return false; }
    virtual Gfx::Palette palette() const override { return Gfx::Palette { *m_palette_impl }; }
    virtual Web::DevicePixelRect screen_rect() const override { return { { 0, 0 }, m_viewport.to_type<Web::DevicePixels>() }; }
    virtual double zoom_level() const override { return 1.0; }
    virtual double device_pixel_ratio() const override { return 1.0; }
    virtual double device_pixels_per_css_pixel() const override { return 1.0; }
    virtual Web::CSS::PreferredColorScheme preferred_color_scheme() const override { return Web::CSS::PreferredColorScheme::Light; }
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
    BrowserPageClient(WebView& view, Gfx::IntSize viewport, NonnullRefPtr<Gfx::PaletteImpl> palette_impl)
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

    WebView* m_view { nullptr };
    GC::Ptr<Web::Page> m_page;
    Gfx::IntSize m_viewport;
    NonnullRefPtr<Gfx::PaletteImpl> m_palette_impl;
    Queue<Web::QueuedInputEvent> m_input_event_queue;
    Web::HTML::CrossProcessIdAllocator m_cross_process_ids { .namespace_id = 1 };
};

GC_DEFINE_ALLOCATOR(BrowserPageClient);

struct WebView::Impl {
    GC::Root<BrowserPageClient> client;
    GC::Root<Web::Page> page;
    GC::Root<Web::DOM::Document> document;
    GC::Root<Web::DOM::DocumentObserver> observer;
    RefPtr<Gfx::Bitmap> bitmap;
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
    return {};
}

}

void WebView::pump()
{
    if (s_event_loop)
        s_event_loop->pump(Core::EventLoop::WaitMode::PollForEvents);
}

std::unique_ptr<WebView> WebView::create(int width, int height)
{
    if (auto result = initialize_engine(); result.is_error()) {
        warnln("webby: the engine could not start: {}", result.error());
        return nullptr;
    }
    return std::unique_ptr<WebView>(new WebView(width, height));
}

WebView::WebView(int width, int height)
    : m_impl(std::make_unique<Impl>())
    , m_width(max(width, 1))
    , m_height(max(height, 1))
{
}

WebView::~WebView()
{
    if (m_impl->client)
        m_impl->client->detach();
}

void WebView::load(std::string const& url)
{
    navigate(url, true);
}

void WebView::reload()
{
    if (!m_url.empty())
        navigate(m_url, false);
}

bool WebView::can_go_back() const { return m_history_index > 0; }
bool WebView::can_go_forward() const { return m_history_index + 1 < m_history.size(); }

void WebView::go_back()
{
    if (!can_go_back())
        return;
    --m_history_index;
    navigate(m_history[m_history_index], false);
}

void WebView::go_forward()
{
    if (!can_go_forward())
        return;
    ++m_history_index;
    navigate(m_history[m_history_index], false);
}

// A load makes a new Page with a new top-level traversable, and parses the document into it directly, in this module
// (the document a navigation would have made, as webby-render and SVGDecodedImageData make theirs).
void WebView::navigate(std::string const& requested_url, bool add_to_history)
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

    ByteString html;
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
        else
            html = ByteString { contents.value().bytes() };
    } else {
        html = error_page_html(url->serialize(), "Only file: pages open so far: the network is not connected to this build yet."sv);
    }

    if (m_impl->client)
        m_impl->client->detach();

    Gfx::IntSize viewport { m_width, m_height };
    auto client = BrowserPageClient::create(*this, viewport, *s_palette);
    auto page = Web::Page::create(*client);
    client->set_page(*page);
    page->set_top_level_traversable(Web::HTML::LocalTraversableNavigable::create_a_new_top_level_traversable(page, nullptr, {}));
    auto& navigable = *page->local_traversable();
    auto& window = *navigable.active_window();
    navigable.set_viewport_size(viewport.to_type<Web::CSSPixels>());

    auto document = Web::DOM::Document::create(*page, window, document_url);
    document->set_id(client->allocate_cross_process_id());
    document->set_document_type(Web::DOM::Document::Type::HTML);
    document->set_content_type("text/html"_utf16_fly_string);
    document->set_browsing_context(navigable.active_browsing_context());
    document->set_window(window);
    window.set_associated_document(*document);
    navigable.set_active_document(*document);
    document->set_ready_to_run_scripts();

    auto observer = Web::DOM::DocumentObserver::create(*document);
    observer->set_document_completely_loaded([this] { did_finish_loading(); });

    m_impl->client = client;
    m_impl->page = page;
    m_impl->document = document;
    m_impl->observer = observer;

    m_url = to_std(document_url.serialize().to_byte_string());
    if (url.has_value() && url->scheme() == "about"sv)
        m_url = "";
    if (add_to_history) {
        if (!m_history.empty())
            m_history.resize(m_history_index + 1);
        m_history.push_back(m_url);
        m_history_index = m_history.size() - 1;
    }
    m_title.clear();
    m_loading = true;
    if (on_link_hover)
        on_link_hover({});
    if (on_url_change)
        on_url_change(m_url);
    if (on_loading_change)
        on_loading_change(true);

    auto parser = Web::HTML::HTMLParser::create_from_byte_string(*document, StringView { html }, Web::HTML::ParserScriptingMode::Normal, "UTF-8"sv);
    parser->run(document_url);
    did_request_frame();
}

void WebView::resize(int width, int height)
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
        m_impl->page->local_traversable()->set_viewport_size(Gfx::IntSize { width, height }.to_type<Web::CSSPixels>());
    did_request_frame();
}

static void fill_white(Gfx::Bitmap& bitmap)
{
    memset(bitmap.scanline_u8(0), 0xff, bitmap.size_in_bytes());
}

// Compositor::rasterize_display_list with the page's scroll offsets: in Ladybird the Compositor process owns them (it
// scrolls by wheel events itself); here the document's own snapshot is the truth.
static ErrorOr<void> rasterize(Compositing::DisplayList const& display_list, Compositing::AccumulatedVisualContextTree const& visual_context_tree,
    Compositing::ScrollStateSnapshot const& scroll_state, Compositing::DisplayListResourceTransaction&& resources, Gfx::Bitmap& target)
{
    Compositing::DisplayListResourceStorage resource_storage;
    resource_storage.apply_transaction(move(resources));
    TRY(resource_storage.validate_for_replay(display_list, visual_context_tree));
    __builtin_memset(target.scanline_u8(0), 0, target.size_in_bytes());
    auto surface = Gfx::PaintingSurface::wrap_bitmap(target);
    Compositor::DisplayListPlayerSkia player { RefPtr<Gfx::SkiaBackendContext> {} };
    Compositor::DisplayListRasterCache raster_cache;
    player.execute(display_list, visual_context_tree, resource_storage, raster_cache, scroll_state, surface, nullptr, nullptr);
    player.flush(*surface);
    return {};
}

uint8_t const* WebView::paint()
{
    if (!m_impl->document)
        return nullptr;
    if (!m_needs_paint && m_impl->bitmap)
        return m_impl->bitmap->scanline_u8(0);
    m_needs_paint = false;

    Gfx::IntSize size { m_width, m_height };
    if (!m_impl->bitmap || m_impl->bitmap->size() != size) {
        auto bitmap = Gfx::Bitmap::create(Gfx::BitmapFormat::BGRA8888, Gfx::AlphaType::Premultiplied, size);
        if (bitmap.is_error())
            return nullptr;
        m_impl->bitmap = bitmap.release_value();
    }

    auto& document = *m_impl->document;
    auto* navigable = document.navigable().ptr();
    if (!navigable)
        return m_impl->bitmap->scanline_u8(0);
    auto& resource_storage = navigable->display_list_resource_storage();

    Web::Layout::ForcedReadScope read { document };
    document.update_layout(Web::DOM::UpdateLayoutReason::SVGDecodedImageDataRender);
    auto display_list = document.record_display_list(read, {}, resource_storage, Web::Painting::PaintCommandCacheMode::ReadWrite);
    if (!display_list) {
        fill_white(*m_impl->bitmap);
        return m_impl->bitmap->scanline_u8(0);
    }
    document.update_paint_and_hit_testing_properties_if_needed();
    auto& paint_state = document.paint_state();
    auto visual_context_tree = paint_state.visual_context_tree(document);
    auto transaction = resource_storage.create_self_contained_transaction(*display_list, visual_context_tree);
    if (transaction.is_error()
        || rasterize(*display_list, visual_context_tree, paint_state.scroll_state_snapshot(), transaction.release_value(), *m_impl->bitmap).is_error())
        fill_white(*m_impl->bitmap);
    return m_impl->bitmap->scanline_u8(0);
}

static Web::DevicePixelPoint point(int x, int y) { return { x, y }; }

void WebView::mouse_down(int x, int y, unsigned button, unsigned buttons, unsigned modifiers, int clicks)
{
    if (m_impl->page)
        m_impl->page->handle_mousedown(point(x, y), point(x, y), button, buttons, modifiers, clicks);
    did_request_frame();
}

void WebView::mouse_up(int x, int y, unsigned button, unsigned buttons, unsigned modifiers)
{
    if (m_impl->page)
        m_impl->page->handle_mouseup(point(x, y), point(x, y), button, buttons, modifiers);
    did_request_frame();
}

void WebView::mouse_move(int x, int y, unsigned buttons, unsigned modifiers)
{
    if (m_impl->page)
        m_impl->page->handle_mousemove(point(x, y), point(x, y), buttons, modifiers);
    did_request_frame();
}

void WebView::mouse_leave()
{
    if (m_impl->page)
        m_impl->page->handle_mouseleave();
}

void WebView::wheel(int x, int y, double dx, double dy, unsigned modifiers)
{
    if (!m_impl->page)
        return;
    auto result = m_impl->page->handle_mousewheel(point(x, y), point(x, y), 0, 0, modifiers, dx, dy,
        Web::wheel_tick_120ths_from_pixel_delta(dx, Web::WheelDeltaPrecision::Discrete),
        Web::wheel_tick_120ths_from_pixel_delta(dy, Web::WheelDeltaPrecision::Discrete));
    // Ladybird scrolls by a wheel event in its Compositor process, and there is none here: unless the page cancelled
    // the event, scroll the viewport on this thread. (Inner scroll containers do not scroll by the wheel yet.)
    if (result != Web::EventResult::Cancelled && m_impl->document && m_impl->document->window())
        m_impl->document->window()->scroll_by(dx, dy, nullptr);
    did_request_frame();
}

void WebView::key_down(unsigned key, unsigned modifiers, uint32_t code_point, bool repeat)
{
    if (m_impl->page)
        m_impl->page->handle_keydown(static_cast<Web::UIEvents::KeyCode>(key), modifiers, code_point, repeat, code_point != 0);
    did_request_frame();
}

void WebView::key_up(unsigned key, unsigned modifiers, uint32_t code_point)
{
    if (m_impl->page)
        m_impl->page->handle_keyup(static_cast<Web::UIEvents::KeyCode>(key), modifiers, code_point, false);
    did_request_frame();
}

void WebView::did_request_frame()
{
    m_needs_paint = true;
    if (on_needs_paint)
        on_needs_paint();
}

void WebView::did_change_title(std::string title)
{
    m_title = move(title);
    if (on_title_change)
        on_title_change(m_title);
}

void WebView::did_request_navigation(std::string url)
{
    // Not inside the old page's own call stack: the load replaces that page.
    Core::deferred_invoke([this, url = move(url)] { load(url); });
}

void WebView::did_finish_loading()
{
    if (!m_loading)
        return;
    m_loading = false;
    if (on_loading_change)
        on_loading_change(false);
    did_request_frame();
}

void WebView::did_hover_link(std::string url)
{
    if (on_link_hover)
        on_link_hover(url);
}

}
