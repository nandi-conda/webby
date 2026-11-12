#include "SyncDoc.h"
#include "SyncKeys.h"
#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <cstdio>
using namespace WebbyUI;
using namespace Qt::StringLiterals;
static QJsonObject load(char const* p) { QFile f(QString::fromLatin1(p)); f.open(QIODevice::ReadOnly); return SyncDoc::from_json(QJsonDocument::fromJson(f.readAll()).object()); }
int main()
{
    qint64 now = 2000000000;
    auto a = load("a.json"), b = load("b.json");
    QJsonObject o;
    o["canonA"] = QString::fromUtf8(SyncDoc::canonical(a));
    o["canonB"] = QString::fromUtf8(SyncDoc::canonical(b));
    o["mergeAB"] = QString::fromUtf8(SyncDoc::canonical(SyncDoc::merge(a, b, now)));
    o["mergeBA"] = QString::fromUtf8(SyncDoc::canonical(SyncDoc::merge(b, a, now)));
    QByteArray key; for (int i = 0; i < 32; ++i) key += char(i * 7 + 3);
    auto code = SyncKeys::code_for(key);
    o["code"] = code;
    auto k = SyncKeys::derive(code);
    o["blobId"] = k.blob_id; o["bookmarksBlobId"] = k.bookmarks_blob_id; o["tabsBlobId"] = k.tabs_blob_id; o["secretsBlobId"] = k.secrets_blob_id;
    o["authToken"] = k.auth_token; o["encKey"] = QString::fromLatin1(k.encryption_key.toHex());
    o["normalized"] = SyncKeys::normalize_code(code.toLower().replace(u'-', u' ').replace(u'o', u'0'));
    QJsonArray d; for (double x : { 1.0, 0.1, 1e21, 1e20, 1.5e-7, 1e-6, 123456789.123, -2.5, 5e-324, 1.7976931348623157e308, 100.0, 0.000001234 }) d.append(SyncDoc::dart_double(x));
    o["doubles"] = d;
    QFile nf(QStringLiteral("nim.json")); nf.open(QIODevice::ReadOnly);
    auto nim = QJsonDocument::fromJson(nf.readAll()).object();
    QString err;
    auto opened = SyncKeys::open(k, nim.value(u"sealed").toString().toUtf8(), &err);
    o["openedNim"] = opened ? QString::fromUtf8(SyncDoc::canonical(*opened)) : (u"ERROR "_s + err);
    QFile out(QStringLiteral("cpp-sealed.txt")); out.open(QIODevice::WriteOnly); out.write(SyncKeys::seal(k, SyncDoc::merge(a, b, now)));
    QString bad;
    o["badCode"] = SyncKeys::key_from_code(code.left(code.size() - 1) + (code.endsWith(u'A') ? u'B' : u'A'), &bad) ? u"accepted"_s : bad;
    fputs(QJsonDocument(o).toJson().constData(), stdout);
    return 0;
}
