/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "BrowserWindow.h"
#include "KeyMap.h"

#include <QFontMetricsF>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QWheelEvent>

namespace {

// Light chrome, close to the Nim desktop front end's.
QColor const strip_color { 0xde, 0xe1, 0xe6 };
QColor const tab_color { 0xff, 0xff, 0xff };
QColor const tab_hover_color { 0xec, 0xee, 0xf1 };
QColor const text_color { 0x20, 0x21, 0x24 };
QColor const dim_text_color { 0x5f, 0x63, 0x68 };
QColor const field_color { 0xf1, 0xf3, 0xf4 };
QColor const focus_color { 0x1a, 0x73, 0xe8 };
QColor const button_hover_color { 0xe8, 0xea, 0xed };
QColor const disabled_color { 0xbd, 0xc1, 0xc6 };

constexpr int max_tab_width = 220;
constexpr int min_tab_width = 72;
constexpr int button_size = 32;

unsigned web_button(Qt::MouseButton button)
{
    switch (button) {
    case Qt::LeftButton:
        return WebbyUI::ButtonPrimary;
    case Qt::RightButton:
        return WebbyUI::ButtonSecondary;
    case Qt::MiddleButton:
        return WebbyUI::ButtonMiddle;
    case Qt::BackButton:
        return WebbyUI::ButtonBackward;
    case Qt::ForwardButton:
        return WebbyUI::ButtonForward;
    default:
        return WebbyUI::ButtonNone;
    }
}

unsigned web_buttons(Qt::MouseButtons buttons)
{
    unsigned result = 0;
    for (auto b : { Qt::LeftButton, Qt::RightButton, Qt::MiddleButton, Qt::BackButton, Qt::ForwardButton }) {
        if (buttons & b)
            result |= web_button(b);
    }
    return result;
}

QString from_std(std::string const& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }
std::string to_std(QString const& s) { return s.toUtf8().toStdString(); }

}

BrowserWindow::BrowserWindow(QStringList const& urls)
{
    setTitle(QStringLiteral("webby"));
    setMinimumSize({ 480, 320 });
    // The engine's event loop (timers, tasks, the page's deferred work) runs between the host's calls.
    m_pump_timer.setInterval(8);
    QObject::connect(&m_pump_timer, &QTimer::timeout, this, [this] { pump(); });
    m_pump_timer.start();
    if (urls.isEmpty())
        new_tab({});
    for (auto const& url : urls)
        new_tab(url);
    activate_tab(0);
    if (urls.isEmpty())
        focus_address(true);
}

BrowserWindow::Tab* BrowserWindow::current()
{
    if (m_current < 0 || m_current >= int(m_tabs.size()))
        return nullptr;
    return &m_tabs[m_current];
}

void BrowserWindow::new_tab(QString const& url)
{
    auto page = page_rect();
    auto view = WebbyUI::WebView::create(page.width(), page.height());
    if (!view)
        return;
    auto* raw = view.get();
    m_tabs.push_back({ std::move(view), QStringLiteral("New Tab"), url, false });
    raw->on_needs_paint = [this, raw] {
        if (current() && current()->view.get() == raw)
            update();
    };
    raw->on_title_change = [this, raw](std::string const&) { sync_from_view(); (void)raw; };
    raw->on_url_change = [this, raw](std::string const& u) {
        if (current() && current()->view.get() == raw && !m_address_focused)
            m_address_text = from_std(u);
        sync_from_view();
    };
    raw->on_loading_change = [this](bool) { sync_from_view(); };
    raw->on_link_hover = [this, raw](std::string const& link) {
        if (current() && current()->view.get() == raw) {
            m_hovered_link = from_std(link);
            update();
        }
    };
    raw->load(to_std(url));
}

void BrowserWindow::close_tab(int index)
{
    if (index < 0 || index >= int(m_tabs.size()))
        return;
    m_tabs.erase(m_tabs.begin() + index);
    if (m_tabs.empty()) {
        QGuiApplication::quit();
        return;
    }
    if (m_current >= int(m_tabs.size()) || m_current > index)
        --m_current;
    activate_tab(qBound(0, m_current, int(m_tabs.size()) - 1));
}

