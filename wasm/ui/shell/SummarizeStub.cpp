/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The UI component has no Summarize: it needs the network for the chrome's own requests and the engine's page
// scripts and page messages, which webby:engine (../wit/engine) does not carry. These keep BrowserWindow's calls; the
// in-tree webby.wasm (../SummaryPanel.cpp, ../Summarize.cpp) has it.

#include "BrowserWindow.h"

using namespace WebbyUI;

struct SummaryJob { };

static QString const unavailable = QStringLiteral("Summarize is not in this build of webby (the full webby.wasm has it)");

void BrowserWindow::summarize_page() { show_toast(unavailable); }
void BrowserWindow::toggle_summary() { show_toast(unavailable); }
void BrowserWindow::close_summary() { }
void BrowserWindow::open_summarize_settings() { show_toast(unavailable); }
void BrowserWindow::ask_about_selection(WebView*, QString const&) { show_toast(unavailable); }
SummaryJob* BrowserWindow::panel_job() const { return nullptr; }
bool BrowserWindow::panel_showing() const { return false; }
QRect BrowserWindow::panel_rect() const { return {}; }
void BrowserWindow::relayout_panel() { }
void BrowserWindow::paint_panel(QPainter&) { }
void BrowserWindow::ensure_panel() { }
void BrowserWindow::render_panel() { }
void BrowserWindow::hook_summarize(WebView&) { }
void BrowserWindow::forget_summary(WebView*) { }
