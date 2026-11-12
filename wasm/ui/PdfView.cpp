/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The PDF viewer (PdfView.h), ported from the Nim front end's nim/src/features/pdf.nim: the same layout, zoom
// steps, selection and find rules, drawn with QPainter. MuPDF is behind webby:pdf (gui.h, the bindings of this
// component's world).

#include "PdfView.h"

#include "gui.h"

#include <QFontMetricsF>
#include <QKeyEvent>
#include <QPainter>
#include <QPainterPath>
#include <QtMath>
#include <algorithm>
#include <cmath>
#include <qt2wasm/gui.h>

namespace WebbyUI {

namespace {

constexpr double gap = 10;     // between pages and around them
constexpr int bar_height = 40; // the bar along the top
constexpr int panel_width = 280;
constexpr int panel_row = 28;
constexpr double zoom_steps[] = { 0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0 };
QColor const background { 0x52, 0x56, 0x59 }; // around the pages (Chrome's PDF viewer grey)
QColor const bar_color { 0x32, 0x36, 0x39 };
QColor const bar_text { 0xf1, 0xf3, 0xf4 };
QColor const bar_dim { 0xbd, 0xc1, 0xc6 };
QColor const bar_hover { 0x4a, 0x4e, 0x51 };
QColor const selection_color { 0x33, 0x90, 0xff, 90 };
QColor const match_color { 0xff, 0xd0, 0x00, 110 };
QColor const current_match_color { 0xff, 0x8c, 0x00, 140 };

QString from_wit(gui_string_t const& s) { return QString::fromUtf8(reinterpret_cast<char const*>(s.ptr), qsizetype(s.len)); }

bool is_space(char32_t c) { return QChar::isSpace(c); }
bool is_word_char(char32_t c) { return QChar::isLetterOrNumber(c) || c == '_' || c == '\''; }

QFont bar_font(int px = 13)
{
    QFont f;
    f.setPixelSize(px);
    return f;
}

}

// The MuPDF document, a webby:pdf resource.
struct PdfView::Document {
    webby_pdf_documents_own_document_t handle;
    ~Document() { webby_pdf_documents_document_drop_own(handle); }
    webby_pdf_documents_borrow_document_t borrow() const { return webby_pdf_documents_borrow_document(handle); }
};

PdfView::PdfView(QString url, QByteArray data, QString mime)
    : m_url(std::move(url))
    , m_data(std::move(data))
{
    // The canonical ABI copies the bytes into the PDF component; the call only borrows them.
    gui_list_u8_t bytes { reinterpret_cast<uint8_t*>(m_data.data()), size_t(m_data.size()) };
    QByteArray kind = (mime.isEmpty() ? QStringLiteral("application/pdf") : mime).toUtf8();
    gui_string_t kind_s { reinterpret_cast<uint8_t*>(kind.data()), size_t(kind.size()) };
    webby_pdf_documents_own_document_t handle;
    gui_string_t err {};
    if (!webby_pdf_documents_static_document_open(&bytes, &kind_s, &handle, &err)) {
        m_failed = true;
        m_error = from_wit(err);
        gui_string_free(&err);
        return;
    }
    // Made in place: a temporary Document would drop the handle when it goes.
    m_doc.reset(new Document { handle });
    webby_pdf_documents_info_t info {};
    webby_pdf_documents_method_document_info(m_doc->borrow(), &info);
    for (size_t i = 0; i < info.pages.len; ++i) {
        Page p;
        p.w = std::max(1.0f, info.pages.ptr[i].width);
        p.h = std::max(1.0f, info.pages.ptr[i].height);
        m_pages.push_back(std::move(p));
    }
    m_title = from_wit(info.title).simplified();
    for (size_t i = 0; i < info.outline.len; ++i) {
        auto const& o = info.outline.ptr[i];
        m_outline.push_back({ int(o.level), from_wit(o.title).simplified(), o.page, o.y });
    }
    webby_pdf_documents_info_free(&info);
    if (m_pages.empty()) {
        m_failed = true;
        m_error = QStringLiteral("it has no pages");
    }
}

PdfView::~PdfView() = default;

QString PdfView::title() const
{
    if (!m_title.isEmpty())
        return m_title;
    auto name = file_name();
    return name;
}

QString PdfView::file_name() const
{
    auto path = m_url.section(u'?', 0, 0).section(u'#', 0, 0);
    auto name = QString::fromUtf8(QByteArray::fromPercentEncoding(path.section(u'/', -1).toUtf8()));
    name.replace(u'\\', u'_');
    while (name.startsWith(u'.'))
        name.remove(0, 1);
    if (name.isEmpty())
        name = QStringLiteral("document");
    if (!name.endsWith(QStringLiteral(".pdf"), Qt::CaseInsensitive))
        name += QStringLiteral(".pdf");
    return name;
}

void PdfView::invalidate()
{
    m_dirty = true;
    if (on_needs_paint)
        on_needs_paint();
}

void PdfView::set_status(QString const& status)
{
    m_status = status;
    invalidate();
}

// Layout.

QRectF PdfView::viewport() const
{
    double left = m_panel_open ? panel_width : 0;
    return QRectF(left, bar_height, std::max(0.0, m_size.width() - left), std::max(0, m_size.height() - bar_height));
}

void PdfView::layout()
{
    double s = scale();
    m_tops.resize(m_pages.size());
    double y = gap;
    for (size_t i = 0; i < m_pages.size(); ++i) {
        m_tops[i] = y;
        y += std::round(m_pages[i].h * s) + gap;
    }
}

double PdfView::total_height() const
{
    if (m_pages.empty())
        return 0;
    return m_tops.back() + std::round(m_pages.back().h * scale()) + gap;
}

double PdfView::total_width() const
{
    double w = 0;
    for (auto const& p : m_pages)
        w = std::max(w, double(p.w));
    return std::round(w * scale()) + 2 * gap;
}

void PdfView::clamp_scroll()
{
    auto vp = viewport();
    m_scroll_y = std::clamp(m_scroll_y, 0.0, std::max(0.0, total_height() - vp.height()));
    m_scroll_x = std::clamp(m_scroll_x, 0.0, std::max(0.0, total_width() - vp.width()));
}

// The page's left edge in the viewport.
double PdfView::page_left(int i) const
{
    auto vp = viewport();
    double pw = std::round(m_pages[i].w * scale());
    if (total_width() <= vp.width())
        return std::round((vp.width() - pw) / 2);
    return std::round((total_width() - pw) / 2 - m_scroll_x);
}

std::pair<int, int> PdfView::visible_range() const
{
    auto vp = viewport();
    double s = scale();
    std::pair<int, int> r { -1, -1 };
    for (int i = 0; i < int(m_pages.size()); ++i) {
        double top = m_tops[i] - m_scroll_y;
        if (top + m_pages[i].h * s < 0)
            continue;
        if (top > vp.height())
            break;
        if (r.first < 0)
            r.first = i;
        r.second = i;
    }
    return r;
}

// The page at the viewport's upper third (the one being read).
int PdfView::current_page() const
{
    double mid = m_scroll_y + viewport().height() / 3;
    int page = 0;
    for (int i = 0; i < int(m_pages.size()); ++i) {
        if (m_tops[i] <= mid)
            page = i;
    }
    return page;
}

double PdfView::fit_zoom() const
{
    double w = 0;
    for (auto const& p : m_pages)
        w = std::max(w, double(p.w));
    auto vw = viewport().width();
    if (w <= 0 || vw <= 0)
        return 1;
    return std::clamp((vw - 2 * gap) / (w * 96.0 / 72.0), 0.25, 1.25);
}

void PdfView::resize(QSize size)
{
    if (size == m_size)
        return;
    bool first = m_size.isEmpty();
    m_size = size;
    if (m_fit_width && !m_pages.empty()) {
        if (first) {
            m_zoom = fit_zoom();
            layout();
        } else {
            set_zoom(fit_zoom(), true);
        }
    }
    if (m_tops.size() != m_pages.size())
        layout();
    clamp_scroll();
    invalidate();
}

void PdfView::scroll_to(double y, double x)
{
    m_scroll_y = y;
    if (x >= 0)
        m_scroll_x = x;
    clamp_scroll();
    m_field_text.clear();
    invalidate();
}

void PdfView::go_to_page(int i, double y_pt)
{
    if (m_failed || m_pages.empty())
        return;
    i = std::clamp(i, 0, int(m_pages.size()) - 1);
    scroll_to(m_tops[i] + y_pt * scale() - (y_pt > 0 ? gap * 2 : gap));
}

// The spot under the anchor (viewport coordinates; the middle by default) stays put.
void PdfView::set_zoom(double z, bool fit, QPointF anchor)
{
    if (m_failed)
        return;
    auto vp = viewport();
    // Without an anchor the middle of the view stays put, except at the top or left edge, which stays there (a
    // window that grows, or Fit width, must not scroll a document still at its start).
    double ax = anchor.x() >= 0 ? anchor.x() : m_scroll_x <= 0 ? 0 : vp.width() / 2;
    double ay = anchor.y() >= 0 ? anchor.y() : m_scroll_y <= 0 ? 0 : vp.height() / 2;
    double fy = (m_scroll_y + ay) / std::max(1.0, total_height());
    double fx = (m_scroll_x + ax) / std::max(1.0, total_width());
    m_fit_width = fit;
    m_zoom = std::clamp(z, zoom_steps[0], zoom_steps[std::size(zoom_steps) - 1]);
    layout();
    m_scroll_y = fy * total_height() - ay;
    m_scroll_x = fx * total_width() - ax;
    scroll_to(m_scroll_y);
}

void PdfView::zoom_step(int steps, QPointF anchor)
{
    if (steps == 0) {
        set_zoom(fit_zoom(), true);
        return;
    }
    QPointF a = anchor;
    if (a.x() >= 0)
        a -= viewport().topLeft();
    double z = m_zoom;
    for (int n = 0; n < std::abs(steps); ++n) {
        if (steps > 0) {
            for (double s : zoom_steps) {
                if (s > z + 0.001) {
                    z = s;
                    break;
                }
            }
        } else {
            for (int i = int(std::size(zoom_steps)) - 1; i >= 0; --i) {
                if (zoom_steps[i] < z - 0.001) {
                    z = zoom_steps[i];
                    break;
                }
            }
        }
    }
    set_zoom(z, false, a);
}

// Work: what is on screen and not here yet, nearest the page being read first, a page either side too; then the
// text of the pages on screen (selection, links), then (find, select all) every page's.

void PdfView::render(int i)
{
    auto& p = m_pages[i];
    float s = scale();
    webby_pdf_documents_pixels_t px {};
    gui_string_t err {};
    if (!webby_pdf_documents_method_document_render(m_doc->borrow(), uint32_t(i), s, &px, &err)) {
        gui_string_free(&err);
        // A white page, so it is not asked for again at this zoom.
        p.image = QImage(1, 1, QImage::Format_ARGB32_Premultiplied);
        p.image.fill(Qt::white);
        p.image_scale = s;
        return;
    }
    QImage image(int(px.width), int(px.height), QImage::Format_ARGB32_Premultiplied);
    if (!image.isNull() && px.data.len >= size_t(px.width) * px.height * 4) {
        for (uint32_t y = 0; y < px.height; ++y)
            memcpy(image.scanLine(int(y)), px.data.ptr + size_t(y) * px.width * 4, size_t(px.width) * 4);
    }
    gui_list_u8_free(&px.data);
    p.image = std::move(image);
    p.image_scale = s;
}

void PdfView::read_text(int i)
{
    auto& p = m_pages[i];
    p.text_state = 2;
    webby_pdf_documents_page_text_t text {};
    gui_string_t err {};
    if (!webby_pdf_documents_method_document_text(m_doc->borrow(), uint32_t(i), &text, &err)) {
        gui_string_free(&err);
        build_find_text(i);
        return;
    }
    p.chars.clear();
    for (size_t l = 0; l < text.lines.len; ++l) {
        auto const& line = text.lines.ptr[l];
        for (size_t k = 0; k < line.len; ++k) {
            auto const& c = line.ptr[k];
            p.chars.push_back({ c.x0, c.y0, c.x1, c.y1, char32_t(c.c), k + 1 == line.len });
        }
    }
    p.links.clear();
    for (size_t l = 0; l < text.links.len; ++l) {
        auto const& k = text.links.ptr[l];
        p.links.push_back({ k.x0, k.y0, k.x1, k.y1, from_wit(k.uri), k.page, k.y });
    }
    webby_pdf_documents_page_text_free(&text);
    build_find_text(i);
}

bool PdfView::pump()
{
    if (m_failed || m_size.isEmpty())
        return false;
    auto [first, last] = visible_range();
    if (first < 0)
        return false;
    float s = scale();
    int mid = current_page();
    std::vector<int> want;
    for (int i = std::max(0, first - 1); i <= std::min(int(m_pages.size()) - 1, last + 1); ++i)
        want.push_back(i);
    std::stable_sort(want.begin(), want.end(), [mid](int a, int b) { return std::abs(a - mid) < std::abs(b - mid); });
    for (int i : want) {
        auto& p = m_pages[i];
        if (!p.image.isNull() && std::abs(p.image_scale - s) < 0.0005f)
            continue;
        render(i);
        // Pages far off screen give their pixels back.
        for (int k = 0; k < int(m_pages.size()); ++k) {
            if ((k < first - 3 || k > last + 3) && !m_pages[k].image.isNull()) {
                m_pages[k].image = {};
                m_pages[k].image_scale = 0;
            }
        }
        invalidate();
        return true;
    }
    for (int i = first; i <= last; ++i) {
        if (m_pages[i].text_state == 0) {
            read_text(i);
            if (m_find_shown && !m_query.isEmpty())
                rematch();
            invalidate();
            return true;
        }
    }
    if ((m_find_shown && !m_query.isEmpty()) || m_select_all_pending) {
        for (int i = 0; i < int(m_pages.size()); ++i) {
            if (m_pages[i].text_state == 0) {
                read_text(i);
                if (m_find_shown && !m_query.isEmpty()) {
                    bool had = m_current_match >= 0;
                    Match cur = had ? m_matches[m_current_match] : Match { -1, 0, 0 };
                    rematch();
                    if (had) {
                        for (int k = 0; k < int(m_matches.size()); ++k) {
                            if (m_matches[k] == cur)
                                m_current_match = k;
                        }
                    } else if (m_current_match >= 0) {
                        scroll_to_match();
                    }
                }
                invalidate();
                return true;
            }
        }
        m_select_all_pending = false;
    }
    return false;
}

// Find.

void PdfView::build_find_text(int i)
{
    auto& p = m_pages[i];
    p.find_text.clear();
    p.find_map.clear();
    for (int k = 0; k < int(p.chars.size()); ++k) {
        auto c = p.chars[k].c;
        p.find_text.push_back(char32_t(QChar::toCaseFolded(uint(c))));
        p.find_map.push_back(k);
        if (p.chars[k].line_end && c != '-' && !is_space(c)) {
            p.find_text.push_back(U' ');
            p.find_map.push_back(-1);
        }
    }
}

void PdfView::rematch(int keep_page)
{
    m_matches.clear();
    m_current_match = -1;
    std::u32string q;
    for (auto c : m_query.toCaseFolded().toUcs4())
        q.push_back(char32_t(c));
    if (q.empty())
        return;
    for (int i = 0; i < int(m_pages.size()); ++i) {
        auto const& p = m_pages[i];
        if (p.text_state != 2)
            continue;
        size_t at = 0;
        while ((at = p.find_text.find(q, at)) != std::u32string::npos) {
            int first = -1, last = -1;
            for (size_t k = at; k < at + q.size(); ++k) {
                if (p.find_map[k] >= 0) {
                    if (first < 0)
                        first = p.find_map[k];
                    last = p.find_map[k];
                }
            }
            if (first >= 0)
                m_matches.push_back({ i, first, last + 1 });
            at += q.size();
        }
    }
    if (!m_matches.empty()) {
        int from = keep_page >= 0 ? keep_page : current_page();
        m_current_match = 0;
        for (int k = 0; k < int(m_matches.size()); ++k) {
            if (m_matches[k].page >= from) {
                m_current_match = k;
                break;
            }
        }
    }
}

void PdfView::scroll_to_match()
{
    if (m_current_match < 0 || m_current_match >= int(m_matches.size()))
        return;
    auto m = m_matches[m_current_match];
    auto const& c = m_pages[m.page].chars[m.first];
    auto vp = viewport();
    double s = scale();
    double y = m_tops[m.page] + c.y0 * s;
    if (y < m_scroll_y + vp.height() * 0.1 || y > m_scroll_y + vp.height() * 0.8)
        m_scroll_y = y - vp.height() / 3;
    double x = page_left(m.page) + m_scroll_x + c.x0 * s;
    if (total_width() > vp.width() && (x < m_scroll_x || x > m_scroll_x + vp.width() * 0.9))
        m_scroll_x = x - vp.width() / 3;
    scroll_to(m_scroll_y);
}

WebView::FindResult PdfView::find_result() const
{
    bool complete = true;
    for (auto const& p : m_pages)
        complete = complete && p.text_state == 2;
    WebView::FindResult r;
    r.total = !complete && m_matches.empty() ? -1 : int(m_matches.size());
    r.index = m_current_match >= 0 ? unsigned(m_current_match) : 0;
    return r;
}

WebView::FindResult PdfView::find(QString const& query)
{
    m_find_shown = true;
    m_query = query;
    if (m_failed)
        return {};
    // The pages on screen first, so the first matches show at once; the rest come in pump().
    auto [first, last] = visible_range();
    for (int i = std::max(0, first); i <= last && i >= 0; ++i) {
        if (m_pages[i].text_state == 0)
            read_text(i);
    }
    rematch();
    scroll_to_match();
    invalidate();
    return find_result();
}

WebView::FindResult PdfView::find_next()
{
    if (!m_matches.empty()) {
        m_current_match = (m_current_match + 1) % int(m_matches.size());
        scroll_to_match();
        invalidate();
    }
    return find_result();
}

WebView::FindResult PdfView::find_previous()
{
    if (!m_matches.empty()) {
        m_current_match = (m_current_match + int(m_matches.size()) - 1) % int(m_matches.size());
        scroll_to_match();
        invalidate();
    }
    return find_result();
}

void PdfView::find_end()
{
    m_find_shown = false;
    m_matches.clear();
    m_current_match = -1;
    invalidate();
}

// Hit testing.

QRectF PdfView::part_rect(Part part) const
{
    QFontMetricsF m(bar_font());
    double x = 8;
    auto button = [](double x) { return QRectF(x, 4, 32, 32); };
    switch (part) {
    case Part::Contents:
        return button(x);
    case Part::PageField:
        x += 40 + m.horizontalAdvance(QStringLiteral("Page")) + 8;
        return QRectF(x, 8, 44, 24);
    case Part::ZoomOut:
    case Part::ZoomIn:
    case Part::Fit: {
        x += 40 + m.horizontalAdvance(QStringLiteral("Page")) + 8 + 44 + 8
            + m.horizontalAdvance(QStringLiteral("of %1").arg(m_pages.size())) + 20;
        if (part == Part::ZoomOut)
            return button(x);
        x += 32 + 56;
        if (part == Part::ZoomIn)
            return button(x);
        x += 40;
        return QRectF(x, 6, m.horizontalAdvance(QStringLiteral("Fit width")) + 20, 28);
    }
    case Part::Save:
        return button(m_size.width() - 40);
    case Part::Panel:
        return m_panel_open ? QRectF(0, bar_height, panel_width, m_size.height() - bar_height) : QRectF();
    case Part::PanelClose:
        return m_panel_open ? QRectF(panel_width - 36, bar_height + 6, 28, 28) : QRectF();
    default:
        return {};
    }
}

PdfView::Part PdfView::part_at(QPointF p) const
{
    if (p.y() < bar_height) {
        for (auto part : { Part::Contents, Part::PageField, Part::ZoomOut, Part::ZoomIn, Part::Fit, Part::Save }) {
            if (part_rect(part).contains(p))
                return part;
        }
        return Part::None;
    }
    if (m_panel_open && p.x() < panel_width)
        return part_rect(Part::PanelClose).contains(p) ? Part::PanelClose : Part::Panel;
    auto vp = viewport();
    QPointF v = p - vp.topLeft();
    double grab = 12;
    if (bar_shown(1) && v.x() >= vp.width() - grab)
        return Part::VBar;
    if (bar_shown(2) && v.y() >= vp.height() - grab)
        return Part::HBar;
    return Part::Pages;
}

// The page under (or nearest to) a frame point, and the point in that page's points.
PdfView::PageHit PdfView::hit(QPointF at) const
{
    PageHit r { -1, 0, 0 };
    if (m_failed || m_pages.empty())
        return r;
    auto vp = viewport();
    QPointF v = at - vp.topLeft();
    double s = scale();
    double doc_y = v.y() + m_scroll_y;
    int best = 0;
    for (int i = 0; i < int(m_pages.size()); ++i) {
        if (m_tops[i] - gap / 2 <= doc_y)
            best = i;
    }
    r.page = best;
    r.px = (v.x() - page_left(best)) / s;
    r.py = (doc_y - m_tops[best]) / s;
    return r;
}

// The caret (a chars index: before that char) nearest to (x, y) in page i's points.
int PdfView::caret_at(int i, double x, double y) const
{
    auto const& chars = m_pages[i].chars;
    if (chars.empty())
        return 0;
    if (y < chars[0].y0 - 2 && x < chars[0].x1)
        return 0;
    int best_start = 0, best_end = 0;
    double best = INFINITY;
    for (int k = 0; k < int(chars.size()); ++k) {
        int start = k;
        double x0 = chars[k].x0, x1 = chars[k].x1, y0 = chars[k].y0, y1 = chars[k].y1;
        while (!chars[k].line_end && k + 1 < int(chars.size())) {
            ++k;
            x0 = std::min(x0, double(chars[k].x0));
            x1 = std::max(x1, double(chars[k].x1));
            y0 = std::min(y0, double(chars[k].y0));
            y1 = std::max(y1, double(chars[k].y1));
        }
        double dy = y < y0 ? y0 - y : y > y1 ? y - y1 : 0;
        double dx = x < x0 ? x0 - x : x > x1 ? x - x1 : 0;
        double dist = dy * 4 + dx;
        if (dist < best) {
            best = dist;
            best_start = start;
            best_end = k;
        }
    }
    for (int c = best_start; c <= best_end; ++c) {
        if (x < (chars[c].x0 + chars[c].x1) / 2)
            return c;
    }
    return best_end + 1;
}

PdfView::Caret PdfView::caret_from(QPointF p) const
{
    auto h = hit(p);
    if (h.page < 0)
        return {};
    return { h.page, caret_at(h.page, h.px, h.py) };
}

PdfView::Link const* PdfView::link_ptr(QPointF p) const
{
    if (part_at(p) != Part::Pages)
        return nullptr;
    auto h = hit(p);
    if (h.page < 0)
        return nullptr;
    for (auto const& l : m_pages[h.page].links) {
        if (h.px >= l.x0 && h.px <= l.x1 && h.py >= l.y0 && h.py <= l.y1)
            return &l;
    }
    return nullptr;
}

PdfView::LinkTarget PdfView::link_at(QPointF p) const
{
    if (auto const* l = link_ptr(p))
        return { l->uri, l->page };
    return {};
}

std::pair<PdfView::Caret, PdfView::Caret> PdfView::sel_range() const
{
    bool forward = m_sel_a.page < m_sel_b.page || (m_sel_a.page == m_sel_b.page && m_sel_a.index <= m_sel_b.index);
    return forward ? std::pair { m_sel_a, m_sel_b } : std::pair { m_sel_b, m_sel_a };
}

bool PdfView::has_selection() const { return !(m_sel_a == m_sel_b); }

QString PdfView::selected_text() const
{
    if (!has_selection() || m_pages.empty())
        return {};
    auto [lo, hi] = sel_range();
    std::u32string out;
    for (int i = lo.page; i <= hi.page && i < int(m_pages.size()); ++i) {
        auto const& chars = m_pages[i].chars;
        int a = i == lo.page ? lo.index : 0;
        int b = std::min(i == hi.page ? hi.index : int(chars.size()), int(chars.size()));
        for (int k = a; k < b; ++k) {
            out.push_back(chars[k].c);
            if (chars[k].line_end && (k + 1 < b || (i < hi.page && k == b - 1))) {
                if (chars[k].c == '-')
                    out.pop_back();
                else if (!is_space(chars[k].c))
                    out.push_back(U'\n');
            }
        }
    }
    while (!out.empty() && is_space(out.back()))
        out.pop_back();
    return QString::fromUcs4(out.data(), qsizetype(out.size()));
}

void PdfView::copy_selection()
{
    if (has_selection())
        qt2wasm::gui::setClipboardText(selected_text());
}

void PdfView::select_word(Caret c, bool line)
{
    auto const& chars = m_pages[c.page].chars;
    if (chars.empty())
        return;
    int a = std::min(c.index, int(chars.size()) - 1);
    int b = a;
    if (line) {
        while (a > 0 && !chars[a - 1].line_end)
            --a;
        while (b < int(chars.size()) - 1 && !chars[b].line_end)
            ++b;
    } else if (is_word_char(chars[a].c)) {
        while (a > 0 && !chars[a - 1].line_end && is_word_char(chars[a - 1].c))
            --a;
        while (b < int(chars.size()) - 1 && !chars[b].line_end && is_word_char(chars[b + 1].c))
            ++b;
    }
    m_sel_a = { c.page, a };
    m_sel_b = { c.page, b + 1 };
}

void PdfView::select_all()
{
    if (m_failed)
        return;
    m_select_all_pending = true;
    m_sel_a = { 0, 0 };
    m_sel_b = { int(m_pages.size()) - 1, INT32_MAX / 2 };
    invalidate();
}

// Scrollbars, drawn as Ladybird draws a page's, in light colours for the grey around the pages.

bool PdfView::bar_shown(int which) const
{
    if (m_failed)
        return false;
    auto vp = viewport();
    return which == 1 ? total_height() > vp.height() + 0.5 : total_width() > vp.width() + 0.5;
}

// The scrollbar's strip along the viewport's right (1) or bottom (2) edge, in viewport coordinates.
QRectF PdfView::bar_track(int which) const
{
    auto vp = viewport();
    double t = (m_bar_hover == which || m_bar_drag == which) ? 12 : 8;
    if (which == 1)
        return QRectF(vp.width() - t, 0, t, vp.height() - (bar_shown(2) ? 12 : 0));
    return QRectF(0, vp.height() - t, vp.width() - (bar_shown(1) ? 12 : 0), t);
}

std::pair<double, double> PdfView::bar_thumb(int which) const
{
    auto vp = viewport();
    auto tr = bar_track(which);
    double room = which == 1 ? tr.height() : tr.width();
    double view = which == 1 ? vp.height() : vp.width();
    double total = which == 1 ? total_height() : total_width();
    double pos = which == 1 ? m_scroll_y : m_scroll_x;
    double len = std::clamp(room * view / std::max(total, 1.0), std::min(24.0, room), room);
    double span = std::max(total - view, 1.0);
    return { std::clamp(pos / span, 0.0, 1.0) * (room - len), len };
}

void PdfView::scroll_from_bar(int which, double along)
{
    auto vp = viewport();
    auto tr = bar_track(which);
    auto th = bar_thumb(which);
    double room = (which == 1 ? tr.height() : tr.width()) - th.second;
    double f = room > 0 ? std::clamp(along / room, 0.0, 1.0) : 0;
    if (which == 1)
        scroll_to(f * (total_height() - vp.height()));
    else
        scroll_to(m_scroll_y, f * (total_width() - vp.width()));
}

int PdfView::panel_row_at(QPointF p) const
{
    if (!m_panel_open || p.x() >= panel_width || p.y() < bar_height + 40)
        return -1;
    int row = int((p.y() - bar_height - 40 + m_panel_scroll) / panel_row);
    return row >= 0 && row < int(m_outline.size()) ? row : -1;
}

// Input.

void PdfView::mouse_press(QPointF p, Qt::MouseButton button, Qt::KeyboardModifiers mods, int clicks)
{
    m_down_at = p;
    auto part = part_at(p);
    if (part != Part::PageField && m_field_focused) {
        m_field_focused = false;
        invalidate();
    }
    if (button != Qt::LeftButton && button != Qt::MiddleButton)
        return;
    switch (part) {
    case Part::PageField:
        m_field_focused = true;
        m_field_text.clear();
        invalidate();
        return;
    case Part::VBar:
    case Part::HBar: {
        int which = part == Part::VBar ? 1 : 2;
        auto th = bar_thumb(which);
        auto tr = bar_track(which);
        auto v = p - viewport().topLeft();
        double along = which == 1 ? v.y() - tr.top() : v.x() - tr.left();
        m_bar_drag = which;
        m_bar_grab = along >= th.first && along <= th.first + th.second ? along - th.first : th.second / 2;
        scroll_from_bar(which, along - m_bar_grab);
        return;
    }
    case Part::Pages: {
        if (button != Qt::LeftButton || m_failed)
            return;
        auto c = caret_from(p);
        if (clicks >= 2 && m_pages[c.page].text_state == 2) {
            select_word(c, clicks >= 3);
            m_dragging = false;
        } else if ((mods & Qt::ShiftModifier) && has_selection()) {
            m_sel_b = c;
            m_dragging = true;
        } else {
            m_sel_a = m_sel_b = c;
            m_dragging = true;
        }
        invalidate();
        return;
    }
    default:
        return;
    }
}

void PdfView::mouse_move(QPointF p, Qt::MouseButtons buttons, Qt::KeyboardModifiers)
{
    auto vp = viewport();
    if (m_bar_drag) {
        if (!(buttons & Qt::LeftButton)) {
            m_bar_drag = 0;
            invalidate();
            return;
        }
        auto tr = bar_track(m_bar_drag);
        auto v = p - vp.topLeft();
        scroll_from_bar(m_bar_drag, (m_bar_drag == 1 ? v.y() - tr.top() : v.x() - tr.left()) - m_bar_grab);
        return;
    }
    if (m_dragging && (buttons & Qt::LeftButton)) {
        m_sel_b = caret_from(p);
        // Dragging past the top or bottom edge scrolls.
        if (p.y() < vp.top())
            scroll_to(m_scroll_y + (p.y() - vp.top()));
        else if (p.y() > vp.bottom())
            scroll_to(m_scroll_y + (p.y() - vp.bottom()));
        invalidate();
        return;
    }
    auto part = part_at(p);
    int bar = part == Part::VBar ? 1 : part == Part::HBar ? 2 : 0;
    int row = panel_row_at(p);
    if (bar != m_bar_hover || part != m_hover || row != m_panel_hover) {
        m_bar_hover = bar;
        m_hover = part;
        m_panel_hover = row;
        invalidate();
    }
    QString link;
    if (auto const* l = link_ptr(p))
        link = l->uri.isEmpty() ? QStringLiteral("Page %1").arg(l->page + 1) : l->uri;
    if (link != m_hovered_link) {
        m_hovered_link = link;
        if (on_link_hover)
            on_link_hover(link);
    }
}

void PdfView::mouse_release(QPointF p, Qt::MouseButton button, Qt::KeyboardModifiers mods)
{
    if (m_bar_drag) {
        m_bar_drag = 0;
        invalidate();
        return;
    }
    m_dragging = false;
    bool still = std::abs(p.x() - m_down_at.x()) < 4 && std::abs(p.y() - m_down_at.y()) < 4;
    if (!still || (button != Qt::LeftButton && button != Qt::MiddleButton))
        return;
    auto part = part_at(p);
    if (part != part_at(m_down_at))
        return;
    switch (part) {
    case Part::Contents:
        m_panel_open = !m_panel_open;
        if (m_fit_width)
            set_zoom(fit_zoom(), true);
        clamp_scroll();
        invalidate();
        return;
    case Part::PanelClose:
        m_panel_open = false;
        if (m_fit_width)
            set_zoom(fit_zoom(), true);
        invalidate();
        return;
    case Part::Panel: {
        int row = panel_row_at(p);
        if (row >= 0 && m_outline[row].page >= 0)
            go_to_page(m_outline[row].page, m_outline[row].y);
        return;
    }
    case Part::ZoomOut:
        zoom_step(-1);
        return;
    case Part::ZoomIn:
        zoom_step(1);
        return;
    case Part::Fit:
        zoom_step(0);
        return;
    case Part::Save:
        if (on_save)
            on_save();
        return;
    case Part::Pages:
        if (auto const* l = link_ptr(p)) {
            if (!l->uri.isEmpty()) {
                if (on_open_url)
                    on_open_url(l->uri, button == Qt::MiddleButton || (mods & Qt::ControlModifier));
            } else if (l->page >= 0) {
                m_sel_b = m_sel_a;
                go_to_page(l->page, l->y);
            }
        }
        return;
    default:
        return;
    }
}

void PdfView::mouse_leave()
{
    if (m_bar_hover || m_hover != Part::None || m_panel_hover >= 0) {
        m_bar_hover = 0;
        m_hover = Part::None;
        m_panel_hover = -1;
        invalidate();
    }
    if (!m_hovered_link.isEmpty()) {
        m_hovered_link.clear();
        if (on_link_hover)
            on_link_hover({});
    }
}

void PdfView::wheel(QPointF p, QPointF pixel_delta, QPoint angle_delta, Qt::KeyboardModifiers mods)
{
    if (m_failed)
        return;
    if (mods & Qt::ControlModifier) {
        if (angle_delta.y())
            zoom_step(angle_delta.y() > 0 ? 1 : -1, p);
        return;
    }
    // A notch (120 eighths of a degree) is three 40-pixel lines, as on web pages; a touchpad reports pixels.
    QPointF d = !pixel_delta.isNull() ? -pixel_delta : QPointF(-angle_delta) / 120.0 * 120.0;
    if ((mods & Qt::ShiftModifier) && d.x() == 0)
        d = QPointF(d.y(), 0);
    if (m_panel_open && p.x() < panel_width && p.y() >= bar_height) {
        double room = std::max(0.0, m_outline.size() * double(panel_row) - (m_size.height() - bar_height - 40));
        m_panel_scroll = std::clamp(m_panel_scroll + d.y(), 0.0, room);
        invalidate();
        return;
    }
    scroll_to(m_scroll_y + d.y(), std::max(0.0, m_scroll_x + d.x()));
}

bool PdfView::key_press(QKeyEvent* event)
{
    auto mods = event->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier | Qt::MetaModifier);
    int key = event->key();
    if (m_field_focused) {
        if (key == Qt::Key_Return || key == Qt::Key_Enter) {
            bool ok = false;
            int n = m_field_text.toInt(&ok);
            m_field_focused = false;
            if (ok)
                go_to_page(n - 1);
            m_field_text.clear();
            invalidate();
        } else if (key == Qt::Key_Escape) {
            m_field_focused = false;
            m_field_text.clear();
            invalidate();
        } else if (key == Qt::Key_Backspace) {
            m_field_text.chop(1);
            invalidate();
        } else if (!event->text().isEmpty() && event->text()[0].isDigit() && m_field_text.size() < 5) {
            m_field_text += event->text()[0];
            invalidate();
        }
        return true;
    }
    if (m_failed)
        return false;
    auto vp = viewport();
    double line = 40;
    if (mods == Qt::ControlModifier) {
        switch (key) {
        case Qt::Key_C:
            copy_selection();
            return true;
        case Qt::Key_A:
            select_all();
            return true;
        case Qt::Key_S:
            if (on_save)
                on_save();
            return true;
        case Qt::Key_Home:
            scroll_to(0);
            return true;
        case Qt::Key_End:
            scroll_to(total_height());
            return true;
        default:
            return false;
        }
    }
    if (mods & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier))
        return false;
    bool shift = mods & Qt::ShiftModifier;
    switch (key) {
    case Qt::Key_Down:
        scroll_to(m_scroll_y + line);
        return true;
    case Qt::Key_Up:
        scroll_to(m_scroll_y - line);
        return true;
    case Qt::Key_PageDown:
        scroll_to(m_scroll_y + vp.height() * 0.9);
        return true;
    case Qt::Key_PageUp:
        scroll_to(m_scroll_y - vp.height() * 0.9);
        return true;
    case Qt::Key_Space:
        scroll_to(m_scroll_y + (shift ? -1 : 1) * vp.height() * 0.9);
        return true;
    case Qt::Key_Home:
        scroll_to(0);
        return true;
    case Qt::Key_End:
        scroll_to(total_height());
        return true;
    case Qt::Key_Left:
        if (total_width() > vp.width())
            scroll_to(m_scroll_y, std::max(0.0, m_scroll_x - line));
        else
            go_to_page(current_page() - 1);
        return true;
    case Qt::Key_Right:
        if (total_width() > vp.width())
            scroll_to(m_scroll_y, m_scroll_x + line);
        else
            go_to_page(current_page() + 1);
        return true;
    case Qt::Key_Escape:
        if (has_selection()) {
            m_sel_b = m_sel_a;
            invalidate();
            return true;
        }
        return false;
    default:
        return false;
    }
}

