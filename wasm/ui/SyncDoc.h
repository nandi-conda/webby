/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The synced form of everything and how two copies merge: a port of the Nim front end's
// nim/src/features/sync/doc.nim, which is the Dart app's SyncDoc. Qt only, so a test can run it on its own.
//
// A doc is an object of sections (passwords, passkeys, neverSave, bookmarks, devices, summaries, sessions, secrets),
// each {key: record}. Records carry "updatedAt" (seconds); a deletion is a tombstone {updatedAt, deleted: true}.
// `canonical` is byte for byte Dart's `SyncDoc.canonical()` (jsonEncode with keys sorted by UTF-16 code units,
// Dart's number and string forms), since merge ties are broken by comparing those encodings and every device must
// pick the same winner.

#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QString>
#include <QStringList>

namespace WebbyUI::SyncDoc {

constexpr qint64 tombstone_lifetime = 180 * 24 * 3600; // seconds a deletion is remembered
constexpr qint64 device_lifetime = 30 * 24 * 3600;     // seconds a silent device stays under "Tabs from other devices"
constexpr int summary_limit = 300;

QStringList const& section_names();

// Dart's double.toString(): JavaScript's shortest form, with ".0" on whole numbers.
QString dart_double(double);
// jsonEncode of a value with its object keys sorted at every level (Dart's _canonicalValue). Whole numbers print as
// integers, except under the key "pos" (a bookmark's position, a double in Dart and Nim), which prints as Dart prints a
// double; other numbers as Dart prints doubles. (Qt's JSON cannot tell 1.0 from 1.)
QByteArray canonical_value(QJsonValue const&);

QJsonObject new_doc();
// The doc's section (an empty object when missing).
QJsonObject section(QJsonObject const& doc, QString const& name);
// SyncDoc.fromJson: the sections that are objects, and in them the records that are objects.
QJsonObject from_json(QJsonValue const&);
// A doc holding only one section.
QJsonObject doc_with(QString const& name, QJsonObject const& records);
// SyncDoc.toJson: version, the three vault sections always, the others when not empty.
QJsonObject to_json(QJsonObject const& doc);
QByteArray canonical(QJsonObject const& doc);
bool same(QJsonObject const& a, QJsonObject const& b);

qint64 updated_at(QJsonObject const& record);
bool is_deleted(QJsonObject const& record);
// Whether `a` wins over `b`: the newer; at the same time a deletion; then the larger encoding.
bool wins(QJsonObject const& a, QJsonObject const& b);

// Merges two copies; the result is the same in either order. `now` in seconds.
QJsonObject merge(QJsonObject const& a, QJsonObject const& b, qint64 now);

}
