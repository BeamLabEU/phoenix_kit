# PR #372 Review — Fix NOT NULL Integer FK Columns (V66 + V67)

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/372
**Author:** alexdont (Sasha Don)
**Merged:** 2026-02-27
**Reviewer:** Claude (Opus 4.6)
**Verdict:** Approve with notes

---

## Summary

Two migrations (V66, V67) that make legacy integer FK columns nullable across 28+ tables. After the UUID cleanup (V56+), schemas only write `_uuid` foreign keys, but many tables still had `NOT NULL` constraints on the old integer columns, causing `not_null_violation` on every insert. Also renames `get_file_instance_bucket_ids` to `get_file_instance_bucket_uuids`.

## What's Good

1. **Thorough coverage** — V67 covers 39 columns across 28 tables. The accompanying plan doc (`dev_docs/plans/2026-02-27-not-null-integer-fk-fix-plan.md`) is excellent: it inventories every table, tracks what was already fixed, and confirms what's not affected.

2. **Idempotent design** — Both migrations guard every operation with `table_exists?`, `column_exists?`, and (V67 adds) `column_not_null?` checks. Safe for partial runs and re-runs.

3. **V65 rename handling** — V67 correctly handles the `plan_id` -> `subscription_type_id` rename from V65 by checking both names via `@subscription_type_columns`.

4. **Clean function rename** — `get_file_instance_bucket_ids` -> `get_file_instance_bucket_uuids` aligns the public API with the UUID migration. No stale callers remain (verified).

## Issues Found

### Medium: V66 `down/1` will fail if rows with NULL user_id exist

**File:** `lib/phoenix_kit/migrations/postgres/v66.ex:48-62`

The `down` migration does `ALTER COLUMN user_id SET NOT NULL` unconditionally. If any rows were inserted after V66 ran (with `user_id = NULL`), the rollback will crash with:

```
ERROR: column "user_id" of relation "..." contains null values
```

V67 has the same issue in its `down/1`.

**Impact:** Low in practice (rollbacks of data-relaxing migrations are inherently risky), but worth documenting. A `WHERE user_id IS NULL` backfill or a `NOT VALID` constraint would make rollbacks safer.

### Low: V66 lacks `column_not_null?` guard (V67 has it)

**File:** `lib/phoenix_kit/migrations/postgres/v66.ex:35-43`

V66 runs `DROP NOT NULL` without checking if the column is already nullable (unlike V67 which has the `column_not_null?/3` guard). This means V66's `up` emits a harmless no-op `ALTER` on already-nullable columns, but it's inconsistent with V67's more defensive approach.

**Impact:** No functional issue — PostgreSQL silently accepts `DROP NOT NULL` on already-nullable columns. Just a code quality inconsistency.

### Low: SQL injection surface in migration helpers

**Files:** Both `v66.ex` and `v67.ex`

Table and column names are interpolated directly into SQL strings:
```elixir
"WHERE table_name = '#{table}' AND column_name = '#{column}'"
```

These values come from compile-time module attributes (`@tables`, `@columns`), so there's no actual injection risk. But the pattern is worth noting for anyone copying this code for dynamic inputs.

## Observations

- The plan document is a great practice. It made the review trivial — every column is inventoried with its source migration.
- The `@current_version` bump from 65 to 67 (skipping ahead by 2 in one PR) is fine since V66 and V67 are in separate files and both are included.
- Future work noted in the plan (dropping integer columns entirely once all parent apps have migrated) is the right long-term direction.

## Pre-existing Issue (Not Introduced by This PR)

`media.ex:354` and `media_selector.ex:213` still use `current_user.id` (integer) when calling `store_file_in_buckets`. This works today because the User schema is Pattern 1 (retains `.id`), but it's a latent issue if User ever moves to Pattern 2.