// Painting.

QImage const& PdfView::paint()
{
    if (m_dirty || m_frame.size() != m_size)
        compose();
    return m_frame;
}

void PdfView::compose()
{
    m_dirty = false;
    if (m_size.isEmpty()) {
        m_frame = {};
        return;
    }
    if (m_frame.size() != m_size)
        m_frame = QImage(m_size, QImage::Format_ARGB32_Premultiplied);
    m_frame.fill(background);
    QPainter p(&m_frame);
    p.setRenderHint(QPainter::Antialiasing);
    if (m_failed) {
        p.setPen(bar_text);
        p.setFont(bar_font(15));
        p.drawText(QRectF(0, bar_height, m_size.width(), m_size.height() - bar_height).adjusted(24, 24, -24, -24),
            Qt::AlignCenter | Qt::TextWordWrap, QStringLiteral("Couldn't open this PDF: %1").arg(m_error));
    } else {
        paint_pages(p);
        paint_scrollbars(p);
    }
    paint_panel(p);
    paint_bar(p);
}

void PdfView::tint_chars(QPainter& p, int i, int first, int last, double left, double top, QColor color)
{
    auto const& chars = m_pages[i].chars;
    double s = scale();
    last = std::min(last, int(chars.size()));
    for (int k = first; k < last; ++k) {
        auto const& c = chars[k];
        p.fillRect(QRectF(left + c.x0 * s, top + c.y0 * s, (c.x1 - c.x0) * s, (c.y1 - c.y0) * s), color);
    }
}

