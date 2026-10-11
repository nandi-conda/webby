# A WEBBY_LADYBIRD_PREFIX already in the environment (e.g. your own Ladybird build) wins over this package.
if [ -z "${WEBBY_LADYBIRD_PREFIX:-}" ]; then
  export WEBBY_LADYBIRD_PREFIX="$CONDA_PREFIX/lib/webby-ladybird"
  export _WEBBY_LADYBIRD_FROM_CONDA=1
fi
