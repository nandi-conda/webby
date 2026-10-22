# webby-sync on Cloudflare

The default server for webby's password/bookmark/tab sync, `https://webby-sync.nandithebull.workers.dev`: a Python
Worker (`src/entry.py`) with the same API as the Dart server in `../sync-server/` (see its README), keeping each blob in
the R2 bucket `webby-sync`. Only the SHA-256 of a blob's token is stored, in the object's custom metadata. Writes are R2
conditional puts, so two devices racing on one blob get one 200/201 and one 412.

    just deploy-sync     # creates the bucket if needed, then deploys (wrangler login or CLOUDFLARE_API_TOKEN)
    just dev-sync        # local server on :8787 with a local R2
    python3 test/roundtrip.py [url]   # API round trip against a running server (default localhost:8787)
