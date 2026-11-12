/*
 * WebGL in the module itself (LocalWebGL.h): Web::WebGL::RemoteWebGLTransport over one in-module CanvasHost, as
 * Ladybird's CompositorRemoteWebGLTransport is over the Compositor process's. Every call runs at once, on this
 * thread, so "wait until the commands ran" is always true.
 */

#include "LocalWebGL.h"

#include <AK/Debug.h>
#include <AK/NeverDestroyed.h>
#include <Compositor/CanvasHost.h>
#include <Compositor/CanvasSurfaceRegistry.h>
#include <Compositor/VideoFrameHolds.h>
#include <LibCompositing/WebGL/WebGLSharedCommandBuffer.h>
#include <LibWeb/WebGL/LocalWebGLTransport.h>
#include <LibWeb/WebGL/RemoteWebGLTransport.h>

extern "C" int latha_gles_ready(void);

namespace WebbyUI {

namespace {

struct LocalCanvases {
    Compositor::CanvasSurfaceRegistry registry;
    Compositor::VideoFrameHolds video_frame_holds;
    // No Skia GPU context: OpenGLContext reads each presented frame back into a CPU painting surface.
    Compositor::CanvasHost host { nullptr, registry, video_frame_holds };
    Compositor::OwnedCanvasSurfaces surfaces { registry, host.canvas_surface_owner_id() };
};

LocalCanvases& canvases()
{
    static NeverDestroyed<LocalCanvases> s_canvases;
    return *s_canvases;
}

class LocalWebGLTransport final : public Web::WebGL::RemoteWebGLTransport {
public:
    virtual ~LocalWebGLTransport() override { destroy_context(); }

private:
    Compositor::CanvasHost& host() { return canvases().host; }

    virtual CreateResult create_context(Compositing::WebGL::WebGLVersion webgl_version, Gfx::IntSize initial_size, bool depth, bool stencil, bool antialias) override
    {
        VERIFY(!m_canvas_id.has_value());
        auto created = host().create_webgl_context(webgl_version, initial_size, depth, stencil, antialias);
        CreateResult result;
        if (created.success) {
            result.success = true;
            result.supported_extensions = move(created.supported_extensions);
            m_canvas_id = created.canvas_id;
        }
        return result;
    }

    virtual Optional<Compositing::CanvasId> canvas_id() const override { return m_canvas_id; }

    virtual void destroy_context() override
    {
        if (!m_canvas_id.has_value())
            return;
        host().destroy_context(*m_canvas_id);
        m_canvas_id.clear();
    }

    virtual void set_shared_command_buffer(Core::AnonymousBuffer const& command_buffer) override
    {
        if (!m_canvas_id.has_value())
            return;
        auto shared = Compositing::WebGL::WebGLSharedCommandBuffer::adopt_received_buffer(command_buffer);
        if (!shared.has_value()) {
            dbgln("webby: invalid WebGL shared command buffer");
            return;
        }
        host().set_webgl_shared_command_buffer(*m_canvas_id, shared.release_value());
    }

    virtual void send_commands_from_shared_buffer(u64 offset, u64 size_in_bytes, u64 flush_sequence_number, Vector<Compositing::WebGL::ImageSourceFrame> const& frames) override
    {
        if (!m_canvas_id.has_value())
            return;
        if (!host().execute_webgl_commands_from_shared_buffer(*m_canvas_id, offset, size_in_bytes, flush_sequence_number, frames))
            dbgln("webby: invalid WebGL shared command buffer range");
    }

    virtual bool wait_until_published_commands_executed() override { return m_canvas_id.has_value(); }

    virtual void send_commands(ReadonlyBytes commands, Vector<Compositing::WebGL::ImageSourceFrame> const& frames) override
    {
        if (!m_canvas_id.has_value())
            return;
        host().execute_webgl_commands(*m_canvas_id, commands, frames);
    }

    virtual void present_canvas(bool preserve_drawing_buffer) override
    {
        if (!m_canvas_id.has_value())
            return;
        host().present_webgl_canvas(*m_canvas_id, preserve_drawing_buffer);
    }

    virtual void clear_drawing_buffer() override
    {
        if (!m_canvas_id.has_value())
            return;
        host().clear_webgl_drawing_buffer(*m_canvas_id);
    }

    virtual ByteBuffer sync_call(ByteBuffer request) override
    {
        if (!m_canvas_id.has_value())
            return {};
        auto reply = host().execute_webgl_sync_call(*m_canvas_id, move(request));
        if (reply.is_error()) {
            dbgln("webby: WebGL sync call failed: {}", reply.error());
            return {};
        }
        return reply.release_value();
    }

    virtual Compositing::WebGL::ReadPixelsResult read_pixels_robust_angle(Compositing::WebGL::GLint x, Compositing::WebGL::GLint y, Compositing::WebGL::GLsizei width, Compositing::WebGL::GLsizei height, Compositing::WebGL::GLenum format, Compositing::WebGL::GLenum type, Compositing::WebGL::GLsizei buf_size, Core::AnonymousBuffer pixels) override
    {
        if (!m_canvas_id.has_value() || buf_size < 0 || (buf_size > 0 && (!pixels.is_valid() || pixels.size() < static_cast<size_t>(buf_size))))
            return {};
        return host().webgl_read_pixels_robust_angle(*m_canvas_id, x, y, width, height, format, type, buf_size, move(pixels));
    }

    virtual bool read_buffer_sub_data(Compositing::WebGL::GLenum target, Compositing::WebGL::GLintptr offset, Compositing::WebGL::GLintptr size, Core::AnonymousBuffer data) override
    {
        if (!m_canvas_id.has_value() || size < 0 || (size > 0 && (!data.is_valid() || data.size() < static_cast<size_t>(size))))
            return false;
        return host().webgl_read_buffer_sub_data(*m_canvas_id, target, offset, size, move(data));
    }

    virtual Gfx::ShareableBitmap read_back_drawing_buffer(Gfx::IntRect const& rect) override
    {
        if (!m_canvas_id.has_value())
            return {};
        return host().read_back_pixels(*m_canvas_id, rect, Gfx::AlphaType::Premultiplied);
    }

    Optional<Compositing::CanvasId> m_canvas_id;
};

RefPtr<Web::WebGL::RemoteWebGLTransport> create_transport(Web::Page&)
{
    return adopt_ref(*new LocalWebGLTransport);
}

}

bool install_local_webgl()
{
    if (!latha_gles_ready())
        return false;
    Web::WebGL::set_local_webgl_transport_factory(create_transport);
    return true;
}

Compositor::OwnedCanvasSurfaces const* local_canvas_surfaces()
{
    if (!latha_gles_ready())
        return nullptr;
    return &canvases().surfaces;
}

}
