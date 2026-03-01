# Investigation: VARCHAR UUID Migration Bug (V56/V63 Type Mismatch)

**Date:** 2026-03-01
**Severity:** High — blocks `mix ecto.migrate` on affected installs
**Affected versions:** Any install upgrading from v49 → v58+ where `phoenix_kit_email_logs.uuid` is `character varying` instead of `uuid`
**Fixed in:** V56 (pre-step added), V63 (cast added), V70 (new re-backfill migration)

---

## Symptom

Running `mix ecto.migrate` after upgrading PhoenixKit from v49 to v58+ fails with:

```
** (Postgrex.Error) ERROR 42804 (datatype_mismatch)
  column "email_log_uuid" is of type uuid but expression is of type character varying

hint: You will need to rewrite or cast the expression.

Failing SQL:
  UPDATE public.phoenix_kit_email_events t
  SET email_log_uuid = s.uuid
  FROM public.phoenix_kit_email_logs s
  WHERE s.id = t.email_log_id
    AND t.email_log_uuid IS NULL
    AND t.email_log_id IS NOT NULL
```

A second failure can occur at V63 with the same pattern for `matched_email_log_uuid` in `phoenix_kit_email_orphaned_events`.

---

## Root Cause 1: `phoenix_kit_email_logs.uuid` is `character varying`

### What should have happened

V40 adds a proper `uuid UUID` column to every legacy table including `phoenix_kit_email_logs`:

```sql
ALTER TABLE phoenix_kit_email_logs ADD COLUMN uuid UUID DEFAULT uuid_generate_v7()
```

### What went wrong

V40's `add_uuid_column_to_table/3` guards with `unless column_exists?` and **silently skips** the table if `uuid` already exists:

```elixir
unless column_exists?(table, :uuid, escaped_prefix) do
  execute("ALTER TABLE #{table_name} ADD COLUMN uuid UUID ...")
  ...
end
```

If `phoenix_kit_email_logs.uuid` was already present — as `character varying` — before V40 ran, V40 skips it entirely. The column keeps its varchar type.

### How did a varchar `uuid` column get there?

Two scenarios:

1. **Manual migration or custom code** in the consuming app added a `uuid` column as `:string` / `Ecto.UUID` before they upgraded to the PhoenixKit version that introduced V40.

2. **Older PhoenixKit version**: An older version of the email log schema may have declared `@primary_key {:uuid, :binary_id}` or used `Ecto.UUID` as a field type, which in some Ecto configurations stores as `character varying` rather than native PostgreSQL `uuid`.

In both cases, V40 sees the column exists and skips. The column stays varchar.

---

## Root Cause 2: The Elixir `rescue` clause does not protect the migration transaction

V56's `UUIDFKColumns.backfill_uuid_fk/6` had a rescue clause intended to silently swallow errors:

```elixir
defp backfill_uuid_fk(...) do
  if table_str in @batch_tables do
    batched_backfill(...)   # runs: execute("DO $$ BEGIN ... END $$;")
  else
    simple_backfill(...)
  end
rescue
  _ -> :ok   # ← DOES NOT WORK AS INTENDED
end
```

**Why this rescue is broken:** When a PostgreSQL statement fails, the database connection's transaction enters an **aborted state** (`ERROR 25P02: in_failed_sql_transaction`). The Elixir `rescue` catches the exception at the Elixir level, but PostgreSQL still has the transaction marked as aborted. Every subsequent `execute/1` call in the same migration transaction will fail with `25P02`, regardless of the rescue.

### What actually happens

1. `batched_backfill` runs the DO block; the UPDATE inside fails with type mismatch.
2. PostgreSQL transaction → aborted state.
3. Elixir `rescue _ -> :ok` catches the Postgrex.Error. Elixir continues.
4. The next `execute/1` call (next table in `process_module_fk_group`) fails with `25P02`.
5. This unrescued exception propagates up and **fails the entire migration**.
6. Ecto rolls back the transaction; the DB version stays at wherever it was before.

The user sees the **first** error (type mismatch from step 1) because that's what Ecto/Mix reports as the migration failure.

---

## Why other projects are not affected

All other installations had `phoenix_kit_email_logs.uuid` created as native PostgreSQL `uuid` type by V40 (or by `uuid_repair.ex` on pre-1.7.0 paths). The type mismatch never occurs for them, so the buggy rescue clause is never triggered.

---

