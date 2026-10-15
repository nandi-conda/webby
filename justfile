# Bare `just` builds and runs the app through pixi (see pixi.toml).
set positional-arguments

# Run webby; extra args go to `flutter run`
default *args:
    pixi run webby "$@"

# Run webby and open a URL, e.g. `just open https://example.com`
open url:
    pixi run webby -a "$1"
