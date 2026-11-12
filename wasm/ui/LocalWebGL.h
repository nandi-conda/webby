/*
 * WebGL in the module itself: Ladybird's Compositor runs a page's WebGL commands (CanvasHost, HostWebGLContext,
 * OpenGLContext) on the latha:gui host's GPU through wasm/gl, here instead of in a Compositor process.
 */

#pragma once

namespace Compositor {
class OwnedCanvasSurfaces;
}

namespace WebbyUI {

// Makes LibWeb's WebGL contexts run here (its local WebGL transport factory). False when the host has no GL, and
// then getContext("webgl") gives null as before.
bool install_local_webgl();

// The canvases WebGL contexts presented, for the display list player to draw.
Compositor::OwnedCanvasSurfaces const* local_canvas_surfaces();

}
