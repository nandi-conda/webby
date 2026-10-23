# webby's Dagger checks

`dagger.json` (repo root) points here: a Python Dagger module whose `@check` functions are webby's fast checks.
Each check runs in containers and gets only the files it reads, so a step whose inputs didn't change is a cache hit.

| Check | What it does | Reruns when |
|---|---|---|
| `nim-desktop` | builds the Nim front end the way `pixi run webby` does (`WEBBY_BUILD_ONLY=1 scripts/pixi_nim.sh`) | nim/, framework/, icons/, pixi.toml/lock change |
| `nimkit-demo` | builds framework/demo for GTK and for the web (`framework/web/build.sh`) | same |
| `sync-server-test` | `dart test` in sync-server/ | sync-server/ changes |
| `sync-server-roundtrip` | sync-worker/test/roundtrip.py against the Dart server built from its Dockerfile | sync-server/ or roundtrip.py change |
| `sync-worker-roundtrip` | roundtrip.py against the Cloudflare Worker under `pywrangler dev` (local R2) | sync-worker/ changes |

The pixi environment (`pixi-env`) is installed from pixi.toml + pixi.lock alone, so it's reused until those change.

Not here: the Ladybird runtime and Android native builds (hours; runtime-build.yml, android-native-build.yml).

## Day to day

Needs Docker (or Podman) and the dagger CLI at the version in dagger.json:

    curl -fsSL https://dl.dagger.io/dagger/install.sh | BIN_DIR=$HOME/.local/bin DAGGER_VERSION=0.21.11 sh

    dagger check                    # run every check
    dagger check -l                 # list them
    dagger check nim-desktop        # just one (globs work: 'sync-*')
    dagger call nim-desktop         # the same check as a plain function call
    dagger call sync-server up --ports 8080:8080   # run the Dart sync server locally
    dagger call pixi-env terminal   # a shell in the pixi env the checks use

`just check` runs `dagger check`.

## In CI

`.github/workflows/dagger.yml` runs `dagger check` on every push. With the repo secret `DAGGER_CLOUD_TOKEN` (dagger.cloud,
org Settings > Tokens) each run's trace is in Dagger Cloud. Repo variable `DAGGER_SCALE_OUT=true` runs the checks on
Dagger Cloud engines, which keep their cache between pushes. Run the workflow by hand with "twice" ticked to see the
second `dagger check` come from the cache.
