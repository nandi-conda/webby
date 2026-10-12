/*
 * Webby: device location for navigator.geolocation, supplied by the Flutter UI.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/HashMap.h>
#include <LibCore/GeolocationProvider.h>

namespace Webby {

// Ladybird asks its browser-process provider for positions; this one has no location source of its own. It says
// what it wants (wanted()) and the UI, which reads the system's location service (GeoClue, Android), hands positions
// and errors back. See webby_geolocation_*() in webby_ffi.h.
class GeolocationProvider final : public Core::GeolocationProvider {
public:
    // Makes Ladybird use this provider. Call before the application is created, so its settings see one is available.
    static void install();
    // The provider Ladybird created, or null before the first request.
    static GeolocationProvider* the();

    virtual ~GeolocationProvider() override;

    virtual ErrorOr<RequestId, Core::GeolocationError> request_current_position(SuccessCallback, ErrorCallback) override;
    virtual void cancel_current_position_request(RequestId) override;
    virtual ErrorOr<WatchId, Core::GeolocationError> start_watching_position(SuccessCallback, ErrorCallback) override;
    virtual void stop_watching_position(WatchId) override;

    // WEBBY_GEOLOCATION_* flags: whether one-off requests are waiting and whether pages are watching.
    int wanted() const;
    u64 serial() const { return m_serial; }

    void did_update_position(Core::GeolocationCoordinates const&);
    void did_error(Core::GeolocationError const&);

private:
    GeolocationProvider() = default;

    struct PositionRequest {
        SuccessCallback on_success;
        ErrorCallback on_error;
    };

    void for_each_watcher(Function<void(PositionRequest&)> const&);

    HashMap<RequestId, PositionRequest> m_current_position_requests;
    HashMap<WatchId, PositionRequest> m_watchers;
    RequestId m_next_request_id { 1 };
    WatchId m_next_watch_id { 1 };
    u64 m_serial { 0 };
    WatchId m_dispatching_watch { 0 };
    bool m_dispatching_watch_stopped { false };
};

}
