# PR #406 — Fix code style

**Author:** construct-d
**Base:** dev
**Stats:** +4 / -2 across 2 files, 2 commits

## What

Two code style fixes: exclude EEx template files from the formatter and alphabetize aliases in `integration.ex`.

## Why

`mix format` was attempting to parse EEx template files in `priv/templates/`, causing formatter noise. Alias ordering was inconsistent with project conventions.

## Key Changes

- `.formatter.exs`: Add `exclude: ["priv/templates/**/*.*"]` to skip template files
- `lib/phoenix_kit_web/integration.ex`: Reorder `Routes` alias before `PhoenixKitWeb` (alphabetical)
