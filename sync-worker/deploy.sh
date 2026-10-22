#!/usr/bin/env bash
# Deploys the sync Worker; run through `pixi run -e sync deploy-sync`, which puts node (npx) and uv on PATH.
# Auth: an earlier `npx wrangler login`, or CLOUDFLARE_API_TOKEN.
set -euo pipefail
cd "$(dirname "$0")"
if ! npx --yes wrangler r2 bucket info webby-sync >/dev/null 2>&1; then
  npx --yes wrangler r2 bucket create webby-sync
fi
uv run pywrangler deploy
