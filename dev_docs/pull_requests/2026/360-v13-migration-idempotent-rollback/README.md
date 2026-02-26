# PR #360 — Fix V13 migration down/0 to use remove_if_exists for idempotency

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/360
**Author:** @construct-d
**Merged:** 2026-02-24 into `dev`
**Version:** 1.7.46 → 1.7.47
**Additions:** +18 | **Deletions:** -13

---

## Goal

Fix the `down/0` function of the V13 migration so that rollbacks are idempotent — they don't crash when the columns or index being removed don't exist.

## Problem

When rolling back V13 on a database that hadn't fully applied the migration (partial apply, failed migration, or `ecto.reset` in some CI scenarios), Postgres would throw:

```
** (Postgrex.Error) ERROR 42703 (undefined_column) column "aws_message_id" does not exist
```

The root cause: bare `remove` in an Ecto migration `alter` block is not idempotent. If the column was never created (or already removed), the migration crashes rather than silently succeeding.

## Changes

### `lib/phoenix_kit/migrations/postgres/v13.ex`

**1. Column removals — `remove` → `remove_if_exists`**

All nine column removals in `down/0` were changed from bare `remove` to `remove_if_exists` with explicit type annotation:

```elixir
# Before
remove :aws_message_id

# After
remove_if_exists :aws_message_id, :string
```

`remove_if_exists` requires the column type as the second argument and is a no-op when the column does not exist, making rollback safe to run multiple times or in any order.

**2. Index drop — `unique_index` with `where:` → `index` by name only**

The index drop was refactored from:

```elixir
drop_if_exists unique_index(:phoenix_kit_email_logs, [:aws_message_id],
                 prefix: prefix,
                 name: "phoenix_kit_email_logs_aws_message_id_index",
                 where: "aws_message_id IS NOT NULL"
               )
```

to:

```elixir
drop_if_exists index(
                 :phoenix_kit_email_logs,
                 [:aws_message_id],
                 prefix: prefix,
                 name: :phoenix_kit_email_logs_aws_message_id_index
               )
```

Key changes:
- `unique_index(...)` → `index(...)` — when dropping, the uniqueness constraint is irrelevant; identification by name is sufficient.
- `where:` clause removed — Ecto identifies the index by name for the existence check. The `where:` predicate on a partial index was potentially causing the `drop_if_exists` to not correctly recognize the existing index.
- String name → atom name — atom is the conventional form for referencing existing database objects by name in Ecto.

## Why This Matters

All PhoenixKit migration `down/0` functions should be idempotent. This is a fundamental property of the Oban-style versioned migration system used here. Prior migrations already used `remove_if_exists` correctly; V13 missed this pattern when first written.

## Files Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit/migrations/postgres/v13.ex` | `remove` → `remove_if_exists`, index drop cleanup |
| `CHANGELOG.md` | Added 1.7.47 entry |
| `mix.exs` | Version bump 1.7.46 → 1.7.47 |
