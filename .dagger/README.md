# webby's Dagger checks

`dagger.toml` (the workspace) and `dagger-module.toml` (the module, both at the repo root) point here: a Python Dagger module whose `@check` functions are webby's fast checks.
Each check runs in containers and gets only the files it reads, so a step whose inputs didn't change is a cache hit.

| Check | What it does | Reruns when |
|---|---|---|
| `nim-desktop` | builds the Nim front end the way `pixi run webby` does (`WEBBY_BUILD_ONLY=1 scripts/pixi_nim.sh`) | nim/, framework/, icons/, pixi.toml/lock change |
| `nimkit-demo` | builds framework/demo for GTK and for the web (`framework/web/build.sh`) | same |
| `sync-server-test` | `dart test` in sync-server/ | sync-server/ changes |
| `sync-server-roundtrip` | sync-worker/test/roundtrip.py against the Dart server built from its Dockerfile | sync-server/ or roundtrip.py change |
| `sync-worker-roundtrip` | roundtrip.py against the Cloudflare Worker under `pywrangler dev` (local R2) | sync-worker/ changes |

The pixi environment (`pixi-env`) is installed from pixi.toml + pixi.lock alone, so it's reused until those change.

`runtime` (not a check) builds the Ladybird engine the way runtime-build.yml does (Ubuntu 22.04, `scripts/build_ladybird.sh`,
`scripts/pack_prebuilt.sh`) and returns the runtime tarball. ccache, vcpkg's binary cache and the build tree live in cache
volumes, so a rebuild on the same engine only recompiles what changed:

    dagger call runtime export --path webby-prebuilt-linux-x64.tar.zst
    dagger call runtime --poke x export --path ...   # adds a one-line LibWeb patch, to time a small change

`.github/workflows/dagger-runtime.yml` runs it on a Dagger Cloud engine by hand. Not here: the Android native build
(android-native-build.yml).

## Day to day

Needs Docker (or Podman) and the dagger CLI at the version in dagger-module.toml (Dagger 1.0):

    curl -fsSL https://dl.dagger.io/dagger/install.sh | BIN_DIR=$HOME/.local/bin DAGGER_VERSION=1.0.0-beta.20 sh

    dagger check                    # run every check
    dagger check -l                 # list them
    dagger check nim-desktop        # just one (globs work: 'sync-*')
    dagger call nim-desktop         # the same check as a plain function call
    dagger call sync-server up --ports 8080:8080   # run the Dart sync server locally
    dagger call pixi-env terminal   # a shell in the pixi env the checks use

`just check` runs `dagger check`.

## In CI

`.github/workflows/dagger.yml` runs `dagger check` on every push. With the repo secret `DAGGER_CLOUD_TOKEN` (dagger.cloud,
org Settings > Tokens) each run's trace is in Dagger Cloud. Org/repo variable `DAGGER_SCALE_OUT=true` runs the checks on
a Dagger Cloud engine (`dagger check --engine=cloud`, signed in with GitHub OIDC), whose cache carries over between runs: an
unchanged push is all CACHED in ~5 s. (`--scale-out`, a fresh engine per check, started cold every time.) Run the workflow by hand with "twice" ticked to see the
second `dagger check` come from the cache.
