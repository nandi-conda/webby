/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The messages between the chrome (WebView.cpp) and the engine worker (EngineWorker.cpp) on their latha:proc channel:
// a kind byte, then fields written in order (little endian numbers, strings as u32 length + bytes). Only std types.

#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace WebbyUI::EngineProtocol {

// The chrome to the engine. `view` is the chrome's id for a view; `seq` numbers a request that waits for its Reply.
enum class ToEngine : uint8_t {
    Hello = 1,      // color scheme (u8)
    Create,         // view, width, height, message prefix
    Destroy,        // view
    Load,           // view, url
    Reload,         // view
    GoBack,         // view
    GoForward,      // view
    SetVisible,     // view, u8
    Resize,         // view, width, height
    MouseDown,      // view, x, y, button, buttons, modifiers, clicks
    MouseUp,        // view, x, y, button, buttons, modifiers
    MouseMove,      // view, x, y, buttons, modifiers
    MouseLeave,     // view
    Wheel,          // view, x, y, f64 dx, f64 dy, modifiers, u32 seq (the frame that shows it says so)
    KeyDown,        // view, key, modifiers, code point, u8 repeat
    KeyUp,          // view, key, modifiers, code point
    AnswerClipboard, // view, u64 request, text
    RunJavaScript,  // view, source
    SetZoom,        // view, f64
    SelectAll,      // view
    InsertText,     // view, text
    FindEnd,        // view
    WebAuthnReply,  // view, u64 request, reply json
    WebAuthnRespond, // view, u8 accepted, s32 account (the engine's own WebAuthnFlow; unused by the chrome)
    SetColorScheme, // u8 dark
    FrameDone,      // view, buffer index: the chrome took the frame in that buffer (the other one is free again)
    PageScripts,    // seq, count, sources: the answer to a PageScriptsRequest
    CollectGarbage, // a full collection of the engine's heap (EngineView::collect_garbage)
    // Requests answered with Reply(seq, ...):
    SelectedText,   // seq, view -> text
    CutSelection,   // seq, view -> text
    Find,           // seq, view, query, u8 case sensitive -> u32 index, s32 total
    FindNext,       // seq, view -> u32 index, s32 total
    FindPrevious,   // seq, view -> u32 index, s32 total
};

// The engine to the chrome.
enum class ToChrome : uint8_t {
    State = 1,          // view, url, title, u8 loading, u8 can go back, u8 can go forward
    TitleChanged,       // view, title
    UrlChanged,         // view, url
    LoadingChanged,     // view, u8
    LinkHovered,        // view, url
    ClipboardWrite,     // view, text, u8 selection
    ClipboardRequest,   // view, u64 request, u8 selection
    ContextMenu,        // view, x, y, link, link text, image, selection, u8 editable
    Download,           // view, url, path, u64 size, mime, error
    Pdf,                // view, url, mime, data (bytes, or in the memory object sent along when big)
    PageMessage,        // view, text, document url
    NavigationRequest,  // view, url: the page navigates; the chrome loads it (Load) unless it takes the URL itself
    WebAuthnRequest,    // view, u64 request, json
    WebAuthnPrompt,     // view, prompt json (the engine's own WebAuthnFlow; unused)
    Frame,              // view, buffer index, width, height, u8 known, s32 moved, rects, scrollbars; the buffers'
                        // memory objects come along when new (two handles, then the buffer size as u64)
    PageScriptsRequest, // seq, view, url: the engine waits for PageScripts(seq)
    Reply,              // seq, then what the request returns
    Memory,             // u8 pressure, u8 critical (since the last one), report: the engine's memory, every second
};

class Writer {
public:
    explicit Writer(uint8_t kind) { m_data.push_back(kind); }
    Writer& u8(uint8_t v) { m_data.push_back(v); return *this; }
    Writer& u32(uint32_t v) { return raw(&v, 4); }
    Writer& s32(int32_t v) { return raw(&v, 4); }
    Writer& u64(uint64_t v) { return raw(&v, 8); }
    Writer& f64(double v) { return raw(&v, 8); }
    Writer& str(std::string const& s) { u32(uint32_t(s.size())); return raw(s.data(), s.size()); }
    Writer& bytes(void const* p, size_t n) { u32(uint32_t(n)); return raw(p, n); }
    std::vector<uint8_t>& data() { return m_data; }

private:
    Writer& raw(void const* p, size_t n)
    {
        auto const* b = static_cast<uint8_t const*>(p);
        m_data.insert(m_data.end(), b, b + n);
        return *this;
    }
    std::vector<uint8_t> m_data;
};

class Reader {
public:
    Reader(uint8_t const* p, size_t n) : m_p(p), m_end(p + n) { }
    uint8_t u8() { uint8_t v = 0; raw(&v, 1); return v; }
    uint32_t u32() { uint32_t v = 0; raw(&v, 4); return v; }
    int32_t s32() { int32_t v = 0; raw(&v, 4); return v; }
    uint64_t u64() { uint64_t v = 0; raw(&v, 8); return v; }
    double f64() { double v = 0; raw(&v, 8); return v; }
    std::string str()
    {
        uint32_t n = u32();
        if (n > size_t(m_end - m_p)) { m_ok = false; m_p = m_end; return {}; }
        std::string s(reinterpret_cast<char const*>(m_p), n);
        m_p += n;
        return s;
    }
    std::vector<uint8_t> bytes()
    {
        auto s = str();
        return std::vector<uint8_t>(s.begin(), s.end());
    }
    bool ok() const { return m_ok; }

private:
    void raw(void* out, size_t n)
    {
        if (n > size_t(m_end - m_p)) { m_ok = false; m_p = m_end; return; }
        memcpy(out, m_p, n);
        m_p += n;
    }
    uint8_t const* m_p;
    uint8_t const* m_end;
    bool m_ok { true };
};

}
