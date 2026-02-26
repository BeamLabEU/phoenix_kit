# PR #366 — Fix 7 outstanding PR review items from #357–#364

**Author:** mdon (Max Don)
**Merged:** 2026-02-25
**Reviewer:** Claude Opus 4.6

## Summary

Batch cleanup PR addressing 7 review items from PRs #357–#364:
- Remove dead `_plugin_session_name` variable
- Check shop disable result in billing cascade, log on failure
- Add doc notes about perf for `all_admin_tabs/0` and `get_config/0`
- Rename `seed_title_in_data` to `seed_translatable_fields`
- Unify slug labels to "Slug (URL-friendly identifier)"
- Add secondary language slug uniqueness via JSONB query

## Verdict: PASS (issues already fixed in later PRs)

## Issues Found

### 1. Legacy Integer IDs in `secondary_slug_exists?/4` — FIXED LATER

**File:** `lib/modules/entities/entity_data.ex`
**Severity:** High (would crash on UUID-only installations)

The PR as submitted used `.id` (integer) for entity/record comparisons and had an `is_binary` branch supporting both integer and UUID entity IDs. This was a transitional pattern that should have used UUID-only from the start.

**Fixed in:** Commit 99a5135b (UUID cleanup) — current code correctly uses `.uuid` and `when is_binary(entity_uuid)` guard.

### 2. `socket.assigns.entity.id` in `data_form.ex` — FIXED LATER

**File:** `lib/modules/entities/web/data_form.ex`
**Severity:** High (runtime crash after integer ID removal)

Both `socket.assigns.entity.id` and `socket.assigns.data_record.id` referenced integer PKs that no longer exist post-UUID cleanup.

**Fixed in:** Same commit — now uses `.uuid`.

### 3. Billing Cascade Pattern Matching — OK

**File:** `lib/phoenix_kit_web/live/modules.ex`

The `maybe_disable_shop_first/2` function correctly handles both `:ok` and `{:ok, _}` return patterns from `disable_system()`. The added logging on failure is good practice.

## Notes

- JSONB fragment `(? -> ? ->> '_slug') = ?` is SQL-injection safe (parameterized via Ecto `^` bindings)
- `nil` handling for `exclude_record_uuid` is correct (conditional where clause)
- Doc improvements for `get_config/0` and `all_admin_tabs/0` are helpful
