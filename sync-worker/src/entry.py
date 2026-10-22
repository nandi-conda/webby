"""webby-sync as a Cloudflare Python Worker: the same API as sync-server/, with blobs in an R2 bucket.

  GET    /v1/blobs/<64 hex>   -> 200 blob + ETag, or 404
  PUT    /v1/blobs/<64 hex>   If-None-Match: * (create) or If-Match: <etag> -> 200/201 + ETag, or 412
  DELETE /v1/blobs/<64 hex>   -> 204
  GET    /healthz             -> 200

Every blob request carries `Authorization: Bearer <token>`. The first write of a blob fixes its token; only the
token's SHA-256 is kept, in the object's custom metadata. Writes are R2 conditional puts, so two devices racing on
the same blob can't both win.
"""

import hashlib
import hmac
import re
from urllib.parse import urlparse

from js import Headers, Object, Uint8Array
from pyodide.ffi import to_js
from workers import Response, WorkerEntrypoint

# Largest blob accepted. A vault with thousands of passwords is well under this.
MAX_BLOB_BYTES = 4 * 1024 * 1024

BLOB_PATH = re.compile(r"^/v1/blobs/([0-9a-f]{64})$")


def reply(status, body=None, headers=None):
    return Response(body, status=status, headers={"Cache-Control": "no-store", **(headers or {})})


def as_bytes(buffer):
    # The workers SDK hands back a memoryview for some objects and a raw JS ArrayBuffer for others.
    return bytes(buffer) if isinstance(buffer, (bytes, memoryview)) else buffer.to_bytes()


def js_dict(value):
    return to_js(value, dict_converter=Object.fromEntries)


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        path = urlparse(request.url).path
        if path == "/healthz":
            return reply(200, "ok")
        match = BLOB_PATH.match(path)
        if not match:
            return reply(404)
        key = match.group(1)
        auth = request.headers.get("Authorization") or ""
        if not auth.startswith("Bearer ") or len(auth) < 30:
            return reply(401)
        token_hash = hashlib.sha256(auth[7:].encode()).hexdigest()
        bucket = self.env.BLOBS

        def owned(obj):
            return hmac.compare_digest(str(obj.customMetadata.token or ""), token_hash)

        method = request.method
        if method in ("GET", "HEAD"):
            obj = await (bucket.get(key) if method == "GET" else bucket.head(key))
            if obj is None:
                return reply(404)
            if not owned(obj):
                return reply(403)
            headers = {"ETag": obj.httpEtag, "Content-Type": "application/octet-stream"}
            if method == "HEAD":
                return reply(200, None, headers)
            return reply(200, as_bytes(await obj.arrayBuffer()), headers)

        if method == "PUT":
            # Read the whole request even when it's too big, so the client gets the 413 rather than a lost connection.
            body = as_bytes(await request.js_object.arrayBuffer())
            if len(body) > MAX_BLOB_BYTES:
                return reply(413)
            if_match = request.headers.get("If-Match")
            if_none_match = request.headers.get("If-None-Match")
            current = await bucket.head(key)
            if current is not None and not owned(current):
                return reply(403)
            if current is None:
                stale = if_match is not None
            else:
                stale = if_none_match == "*" or (if_match not in (None, "*") and if_match != current.httpEtag)
            if stale:
                return reply(412)
            if if_match is None and if_none_match != "*":
                # Unconditional writes would let devices overwrite each other.
                return reply(428)
            # Condition the write on what was just checked, so a concurrent write in between turns this one into a
            # 412 (and the token can't change under us).
            condition = Headers.new()
            if current is None:
                condition.set("If-None-Match", "*")
            else:
                condition.set("If-Match", current.httpEtag)
            written = await bucket.put(
                key,
                Uint8Array.new(to_js(body)),
                js_dict({
                    "onlyIf": condition,
                    "customMetadata": {"token": token_hash},
                    "httpMetadata": {"contentType": "application/octet-stream"},
                }),
            )
            if written is None:
                return reply(412)
            return reply(201 if current is None else 200, None, {"ETag": written.httpEtag})

        if method == "DELETE":
            current = await bucket.head(key)
            if current is not None:
                if not owned(current):
                    return reply(403)
                await bucket.delete(key)
            return reply(204)

        return reply(405)
