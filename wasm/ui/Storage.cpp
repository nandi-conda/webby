/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Storage.h"

#include <AK/HashMap.h>
#include <AK/JsonObject.h>
#include <AK/JsonValue.h>
#include <AK/NonnullOwnPtr.h>
#include <AK/OwnPtr.h>
#include <AK/String.h>
#include <AK/Utf16String.h>
#include <LibCore/Directory.h>
#include <LibCore/File.h>
#include <LibCore/Timer.h>
#include <LibFileSystem/FileSystem.h>
#include <LibWeb/HTML/Scripting/Environments.h>
#include <LibWeb/StorageAPI/StorageAreaMirror.h>
#include <LibWeb/StorageAPI/StorageKey.h>
#include <LibWebCommon/StorageAPI/StorageEndpoint.h>
#include <AK/LexicalPath.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

namespace WebbyUI::Storage {

using Web::StorageAPI::StorageAreaConnection;
using Web::StorageAPI::StorageAreaId;
using Web::StorageAPI::StorageEndpointType;

namespace {

struct Area {
    AK_ALLOC_WITH_KMALLOC;

    StorageAreaId id;
    StorageEndpointType endpoint;
    OrderedHashMap<Utf16String, Utf16String> items;
    u64 usage { 0 };
};

u64 item_size(Utf16String const& key, Utf16String const& value)
{
    return Web::StorageAPI::storage_quota_size(key) + Web::StorageAPI::storage_quota_size(value);
}

// The profile folder, found the way Profile.cpp (the Qt side) finds it: $WEBBY_DATA_DIR, else
// $XDG_DATA_HOME/webby/profiles/$WEBBY_PROFILE, else ~/.local/share/webby/profiles/default.
ByteString profile_dir()
{
    if (auto const* dir = getenv("WEBBY_DATA_DIR"); dir && *dir)
        return dir;
    ByteString data;
    if (auto const* xdg = getenv("XDG_DATA_HOME"); xdg && *xdg) {
        data = xdg;
    } else {
        auto const* home = getenv("HOME");
        data = ByteString::formatted("{}/.local/share", home && *home ? home : "/tmp");
    }
    auto const* profile = getenv("WEBBY_PROFILE");
    return ByteString::formatted("{}/webby/profiles/{}", data, profile && *profile ? profile : "default");
}

class Owner final : public Web::StorageAPI::StorageAreaMirrorClient {
public:
    Owner()
        : m_path(ByteString::formatted("{}/local_storage.json", profile_dir()))
    {
        m_save_timer = Core::Timer::create_single_shot(AK::Duration::from_milliseconds(500), [this] { save(); });
        load();
    }

    virtual StorageAreaConnection connect_to_storage_area(Web::PageId page_id, StorageEndpointType endpoint, Web::HTML::EnvironmentId const& environment_id) override
    {
        auto environment = Web::HTML::environment_settings_object_with_id(environment_id);
        if (!environment)
            return {};
        auto storage_key = Web::StorageAPI::obtain_a_storage_key(*environment);
        if (!storage_key.has_value())
            return {};

        auto& area = area_for(endpoint, page_id, storage_key->to_string());
        StorageAreaConnection connection;
        connection.id = area.id;
        connection.keys.ensure_capacity(area.items.size());
        connection.values.ensure_capacity(area.items.size());
        for (auto const& item : area.items) {
            connection.keys.unchecked_append(item.key);
            connection.values.unchecked_append(item.value);
        }
        connection.usage = area.usage;
        return connection;
    }

    // An area outlives its mirror: the next document of the origin connects to it again.
    virtual void disconnect_from_storage_area(StorageAreaId) override { }

    // The mirror checked the quota against the same map before sending, and nothing else writes here, so every write
    // is accepted, and acknowledged at once (the mirror holds it as pending until then).
    virtual void set_storage_item(StorageAreaId id, Utf16String const& key, Utf16String const& value, String const&) override
    {
        if (auto* area = find(id)) {
            if (auto existing = area->items.find(key); existing != area->items.end())
                area->usage -= item_size(existing->key, existing->value);
            area->items.set(key, value);
            area->usage += item_size(key, value);
            changed(*area);
        }
        Web::StorageAPI::StorageAreaMirror::did_acknowledge_write(id);
    }

    virtual void remove_storage_item(StorageAreaId id, Utf16String const& key, String const&) override
    {
        if (auto* area = find(id)) {
            if (auto existing = area->items.find(key); existing != area->items.end()) {
                area->usage -= item_size(existing->key, existing->value);
                area->items.remove(key);
                changed(*area);
            }
        }
        Web::StorageAPI::StorageAreaMirror::did_acknowledge_write(id);
    }