void BrowserWindow::activate_tab(int index)
{
    if (index < 0 || index >= int(m_tabs.size()))
        return;
    m_current = index;
    auto page = page_rect();
    m_tabs[index].view->resize(page.width(), page.height());
    m_address_text = from_std(m_tabs[index].view->url());
    m_hovered_link.clear();
    sync_from_view();
}

void BrowserWindow::sync_from_view()
{
    for (auto& tab : m_tabs) {
        auto title = from_std(tab.view->title()).simplified();
        tab.url = from_std(tab.view->url());
        tab.title = !title.isEmpty() ? title : !tab.url.isEmpty() ? tab.url : QStringLiteral("New Tab");
        tab.loading = tab.view->is_loading();
    }
    if (auto* tab = current())
        setTitle(tab->title + QStringLiteral(" - webby"));
    update();
}

void BrowserWindow::pump()
{
    WebbyUI::WebView::pump();
    if (auto* tab = current(); tab && tab->view->needs_paint())
        update();
}

void BrowserWindow::navigate_from_address()
{
    auto* tab = current();
    if (!tab)
        return;
    auto text = m_address_text.trimmed();
    focus_address(false);
    tab->view->load(to_std(text));
}

void BrowserWindow::focus_address(bool focus)
{
    m_address_focused = focus;
    if (focus) {
        m_address_anchor = 0;
        m_address_cursor = m_address_text.size();
    } else if (auto* tab = current()) {
        m_address_text = from_std(tab->view->url());
    }
    update();
}

// Geometry, in logical pixels.

QRectF BrowserWindow::tab_rect(int index) const
{
    qreal available = width() - 8 - 40;
    qreal w = m_tabs.empty() ? max_tab_width : qBound<qreal>(min_tab_width, available / m_tabs.size(), max_tab_width);
    return { 8 + index * w, 6, w - 2, qreal(tab_strip_height - 6) };
}

QRectF BrowserWindow::tab_close_rect(int index) const
{
    auto r = tab_rect(index);
    return { r.right() - 26, r.top() + (r.height() - 18) / 2, 18, 18 };
}

QRectF BrowserWindow::new_tab_rect() const
{
    auto r = tab_rect(int(m_tabs.size()));
    return { r.left() + 4, r.top() + (r.height() - 26) / 2, 26, 26 };
}

QRectF BrowserWindow::button_rect(int index) const
{
    return { 8.0 + index * (button_size + 4), tab_strip_height + (toolbar_height - button_size) / 2.0, qreal(button_size), qreal(button_size) };
}

QRectF BrowserWindow::address_rect() const
{
    auto left = button_rect(3).left() + 4;
    return { left, tab_strip_height + 6.0, qMax<qreal>(80, width() - left - 12), toolbar_height - 12.0 };
}

QRect BrowserWindow::page_rect() const
{
    return { 0, chrome_height, qMax(1, width()), qMax(1, height() - chrome_height) };
}

BrowserWindow::HitResult BrowserWindow::hit_test(QPointF p) const
{
    for (int i = 0; i < int(m_tabs.size()); ++i) {
        if (tab_close_rect(i).contains(p))
            return { Hit::TabClose, i };
        if (tab_rect(i).contains(p))
            return { Hit::Tab, i };
    }
    if (new_tab_rect().contains(p))
        return { Hit::NewTab };
    if (button_rect(0).contains(p))
        return { Hit::Back };
    if (button_rect(1).contains(p))
        return { Hit::Forward };
    if (button_rect(2).contains(p))
        return { Hit::Reload };
    if (address_rect().contains(p))
        return { Hit::Address };
    if (page_rect().contains(p.toPoint()))
        return { Hit::Page };
    return {};
}

// Painting.

void BrowserWindow::paintEvent(QPaintEvent*)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    paint_page(painter);
    paint_tabs(painter);
    paint_toolbar(painter);
    paint_status(painter);
}

