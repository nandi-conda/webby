# webby-sync on Cloudflare

The default server for webby's password/bookmark/tab sync, `https://webby-sync.nandithebull.workers.dev`: a Python
Worker (`src/entry.py`) keeping each blob in the R2 bucket `webby-sync`. The server stores one opaque blob per sync
key and can't read it: devices encrypt with a key derived from their sync code before uploading, and the blob's name
and access token are derived from that code too. Only the SHA-256 of a blob's token is stored, in the object's custom
metadata. Writes are R2 conditional puts, so two devices racing on one blob get one 200/201 and one 412.

API (every blob request carries `Authorization: Bearer <token>`):

| request | result |
|---|---|
| `GET /v1/blobs/<64 hex>` | 200 with the blob and its `ETag`, or 404 |
| `PUT /v1/blobs/<64 hex>` with `If-None-Match: *` (create) or `If-Match: <etag>` | 201/200 with the new `ETag`, or 412 if another device wrote first |
| `DELETE /v1/blobs/<64 hex>` | 204 |
| `GET /healthz` | 200 |

The first write fixes a blob's token.

    just deploy-sync     # = pixi run -e sync deploy-sync: creates the bucket if needed, then deploys
                         # (node + uv come from pixi; auth: `pixi run -e sync npx wrangler login` or CLOUDFLARE_API_TOKEN)
    just dev-sync        # local server on :8787 with a local R2
    python3 test/roundtrip.py [url]   # API round trip against a running server (default localhost:8787)
