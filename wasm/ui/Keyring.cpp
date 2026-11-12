/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Keyring.h"

#include <QByteArray>
#include <QElapsedTimer>
#include <QTimer>
#include <memory>

extern "C" {
#include "pty_guest.h"
}

namespace WebbyUI::Keyring {

namespace {

// An unlock prompt (a locked keyring) waits for the user's password.
constexpr int time_limit_ms = 120000;

QString to_qstring(pty_guest_string_t const& s)
{
    return QString::fromUtf8(reinterpret_cast<char const*>(s.ptr), qsizetype(s.len));
}

struct Running {
    uint32_t id { 0 };
    QByteArray output;
    QElapsedTimer started;
    QTimer timer;
    std::function<void(Lookup)> done;
};

void read_output(Running& run)
{
    pty_guest_string_t chunk {};
    latha_gui_pty_read(run.id, &chunk);
    if (chunk.len)
        run.output += QByteArray::fromBase64(QByteArray(reinterpret_cast<char const*>(chunk.ptr), qsizetype(chunk.len)));
    pty_guest_string_free(&chunk);
}

}

void lookup(QString const& profile, std::function<void(Lookup)> done)
{
    // The import is not optional: a host must offer latha:gui's pty interface to run webby.wasm (latha-gui does).
    QByteArray const args[] = { "secret-tool", "lookup", "application", "webby", "profile", profile.toUtf8() };
    pty_guest_string_t argv_items[std::size(args)];
    for (size_t i = 0; i < std::size(args); ++i)
        argv_items[i] = { reinterpret_cast<uint8_t*>(const_cast<char*>(args[i].constData())), size_t(args[i].size()) };
    pty_guest_list_string_t argv { argv_items, std::size(args) };
    pty_guest_list_tuple2_string_string_t env { nullptr, 0 };
    uint32_t id = 0;
    pty_guest_string_t err {};
    // Wide enough that the tool's one line (a 44-character key) never wraps.
    if (!latha_gui_pty_spawn(&argv, &env, nullptr, 400, 24, &id, &err)) {
        Lookup result;
        result.error = QStringLiteral("the host could not run secret-tool (%1)").arg(to_qstring(err));
        pty_guest_string_free(&err);
        QTimer::singleShot(0, [done = std::move(done), result] { done(result); });
        return;
    }
    auto run = std::make_shared<Running>();
    run->id = id;
    run->done = std::move(done);
    run->started.start();
    run->timer.setInterval(30);
    QObject::connect(&run->timer, &QTimer::timeout, [run] {
        read_output(*run);
        int32_t code = 0;
        bool ended = latha_gui_pty_exit_code(run->id, &code);
        bool too_long = run->started.elapsed() > time_limit_ms;
        if (!ended && !too_long)
            return;
        run->timer.stop();
        // The connection holds `run` too: drop it (Qt keeps this slot alive until it returns).
        run->timer.disconnect();
        latha_gui_pty_close(run->id);
        Lookup result;
        auto text = QString::fromUtf8(run->output).trimmed();
        // The secret is the last line (GLib may warn before it).
        auto last = text.section(u'\n', -1).trimmed();
        if (too_long)
            result.error = QStringLiteral("secret-tool did not answer");
        else if (code == 0 && !text.isEmpty())
            result = { true, last, {} };
        else if (code == 127 || text.contains(QStringLiteral("No such file")) || text.contains(QStringLiteral("not found")))
            result.error = QStringLiteral("secret-tool is not installed (it comes with libsecret)");
        else if (!text.isEmpty() && code != 1)
            result.error = text.left(200);
        // Exit code 1 and no output: the keyring answered, without the item.
        auto done = std::move(run->done);
        // `run` (and its timer) goes with this last copy, after the timer's signal has returned.
        QTimer::singleShot(0, [run, done = std::move(done), result]() mutable {
            done(result);
            run.reset();
        });
    });
    run->timer.start();
}

}
