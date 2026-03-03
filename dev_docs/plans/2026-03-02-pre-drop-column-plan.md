# Plan: V72 Preparation Release — Fix hardcoded `id` references and DB prerequisites

> **Status**: Planning (next up after Category A)
> **Date**: 2026-03-02
> **Updated**: 2026-03-03
> **Migration version**: V73 (V72 used by Category A rename)
> **Verified against**: dev-nalazurke-fr after v1.7.54 (V72) on 2026-03-03

## Context

Before the big migration that drops integer `id`/`_id` columns (documented in `dev_docs/plans/2026-03-02-drop-integer-id-columns-plan.md`, now V74), several code and DB preparation steps can be shipped safely now. These are backwards-compatible with the current dual-column state.

> **Note**: V72 was used for Category A table renames (see `2026-03-02-category-a-tables-plan.md`).
> This plan now targets V73.

**Problems found during investigation (all verified still present after V71):**
1. Raw SQL in db.ex, api_controller.ex, and connection_notifier.ex hardcodes `id` as the PK column — breaks on tables where PK is `uuid` (30 Category A tables + 4 publishing tables already have UUID PK)
2. 4 DB indexes still use `_id` naming while Ecto columns are `_uuid` — schema constraint names reference these old index names
3. PL/pgSQL trigger function hardcodes `OLD.id`/`NEW.id` — returns empty string for UUID-PK tables
4. 7 `uuid` columns are nullable (0 actual NULLs) — prerequisite for PK promotion
5. 3 tables missing unique index on `uuid` — prerequisite for PK promotion
6. OAuth upsert still excludes dead `:user_id` column

---

## Part 1: Migration V73 — DB prerequisites

File: `lib/phoenix_kit/migrations/postgres/v73.ex`

### Step 1: SET NOT NULL on 7 nullable uuid columns
Safe — 0 actual NULLs exist on production:
```
phoenix_kit_ai_endpoints, phoenix_kit_ai_prompts, phoenix_kit_consent_logs,
phoenix_kit_payment_methods, phoenix_kit_subscription_types,
phoenix_kit_sync_connections, phoenix_kit_role_permissions
```

### Step 2: Add missing unique indexes on uuid
3 tables need unique index before uuid can become PK:
```
phoenix_kit_consent_logs, phoenix_kit_payment_methods, phoenix_kit_subscription_types
```

### Step 3: Rename 4 indexes from `_id` to `_uuid` naming
These indexes exist in DB with old names but index `_uuid` columns:
```sql
ALTER INDEX phoenix_kit_post_tag_assignments_post_id_tag_id_index
  RENAME TO phoenix_kit_post_tag_assignments_post_uuid_tag_uuid_index;
ALTER INDEX phoenix_kit_post_group_assignments_post_id_group_id_index
  RENAME TO phoenix_kit_post_group_assignments_post_uuid_group_uuid_index;
ALTER INDEX phoenix_kit_post_media_post_id_position_index
  RENAME TO phoenix_kit_post_media_post_uuid_position_index;
ALTER INDEX phoenix_kit_file_instances_file_id_variant_name_index
  RENAME TO phoenix_kit_file_instances_file_uuid_variant_name_index;
```

### Infrastructure
- `lib/phoenix_kit/migrations/postgres.ex` — bump `@current_version` from 72 to 73

---

## Part 2: Code fixes (all backwards-compatible)

### 2a: Dynamic PK detection in `lib/modules/db/db.ex`

**Line 223 — `fetch_row/3`**: Replace `WHERE id = $1` with dynamic PK:
```elixir
pk_col = get_pk_column(schema, table)
sql = "SELECT * FROM #{qualified} WHERE #{pk_col} = $1 LIMIT 1"
```

**Line 277 — `table_preview/3`**: Replace hardcoded `"id"` check:
```elixir
# Before
order_column = if Enum.any?(columns, &(&1.name == "id")), do: "id", else: "ctid"
# After — prefer uuid, then id, then ctid
order_column = cond do
  Enum.any?(columns, &(&1.name == "uuid")) -> "uuid"
  Enum.any?(columns, &(&1.name == "id")) -> "id"
  true -> "ctid"
end
```

