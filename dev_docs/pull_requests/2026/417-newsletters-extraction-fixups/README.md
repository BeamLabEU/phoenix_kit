# PR #417 — Fix test and worker guard after Newsletters extraction

**Author:** Tymofii Shapovalov (timujinne)
**Base:** dev
**Stats:** +2 / -2 across 2 files, 1 commit

## What

Cleans up two breakages left behind after `PhoenixKit.Modules.Newsletters` was extracted to the `phoenix_kit_newsletters` package (PR #413).

## Why

1. `module_test.exs` still listed `Newsletters` in `@all_internal_modules`, causing `Code.ensure_loaded!` to crash the entire test describe block (22 tests invalidated).
2. `ProcessScheduledJobsWorker` guarded `enabled?/0` but not `process_scheduled_broadcasts/0` — if the external package is loaded at a version that removed or renamed that function, the Oban worker would crash.

## Key Changes

- Remove `PhoenixKit.Modules.Newsletters` from test module list, update count 21 → 20
- Add `function_exported?` guard for `process_scheduled_broadcasts/0` before calling it
