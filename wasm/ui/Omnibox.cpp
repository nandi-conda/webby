/*
 * Copyright (c) 2026-present, the webby developers.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "Omnibox.h"
#include "Profile.h"

#include <QHash>
#include <QStringList>
#include <QUrl>
#include <algorithm>

using namespace Qt::StringLiterals;

namespace WebbyUI::Omnibox {

QString query_url()
{
    auto env = qEnvironmentVariable("WEBBY_SEARCH_URL");
    return env.contains(QStringLiteral("%s")) ? env : QStringLiteral("https://www.google.com/search?q=%s");
}

static int scheme_length(QString const& text)
{
    if (text.isEmpty() || !text.at(0).isLetter() || text.at(0).unicode() > 127)
        return 0;
    for (int i = 1; i < text.size(); ++i) {
        auto c = text.at(i);
        if (c == u':')
            return i + 1;
        if (!(c.unicode() < 128 && (c.isLetterOrNumber() || c == u'+' || c == u'.' || c == u'-')))
            return 0;
    }
    return 0;
}

static bool ascii_all(QString const& s, auto predicate)
{
    return std::all_of(s.begin(), s.end(), [&](QChar c) { return c.unicode() < 128 && predicate(char(c.unicode())); });
}

// A port of looksLikeAddress in nim/src/features/omnibox/address.nim.
bool looks_like_address(QString const& text)
{
    if (text.isEmpty() || std::any_of(text.begin(), text.end(), [](QChar c) { return c.isSpace(); }))
        return false;
    int s = scheme_length(text);
    int colon = int(text.indexOf(u':'));
    bool host_with_port = colon > 0 && colon + 1 < text.size() && text.at(colon + 1).isDigit();
    if (s > 0 && !host_with_port) {
        static QStringList const schemes { u"about"_s, u"data"_s, u"file"_s, u"mailto"_s, u"javascript"_s, u"view-source"_s };
        return text.contains(QStringLiteral("://")) || schemes.contains(text.left(s - 1).toLower());
    }
    auto authority = text;
    for (int i = 0; i < text.size(); ++i) {
        auto c = text.at(i);
        if (c == u'/' || c == u'?' || c == u'#') {
            authority = text.left(i);
            break;
        }
    }
    if (auto at = authority.lastIndexOf(u'@'); at >= 0)
        authority = authority.mid(at + 1);
    auto host = authority;
    if (authority.startsWith(u'[')) {
        auto close = authority.indexOf(u']');
        if (close < 0)
            return false;
        host = authority.left(close + 1);
        auto rest = authority.mid(close + 1);
        if (host.size() < 3 || !ascii_all(host.mid(1, host.size() - 2), [](char c) { return isxdigit(c) || c == ':' || c == '.'; }))
            return false;
        if (!rest.isEmpty() && !(rest.at(0) == u':' && rest.size() >= 2 && rest.size() <= 6 && ascii_all(rest.mid(1), [](char c) { return isdigit(c); })))
            return false;
        return true;
    }
    if (auto c = authority.lastIndexOf(u':'); c >= 0) {
        auto port = authority.mid(c + 1);
        if (port.isEmpty() || port.size() > 5 || !ascii_all(port, [](char ch) { return isdigit(ch); }))
            return false;
        host = authority.left(c);
    }
    if (host.isEmpty() || std::any_of(host.begin(), host.end(), [](QChar c) { return c == u':' || c == u'/' || c == u'?' || c == u'#' || c == u'@' || c.isSpace(); }))
        return false;
    host = host.toLower();
    if (host == u"localhost")
        return true;
    auto parts = host.split(u'.');
    if (parts.size() == 4 && std::all_of(parts.begin(), parts.end(), [](QString const& p) { return p.size() >= 1 && p.size() <= 3 && ascii_all(p, [](char c) { return isdigit(c); }); }))
        return true;
    if (parts.size() > 1 && parts.last().isEmpty())
        parts.removeLast();
    if (parts.size() < 2)
        return false;
    auto const& tld = parts.last();
    if (tld.size() < 2 || tld.size() > 63 || !ascii_all(tld, [](char c) { return isalpha(c); }))
        return false;
    for (int i = 0; i + 1 < parts.size(); ++i) {
        if (parts[i].isEmpty() || !ascii_all(parts[i], [](char c) { return islower(c) || isdigit(c) || c == '-'; }))
            return false;
    }
    return true;
}

QString address_to_url(QString const& input)
{
    auto text = input.trimmed();
    if (text.isEmpty() || text.startsWith(u'/') || looks_like_address(text))
        return text;
    return query_url().replace(QStringLiteral("%s"), QString::fromLatin1(QUrl::toPercentEncoding(text)));
}

QList<Suggestion> suggestions(QString const& input, int limit)
{
    QList<Suggestion> out;
    auto text = input.trimmed();
    if (text.isEmpty())
        return out;
    if (looks_like_address(text) || text.startsWith(u'/'))
        out.append({ Suggestion::Kind::Address, text, address_to_url(text) });
    else
        out.append({ Suggestion::Kind::Search, text, address_to_url(text) });

    auto words = text.toLower().split(u' ', Qt::SkipEmptyParts);
    auto matches = [&](QString const& title, QString const& url) {
        auto hay = (title + u' ' + url).toLower();
        return std::all_of(words.begin(), words.end(), [&](QString const& w) { return hay.contains(w); });
    };
    QStringList seen { out.first().url };
    for (auto const* b : Profile::Bookmarks::the().all()) {
        if (out.size() >= limit)
            return out;
        if (!seen.contains(b->url) && matches(b->title, b->url)) {
            out.append({ Suggestion::Kind::Bookmark, b->label(), b->url });
            seen.append(b->url);
        }
    }
    // History: count visits per URL (newest title wins), rank by count then recency; a URL that starts with the text
    // (after its scheme and www.) comes first, as the field's completion would.
    struct Entry {
        QString title;
        int count { 0 };
        qint64 last { 0 };
        bool prefix { false };
    };
    QHash<QString, Entry> by_url;
    auto lower = text.toLower();
    for (auto const& v : Profile::History::the().visits()) {
        if (!matches(v.title, v.url))
            continue;
        auto& e = by_url[v.url];
        ++e.count;
        e.last = v.time;
        if (!v.title.isEmpty())
            e.title = v.title;
        auto bare = v.url.toLower();
        for (auto prefix : { u"https://"_s, u"http://"_s })
            if (bare.startsWith(prefix))
                bare = bare.mid(prefix.size());
        if (bare.startsWith(u"www."_s))
            bare = bare.mid(4);
        e.prefix = bare.startsWith(lower);
    }
    QList<QString> urls = by_url.keys();
    std::sort(urls.begin(), urls.end(), [&](QString const& a, QString const& b) {
        auto const& x = by_url[a];
        auto const& y = by_url[b];
        if (x.prefix != y.prefix)
            return x.prefix;
        if (x.count != y.count)
            return x.count > y.count;
        return x.last > y.last;
    });
    for (auto const& url : urls) {
        if (out.size() >= limit)
            break;
        if (seen.contains(url))
            continue;
        auto const& e = by_url[url];
        out.append({ Suggestion::Kind::History, e.title.isEmpty() ? url : e.title, url });
        seen.append(url);
    }
    return out;
}

}
