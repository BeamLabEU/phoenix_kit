# Plan: Drop integer `id` and `_id` columns from PhoenixKit database

> **Status**: Planning
> **Date**: 2026-03-02
> **Migration version**: V73 (requires V72 from pre-drop plan to be shipped first)
> **Verified against**: dev-nalazurke-fr after v1.7.53 (V71) on 2026-03-02

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
| Nullable `uuid` columns (0 actual NULLs) | 7 |
| Tables missing unique index on `uuid` | 3 |
| UUID-type `_id` FK columns with `_uuid` counterpart | 0 |

### Three table categories

**Category A** — 30 tables where PK `id` is already UUID type (no separate `uuid` column).
Schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}`.
Action: rename `id` → `uuid` (metadata-only, instant).

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

## Part 1: Migration V73

File: `lib/phoenix_kit/migrations/postgres/v73.ex`

### Step 1: Prerequisites (handled by V72 pre-drop plan)

> NOT NULL on 7 uuid columns, unique indexes on 3 tables, and index renames are all
> handled by V72 (pre-drop plan). V73 assumes V72 has already run.

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

### Step 5: Rename UUID-type `id` → `uuid` on 30 Category A tables

```sql
ALTER TABLE {table} RENAME COLUMN id TO uuid;
```

Metadata-only, instant. PK constraint auto-follows the rename.

**Category A tables:**

```
phoenix_kit_buckets              phoenix_kit_comment_dislikes
phoenix_kit_comment_likes        phoenix_kit_comments
phoenix_kit_comments_dislikes    phoenix_kit_comments_likes
phoenix_kit_file_instances       phoenix_kit_file_locations
phoenix_kit_files                phoenix_kit_post_comments
phoenix_kit_post_dislikes        phoenix_kit_post_groups
phoenix_kit_post_likes           phoenix_kit_post_media
phoenix_kit_post_mentions        phoenix_kit_post_tags
phoenix_kit_post_views           phoenix_kit_posts
phoenix_kit_scheduled_jobs       phoenix_kit_storage_dimensions
phoenix_kit_ticket_attachments   phoenix_kit_ticket_comments
phoenix_kit_ticket_status_history phoenix_kit_tickets
phoenix_kit_user_blocks          phoenix_kit_user_blocks_history
phoenix_kit_user_connections     phoenix_kit_user_connections_history
phoenix_kit_user_follows         phoenix_kit_user_follows_history
```

After this step, ALL PhoenixKit tables have `uuid` as the PK column name.

---

## Part 2: Schema Updates (30 files)

Remove `source: :id` from all 30 schemas since the DB column is now `uuid`:

```elixir
# Before
@primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

# After
@primary_key {:uuid, UUIDv7, autogenerate: true}
```

**Files:**

| Module | Schemas |
|--------|---------|
| Posts | `post.ex`, `post_comment.ex`, `post_like.ex`, `post_dislike.ex`, `post_view.ex`, `post_mention.ex`, `post_media.ex`, `post_group.ex`, `post_tag.ex`, `comment_like.ex`, `comment_dislike.ex` |
| Storage | `file.ex`, `file_instance.ex`, `file_location.ex`, `bucket.ex`, `dimension.ex` |
| Tickets | `ticket.ex`, `ticket_comment.ex`, `ticket_attachment.ex`, `ticket_status_history.ex` |
| Comments | `comment.ex`, `comment_like.ex`, `comment_dislike.ex` |
| Connections | `block.ex`, `block_history.ex`, `connection.ex`, `connection_history.ex`, `follow.ex`, `follow_history.ex` |
| Billing | `webhook_event.ex` |

---

## Part 3: Code Updates

### Raw SQL in sync/db modules

The sync module and DB explorer use `ORDER BY id` and `WHERE id = ...` for generic table access (any table, not just PhoenixKit). Fix by detecting PK column dynamically.

**Files:**
- `lib/modules/db/db.ex:223` — `WHERE id = $1`
- `lib/modules/sync/web/api_controller.ex:1143,1166-1181` — `ORDER BY id`, `WHERE id`

**Helper function:**

```elixir
defp get_pk_column(repo, table_name) do
  sql = """
  SELECT a.attname FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
  WHERE i.indrelid = $1::regclass AND i.indisprimary
  """
  case repo.query(sql, [table_name]) do
    {:ok, %{rows: [[col]]}} -> col
    _ -> "id"  # fallback for non-PhoenixKit tables
  end
end
```

### Conflict targets in upserts

- `lib/phoenix_kit/users/oauth.ex:107` — `{:replace_all_except, [:uuid, :user_id, ...]}` → remove `:user_id`

### Constraint names in schemas

> Handled by V72 pre-drop plan (index renames + schema constraint name updates).
> By the time V73 ships, these will already be correct.

### Doctor task

- `lib/mix/tasks/phoenix_kit.doctor.ex` — update diagnostics to expect `uuid` PK instead of `id`

---

## Part 4: Infrastructure

- `lib/phoenix_kit/migrations/postgres.ex` — bump `@current_version` from 72 to 73

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
| New migration file (`v73.ex`) | ~400–600 lines |
| Infrastructure (`postgres.ex`) | 1 line change |
| Schema files (remove `source: :id`) | 30 files |
| Schema files (update constraint names) | 0 (handled by V72) |
| Code files (raw SQL, oauth, doctor) | ~5 files |

---

## Open Questions

1. ~~**UUID-type `_id` FK columns without `_uuid` counterpart**~~ — **RESOLVED**: Verified 0 such columns exist on production. No action needed.
2. **Sync module range queries** — `receiver.ex` uses `start_id`/`end_id` integer ranges. After dropping integer `id`, these need UUID-based pagination instead.
3. **`uuid_fk_columns.ex` cleanup** — After migration, the backfill/constraint logic in this module is dead code. Clean up or keep for rollback?
