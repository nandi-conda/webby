# Bare `just` builds and runs the app through pixi (see pixi.toml).
set positional-arguments

# Run webby; extra args are URLs or --incognito
default *args:
    pixi run webby "$@"

# Run webby and open a URL, e.g. `just open https://example.com`
open url:
    pixi run webby "$1"


# Deploy the sync server (sync-worker/) to Cloudflare as https://webby-sync.nandithebull.workers.dev.
# Needs uv and npx. Auth: an earlier `npx wrangler login`, or CLOUDFLARE_API_TOKEN set to a token with
# "Workers Scripts: Edit" and "Workers R2 Storage: Edit" on the nandi account.
deploy-sync:
    cd sync-worker && (npx --yes wrangler r2 bucket info webby-sync >/dev/null 2>&1 || npx --yes wrangler r2 bucket create webby-sync)
    cd sync-worker && uv run pywrangler deploy

# Run the sync server locally on :8787 (in-memory R2); `python3 sync-worker/test/roundtrip.py` tests it
dev-sync:
    cd sync-worker && uv run pywrangler dev --port 8787