**Lines 558-591 — `ensure_notify_function/0`**: Update PL/pgSQL trigger to try `uuid` first:
```sql
BEGIN row_id := OLD.uuid::TEXT;
EXCEPTION WHEN undefined_column THEN
  BEGIN row_id := OLD.id::TEXT;
  EXCEPTION WHEN undefined_column THEN row_id := '';
  END;
END;
```

Helper function (private to db.ex):
```elixir
defp get_pk_column(schema, table) do
  qualified = qualified_table(schema, table)
  sql = """
  SELECT a.attname FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
  WHERE i.indrelid = $1::regclass AND i.indisprimary
  """
  case RepoHelper.query(sql, [qualified]) do
    {:ok, %{rows: [[col]]}} -> col
    _ -> "id"
  end
end
```

### 2b: Dynamic PK in `lib/modules/sync/web/api_controller.ex`

**Line 1143 — `fetch_filtered_records/5`**: Replace `ORDER BY id` with dynamic PK.

**Lines 1166-1185 — `build_where_clause/1`**: Replace all `WHERE id` with the PK column. The function needs the PK column name passed in. The `:ids`/`:id_start`/`:id_end` option keys stay the same (API contract), but SQL uses the actual PK column.

Needs its own `get_pk_column/2` helper (or extract to a shared utility).

### 2c: Dynamic PK in `lib/modules/sync/connection_notifier.ex`

**Line 1101** — `insert_record/4`: Replace `Map.drop(record, ["id", :id])` with dynamic PK stripping
**Line 1119** — Replace `ON CONFLICT (id)` with dynamic PK column
**Line 1142** — `build_update_clause/1`: Replace `Enum.reject(&(&1 == "id"))` with dynamic PK

### 2d: Schema constraint names (4 files)

Update hardcoded index names to match the renamed indexes from Part 1 Step 3:

- `lib/modules/posts/schemas/post_tag_assignment.ex:70` — `post_id_tag_id_index` → `post_uuid_tag_uuid_index`
- `lib/modules/posts/schemas/post_group_assignment.ex:84` — `post_id_group_id_index` → `post_uuid_group_uuid_index`
- `lib/modules/posts/schemas/post_media.ex:83` — `post_id_position_index` → `post_uuid_position_index`
- `lib/modules/storage/schemas/file_instance.ex:170` — `file_id_variant_name_index` → `file_uuid_variant_name_index`

### 2e: OAuth conflict target

**`lib/phoenix_kit/users/oauth.ex:107`** — Remove dead `:user_id`:
```elixir
# Before
{:replace_all_except, [:uuid, :user_id, :user_uuid, :provider, :inserted_at]}
# After
{:replace_all_except, [:uuid, :user_uuid, :provider, :inserted_at]}
```

---

## Verification

1. `mix compile --warnings-as-errors`
2. Deploy to staging/production — V73 migration runs (NOT NULL, unique indexes, index renames)
3. DB explorer works on both `id`-PK and `uuid`-PK tables
4. Sync operations work correctly
5. `mix phoenix_kit.doctor` passes

---

## Files to modify

| File | Changes |
|------|---------|
| `lib/phoenix_kit/migrations/postgres/v73.ex` | **New** — SET NOT NULL, unique indexes, index renames |
| `lib/phoenix_kit/migrations/postgres.ex` | Bump `@current_version` 72 → 73 |
| `lib/modules/db/db.ex` | Dynamic PK in `fetch_row`, `table_preview`, `ensure_notify_function` |
| `lib/modules/sync/web/api_controller.ex` | Dynamic PK in `fetch_filtered_records`, `build_where_clause` |
| `lib/modules/sync/connection_notifier.ex` | Dynamic PK in `insert_record`, `build_update_clause` |
| `lib/modules/posts/schemas/post_tag_assignment.ex` | Update constraint name |
| `lib/modules/posts/schemas/post_group_assignment.ex` | Update constraint name |
| `lib/modules/posts/schemas/post_media.ex` | Update constraint name |
| `lib/modules/storage/schemas/file_instance.ex` | Update constraint name |
| `lib/phoenix_kit/users/oauth.ex` | Remove `:user_id` from replace_all_except |
