# Bare `just` builds and runs the app through pixi (see pixi.toml).
set positional-arguments

# Run webby; extra args are URLs or --incognito
default *args:
    pixi run webby "$@"

# Run webby and open a URL, e.g. `just open https://example.com`
open url:
    pixi run webby "$1"


# Deploy the sync server (sync-worker/) to Cloudflare as https://webby-sync.nandithebull.workers.dev.
# Node and uv come from pixi's `sync` environment. Auth: an earlier `pixi run -e sync npx wrangler login`, or
# CLOUDFLARE_API_TOKEN set to a token with "Workers Scripts: Edit" and "Workers R2 Storage: Edit" on the nandi account.
deploy-sync:
    pixi run -e sync deploy-sync

# Run the sync server locally on :8787 (local R2); `python3 sync-worker/test/roundtrip.py` tests it
dev-sync:
    pixi run -e sync dev-sync
