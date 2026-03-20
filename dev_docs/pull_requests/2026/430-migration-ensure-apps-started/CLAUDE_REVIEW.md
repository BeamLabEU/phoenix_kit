# Claude Review — PR #430: Fix migrations ensure apps started

**Verdict:** Approve — correct fix for a real runtime failure

## Analysis

The fix adds `Application.ensure_all_started/1` for four OTP apps before calling `repo.start_link/1` in the migration runner. This is the correct approach — migrations can run outside normal app boot (during install, update scripts, etc.) where these deps aren't guaranteed to be started.

### Observation: Redundant calls are harmless

`:postgrex` transitively depends on `:db_connection`, and `:ecto` transitively depends on `:telemetry`. So `ensure_all_started(:ecto)` + `ensure_all_started(:postgrex)` would be sufficient. However, the explicit calls are clearer about intent and `ensure_all_started` is idempotent, so the redundancy has zero runtime cost.

### Return values not checked

`Application.ensure_all_started/1` returns `{:ok, started_apps}` or `{:error, reason}`. The return values are ignored. If any of these apps fail to start, `repo.start_link/1` will fail with a less clear error. For a migration context this is acceptable — if `:postgrex` can't start, there's nothing to recover from.

## Nothing to Improve

Correct, defensive fix. No changes needed.
