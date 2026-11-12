/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The PDF viewer: a tab whose page is a PDF shows this instead of the engine's page, as the Nim front end's
// nim/src/features/pdf.nim does. MuPDF renders (the webby-pdf component, wasm/pdf, imported as webby:pdf); this
// paints the frame the window shows in the page area, with the same parts as the Nim viewer:
//
//   - a bar along the top: Contents (the outline, in a panel on the left), the page number (click it and type one to
//     go there), zoom out / the zoom / zoom in, Fit width, and Save to the downloads folder;
//   - the pages on Chrome's PDF grey, rendered lazily (what is on screen, nearest the page being read first, one page
//     per pump so the window stays responsive), the ones far away given back;
//   - Ladybird-style scrollbars (a pill that widens under the pointer; drag it or click the track);
//   - text: drag to select (double click a word, triple click a line, Shift+click extends), Ctrl+C and Ctrl+A,
//     find (the window's find bar asks find/find_next/...), links inside the document and out;
//   - keys: arrows, Page Up/Down, Space/Shift+Space, Home/End, Ctrl+Home/End, Ctrl+S saves; Ctrl+wheel zooms.
//
// Coordinates are the page area's (logical pixels, origin its top left).

#pragma once

#include "WebView.h"

#include <QByteArray>
#include <QImage>
#include <QPointF>
#include <QRectF>
#include <QSize>
#include <QString>
#include <functional>
#include <memory>
#include <vector>

class QKeyEvent;
class QPainter;

namespace WebbyUI {

class PdfView {
public:
    // Opens `data` (a navigation's PDF from `url`). A PDF MuPDF cannot open still gets a view, which says why and can
    // save the file.
    PdfView(QString url, QByteArray data, QString mime);
    ~PdfView();

    QString const& url() const { return m_url; }
    QByteArray const& data() const { return m_data; }
    // The document's title, else the URL's file name.
    QString title() const;
    // A name to save it as ("paper.pdf").
    QString file_name() const;
    bool failed() const { return m_failed; }

    void resize(QSize);
    QSize size() const { return m_size; }
    // The frame (premultiplied ARGB32, size()), composed again if something changed.
    QImage const& paint();
    bool needs_paint() const { return m_dirty; }
    // Renders or reads the next thing the view is missing, at most one page; true when it did something.
    bool pump();

    // Input. Each may ask for a repaint through on_needs_paint.
    void mouse_press(QPointF, Qt::MouseButton, Qt::KeyboardModifiers, int clicks);
    void mouse_move(QPointF, Qt::MouseButtons, Qt::KeyboardModifiers);
    void mouse_release(QPointF, Qt::MouseButton, Qt::KeyboardModifiers);
    void mouse_leave();
    void wheel(QPointF, QPointF pixel_delta, QPoint angle_delta, Qt::KeyboardModifiers);
    bool key_press(QKeyEvent*);

    // Find, for the window's find bar.
    WebView::FindResult find(QString const& query);
    WebView::FindResult find_next();
    WebView::FindResult find_previous();
    void find_end();
    // The matches so far (more come in as pump() reads the pages' text).
    WebView::FindResult find_state() const { return find_result(); }

    double zoom() const { return m_zoom; }
    void zoom_step(int steps, QPointF anchor = { -1, -1 }); // 0: fit width
    bool has_selection() const;
    QString selected_text() const;
    void select_all();
    void copy_selection();

    struct LinkTarget {
        QString uri; // outside the document; "" for a page in it
        int page { -1 };
    };
    LinkTarget link_at(QPointF) const;