    virtual void clear_storage_area(StorageAreaId id, String const&) override
    {
        if (auto* area = find(id)) {
            area->items.clear();
            area->usage = 0;
            changed(*area);
        }
        Web::StorageAPI::StorageAreaMirror::did_acknowledge_write(id);
    }

    void save()
    {
        if (!m_dirty)
            return;
        m_dirty = false;

        JsonObject root;
        for (auto const& entry : m_local_areas) {
            if (entry.value->items.is_empty())
                continue;
            JsonObject items;
            for (auto const& item : entry.value->items)
                items.set(item.key.to_well_formed_utf8(), JsonValue { item.value.to_well_formed_utf8() });
            root.set(entry.key, move(items));
        }
        auto json = root.serialized();

        // Written whole to a temporary file and renamed over the old one, so a crash mid-write keeps the last copy.
        auto result = [&]() -> ErrorOr<void> {
            auto path = LexicalPath { m_path };
            auto dir = path.dirname();
            if (!FileSystem::is_directory(dir))
                (void)TRY(Core::Directory::create(ByteString { dir }, Core::Directory::CreateDirectories::Yes));
            auto temporary = ByteString::formatted("{}.tmp", m_path);
            {
                auto file = TRY(Core::File::open(temporary, Core::File::OpenMode::Write | Core::File::OpenMode::Truncate));
                TRY(file->write_until_depleted(json.bytes()));
            }
            if (::rename(temporary.characters(), m_path.characters()) < 0)
                return Error::from_errno(errno);
            return {};
        }();
        if (result.is_error() && !m_warned) {
            // With no folder for the profile (latha-gui --no-root), localStorage still works, for this run only.
            warnln("webby: localStorage could not be saved to {}: {}", m_path, result.error());
            m_warned = true;
        }
    }

private:
    Area* find(StorageAreaId id)
    {
        auto it = m_areas_by_id.find(id);
        return it == m_areas_by_id.end() ? nullptr : it->value;
    }

    Area& area_for(StorageEndpointType endpoint, Web::PageId page_id, String storage_key)
    {
        if (endpoint == StorageEndpointType::LocalStorage) {
            if (auto existing = m_local_areas.get(storage_key); existing.has_value())
                return **existing;
            auto& area = new_area(endpoint);
            m_local_areas.set(move(storage_key), &area);
            return area;
        }
        // Session storage is partitioned by the traversable, which is the page.
        auto key = MUST(String::formatted("{}/{}", page_id.value(), storage_key));
        if (auto existing = m_session_areas.get(key); existing.has_value())
            return **existing;
        auto& area = new_area(endpoint);
        m_session_areas.set(move(key), &area);
        return area;
    }

    Area& new_area(StorageEndpointType endpoint)
    {
        auto area = make<Area>(StorageAreaId { ++m_next_id }, endpoint);
        auto& ref = *area;
        m_areas_by_id.set(ref.id, &ref);
        m_areas.append(move(area));
        return ref;
    }

    void changed(Area const& area)
    {
        if (area.endpoint != StorageEndpointType::LocalStorage)
            return;
        m_dirty = true;
        m_save_timer->restart();
    }

    void load()
    {
        auto file = Core::File::open(m_path, Core::File::OpenMode::Read);
        if (file.is_error())
            return;
        auto contents = file.value()->read_until_eof();
        if (contents.is_error())
            return;
        auto json = JsonValue::from_string(contents.value());
        if (json.is_error() || !json.value().is_object()) {
            warnln("webby: {} is not a JSON object; starting with empty localStorage", m_path);
            return;
        }
        json.value().as_object().for_each_member([&](String const& storage_key, JsonValue const& value) {
            if (!value.is_object())
                return;
            auto& area = area_for(StorageEndpointType::LocalStorage, {}, storage_key);
            value.as_object().for_each_member([&](String const& key, JsonValue const& item) {
                if (!item.is_string())
                    return;
                auto k = Utf16String::from_utf8(key);
                auto v = Utf16String::from_utf8(item.as_string());
                area.usage += item_size(k, v);
                area.items.set(move(k), move(v));
            });
        });
    }

    ByteString m_path;
    RefPtr<Core::Timer> m_save_timer;
    bool m_dirty { false };
    bool m_warned { false };
    u64 m_next_id { 0 };
    Vector<NonnullOwnPtr<Area>> m_areas;
    HashMap<StorageAreaId, Area*> m_areas_by_id;
    HashMap<String, Area*> m_local_areas;
    HashMap<String, Area*> m_session_areas;
};

Owner* s_owner = nullptr;

}

void initialize()
{
    if (s_owner)
        return;
    s_owner = new Owner;
    Web::StorageAPI::set_storage_area_mirror_client(s_owner);
}

void flush()
{
    if (s_owner)
        s_owner->save();
}

}