void PdfView::paint_pages(QPainter& p)
{
    auto vp = viewport();
    p.save();
    p.setClipRect(vp);
    p.translate(vp.topLeft());
    auto [first, last] = visible_range();
    double s = scale();
    auto [lo, hi] = sel_range();
    for (int i = first; i >= 0 && i <= last; ++i) {
        auto const& page = m_pages[i];
        double left = page_left(i);
        double top = m_tops[i] - m_scroll_y;
        QRectF r(left, top, std::round(page.w * s), std::round(page.h * s));
        if (!page.image.isNull()) {
            // An older zoom's pixels are stretched until the new ones come.
            p.setRenderHint(QPainter::SmoothPixmapTransform, std::abs(page.image_scale - s) > 0.0005f);
            p.drawImage(r, page.image);
        } else {
            p.fillRect(r, Qt::white);
        }
        if (page.text_state != 2 || page.chars.empty())
            continue;
        if (m_find_shown) {
            for (int k = 0; k < int(m_matches.size()); ++k) {
                auto const& m = m_matches[k];
                if (m.page == i)
                    tint_chars(p, i, m.first, m.last, left, top, k == m_current_match ? current_match_color : match_color);
            }
        }
        if (has_selection() && i >= lo.page && i <= hi.page) {
            int a = i == lo.page ? lo.index : 0;
            int b = i == hi.page ? hi.index : int(page.chars.size());
            if (b > a)
                tint_chars(p, i, a, b, left, top, selection_color);
        }
    }
    p.restore();
}

