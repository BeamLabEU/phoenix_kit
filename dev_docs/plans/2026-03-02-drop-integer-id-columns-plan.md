# Plan: Drop integer `id` and `_id` columns from PhoenixKit database

> **Status**: Planning (Category A done, V73 prerequisites done, Category B next)
> **Date**: 2026-03-02
> **Updated**: 2026-03-03
> **Migration version**: V74 (V73 pre-drop prerequisites shipped in v1.7.55)
> **Verified against**: dev-nalazurke-fr after v1.7.55 (V73) on 2026-03-03

## Context

PhoenixKit migrated from integer IDs to UUIDs over several versions (V40–V56+). The database now has dual columns: every table has a `uuid` column (used by Ecto) alongside legacy integer `id` PK + integer `_id` FK columns no longer used by the application. This migration drops the dead integer columns and promotes `uuid` to PK.

### Production DB state (verified on dev-nalazurke-fr after V71 / v1.7.53)

| Metric | Count |
|--------|-------|
| FK constraints referencing `id` | 98 |
| FK constraints referencing `uuid` (already working) | 69 |
| `_uuid` FK columns (in use by Ecto) | 130 |
| Legacy integer `_id` FK columns (dead) | 80 |
| Tables with bigint `id` PK + separate `uuid` column (Category B) | 45 |
| Tables with UUID-type `id` PK, no `uuid` column (Category A) | 30 |
| Tables already at target state — PK is `uuid`, no `id` col (Category C) | 4 |
| Tables without PK (join tables) | 2 |
| Nullable `uuid` columns (0 actual NULLs) | ~~7~~ 0 (fixed by V73) |
| Tables missing unique index on `uuid` | ~~3~~ 0 (fixed by V73) |
| UUID-type `_id` FK columns with `_uuid` counterpart | 0 |

### Three table categories

**Category A** — 30 tables where PK `id` was already UUID type (no separate `uuid` column).
~~Schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}`.~~
~~Action: rename `id` → `uuid` (metadata-only, instant).~~
**DONE** — Completed in V72 (v1.7.54, 2026-03-03). All 30 tables renamed, 29 schemas updated, 4 missing FK constraints added.

**Category B** — 45 tables where PK `id` is bigint and a separate `uuid` column exists.
Schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}`.
Action: drop `id`, make `uuid` the PK.

**Category C** — 4 publishing tables already at target state (PK column is `uuid`, no `id` column):
`phoenix_kit_publishing_contents`, `phoenix_kit_publishing_groups`, `phoenix_kit_publishing_posts`, `phoenix_kit_publishing_versions`.
Action: none needed.

**No PK** — 2 join tables: `phoenix_kit_post_group_assignments`, `phoenix_kit_post_tag_assignments`.
Action: none needed (use composite unique indexes).

## Scope

### DO
- Drop bigint `id` columns on 45 Category B tables, make `uuid` the new PK
- Rename UUID-type `id` → `uuid` on 30 Category A tables (metadata-only, instant) for consistency
- Drop all 80 integer `_id` FK columns (have `_uuid` counterparts)
- Drop 98 FK constraints referencing `id`
- Remove `source: :id` from 30 Ecto schemas
- Fix raw SQL queries in sync/db modules to detect PK column dynamically

### DON'T touch
- FK constraints referencing `uuid` (69 constraints) — keep as-is
- 4 Category C publishing tables — already at target state
- 2 join tables without PKs — keep as-is

---

## Part 1: Migration V74

File: `lib/phoenix_kit/migrations/postgres/v74.ex`

### Step 1: Prerequisites — DONE (V73, v1.7.55)

> NOT NULL on 7 uuid columns, unique indexes on 3 tables, and index renames are all
> handled by V73 (v1.7.55, released 2026-03-03). Verified on dev-nalazurke-fr.
> V74 assumes V73 has already run.

### Step 2: Drop all FK constraints referencing `id`

Dynamic query — drops all 98 FK constraints:

```sql
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN SELECT tc.constraint_name, tc.table_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu USING (constraint_name)
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_name LIKE 'phoenix_kit_%'
      AND ccu.column_name = 'id'
  LOOP
    EXECUTE 'ALTER TABLE ' || r.table_name || ' DROP CONSTRAINT IF EXISTS ' || r.constraint_name;
  END LOOP;
END $$;
```

### Step 3: Drop integer `_id` FK columns (80 columns)

All integer/bigint `_id` columns. Source list from `uuid_fk_columns.ex` groups A–D plus extras.

```sql
ALTER TABLE {table} DROP COLUMN IF EXISTS {int_fk_column};
```

**From uuid_fk_columns.ex** (72 columns across Groups A–D):
- Group A (→ users): `user_id`, `assigned_by`, `author_id`, `target_user_id`, `admin_user_id`, `granted_by`, `blocker_id`, `blocked_id`, `follower_id`, `followed_id`, `requester_id`, `recipient_id`, `user_a_id`, `user_b_id`, `actor_id`, `approved_by`, `suspended_by`, `revoked_by`, `created_by`, `denied_by`, `initiated_by`, `assigned_to_id`, `changed_by_id`, `created_by_user_id`, `updated_by_user_id`, `beneficiary`, `used_by`
- Group B (→ roles): `role_id`
- Group C (→ entities): `entity_id`
- Group D (internal): `cart_id`, `product_id`, `shipping_method_id`, `merged_into_cart_id`, `payment_option_id`, `category_id`, `parent_id` (shop), `featured_product_id`, `billing_profile_id`, `order_id`, `invoice_id`, `subscription_type_id`, `payment_method_id`, `email_log_id`, `endpoint_id`, `prompt_id`, `connection_id`, `code_id`

