/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "ProcChannel.h"

#include <cstdlib>
#include <cstring>

#include "proc_guest.h"

namespace WebbyUI::Proc {

bool workers_available()
{
    auto const* v = getenv("LATHA_GUI_WORKER");
    return v && strcmp(v, "1") == 0;
}

bool send(uint32_t channel, std::vector<uint8_t> const& data, std::vector<uint32_t> const& handles)
{
    proc_guest_list_u8_t d { const_cast<uint8_t*>(data.data()), data.size() };
    proc_guest_list_handle_t h { const_cast<uint32_t*>(handles.data()), handles.size() };
    latha_proc_channels_error_t err {};
    return latha_proc_channels_send(channel, &d, &h, &err);
}

Received receive(uint32_t channel, int timeout_ms, Message& out)
{
    latha_proc_channels_message_t m {};
    latha_proc_channels_error_t err {};
    if (!latha_proc_channels_recv(channel, timeout_ms, &m, &err))
        return err == LATHA_PROC_CHANNELS_ERROR_TIMEOUT ? Received::Timeout : Received::Closed;
    out.data.assign(m.data.ptr, m.data.ptr + m.data.len);
    out.handles.assign(m.handles.ptr, m.handles.ptr + m.handles.len);
    latha_proc_channels_message_free(&m);
    return Received::Message;
}

bool wait(uint32_t channel, int timeout_ms)
{
    proc_guest_list_handle_t hs { &channel, 1 };
    proc_guest_list_u32_t ready {};
    latha_proc_channels_wait(&hs, timeout_ms, &ready);
    bool any = ready.len > 0;
    proc_guest_list_u32_free(&ready);
    return any;
}

void close(uint32_t handle)
{
    latha_proc_channels_close(handle);
}

std::optional<uint32_t> parent()
{
    uint32_t h = 0;
    if (!latha_proc_channels_parent(&h))
        return {};
    return h;
}

bool spawn_worker(std::vector<std::string> const& args, uint32_t& pid, uint32_t& channel, std::string& error)
{
    std::vector<proc_guest_string_t> items;
    for (auto const& a : args)
        items.push_back({ reinterpret_cast<uint8_t*>(const_cast<char*>(a.data())), a.size() });
    proc_guest_list_string_t list { items.data(), items.size() };
    proc_guest_string_t path { nullptr, 0 };
    proc_guest_tuple2_u32_handle_t ret {};
    proc_guest_string_t err {};
    if (!latha_proc_process_spawn(&path, &list, &ret, &err)) {
        error.assign(reinterpret_cast<char const*>(err.ptr), err.len);
        proc_guest_string_free(&err);
        return false;
    }
    pid = ret.f0;
    channel = ret.f1;
    return true;
}

size_t page_size()
{
    static size_t size = latha_proc_memory_page_size();
    return size;
}

size_t round_to_pages(size_t n)
{
    auto p = page_size();
    return (n + p - 1) / p * p;
}

std::optional<uint32_t> create_memory(size_t size)
{
    uint32_t h = 0;
    latha_proc_memory_error_t err {};
    if (!latha_proc_memory_create(size, &h, &err))
        return {};
    return h;
}

uint8_t* map(uint32_t memory, size_t size)
{
    auto* p = static_cast<uint8_t*>(aligned_alloc(page_size(), size));
    if (!p)
        return nullptr;
    latha_proc_memory_error_t err {};
    if (!latha_proc_memory_map_at(memory, 0, uint32_t(reinterpret_cast<uintptr_t>(p)), uint32_t(size), &err)) {
        free(p);
        return nullptr;
    }
    return p;
}

void unmap(uint8_t* p, size_t size)
{
    if (!p)
        return;
    latha_proc_memory_error_t err {};
    // The space is ours again (zeroed private pages), then back to malloc.
    latha_proc_memory_unmap_at(uint32_t(reinterpret_cast<uintptr_t>(p)), uint32_t(size), &err);
    free(p);
}

}
