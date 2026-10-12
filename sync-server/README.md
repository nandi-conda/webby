# webby-sync

The server webby's password sync talks to. It stores one opaque blob per sync key and can't read it: devices encrypt
the vault with a key derived from their sync code before uploading, and the blob's name and access token are derived
from that code too. The server keeps only the token's SHA-256.

API (every blob request carries `Authorization: Bearer <token>`):

| request | result |
|---|---|
| `GET /v1/blobs/<64 hex>` | 200 with the blob and its `ETag`, or 404 |
| `PUT /v1/blobs/<64 hex>` with `If-None-Match: *` (create) or `If-Match: <etag>` | 201/200 with the new `ETag`, or 412 if another device wrote first |
| `DELETE /v1/blobs/<64 hex>` | 204 |
| `GET /healthz` | 200 |

The first write fixes a blob's token. Blobs are capped at 4 MiB. Data lives in `$DATA_DIR` (default `./data`), the
port is `$PORT` (default 8080).

## Run it

    dart pub get && dart run bin/server.dart          # local
    docker build -t webby-sync . && docker run -p 8080:8080 -v webby-sync:/data webby-sync
    fly launch --copy-config --no-deploy && fly volumes create webby_sync_data --size 1 && fly deploy

The public instance (https://webby-sync.fly.dev, webby's default) is deployed with `deploy_fly.py`, which needs only
`FLY_API_KEY` and the Machines API: `python3 deploy_fly.py machine <commit sha>` redeploys it.

Put it behind HTTPS (Fly does that), then pick "My sync server" in webby's sync setup. Tests: `dart test`.