void BrowserWindow::paint_tabs(QPainter& p)
{
    p.fillRect(QRectF(0, 0, width(), tab_strip_height), strip_color);
    QFont font = p.font();
    font.setPixelSize(13);
    p.setFont(font);
    QFontMetricsF metrics(font);
    for (int i = 0; i < int(m_tabs.size()); ++i) {
        auto r = tab_rect(i);
        bool active = i == m_current;
        bool hovered = m_hover.tab == i && (m_hover.hit == Hit::Tab || m_hover.hit == Hit::TabClose);
        if (active || hovered) {
            QPainterPath path;
            path.addRoundedRect(r.adjusted(0, 0, 0, 8), 8, 8);
            p.save();
            p.setClipRect(QRectF(0, 0, width(), tab_strip_height));
            p.fillPath(path, active ? tab_color : tab_hover_color);
            p.restore();
        }
        auto text_rect = r.adjusted(12, 0, -30, 0);
        auto title = m_tabs[i].loading ? QStringLiteral("Loading…") : m_tabs[i].title;
        p.setPen(active ? text_color : dim_text_color);
        p.drawText(text_rect, Qt::AlignVCenter | Qt::AlignLeft, metrics.elidedText(title, Qt::ElideRight, text_rect.width()));
        auto c = tab_close_rect(i);
        if (m_hover.hit == Hit::TabClose && m_hover.tab == i) {
            p.setPen(Qt::NoPen);
            p.setBrush(button_hover_color.darker(105));
            p.drawEllipse(c);
        }
        p.setPen(QPen(dim_text_color, 1.4));
        auto x = c.adjusted(5, 5, -5, -5);
        p.drawLine(x.topLeft(), x.bottomRight());
        p.drawLine(x.topRight(), x.bottomLeft());
    }
    auto n = new_tab_rect();
    if (m_hover.hit == Hit::NewTab) {
        p.setPen(Qt::NoPen);
        p.setBrush(button_hover_color);
        p.drawEllipse(n);
    }
    p.setPen(QPen(dim_text_color, 1.6));
    auto c = n.center();
    p.drawLine(QPointF(c.x() - 6, c.y()), QPointF(c.x() + 6, c.y()));
    p.drawLine(QPointF(c.x(), c.y() - 6), QPointF(c.x(), c.y() + 6));
}