void PdfView::paint_scrollbars(QPainter& p)
{
    auto vp = viewport();
    p.save();
    p.translate(vp.topLeft());
    for (int which : { 1, 2 }) {
        if (!bar_shown(which))
            continue;
        auto tr = bar_track(which);
        bool wide = m_bar_hover == which || m_bar_drag == which;
        if (wide)
            p.fillRect(tr, QColor(255, 255, 255, 26));
        auto [start, len] = bar_thumb(which);
        double inset = 2;
        QRectF thumb = which == 1 ? QRectF(tr.left() + inset, tr.top() + start + inset, tr.width() - inset * 1.5, len - 2 * inset)
                                  : QRectF(tr.left() + start + inset, tr.top() + inset, len - 2 * inset, tr.height() - inset * 1.5);
        int alpha = m_bar_drag == which ? 230 : wide ? 210 : 190;
        double rr = std::min(thumb.width(), thumb.height()) / 2;
        p.setPen(Qt::NoPen);
        p.setBrush(QColor(255, 255, 255, 150));
        auto rim = thumb.adjusted(-1, -1, 1, 1);
        p.drawRoundedRect(rim, rr + 1, rr + 1);
        p.setBrush(QColor(0x6a, 0x6a, 0x6a, alpha));
        p.drawRoundedRect(thumb, rr, rr);
    }
    p.restore();
}