    std::function<void()> on_needs_paint;
    std::function<void(QString const&)> on_link_hover; // "" when the pointer leaves a link
    std::function<void(QString const& url, bool new_tab)> on_open_url;
    std::function<void()> on_save;
    // Says something in the bar ("Saved as …").
    void set_status(QString const&);

private:
    struct PChar {
        float x0, y0, x1, y1; // points, from the page's top left
        char32_t c;
        bool line_end;
    };
    struct Link {
        float x0, y0, x1, y1;
        QString uri;
        int page;
        float y;
    };
    struct Page {
        float w { 612 }, h { 792 }; // points
        QImage image;
        float image_scale { 0 };
        int text_state { 0 }; // 0 not read, 2 here
        std::vector<PChar> chars;
        std::vector<Link> links;
        std::u32string find_text; // chars (folded to lower case), a space at line ends
        std::vector<int> find_map; // find_text index -> chars index (-1: an added space)
    };
    struct Caret {
        int page { 0 };
        int index { 0 };
        bool operator==(Caret const&) const = default;
    };
    struct Match {
        int page, first, last; // chars first ..< last
        bool operator==(Match const&) const = default;
    };
    struct Outline {
        int level;
        QString title;
        int page;
        float y;
    };
    enum class Part {
        None,
        Contents,
        PageField,
        ZoomOut,
        ZoomIn,
        Fit,
        Save,
        Panel,
        PanelClose,
        Pages,
        VBar,
        HBar,
    };

    void invalidate();
    float scale() const { return float(m_zoom * 96.0 / 72.0); }
    QRectF viewport() const; // where the pages show, in frame coordinates
    void layout();
    double total_height() const;
    double total_width() const;
    void clamp_scroll();
    double page_left(int) const;
    std::pair<int, int> visible_range() const;
    int current_page() const;
    double fit_zoom() const;
    void scroll_to(double y, double x = -1);
    void go_to_page(int, double y_pt = 0);
    void set_zoom(double, bool fit, QPointF anchor = { -1, -1 });
    void render(int);
    void read_text(int);
    void build_find_text(int);
    void rematch(int keep_page = -1);
    void scroll_to_match();
    WebView::FindResult find_result() const;

    // Hit testing, in frame coordinates.
    Part part_at(QPointF) const;
    QRectF part_rect(Part) const;
    struct PageHit {
        int page;
        double px, py; // points
    };
    PageHit hit(QPointF) const;
    int caret_at(int page, double x, double y) const;
    Caret caret_from(QPointF) const;
    Link const* link_ptr(QPointF) const;
    std::pair<Caret, Caret> sel_range() const;
    void select_word(Caret, bool line);

    // Scrollbars: 1 vertical, 2 horizontal.
    bool bar_shown(int) const;
    QRectF bar_track(int) const;
    std::pair<double, double> bar_thumb(int) const;
    void scroll_from_bar(int, double along);

    void compose();
    void paint_bar(QPainter&);
    void paint_panel(QPainter&);
    void paint_pages(QPainter&);
    void paint_scrollbars(QPainter&);
    void tint_chars(QPainter&, int page, int first, int last, double left, double top, QColor);
    int panel_row_at(QPointF) const;

    QString m_url;
    QByteArray m_data;
    QString m_title;
    QString m_error;
    QString m_status;
    bool m_failed { false };
    struct Document;
    std::unique_ptr<Document> m_doc;

    std::vector<Page> m_pages;
    std::vector<double> m_tops; // each page's top, in pixels at the current scale, from the document's top
    std::vector<Outline> m_outline;

    QSize m_size;
    QImage m_frame;
    bool m_dirty { true };

    double m_zoom { 1 };
    bool m_fit_width { true };
    double m_scroll_x { 0 };
    double m_scroll_y { 0 };

    Caret m_sel_a, m_sel_b; // anchor and focus (equal: nothing selected)
    bool m_dragging { false };
    QPointF m_down_at;
    bool m_select_all_pending { false };

    QString m_query;
    bool m_find_shown { false };
    std::vector<Match> m_matches;
    int m_current_match { -1 };

    int m_bar_hover { 0 };
    int m_bar_drag { 0 };
    double m_bar_grab { 0 };
    Part m_hover { Part::None };
    QString m_hovered_link;

    bool m_panel_open { false };
    double m_panel_scroll { 0 };
    int m_panel_hover { -1 };

    bool m_field_focused { false };
    QString m_field_text;
};

}
