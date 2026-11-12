/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "WebView.h"
#include "Network.h"
#include "Resources.h"
#include "Storage.h"

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
#include <LibCore/MimeData.h>
#include <LibCore/ResourceImplementation.h>
#include <LibCore/ResourceImplementationFile.h>
#include <LibCore/System.h>
#include <LibCore/Timer.h>
#include <LibFileSystem/FileSystem.h>
#include <LibGC/Root.h>
#include <LibGfx/Bitmap.h>
#include <LibGfx/Font/FontDatabase.h>
#include <LibGfx/Font/PathFontProvider.h>
#include <LibGfx/Font/Typeface.h>
#include <LibGfx/Palette.h>
#include <LibGfx/SystemTheme.h>
#include <LibTextCodec/Decoder.h>
#include <LibURL/Parser.h>
#include <LibWeb/Bindings/MainThreadVM.h>
#include <LibWeb/DOM/Document.h>
#include <LibWeb/DOM/DocumentObserver.h>
#include <LibWeb/HTML/BrowsingContext.h>
#include <LibWeb/HTML/CustomElements/CustomElementRegistry.h>
#include <LibWeb/HTML/DocumentState.h>
#include <LibWeb/Fetch/Infrastructure/HTTP/MIME.h>
#include <LibWeb/HTML/HTMLImageElement.h>
#include <LibWeb/HTML/HTMLInputElement.h>
#include <LibWeb/HTML/HTMLTextAreaElement.h>
#include <LibWeb/HTML/LocalNavigable.h>
#include <LibWeb/HTML/LocalTraversableNavigable.h>
#include <LibWeb/HTML/Navigation.h>
#include <LibWeb/HTML/SessionHistoryEntry.h>
#include <LibWeb/HTML/Parser/HTMLEncodingDetection.h>
#include <LibWeb/HTML/Parser/HTMLParser.h>
#include <LibWeb/HTML/Parser/HTMLTokenizer.h>
#include <LibWeb/HTML/Window.h>
#include <LibWeb/Layout/RenderDocument.h>
#include <LibWeb/Loader/FileRequest.h>
#include <LibWeb/Loader/ResourceLoader.h>
#include <LibWeb/Page/Page.h>
#include <LibWeb/Painting/DocumentPaintState.h>
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
<p>Type a web address or a <code>file://</code> path in the address bar to open a page.</p>
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
    void set_zoom(double zoom) { m_zoom = zoom; }
    void detach() { m_view = nullptr; }

    virtual Web::PageId id() const override { return 1; }
    virtual Web::Page& page() override { return *m_page; }
    virtual Web::Page const& page() const override { return *m_page; }
    virtual bool is_connection_open() const override { return false; }
    virtual Gfx::Palette palette() const override { return Gfx::Palette { *m_palette_impl }; }
    virtual Web::DevicePixelRect screen_rect() const override { return { { 0, 0 }, m_viewport.to_type<Web::DevicePixels>() }; }
    // Page zoom (Ctrl +/-): the viewport's device pixels stay the window's, its CSS pixels grow or shrink.
    virtual double zoom_level() const override { return m_zoom; }
    virtual double device_pixel_ratio() const override { return 1.0; }
    virtual double device_pixels_per_css_pixel() const override { return m_zoom; }
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
    double m_zoom { 1.0 };
    NonnullRefPtr<Gfx::PaletteImpl> m_palette_impl;
    Queue<Web::QueuedInputEvent> m_input_event_queue;
    u64 m_next_primary_paste { 0 };
    Web::HTML::CrossProcessIdAllocator m_cross_process_ids { .namespace_id = 1 };
};

GC_DEFINE_ALLOCATOR(BrowserPageClient);

struct WebView::Impl {
    GC::Root<BrowserPageClient> client;
    GC::Root<Web::Page> page;
    GC::Root<Web::DOM::Document> document;
    GC::Root<Web::DOM::DocumentObserver> observer;
    RefPtr<Gfx::Bitmap> bitmap;
    RefPtr<Core::Timer> render_block_timer;
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
    if (m_fetch_id)
        Network::cancel(m_fetch_id);
    if (m_impl->client)
        m_impl->client->detach();
    // A tab closing may be the app quitting: localStorage is otherwise written half a second after a change.
    Storage::flush();
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

struct LoadedDocument {
    URL::URL url;
    ByteBuffer html;
    Optional<Web::MimeSniff::MimeType> mime_type;
};

// Downloads. A response is saved rather than shown when its Content-Disposition says attachment, or its type is one
// the engine has no way to show (not HTML, XML, text, an image, JSON or JavaScript), as Ladybird's navigation does.

static bool is_download(Network::Document const& document, Optional<Web::MimeSniff::MimeType> const& type)
{
    if (document.content_disposition.has_value()) {
        auto disposition = document.content_disposition->view().trim_whitespace();
        if (disposition.starts_with("attachment"sv, CaseSensitivity::CaseInsensitive))
            return true;
    }
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
    if (file_body.has_value())
        show_document({ document_url, file_body.release_value(), move(file_type) });
    else
        show_document({ document_url, MUST(ByteBuffer::copy(html.bytes())), {} });
}

void WebView::did_download(Download download)
{
    if (on_download)
        on_download(download);
}

void WebView::set_location(std::string url, bool add_to_history)
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
void WebView::show_document(LoadedDocument loaded)
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
    page->set_top_level_traversable(Web::HTML::LocalTraversableNavigable::create_a_new_top_level_traversable(page, nullptr, {}));
    auto& navigable = *page->local_traversable();
    auto& window = *navigable.active_window();
    navigable.set_viewport_size(page->device_to_css_size(viewport.to_type<Web::DevicePixels>()));

