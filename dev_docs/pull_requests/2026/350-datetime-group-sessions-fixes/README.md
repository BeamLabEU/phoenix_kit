# PR #350 — Fix runtime crashes after struct and DateTime migrations

**Author:** timujinne
**Merged:** 2026-02-18
**Base:** dev
**Files changed:** 21 (+84 / -40)

## Summary

Fixes three categories of runtime crashes introduced by PR #347's schema migration from `:utc_datetime_usec` to `:utc_datetime`:

1. **DateTime truncation (19 files):** `DateTime.utc_now()` returns microseconds, but `:utc_datetime` fields reject non-zero microseconds. Added `DateTime.truncate(:second)` to all affected call sites.

2. **Group struct conversion (1 file):** `Registry.handle_call({:register_groups, ...})` inserted plain maps into ETS without converting to `%Group{}` structs, crashing sidebar templates that use dot syntax.

3. **Live sessions UUID fix (2 files):** `SimplePresence.track_user` stores `user.uuid` in the `user_id` field, but `preload_users_for_sessions` queried by integer `id` column. Added `get_users_by_uuids/1` and switched the lookup.

## Commits

- `5bf69770` Fix register_groups to convert plain maps to Group structs
- `4e024348` Fix DateTime.utc_now() microsecond crashes after utc_datetime migration
- `eabc6a32` Fix CastError in live sessions by using UUID lookup instead of integer id