## The Fix (merged in this commit)

### Fix 1: `UUIDFKColumns.ex` — EXCEPTION handler inside DO block + `::uuid` cast

The rescue clause is removed. Instead, error handling is moved **inside** the PostgreSQL DO block via `EXCEPTION WHEN OTHERS THEN`:

```sql
DO $$
BEGIN
  UPDATE phoenix_kit_email_events t
  SET email_log_uuid = s.uuid::uuid      -- explicit cast handles varchar source
  FROM phoenix_kit_email_logs s
  WHERE ...;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'PhoenixKit: skipping email_log_uuid backfill — %', SQLERRM;
END $$;
```

The `EXCEPTION` clause catches the error *inside PostgreSQL*, before it reaches the outer transaction. The outer transaction **never enters the aborted state**. Execution continues cleanly.

The `::uuid` cast handles the varchar source column: PostgreSQL can cast a valid UUID string from `character varying` to `uuid` without error.

The same pattern is applied to both `simple_backfill` and `batched_backfill`.

### Fix 2: V56 — Convert varchar `uuid` columns before `UUIDFKColumns.up`

A new pre-step in V56's `up/1` scans all source tables referenced in `UUIDFKColumns` and converts any `character varying` uuid columns to proper `uuid` type:

```sql
ALTER TABLE phoenix_kit_email_logs ALTER COLUMN uuid TYPE uuid USING uuid::uuid
```

This is idempotent: if the column is already `uuid` type, the condition is false and the ALTER is skipped.

This fixes the **root cause** for any install that hasn't yet run V56.

### Fix 3: V63 — `::uuid` cast on `matched_email_log_uuid` backfill

V63 directly executes `SET matched_email_log_uuid = l.uuid` without any protection. The same type mismatch would occur if `phoenix_kit_email_logs.uuid` is still varchar when V63 runs. The backfill is wrapped in a DO block with EXCEPTION handler and the `::uuid` cast is added.

### Fix 4: V70 — Re-backfill for installs that already ran V56

For installs that ran V56 **before** this fix was applied, the buggy rescue clause silently caught the backfill error. These installs ended up with `email_log_uuid` filled with random UUIDs (from the `set_not_null` fallback in `add_constraints`) rather than the correct values from `phoenix_kit_email_logs`.

V70:
1. Converts `phoenix_kit_email_logs.uuid` to proper UUID type if still varchar.
2. Drops the (potentially wrong) FK constraint on `email_log_uuid`.
3. Re-runs the backfill: `SET email_log_uuid = s.uuid FROM phoenix_kit_email_logs`.
4. Re-adds the FK constraint.
5. Does the same for `matched_email_log_uuid` in `phoenix_kit_email_orphaned_events` (V63 path).

---

## Timeline

| Version | What happened |
|---------|--------------|
| V07 | `phoenix_kit_email_logs` created (integer `id` PK, no `uuid` column) |
| V40 | Adds `uuid UUID` to all legacy tables — **skipped** on affected installs because a varchar `uuid` already existed |
| V56 | Tries to backfill `email_log_uuid` from `phoenix_kit_email_logs.uuid`; fails with type mismatch; buggy rescue causes transaction abort → **migration fails** |
| V63 | Tries to backfill `matched_email_log_uuid` from `phoenix_kit_email_logs.uuid`; no rescue at all → **migration fails** |
| V56 (fixed) | Converts varchar uuid → proper UUID type before backfill |
| V63 (fixed) | `::uuid` cast + EXCEPTION handler added |
| V70 (new) | Re-backfills any installs that ran the old broken V56 |

---

## Verifying the fix

On the affected database, after applying V70:

```sql
-- Should return 'uuid', not 'character varying'
SELECT data_type FROM information_schema.columns
WHERE table_name = 'phoenix_kit_email_logs'
  AND column_name = 'uuid'
  AND table_schema = 'public';

-- Should return 0 — no NULLs remain
SELECT COUNT(*) FROM phoenix_kit_email_events
WHERE email_log_uuid IS NULL AND email_log_id IS NOT NULL;

-- Should return 0 — all email_log_uuid values reference a real email log uuid
SELECT COUNT(*) FROM phoenix_kit_email_events e
LEFT JOIN phoenix_kit_email_logs l ON e.email_log_uuid = l.uuid
WHERE e.email_log_uuid IS NOT NULL AND l.uuid IS NULL;
```