    auto document = Web::DOM::Document::create(*page, window, document_url);
    document->set_id(client->allocate_cross_process_id());
    document->set_origin(document_url.origin());
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

    m_title.clear();
    if (on_link_hover)
        on_link_hover({});

    if (as_text) {
        parse_text_document(*document, loaded.html, *loaded.mime_type, document_url);
    } else {
        auto parser = Web::HTML::HTMLParser::create_with_uncertain_encoding(*document, loaded.html, loaded.mime_type);
        parser->run(document_url);
    }
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
        m_impl->page->local_traversable()->set_viewport_size(m_impl->page->device_to_css_size(Gfx::IntSize { width, height }.to_type<Web::DevicePixels>()));
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
    // White below the page, as a browser's canvas is: a page with no background of its own is not see-through.
    __builtin_memset(target.scanline_u8(0), 0xff, target.size_in_bytes());
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
        fill_white(*m_impl->bitmap);
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
        m_impl->document->window()->scroll_by(dx / m_zoom, dy / m_zoom, nullptr);
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

void WebView::did_write_clipboard(std::string text, bool selection)
{
    if (on_clipboard_write)
        on_clipboard_write(text, selection);
}

void WebView::did_request_clipboard(uint64_t request, bool selection)
{
    if (on_clipboard_request)
        on_clipboard_request(request, selection);
    else
        answer_clipboard(request, {});
}

void WebView::answer_clipboard(uint64_t request, std::string const& text)
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

void WebView::did_hover_link(std::string url)
{
    if (on_link_hover)
        on_link_hover(url);
}

void WebView::did_request_context_menu(ContextMenu menu)
{
    if (on_context_menu)
        on_context_menu(menu);
}

static GC::Ptr<Web::HTML::LocalNavigable> focused_navigable(GC::Root<Web::Page> const& page)
{
    return page ? page->hosted_focused_navigable() : nullptr;
}

std::string WebView::selected_text() const
{
    auto navigable = focused_navigable(m_impl->page);
    return navigable ? to_std(navigable->selected_text().to_utf8().to_byte_string()) : std::string {};
}

void WebView::select_all()
{
    if (auto navigable = focused_navigable(m_impl->page))
        navigable->select_all();
    did_request_frame();
}

std::string WebView::cut_selection()
{
    auto navigable = focused_navigable(m_impl->page);
    auto text = navigable ? to_std(navigable->cut_selected_text().to_utf8().to_byte_string()) : std::string {};
    did_request_frame();
    return text;
}

void WebView::insert_text(std::string const& text)
{
    if (text.empty())
        return;
    if (auto navigable = focused_navigable(m_impl->page)) {
        auto utf16 = Utf16String::from_utf8_with_replacement_character(StringView { text.data(), text.size() });
        navigable->paste(utf16);
    }
    did_request_frame();
}


void WebView::set_zoom(double zoom)
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

static WebView::FindResult find_result(Web::Page::FindInPageResult const& result)
{
    return { unsigned(result.current_match_index), result.total_match_count.has_value() ? int(*result.total_match_count) : -1 };
}

WebView::FindResult WebView::find(std::string const& query, bool case_sensitive)
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

WebView::FindResult WebView::find_next()
{
    if (!m_impl->page || !m_impl->document)
        return { 0, 0 };
    auto result = m_impl->page->find_in_page_next_match();
    did_request_frame();
    return find_result(result);
}

WebView::FindResult WebView::find_previous()
{
    if (!m_impl->page || !m_impl->document)
        return { 0, 0 };
    auto result = m_impl->page->find_in_page_previous_match();
    did_request_frame();
    return find_result(result);
}

void WebView::find_end()
{
    if (m_impl->page && m_impl->document)
        m_impl->page->find_in_page_end();
    did_request_frame();
}

}