void PdfView::paint_panel(QPainter& p)
{
    if (!m_panel_open)
        return;
    QRectF panel(0, bar_height, panel_width, m_size.height() - bar_height);
    p.fillRect(panel, QColor(0x3c, 0x40, 0x43));
    p.setFont(bar_font(14));
    p.setPen(bar_text);
    p.drawText(QRectF(14, bar_height, panel_width - 50, 40), Qt::AlignVCenter | Qt::AlignLeft, QStringLiteral("Contents"));
    // The close button: an X.
    auto close = part_rect(Part::PanelClose);
    if (m_hover == Part::PanelClose) {
        p.setPen(Qt::NoPen);
        p.setBrush(bar_hover);
        p.drawEllipse(close);
    }
    p.setPen(QPen(bar_text, 1.6));
    auto c = close.center();
    p.drawLine(c + QPointF(-5, -5), c + QPointF(5, 5));
    p.drawLine(c + QPointF(5, -5), c + QPointF(-5, 5));
    p.save();
    QRectF list(0, bar_height + 40, panel_width, panel.height() - 40);
    p.setClipRect(list);
    QFont font = bar_font(13);
    QFontMetricsF metrics(font);
    p.setFont(font);
    if (m_outline.empty()) {
        p.setPen(bar_dim);
        p.drawText(list.adjusted(14, 6, -14, 0), Qt::AlignTop | Qt::AlignLeft | Qt::TextWordWrap,
            QStringLiteral("This PDF has no contents list."));
    }
    int current = current_page();
    for (int i = 0; i < int(m_outline.size()); ++i) {
        QRectF row(0, list.top() + i * panel_row - m_panel_scroll, panel_width, panel_row);
        if (row.bottom() < list.top() || row.top() > list.bottom())
            continue;
        auto const& o = m_outline[i];
        bool here = o.page == current && (i + 1 >= int(m_outline.size()) || m_outline[i + 1].page != current);
        if (i == m_panel_hover)
            p.fillRect(row, bar_hover);
        else if (here)
            p.fillRect(row, QColor(0x4a, 0x4e, 0x51, 150));
        double indent = 14 + std::min(o.level, 6) * 14;
        p.setPen(o.page >= 0 ? bar_text : bar_dim);
        auto page_label = o.page >= 0 ? QString::number(o.page + 1) : QString();
        double label_w = metrics.horizontalAdvance(page_label) + 14;
        p.drawText(row.adjusted(indent, 0, -label_w, 0), Qt::AlignVCenter | Qt::AlignLeft,
            metrics.elidedText(o.title, Qt::ElideRight, panel_width - indent - label_w - 4));
        p.setPen(bar_dim);
        p.drawText(row.adjusted(0, 0, -10, 0), Qt::AlignVCenter | Qt::AlignRight, page_label);
    }
    p.restore();
}

