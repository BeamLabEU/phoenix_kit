#!/usr/bin/env sh
set -eu

if [ -f "mix.exs" ]; then
  mix local.hex --force >/dev/null 2>&1 || true
  mix local.rebar --force >/dev/null 2>&1 || true
  mix deps.get
fi

exec "$@"