void BrowserWindow::paint_toolbar(QPainter& p)
{
    QRectF bar(0, tab_strip_height, width(), toolbar_height);
    p.fillRect(bar, tab_color);
    p.setPen(QPen(QColor(0xda, 0xdc, 0xe0), 1));
    p.drawLine(QPointF(0, chrome_height - 0.5), QPointF(width(), chrome_height - 0.5));

    auto* tab = current();
    bool can_back = tab && tab->view->can_go_back();
    bool can_forward = tab && tab->view->can_go_forward();
    Hit buttons[] = { Hit::Back, Hit::Forward, Hit::Reload };
    bool enabled[] = { can_back, can_forward, tab != nullptr };
    for (int i = 0; i < 3; ++i) {
        auto r = button_rect(i);
        if (m_hover.hit == buttons[i] && enabled[i]) {
            p.setPen(Qt::NoPen);
            p.setBrush(button_hover_color);
            p.drawEllipse(r);
        }
        p.setPen(QPen(enabled[i] ? text_color : disabled_color, 1.8, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.setBrush(Qt::NoBrush);
        auto c = r.center();
        if (i < 2) {
            qreal d = i == 0 ? -1 : 1;
            p.drawLine(QPointF(c.x() - 7 * d, c.y()), QPointF(c.x() + 7 * d, c.y()));
            p.drawLine(QPointF(c.x() + 7 * d, c.y()), QPointF(c.x() + 2 * d, c.y() - 5));
            p.drawLine(QPointF(c.x() + 7 * d, c.y()), QPointF(c.x() + 2 * d, c.y() + 5));
        } else if (tab && tab->loading) {
            auto x = QRectF(c.x() - 6, c.y() - 6, 12, 12);
            p.drawLine(x.topLeft(), x.bottomRight());
            p.drawLine(x.topRight(), x.bottomLeft());
        } else {
            QRectF arc(c.x() - 7, c.y() - 7, 14, 14);
            p.drawArc(arc, 90 * 16, 300 * 16);
            QPointF tip(c.x() + 1, c.y() - 7);
            p.drawLine(tip, tip + QPointF(-4, -3.5));
            p.drawLine(tip, tip + QPointF(-4, 3.5));
        }
    }

    auto field = address_rect();
    QPainterPath path;
    path.addRoundedRect(field, field.height() / 2, field.height() / 2);
    p.fillPath(path, m_address_focused ? tab_color : field_color);
    if (m_address_focused) {
        p.setPen(QPen(focus_color, 2));
        p.setBrush(Qt::NoBrush);
        p.drawPath(path);
    }

    QFont font = p.font();
    font.setPixelSize(14);
    p.setFont(font);
    QFontMetricsF metrics(font);
    auto text_rect = field.adjusted(16, 0, -16, 0);
    p.save();
    p.setClipRect(text_rect);
    if (m_address_text.isEmpty() && !m_address_focused) {
        p.setPen(dim_text_color);
        p.drawText(text_rect, Qt::AlignVCenter | Qt::AlignLeft, QStringLiteral("Search or enter a file:// address"));
    } else {
        qreal baseline = text_rect.center().y() + (metrics.ascent() - metrics.descent()) / 2;
        if (m_address_focused && m_address_anchor != m_address_cursor) {
            int a = qMin(m_address_anchor, m_address_cursor);
            int b = qMax(m_address_anchor, m_address_cursor);
            qreal x0 = text_rect.left() + metrics.horizontalAdvance(m_address_text.left(a));
            qreal x1 = text_rect.left() + metrics.horizontalAdvance(m_address_text.left(b));
            p.fillRect(QRectF(x0, text_rect.center().y() - metrics.height() / 2, x1 - x0, metrics.height()), QColor(0xc2, 0xdb, 0xff));
        }
        p.setPen(text_color);
        p.drawText(QPointF(text_rect.left(), baseline), m_address_text);
        if (m_address_focused) {
            qreal x = text_rect.left() + metrics.horizontalAdvance(m_address_text.left(m_address_cursor));
            p.setPen(QPen(text_color, 1));
            p.drawLine(QPointF(x, text_rect.center().y() - metrics.height() / 2), QPointF(x, text_rect.center().y() + metrics.height() / 2));
        }
    }
    p.restore();
}

void BrowserWindow::paint_page(QPainter& p)
{
    auto r = page_rect();
    auto* tab = current();
    uint8_t const* pixels = tab ? tab->view->paint() : nullptr;
    if (!pixels) {
        p.fillRect(r, Qt::white);
        return;
    }
    QImage image(pixels, tab->view->width(), tab->view->height(), tab->view->width() * 4, QImage::Format_ARGB32_Premultiplied);
    p.drawImage(r.topLeft(), image);
    if (image.width() < r.width())
        p.fillRect(QRect(r.left() + image.width(), r.top(), r.width() - image.width(), r.height()), Qt::white);
    if (image.height() < r.height())
        p.fillRect(QRect(r.left(), r.top() + image.height(), r.width(), r.height() - image.height()), Qt::white);
}

void BrowserWindow::paint_status(QPainter& p)
{
    if (m_hovered_link.isEmpty())
        return;
    QFont font = p.font();
    font.setPixelSize(12);
    p.setFont(font);
    QFontMetricsF metrics(font);
    auto text = metrics.elidedText(m_hovered_link, Qt::ElideMiddle, width() * 0.6);
    QRectF box(0, height() - 24, metrics.horizontalAdvance(text) + 16, 24);
    p.setPen(QPen(QColor(0xda, 0xdc, 0xe0), 1));
    p.setBrush(QColor(0xf8, 0xf9, 0xfa));
    p.drawRect(box.adjusted(-1, 0, 0, 1));
    p.setPen(text_color);
    p.drawText(box.adjusted(8, 0, 0, 0), Qt::AlignVCenter | Qt::AlignLeft, text);
}

// Input.

void BrowserWindow::resizeEvent(QResizeEvent*)
{
    if (auto* tab = current()) {
        auto page = page_rect();
        tab->view->resize(page.width(), page.height());
    }
    update();
}

int BrowserWindow::address_index_at(qreal x) const
{
    QFont font;
    font.setPixelSize(14);
    QFontMetricsF metrics(font);
    qreal left = address_rect().left() + 16;
    for (int i = 0; i <= m_address_text.size(); ++i) {
        qreal w = metrics.horizontalAdvance(m_address_text.left(i));
        if (left + w >= x) {
            if (i > 0 && (left + w) - x > x - (left + metrics.horizontalAdvance(m_address_text.left(i - 1))))
                return i - 1;
            return i;
        }
    }
    return m_address_text.size();
}

void BrowserWindow::mousePressEvent(QMouseEvent* event)
{
    auto hit = hit_test(event->position());
    m_pressed = hit;
    if (hit.hit != Hit::Address && hit.hit != Hit::None && m_address_focused)
        focus_address(false);
    auto* tab = current();
    switch (hit.hit) {
    case Hit::Tab:
        if (event->button() == Qt::MiddleButton)
            close_tab(hit.tab);
        else
            activate_tab(hit.tab);
        break;
    case Hit::Address:
        if (!m_address_focused) {
            focus_address(true);
        } else {
            m_address_cursor = address_index_at(event->position().x());
            if (!(event->modifiers() & Qt::ShiftModifier))
                m_address_anchor = m_address_cursor;
            update();
        }
        break;
    case Hit::Page:
        if (tab) {
            auto page = page_rect();
            m_page_buttons = web_buttons(event->buttons());
            tab->view->mouse_down(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(),
                web_button(event->button()), m_page_buttons, web_modifiers(event->modifiers()), 1);
        }
        break;
    default:
        break;
    }
}

void BrowserWindow::mouseDoubleClickEvent(QMouseEvent* event)
{
    auto hit = hit_test(event->position());
    if (hit.hit == Hit::Address) {
        m_address_anchor = 0;
        m_address_cursor = m_address_text.size();
        update();
        return;
    }
    if (hit.hit == Hit::None && event->position().y() < tab_strip_height) {
        new_tab({});
        activate_tab(int(m_tabs.size()) - 1);
        focus_address(true);
        return;
    }
    if (hit.hit == Hit::Page) {
        if (auto* tab = current()) {
            auto page = page_rect();
            tab->view->mouse_down(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(),
                web_button(event->button()), web_buttons(event->buttons()), web_modifiers(event->modifiers()), 2);
        }
    }
}

void BrowserWindow::mouseReleaseEvent(QMouseEvent* event)
{
    auto hit = hit_test(event->position());
    auto pressed = m_pressed;
    m_pressed = {};
    auto* tab = current();
    if (pressed.hit == Hit::Page && tab) {
        auto page = page_rect();
        m_page_buttons = web_buttons(event->buttons());
        tab->view->mouse_up(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(),
            web_button(event->button()), m_page_buttons, web_modifiers(event->modifiers()));
        return;
    }
    if (hit.hit != pressed.hit || event->button() != Qt::LeftButton)
        return;
    switch (hit.hit) {
    case Hit::TabClose:
        if (hit.tab == pressed.tab)
            close_tab(hit.tab);
        break;
    case Hit::NewTab:
        new_tab({});
        activate_tab(int(m_tabs.size()) - 1);
        focus_address(true);
        break;
    case Hit::Back:
        if (tab)
            tab->view->go_back();
        break;
    case Hit::Forward:
        if (tab)
            tab->view->go_forward();
        break;
    case Hit::Reload:
        if (tab)
            tab->view->reload();
        break;
    default:
        break;
    }
}

void BrowserWindow::mouseMoveEvent(QMouseEvent* event)
{
    auto hit = hit_test(event->position());
    if (hit.hit != m_hover.hit || hit.tab != m_hover.tab) {
        m_hover = hit;
        update();
    }
    if (m_pressed.hit == Hit::Address && (event->buttons() & Qt::LeftButton)) {
        m_address_cursor = address_index_at(event->position().x());
        update();
        return;
    }
    auto* tab = current();
    if (!tab)
        return;
    bool in_page = hit.hit == Hit::Page || m_pressed.hit == Hit::Page;
    if (in_page) {
        auto page = page_rect();
        tab->view->mouse_move(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(),
            web_buttons(event->buttons()), web_modifiers(event->modifiers()));
        m_page_has_mouse = true;
    } else if (m_page_has_mouse) {
        tab->view->mouse_leave();
        m_page_has_mouse = false;
        m_hovered_link.clear();
    }
}

void BrowserWindow::wheelEvent(QWheelEvent* event)
{
    auto* tab = current();
    if (!tab || hit_test(event->position()).hit != Hit::Page)
        return;
    auto page = page_rect();
    // A notch is 120 eighths of a degree in angleDelta and scrolls three 40-pixel lines; a touchpad reports pixels.
    QPointF delta = !event->pixelDelta().isNull() ? QPointF(-event->pixelDelta()) : QPointF(-event->angleDelta()) / 120.0 * 120.0;
    tab->view->wheel(int(event->position().x()) - page.left(), int(event->position().y()) - page.top(), delta.x(), delta.y(),
        web_modifiers(event->modifiers()));
}

bool BrowserWindow::address_key(QKeyEvent* event)
{
    auto mods = event->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier);
    bool shift = event->modifiers() & Qt::ShiftModifier;
    auto remove_selection = [this] {
        if (m_address_anchor == m_address_cursor)
            return false;
        int a = qMin(m_address_anchor, m_address_cursor);
        m_address_text.remove(a, qAbs(m_address_anchor - m_address_cursor));
        m_address_cursor = m_address_anchor = a;
        return true;
    };
    auto move = [&](int to) {
        m_address_cursor = qBound(0, to, int(m_address_text.size()));
        if (!shift)
            m_address_anchor = m_address_cursor;
    };
    switch (event->key()) {
    case Qt::Key_Return:
    case Qt::Key_Enter:
        navigate_from_address();
        return true;
    case Qt::Key_Escape:
        focus_address(false);
        return true;
    case Qt::Key_Left:
        move(m_address_cursor - 1);
        break;
    case Qt::Key_Right:
        move(m_address_cursor + 1);
        break;
    case Qt::Key_Home:
        move(0);
        break;
    case Qt::Key_End:
        move(int(m_address_text.size()));
        break;
    case Qt::Key_Backspace:
        if (!remove_selection() && m_address_cursor > 0) {
            m_address_text.remove(m_address_cursor - 1, 1);
            m_address_anchor = --m_address_cursor;
        }
        break;
    case Qt::Key_Delete:
        if (!remove_selection() && m_address_cursor < m_address_text.size())
            m_address_text.remove(m_address_cursor, 1);
        break;
    case Qt::Key_A:
        if (mods == Qt::ControlModifier) {
            m_address_anchor = 0;
            m_address_cursor = int(m_address_text.size());
            break;
        }
        [[fallthrough]];
    default:
        if (mods & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier))
            return false;
        auto text = event->text();
        if (text.isEmpty() || !text.at(0).isPrint())
            return false;
        remove_selection();
        m_address_text.insert(m_address_cursor, text);
        m_address_cursor += int(text.size());
        m_address_anchor = m_address_cursor;
        break;
    }
    update();
    return true;
}