void PdfView::paint_bar(QPainter& p)
{
    QRectF bar(0, 0, m_size.width(), bar_height);
    p.fillRect(bar, bar_color);
    p.setFont(bar_font());
    QFontMetricsF m(bar_font());
    auto button_bg = [&](Part part) {
        auto r = part_rect(part);
        if (m_hover == part) {
            p.setPen(Qt::NoPen);
            p.setBrush(bar_hover);
            p.drawRoundedRect(r, 6, 6);
        }
        return r;
    };
    QPen line(bar_text, 1.8, Qt::SolidLine, Qt::RoundCap);

    // Contents: three lines (a list).
    auto r = button_bg(Part::Contents);
    if (m_panel_open) {
        p.setPen(Qt::NoPen);
        p.setBrush(QColor(0x5f, 0x63, 0x68));
        p.drawRoundedRect(r, 6, 6);
    }
    p.setPen(line);
    for (int k = -1; k <= 1; ++k)
        p.drawLine(QPointF(r.center().x() - 7, r.center().y() + k * 5), QPointF(r.center().x() + 7, r.center().y() + k * 5));

    bool ready = !m_failed;
    p.setPen(ready ? bar_text : bar_dim);
    double x = r.right() + 8;
    p.drawText(QRectF(x, 0, 60, bar_height), Qt::AlignVCenter | Qt::AlignLeft, QStringLiteral("Page"));

    // The page number: what the user typed while the field has focus, else the page being read.
    auto field = part_rect(Part::PageField);
    p.setPen(m_field_focused ? QPen(QColor(0x8a, 0xb4, 0xf8), 1.5) : Qt::NoPen);
    p.setBrush(QColor(0x20, 0x21, 0x24));
    p.drawRoundedRect(field, 4, 4);
    QString number = m_field_focused ? m_field_text : ready ? QString::number(current_page() + 1) : QStringLiteral("–");
    p.setPen(bar_text);
    p.drawText(field, Qt::AlignCenter, number);
    if (m_field_focused) {
        double tx = field.center().x() + m.horizontalAdvance(number) / 2 + 1;
        p.drawLine(QPointF(tx, field.top() + 5), QPointF(tx, field.bottom() - 5));
    }
    p.setPen(bar_dim);
    p.drawText(QRectF(field.right() + 8, 0, 120, bar_height), Qt::AlignVCenter | Qt::AlignLeft,
        QStringLiteral("of %1").arg(m_pages.size()));

    // Zoom out, the zoom, zoom in, Fit width.
    r = button_bg(Part::ZoomOut);
    p.setPen(line);
    p.drawLine(QPointF(r.center().x() - 6, r.center().y()), QPointF(r.center().x() + 6, r.center().y()));
    p.setPen(bar_text);
    p.drawText(QRectF(r.right(), 0, 56, bar_height), Qt::AlignCenter, QStringLiteral("%1%").arg(qRound(m_zoom * 100)));
    r = button_bg(Part::ZoomIn);
    p.setPen(line);
    p.drawLine(QPointF(r.center().x() - 6, r.center().y()), QPointF(r.center().x() + 6, r.center().y()));
    p.drawLine(QPointF(r.center().x(), r.center().y() - 6), QPointF(r.center().x(), r.center().y() + 6));
    auto fit = part_rect(Part::Fit);
    p.setPen(QPen(m_fit_width ? QColor(0x8a, 0xb4, 0xf8) : QColor(0x80, 0x86, 0x8b), 1));
    p.setBrush(m_hover == Part::Fit ? bar_hover : Qt::transparent);
    p.drawRoundedRect(fit, 6, 6);
    p.setPen(m_fit_width ? QColor(0x8a, 0xb4, 0xf8) : bar_text);
    p.drawText(fit, Qt::AlignCenter, QStringLiteral("Fit width"));

    // Save: an arrow down onto a line.
    r = button_bg(Part::Save);
    p.setPen(line);
    auto c = r.center();
    p.drawLine(c + QPointF(0, -8), c + QPointF(0, 3));
    p.drawLine(c + QPointF(-5, -2), c + QPointF(0, 3));
    p.drawLine(c + QPointF(5, -2), c + QPointF(0, 3));
    p.drawLine(c + QPointF(-7, 8), c + QPointF(7, 8));

    // The status (Saved as …), else the document's title, between the controls and Save.
    double left = fit.right() + 16, right = r.left() - 12;
    if (right > left + 40) {
        auto text = !m_status.isEmpty() ? m_status : title();
        p.setPen(m_status.isEmpty() ? bar_dim : bar_text);
        p.drawText(QRectF(left, 0, right - left, bar_height), Qt::AlignVCenter | Qt::AlignRight,
            m.elidedText(text, Qt::ElideMiddle, right - left));
    }
}

}
