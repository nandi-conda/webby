/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// latha:proc (wit/proc/proc.wit) for webby's engine worker: channels, spawning this component as a worker, and shared
// memory, over the component's imports. Only std types.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace WebbyUI::Proc {

// The host runs this component as a worker (latha-gui 0.9.0 and later set LATHA_GUI_WORKER=1).
bool workers_available();

struct Message {
    std::vector<uint8_t> data;
    std::vector<uint32_t> handles;
};

enum class Received {
    Message,
    Timeout,
    Closed,
};

bool send(uint32_t channel, std::vector<uint8_t> const& data, std::vector<uint32_t> const& handles = {});
// timeout_ms 0: do not wait, < 0: for ever.
Received receive(uint32_t channel, int timeout_ms, Message&);
// Whether a message (or the peer's close) is waiting, after at most timeout_ms.
bool wait(uint32_t channel, int timeout_ms);
void close(uint32_t handle);
std::optional<uint32_t> parent();
// This component again, as a worker on its own thread of the host: its pid and our end of its channel.
bool spawn_worker(std::vector<std::string> const& args, uint32_t& pid, uint32_t& channel, std::string& error);

// Shared memory. A mapping is page aligned space of ours (allocated here) that shows the object's bytes.
size_t page_size();
size_t round_to_pages(size_t);
std::optional<uint32_t> create_memory(size_t size);
// Maps `size` bytes (a multiple of page_size) of the object; nullptr if it cannot.
uint8_t* map(uint32_t memory, size_t size);
void unmap(uint8_t*, size_t size);

}
