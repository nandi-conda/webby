/*
 * Webby: device location for navigator.geolocation, supplied by the UI.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <WebbyGeolocation.h>
#include <webby_ffi.h>

namespace Webby {

static GeolocationProvider* s_provider;

void GeolocationProvider::install()
{
    Core::GeolocationProvider::set_provider_functions(
        []() -> ErrorOr<NonnullOwnPtr<Core::GeolocationProvider>> {
            return TRY(adopt_nonnull_own_or_enomem(new (nothrow) GeolocationProvider));
        },
        [] { return true; });
}

GeolocationProvider* GeolocationProvider::the()
{
    return s_provider;
}

GeolocationProvider::~GeolocationProvider()
{
    if (s_provider == this)
        s_provider = nullptr;
}

ErrorOr<GeolocationProvider::RequestId, Core::GeolocationError> GeolocationProvider::request_current_position(SuccessCallback on_success, ErrorCallback on_error)
{
    s_provider = this;
    auto id = m_next_request_id++;
    m_current_position_requests.set(id, { move(on_success), move(on_error) });
    ++m_serial;
    return id;
}

void GeolocationProvider::cancel_current_position_request(RequestId id)
{
    if (m_current_position_requests.remove(id))
        ++m_serial;
}

ErrorOr<GeolocationProvider::WatchId, Core::GeolocationError> GeolocationProvider::start_watching_position(SuccessCallback on_success, ErrorCallback on_error)
{
    s_provider = this;
    auto id = m_next_watch_id++;
    m_watchers.set(id, { move(on_success), move(on_error) });
    ++m_serial;
    return id;
}

void GeolocationProvider::stop_watching_position(WatchId id)
{
    // A watcher may stop itself from its own callback, which is out of the map while it runs.
    if (m_dispatching_watch == id) {
        m_dispatching_watch_stopped = true;
        ++m_serial;
        return;
    }
    if (m_watchers.remove(id))
        ++m_serial;
}

void GeolocationProvider::for_each_watcher(Function<void(PositionRequest&)> const& callback)
{
    Vector<WatchId> watch_ids;
    for (auto const& watcher : m_watchers)
        watch_ids.append(watcher.key);
    for (auto id : watch_ids) {
        auto watcher = m_watchers.take(id);
        if (!watcher.has_value())
            continue;
        m_dispatching_watch = id;
        m_dispatching_watch_stopped = false;
        callback(*watcher);
        m_dispatching_watch = 0;
        if (!m_dispatching_watch_stopped)
            m_watchers.set(id, watcher.release_value());
    }
}

int GeolocationProvider::wanted() const
{
    int flags = 0;
    if (!m_current_position_requests.is_empty())
        flags |= WEBBY_GEOLOCATION_REQUESTED;
    if (!m_watchers.is_empty())
        flags |= WEBBY_GEOLOCATION_WATCHING;
    return flags;
}

void GeolocationProvider::did_update_position(Core::GeolocationCoordinates const& coordinates)
{
    // Callbacks may cancel or start requests, so work on what's here now.
    auto requests = move(m_current_position_requests);
    if (!requests.is_empty())
        ++m_serial;
    for (auto& request : requests)
        request.value.on_success(coordinates);

    for_each_watcher([&](PositionRequest& watcher) { watcher.on_success(coordinates); });
}

void GeolocationProvider::did_error(Core::GeolocationError const& error)
{
    auto requests = move(m_current_position_requests);
    if (!requests.is_empty())
        ++m_serial;
    for (auto& request : requests)
        request.value.on_error(error);

    for_each_watcher([&](PositionRequest& watcher) { watcher.on_error(error); });
}

}
