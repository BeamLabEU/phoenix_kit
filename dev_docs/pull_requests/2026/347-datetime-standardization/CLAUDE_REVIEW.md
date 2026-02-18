# PR #347 Review: DateTime Standardization

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/347
**Title:** Fix for DateTime and datetime usage to the same format
**Author:** alexdont (Sasha Don)
**Merged:** 2026-02-17
**Stats:** +821 / -280 across 77 files

---

## Summary

This PR completes the DateTime standardization effort that was planned in `dev_docs/2026-02-15-datetime-inconsistency-report.md`. It addresses a production bug caused by mixing `NaiveDateTime` and `DateTime` types across schemas. The PR standardizes all schemas, application code, and database columns to use a single consistent datetime convention.

## Changes by Category

### 1. V58 Migration — Timestamp Column Type Standardization (1 new file)

**File:** `lib/phoenix_kit/migrations/postgres/v58.ex` (+334 lines)

Converts all timestamp columns across 68 PhoenixKit tables from `timestamp` (without timezone) to `timestamptz` (with timezone).

**Strengths:**
- Comprehensive coverage of all 68 tables with ~193 columns
- Fully idempotent: checks `table_exists?`, `column_exists?`, and `column_is_timestamptz?` before altering
- Clean `down` migration with proper `USING col AT TIME ZONE 'UTC'` for safe revert
- Well-organized by migration version origin (V01, V03, V04, etc.) with comments
- Handles optional modules gracefully (skips tables that don't exist)

**Concerns:**
- **SQL injection surface:** Table and column names are interpolated directly into SQL strings (e.g., `"ALTER TABLE #{full_table} ALTER COLUMN #{col} TYPE timestamptz"`). While these values come from a hardcoded module attribute (`@timestamp_columns`) and are not user-controlled, using parameterized queries or at minimum quoting identifiers would be more defensive. This is consistent with how other PhoenixKit migrations work though.
- **No locking strategy mentioned:** `ALTER COLUMN ... TYPE` on large tables acquires an `ACCESS EXCLUSIVE` lock. For production databases with significant data, this could cause downtime. The module docs mention this is "no USING clause needed for up" but doesn't address lock duration. In practice, PostgreSQL can do this conversion without rewriting data (metadata-only change), so the lock should be brief.
- **`repo()` call in migration helpers:** The `table_exists?`, `column_exists?`, and `column_is_timestamptz?` helpers call `repo().query/3` directly. This follows the existing pattern in `uuid_fk_columns.ex`, so it's consistent with the codebase.

### 2. Schema Standardization (~55 schema files)

Three categories of changes:

| Change | Count | Example |
|--------|-------|---------|
| `timestamps()` → `timestamps(type: :utc_datetime)` | 8 files | `user.ex`, `role.ex`, `admin_note.ex`, shop schemas |
| `timestamps(type: :naive_datetime)` → `timestamps(type: :utc_datetime)` | ~26 files | Posts, comments, tickets, storage, connections |
| `timestamps(type: :utc_datetime_usec)` → `timestamps(type: :utc_datetime)` | ~17 files | AI, emails, billing, sync, legal, oauth, audit log |
| `field :x, :naive_datetime` → `field :x, :utc_datetime` | 9 files, 11 fields | `confirmed_at`, `assigned_at`, `requested_at`, etc. |
| `field :x, :utc_datetime_usec` → `field :x, :utc_datetime` | ~17 files, ~30 fields | Various event/status timestamps |

**Assessment:** Clean mechanical changes. All correctly applied. The downgrade from `:utc_datetime_usec` to `:utc_datetime` is intentional per the standardization plan — microsecond precision is not needed for this application.

### 3. Application Code — NaiveDateTime to DateTime (14 files, 19 calls)

All instances of `NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)` replaced with `DateTime.utc_now()`.

**Key files:**
- `user.ex` — `confirm_changeset`
- `permissions.ex` — bulk insert timestamps
- `role_assignment.ex` — `put_assigned_at`
- `magic_link_registration.ex` — `do_complete_registration`
- `roles.ex` — `maybe_add_confirmed_at`
- `sessions.ex` — `get_session_stats`, `calculate_age_in_days`, `session_expired?`
- `storage.ex` — `reset_dimensions_to_defaults` bulk insert
- `comments.ex` — `bulk_update_status`
- `connection.ex`, `block.ex`, `follow.ex` + history schemas — timestamp helpers

**Note on sessions.ex:** The `today_start` calculation on line ~233 uses `%{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}` which works the same with `DateTime` as it did with `NaiveDateTime` since both structs have these fields.

### 4. Type Specs Updated

All `NaiveDateTime.t()` references in `@type t` declarations updated to `DateTime.t()`. Consistent across all affected schema modules.

### 5. UUID FK Backfill Fix

**File:** `lib/phoenix_kit/migrations/uuid_fk_columns.ex` (+7 lines)

Added a `UPDATE ... SET uuid_fk = uuid_generate_v7() WHERE uuid_fk IS NULL` before the `SET NOT NULL` constraint. This handles orphaned integer FK references (e.g., `created_by` references a deleted user with no CASCADE constraint).

**Assessment:** Good defensive fix. Without this, the `SET NOT NULL` would fail on databases with orphaned references. Using `uuid_generate_v7()` for backfill is reasonable — the values are synthetic but preserve the NOT NULL invariant.

### 6. Documentation Updates

- **CLAUDE.md:** Added "Structs Over Plain Maps" and "DateTime: Always Use `DateTime.utc_now()`" style guidelines, plus full DateTime Convention reference table
- **`dev_docs/2026-02-15-datetime-inconsistency-report.md`:** Updated recommendation from `:utc_datetime_usec` to `:utc_datetime`, marked Phase 1 as COMPLETED, simplified migration plan
- **`dev_docs/2026-02-17-datetime-standardization-plan.md`:** New detailed plan document listing every file and field that needed changing

### 7. Migration Version Bump

- `@current_version` bumped from 57 to 58 in `postgres.ex`
- V57 label changed from "LATEST" to just the description
- V58 marked as "LATEST"

---

## Risk Assessment

| Area | Risk | Notes |
|------|------|-------|
| Schema type changes | **Low** | Ecto handles `DateTime` ↔ `:utc_datetime` transparently |
| V58 migration on large DBs | **Medium** | `ALTER COLUMN TYPE` is metadata-only for timestamp→timestamptz (no rewrite), but still acquires ACCESS EXCLUSIVE lock briefly |
| `:utc_datetime_usec` downgrade | **Low** | Only loses microsecond precision in Elixir; DB retains full precision. Application doesn't use sub-second timestamps |
| UUID FK backfill | **Low** | Generates synthetic UUIDs for orphaned rows; data integrity preserved |
| Application code changes | **Low** | `DateTime.utc_now()` is drop-in replacement for the `NaiveDateTime.utc_now() |> truncate(:second)` pattern |

---

## Potential Follow-ups

1. **Credo check for `NaiveDateTime.utc_now()`** — The report mentions adding a compile-time check to prevent regressions. Not yet implemented.
2. **Display utilities** — `time_display.ex` and `file_display.ex` still handle both `DateTime` and `NaiveDateTime` (intentionally, for backward compat). Could be simplified once all data is confirmed to be `DateTime`.
3. **`sessions.ex` today_start calculation** — The struct update `%{now | hour: 0, ...}` works but `DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")` would be more idiomatic. Minor style point.

---

## Verdict

**Approve.** This is a thorough, well-planned standardization effort that eliminates a documented class of bugs (NaiveDateTime/DateTime type mismatches). The changes are mechanical and consistent. The V58 migration is properly idempotent with good safety checks. The UUID FK backfill fix is a smart addition that unblocks installations with orphaned references. Documentation is comprehensive.

The PR successfully completes Phase 1 and Phase 2 (V58 migration) of the DateTime standardization plan from `dev_docs/2026-02-15-datetime-inconsistency-report.md`.
