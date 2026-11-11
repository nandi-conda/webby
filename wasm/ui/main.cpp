/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// webby's Qt UI as a latha:gui component (qt2wasm's GUI world): the host calls start, then sends input and asks for
// frames. Arguments are URLs (or paths) to open, one tab each, and test input (--click, --wheel; see below).

#include "BrowserWindow.h"

#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QMouseEvent>
#include <QTimer>
#include <QWheelEvent>
#include <qt2wasm/gui.h>

static void add_chrome_fonts()
{
    // The chrome uses the host's fonts, which the host opens to the module (latha-gui opens / by default).
    char const* candidates[] = {
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    };
    for (auto const* path : candidates) {
        if (!QFile::exists(QString::fromUtf8(path)))
            continue;
        int id = QFontDatabase::addApplicationFont(QString::fromUtf8(path));
        if (id >= 0) {
            auto families = QFontDatabase::applicationFontFamilies(id);
            if (!families.isEmpty())
                QGuiApplication::setFont(QFont(families.first()));
            return;
        }
    }
}

// Test input, so that the UI can be driven headless (latha-gui --screenshot only types): --click=X,Y@MS clicks the
// left button at X,Y (window pixels) MS milliseconds after start, --wheel=DY@MS scrolls by DY pixels over the page.
static bool schedule_test_input(QWindow* window, QString const& arg)
{
    auto at = arg.lastIndexOf(u'@');
    if (at < 0)
        return false;
    int ms = arg.mid(at + 1).toInt();
    if (arg.startsWith(QStringLiteral("--click="))) {
        auto xy = arg.mid(8, at - 8).split(u',');
        if (xy.size() != 2)
            return false;
        QPointF pos(xy[0].toDouble(), xy[1].toDouble());
        QTimer::singleShot(ms, window, [window, pos] {
            QMouseEvent move(QEvent::MouseMove, pos, window->mapToGlobal(pos), Qt::NoButton, Qt::NoButton, Qt::NoModifier);
            QGuiApplication::sendEvent(window, &move);
            QMouseEvent press(QEvent::MouseButtonPress, pos, window->mapToGlobal(pos), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
            QGuiApplication::sendEvent(window, &press);
            QMouseEvent release(QEvent::MouseButtonRelease, pos, window->mapToGlobal(pos), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
            QGuiApplication::sendEvent(window, &release);
        });
        return true;
    }
    if (arg.startsWith(QStringLiteral("--wheel="))) {
        int dy = arg.mid(8, at - 8).toInt();
        QTimer::singleShot(ms, window, [window, dy] {
            QPointF pos(window->width() / 2.0, window->height() / 2.0);
            QWheelEvent wheel(pos, window->mapToGlobal(pos), QPoint(0, -dy), QPoint(0, -dy * 120 / 100), Qt::NoButton,
                Qt::NoModifier, Qt::NoScrollPhase, false);
            QGuiApplication::sendEvent(window, &wheel);
        });
        return true;
    }
    return false;
}

extern "C" int qt2wasm_gui_main(int argc, char** argv)
{
    add_chrome_fonts();
    QStringList urls;
    QStringList test_input;
    for (int i = 1; i < argc; ++i) {
        auto arg = QString::fromUtf8(argv[i]);
        if (arg.startsWith(QStringLiteral("--click=")) || arg.startsWith(QStringLiteral("--wheel=")))
            test_input << arg;
        else
            urls << arg;
    }
    auto* window = new BrowserWindow(urls);
    window->resize(1100, 760);
    window->show();
    for (auto const& arg : test_input) {
        if (!schedule_test_input(window, arg))
            qWarning("webby: bad test input %s", qPrintable(arg));
    }
    return 0;
}