void BrowserWindow::keyPressEvent(QKeyEvent* event)
{
    auto mods = event->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier | Qt::MetaModifier);
    auto* tab = current();
    // Browser shortcuts first.
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_T) {
        new_tab({});
        activate_tab(int(m_tabs.size()) - 1);
        focus_address(true);
        return;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_W) {
        close_tab(m_current);
        return;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_L) {
        focus_address(true);
        return;
    }
    if ((mods == Qt::ControlModifier && event->key() == Qt::Key_R) || (mods == Qt::NoModifier && event->key() == Qt::Key_F5)) {
        if (tab)
            tab->view->reload();
        return;
    }
    if (mods == Qt::AltModifier && (event->key() == Qt::Key_Left || event->key() == Qt::Key_Right)) {
        if (tab)
            event->key() == Qt::Key_Left ? tab->view->go_back() : tab->view->go_forward();
        return;
    }
    if (mods == Qt::ControlModifier && event->key() == Qt::Key_Tab && !m_tabs.empty()) {
        activate_tab((m_current + 1) % int(m_tabs.size()));
        return;
    }
    if (m_address_focused) {
        address_key(event);
        return;
    }
    if (!tab)
        return;
    auto text = event->text();
    uint32_t code_point = text.isEmpty() ? 0 : text.toUcs4().value(0);
    if (code_point && !QChar::isPrint(code_point) && code_point != '\r' && code_point != '\t' && code_point != '\b')
        code_point = 0;
    tab->view->key_down(web_key_code(*event), web_modifiers(event->modifiers()), code_point, event->isAutoRepeat());
}

void BrowserWindow::keyReleaseEvent(QKeyEvent* event)
{
    if (m_address_focused)
        return;
    if (auto* tab = current())
        tab->view->key_up(web_key_code(*event), web_modifiers(event->modifiers()), 0);
}

bool BrowserWindow::event(QEvent* event)
{
    if (event->type() == QEvent::Leave) {
        m_hover = {};
        if (m_page_has_mouse) {
            if (auto* tab = current())
                tab->view->mouse_leave();
            m_page_has_mouse = false;
        }
        update();
    }
    return QRasterWindow::event(event);
}
