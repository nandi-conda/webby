/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The engine worker: on a host that can (latha-gui 0.9.0 and later, Proc::workers_available), webby.wasm starts a
// second instance of itself on another thread of the host, and every page's LibWeb, LibJS, raster, network and media
// run there (EngineView), while the chrome (Qt) keeps its own thread: typing, menus and the chrome's painting never
// wait for a page's script or layout, and a page's work runs at the same time as the chrome's. WebView.cpp is the
// chrome's side; EngineWorker.cpp the worker's (latha:proc/worker's run export). The two talk over the worker's
// channel (EngineProtocol.h); frames come through shared memory: two buffers per view, so the engine draws the next
// frame while the chrome shows the last.

#pragma once

namespace WebbyUI::EngineWorker {

// How long the worker sleeps at most between turns of its event loop when nothing arrives (timers, sockets).
constexpr int idle_wait_ms = 4;

}
