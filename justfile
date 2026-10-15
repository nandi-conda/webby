# Bare `just` builds and runs the app through pixi (see pixi.toml).
set positional-arguments

# Run webby; extra args are URLs or --incognito
default *args:
    pixi run webby "$@"

# Run webby and open a URL, e.g. `just open https://example.com`
open url:
    pixi run webby "$1"

