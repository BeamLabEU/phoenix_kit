# PR #445: Add database connection check to install and update tasks

**Author**: @construct-d
**Reviewer**: @claude
**Status**: ✅ Reviewed & Fixed
**Commit**: `5153873..2bd4ec7` (3 commits) + review fixes
**Date**: 2026-03-23

## Goal

Add an early database connectivity check to the `install` and `update` Mix tasks so users get a clear error message when PostgreSQL is unreachable, rather than a cryptic Ecto/Postgrex crash deeper in the task.

## Original PR — What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit/install/db_connection_check.ex` | New module with `check?/0` and `check!/0` functions |
| `lib/mix/tasks/phoenix_kit.install.ex` | Alias + call `DbConnectionCheck.check!()` after `super(argv)` |
| `lib/mix/tasks/phoenix_kit.update.ex` | Alias + call `DbConnectionCheck.check!()` after `app.start` |
| `lib/mix/tasks/phoenix_kit.status.ex` | Alias + call `DbConnectionCheck.check!()` after ensuring repo is started |

### What Was Good

1. **Clean extraction** — Check logic in its own module, reused across tasks.
2. **Defensive checks** — `Code.ensure_loaded?` and `function_exported?` before `repo.query/3` prevents crashes when the repo module isn't available.
3. **User-friendly error** — Clear actionable message with numbered steps.
4. **`log: false`** — Keeps `SELECT 1` out of Ecto query logs.

## Issues Found

### 1. Wrong typespec — `@spec check!() :: no_return()`

The `unless` block falls through to `nil` on success, but `no_return()` tells Dialyzer the function *never* returns. This makes Dialyzer treat all code after the call as unreachable dead code.

**Fixed:** `@spec ensure_connected!() :: :ok | no_return()` with explicit `:ok` return via `if/else`.

### 2. `check?`/`check!` naming

`check?` reads awkwardly as a function name in Elixir. Boolean functions are conventionally named after the condition they test.

**Fixed:** Renamed to `connected?/0` and `ensure_connected!/0` — both read naturally and communicate intent clearly.

### 3. No explicit return value on success

The `unless` block returned `nil` on the happy path. Conventional `!` functions return `:ok` or a meaningful value.

**Fixed:** Rewrote as `if connected?(), do: :ok, else: ...` — returns `:ok` explicitly.

### 4. Hardcoded `config/dev.exs` in error message

The error said "Configuration in config/dev.exs is correct" but the task could run in any Mix env.

**Fixed:** Changed to `config/#{Mix.env()}.exs` so the message reflects the actual environment.

### 5. No query timeout

`repo.query("SELECT 1")` with no timeout could hang indefinitely if PostgreSQL accepts connections but is unresponsive.

**Fixed:** Added `timeout: 5_000` to the query options.

### 6. `status.ex` — hard exit defeats the purpose of a status task

This was the most significant issue. The `status` task already handles DB failures gracefully — `get_database_status/1` catches connection errors and displays them in the status tree as "Connection failed". Adding `check!()` that calls `exit({:shutdown, 1})` *before* the status display means `mix phoenix_kit.status` crashes instead of showing what's wrong. The whole point of a status command is to report state, not abort on bad state.

The PR also added a redundant repo startup block (lines 74–81) that duplicated logic already in `get_database_status` → `test_repo_and_tables` → `ensure_repo_started`.

**Fixed:** Removed `DbConnectionCheck` from `status.ex` entirely — both the alias, the repo startup block, and the `check!()` call. The task's existing error handling is the correct approach.

## Final State After Review Fixes

| File | Final State |
|------|-------------|
| `lib/phoenix_kit/install/db_connection_check.ex` | `connected?/0` + `ensure_connected!/0`, correct spec, timeout, env-aware error |
| `lib/mix/tasks/phoenix_kit.install.ex` | Calls `DbConnectionCheck.ensure_connected!()` (gates migrations) |
| `lib/mix/tasks/phoenix_kit.update.ex` | Calls `DbConnectionCheck.ensure_connected!()` (gates Igniter + post-tasks) |
| `lib/mix/tasks/phoenix_kit.status.ex` | `DbConnectionCheck` removed — uses its own graceful error handling |

## Verification

- [x] `mix compile` — clean, no warnings
- [x] `mix format` — no changes needed
- [x] `mix credo --strict` — no issues found
