"""Round trip against a running webby-sync (default: `pywrangler dev` on localhost:8787).

    python3 test/roundtrip.py [base url]
"""

import os
import sys
import urllib.error
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8787"
BLOB = BASE + "/v1/blobs/" + os.urandom(32).hex()
TOKEN = "t" * 40
OTHER = "o" * 40


def call(method, url=BLOB, body=None, token=TOKEN, **headers):
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, response.headers.get("ETag"), response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers.get("ETag"), error.read()


def expect(label, got, want):
    print(f"{'ok  ' if got == want else 'FAIL'} {label}: {got}")
    if got != want:
        sys.exit(1)


expect("healthz", call("GET", BASE + "/healthz", token=None)[0], 200)
expect("no token", call("GET", token=None)[0], 401)
expect("short token", call("GET", token="short")[0], 401)
expect("bad path", call("GET", BASE + "/v1/blobs/xyz")[0], 404)
expect("missing", call("GET")[0], 404)
expect("unconditional put", call("PUT", body=b"one")[0], 428)
expect("if-match on missing", call("PUT", body=b"one", **{"If-Match": '"nope"'})[0], 412)
status, etag1, _ = call("PUT", body=b"one", **{"If-None-Match": "*"})
expect("create", status, 201)
expect("create again", call("PUT", body=b"two", **{"If-None-Match": "*"})[0], 412)
status, etag, body = call("GET")
expect("read", (status, etag, body), (200, etag1, b"one"))
expect("other token read", call("GET", token=OTHER)[0], 403)
expect("other token write", call("PUT", body=b"x", token=OTHER, **{"If-Match": etag1})[0], 403)
status, etag2, _ = call("PUT", body=b"two", **{"If-Match": etag1})
expect("update", status, 200)
expect("stale update", call("PUT", body=b"three", **{"If-Match": etag1})[0], 412)
expect("read new", call("GET")[2], b"two")
expect("wildcard update", call("PUT", body=b"four", **{"If-Match": "*"})[0], 200)
expect("too big", call("PUT", body=b"x" * (4 * 1024 * 1024 + 1), **{"If-Match": "*"})[0], 413)
expect("other token delete", call("DELETE", token=OTHER)[0], 403)
expect("delete", call("DELETE")[0], 204)
expect("gone", call("GET")[0], 404)
print("all passed")