**Extra columns NOT in uuid_fk_columns.ex** (8 columns):
- `phoenix_kit_invoices.subscription_id` (integer)
- `phoenix_kit_email_orphaned_events.matched_email_log_id` (integer)
- `phoenix_kit_publishing_posts.created_by_id` (bigint)
- `phoenix_kit_publishing_posts.updated_by_id` (bigint)
- `phoenix_kit_publishing_versions.created_by_id` (bigint)
- `phoenix_kit_shop_cart_items.variant_id` (bigint)
- `phoenix_kit_scheduled_jobs.created_by_id` (bigint)
- `phoenix_kit_ai_requests.account_id` (integer)

### ~~Step 4: Drop UUID-type `_id` FK columns~~ — REMOVED

> Verified 2026-03-02 on dev-nalazurke-fr: **0 UUID-type `_id` FK columns with `_uuid` counterparts exist.**
> This step is a no-op and has been removed. Additionally, the original SQL had a bug:
> `LIKE '%_id'` where `_` is a SQL wildcard — would have matched columns like `uuid`, `author_uuid` etc.
> Correct pattern would be `column_name ~ '_id$'` (regex).

### Step 4: Drop bigint `id` and make `uuid` PK (45 Category B tables)

```sql
ALTER TABLE {table} DROP CONSTRAINT IF EXISTS {table}_pkey;
ALTER TABLE {table} DROP COLUMN id;
ALTER TABLE {table} ADD PRIMARY KEY (uuid);
```

The old serial/bigserial sequence is automatically dropped with the column.

### ~~Step 5: Rename UUID-type `id` → `uuid` on 30 Category A tables~~ — DONE

> **Completed in V72** (v1.7.54, 2026-03-03). All 30 Category A tables already have
> `uuid` as PK column. This step is a no-op for V74.

After V74, ALL PhoenixKit tables have `uuid` as the PK column name.

---

## ~~Part 2: Schema Updates (30 files)~~ — DONE

> **Completed in V72** (v1.7.54, 2026-03-03). Removed `source: :id` from 29 Category A
> schemas (webhook_event.ex is Category B, scheduled_jobs already correct).
> Only `webhook_event.ex` still has `source: :id` — will be updated when Category B drops `id` column.

---

## Part 3: Code Updates — MOSTLY DONE (V73, v1.7.55)

### Raw SQL in sync/db modules — DONE

Dynamic PK detection shipped in v1.7.55. `RepoHelper.get_pk_column/1` queries `pg_index`
for the actual PK column name, falls back to `"id"`.

**Files updated:**
- `lib/phoenix_kit/repo_helper.ex` — new `get_pk_column/1` helper
- `lib/modules/db/db.ex` — `fetch_row`, `table_preview`, `ensure_notify_function`
- `lib/modules/sync/web/api_controller.ex` — `fetch_filtered_records`, `build_where_clause`
- `lib/modules/sync/connection_notifier.ex` — `insert_record`, `build_update_clause`

### Conflict targets in upserts — DONE

- `lib/phoenix_kit/users/oauth.ex:107` — removed dead `:user_id` from `replace_all_except`

### Constraint names in schemas — DONE

Index renames (V73 migration) + schema constraint name updates shipped in v1.7.55.

### Doctor task — TODO

- `lib/mix/tasks/phoenix_kit.doctor.ex` — update diagnostics to expect `uuid` PK instead of `id`

---

## Part 4: Infrastructure

- `lib/phoenix_kit/migrations/postgres.ex` — bump `@current_version` from 73 to 74
- `mix.exs` — bump version to 1.7.56
- `CHANGELOG.md` — add 1.7.56 entry

---

## Verification

1. `mix compile --warnings-as-errors`
2. SQL checks after migration:

```sql
-- No more bigint PK columns
SELECT table_name FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu USING (constraint_name)
JOIN information_schema.columns c USING (table_name, column_name)
WHERE tc.constraint_type = 'PRIMARY KEY' AND c.data_type IN ('bigint', 'integer')
AND tc.table_name LIKE 'phoenix_kit_%';
-- Expected: 0 rows

-- No more integer _id FK columns
SELECT table_name, column_name FROM information_schema.columns
WHERE table_name LIKE 'phoenix_kit_%' AND column_name LIKE '%\_id'
AND data_type IN ('integer', 'bigint');
-- Expected: 0 rows

-- All PKs are on uuid column
SELECT table_name, column_name FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu USING (constraint_name)
WHERE tc.constraint_type = 'PRIMARY KEY'
AND tc.table_name LIKE 'phoenix_kit_%'
AND kcu.column_name != 'uuid';
-- Expected: 0 rows (except join tables with composite PKs)
```

3. `mix phoenix_kit.doctor` — all checks pass
4. Start app, test key operations

---

## Estimated Scope

| Category | Count |
|----------|-------|
| New migration file (`v74.ex`) | ~400–600 lines |
| Infrastructure (`postgres.ex`) | 1 line change |
| Schema files (remove `source: :id`) | 1 file (webhook_event.ex only — 29 done in V72) |
| Schema files (update constraint names) | 0 (done in V73) |
| Code files (raw SQL, oauth) | 0 (done in V73) |
| Code files (doctor task) | 1 file |

---

## Open Questions

1. ~~**UUID-type `_id` FK columns without `_uuid` counterpart**~~ — **RESOLVED**: Verified 0 such columns exist on production. No action needed.
2. **Sync module range queries** — `receiver.ex` uses `start_id`/`end_id` integer ranges. After dropping integer `id`, these need UUID-based pagination instead.
3. **`uuid_fk_columns.ex` cleanup** — After migration, the backfill/constraint logic in this module is dead code. Clean up or keep for rollback?
