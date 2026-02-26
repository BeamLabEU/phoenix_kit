# V62: UUID Column Rename Plan (`_id` → `_uuid`) — COMPLETED

**Date:** 2026-02-23
**Status:** ✅ FULLY IMPLEMENTED AND VERIFIED
**Depends on:** V61 (uuid safety net migration, merged to main)
**Completed in:** V62-V65 migrations
**Current version:** 1.7.48 / V65

---

## Goal

Rename all UUID-type database columns that still use the `_id` suffix to `_uuid`.

**Naming convention** (from `dev_docs/guides/2026-02-17-uuid-migration-instructions-v3.md`):
- `_id` suffix = integer (legacy, deprecated, will be dropped after cutover)
- `_uuid` suffix = UUID type

Currently ~38 UUID columns violate this convention by using `_id` names.

---

## Scope

### What to rename
UUID-type columns named `*_id` that store UUID values → rename to `*_uuid`.

### What NOT to rename
- Integer `_id` columns (legacy dual-write: `user_id`, `category_id`, `created_by_id`, etc.) — leave as-is
- The `id` column itself on Pattern 2 tables (UUID native PK stored in `id` via `source: :id`) — leave as-is
- `uuid` columns (already correctly named)
- Columns in Connections module (`requester_id`, `recipient_id`, `blocker_id`, `blocked_id`) — these are INTEGER with `_uuid` companions already

---

## Complete Column Rename List

### Group A: Posts Module (11 tables, 17 columns)

| # | Table | Old Column | New Column | FK Target | Notes |
|---|-------|-----------|------------|-----------|-------|
| 1 | `phoenix_kit_post_comments` | `post_id` | `post_uuid` | `posts(id)` | |
| 2 | `phoenix_kit_post_comments` | `parent_id` | `parent_uuid` | `post_comments(id)` | Self-referencing FK |
| 3 | `phoenix_kit_post_likes` | `post_id` | `post_uuid` | `posts(id)` | |
| 4 | `phoenix_kit_post_dislikes` | `post_id` | `post_uuid` | `posts(id)` | |
| 5 | `phoenix_kit_post_mentions` | `post_id` | `post_uuid` | `posts(id)` | |
| 6 | `phoenix_kit_post_media` | `post_id` | `post_uuid` | `posts(id)` | |
| 7 | `phoenix_kit_post_media` | `file_id` | `file_uuid` | `files(id)` | |
| 8 | `phoenix_kit_post_views` | `post_id` | `post_uuid` | `posts(id)` | |
| 9 | `phoenix_kit_post_tag_assignments` | `post_id` | `post_uuid` | `posts(id)` | **Composite PK** |
| 10 | `phoenix_kit_post_tag_assignments` | `tag_id` | `tag_uuid` | `post_tags(id)` | **Composite PK** |
| 11 | `phoenix_kit_post_group_assignments` | `post_id` | `post_uuid` | `posts(id)` | **Composite PK** |
| 12 | `phoenix_kit_post_group_assignments` | `group_id` | `group_uuid` | `post_groups(id)` | **Composite PK** |
| 13 | `phoenix_kit_post_groups` | `cover_image_id` | `cover_image_uuid` | `files(id)` | Raw UUID field, no FK constraint |
| 14 | `phoenix_kit_comment_likes` | `comment_id` | `comment_uuid` | `post_comments(id)` | Posts-module comment likes |
| 15 | `phoenix_kit_comment_dislikes` | `comment_id` | `comment_uuid` | `post_comments(id)` | Posts-module comment dislikes |

### Group B: Comments Module (3 tables, 4 columns)

Tables created by V55. May not exist on all installs (module must be enabled).

| # | Table | Old Column | New Column | FK Target | Notes |
|---|-------|-----------|------------|-----------|-------|
| 16 | `phoenix_kit_comments` | `resource_id` | `resource_uuid` | None | Polymorphic, no FK constraint |
| 17 | `phoenix_kit_comments` | `parent_id` | `parent_uuid` | `comments(id)` | Self-referencing FK |
| 18 | `phoenix_kit_comments_likes` | `comment_id` | `comment_uuid` | `comments(id)` | |
| 19 | `phoenix_kit_comments_dislikes` | `comment_id` | `comment_uuid` | `comments(id)` | |

### Group C: Tickets Module (3 tables, 6 columns)

| # | Table | Old Column | New Column | FK Target | Notes |
|---|-------|-----------|------------|-----------|-------|
| 20 | `phoenix_kit_ticket_comments` | `ticket_id` | `ticket_uuid` | `tickets(id)` | |
| 21 | `phoenix_kit_ticket_comments` | `parent_id` | `parent_uuid` | `ticket_comments(id)` | Self-referencing FK |
| 22 | `phoenix_kit_ticket_attachments` | `ticket_id` | `ticket_uuid` | `tickets(id)` | |
| 23 | `phoenix_kit_ticket_attachments` | `comment_id` | `comment_uuid` | `ticket_comments(id)` | |
| 24 | `phoenix_kit_ticket_attachments` | `file_id` | `file_uuid` | `files(id)` | |
| 25 | `phoenix_kit_ticket_status_history` | `ticket_id` | `ticket_uuid` | `tickets(id)` | |

### Group D: Storage Module (2 tables, 3 columns)

| # | Table | Old Column | New Column | FK Target | Notes |
|---|-------|-----------|------------|-----------|-------|
| 26 | `phoenix_kit_file_instances` | `file_id` | `file_uuid` | `files(id)` | |
| 27 | `phoenix_kit_file_locations` | `bucket_id` | `bucket_uuid` | `buckets(id)` | |
| 28 | `phoenix_kit_file_locations` | `file_instance_id` | `file_instance_uuid` | `file_instances(id)` | |

### Group E: Publishing Module (3 tables, 3 columns)

Tables created by V59. May not exist on all installs.

| # | Table | Old Column | New Column | FK Target | Notes |
|---|-------|-----------|------------|-----------|-------|
| 29 | `phoenix_kit_publishing_posts` | `group_id` | `group_uuid` | `publishing_groups(uuid)` | FK target is `uuid` not `id` |
| 30 | `phoenix_kit_publishing_versions` | `post_id` | `post_uuid` | `publishing_posts(uuid)` | FK target is `uuid` not `id` |
| 31 | `phoenix_kit_publishing_contents` | `version_id` | `version_uuid` | `publishing_versions(uuid)` | FK target is `uuid` not `id` |

### Group F: Shop Module (2 tables, 3 columns)

| # | Table | Old Column | New Column | FK Target | Notes |
|---|-------|-----------|------------|-----------|-------|
| 32 | `phoenix_kit_shop_categories` | `image_id` | `image_uuid` | None | Raw `Ecto.UUID` field, no FK |
| 33 | `phoenix_kit_shop_products` | `featured_image_id` | `featured_image_uuid` | None | Raw `Ecto.UUID` field, no FK |
| 34 | `phoenix_kit_shop_products` | `file_id` | `file_uuid` | None | Raw `Ecto.UUID` field, no FK |

### Group G: Scheduled Jobs (1 table, 1 column)

| # | Table | Old Column | New Column | FK Target | Notes |
|---|-------|-----------|------------|-----------|-------|
| 35 | `phoenix_kit_scheduled_jobs` | `resource_id` | `resource_uuid` | None | Polymorphic, no FK constraint |

**Total: 25 tables, 35 column renames**

---

## Implementation Steps

### Step 1: Create V62 Migration

File: `lib/phoenix_kit/migrations/postgres/v62.ex`

**Pattern for each table:**
```sql
-- All tables must be guarded with IF EXISTS (modules may not be installed)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'phoenix_kit_post_likes'
             AND column_name = 'post_id'
             AND table_schema = 'public') THEN
    ALTER TABLE phoenix_kit_post_likes RENAME COLUMN post_id TO post_uuid;
  END IF;
END $$;
```

**CRITICAL: Start V62's `up()` with `flush()`** to prevent the same buffering bug that hit V40.

**PostgreSQL behavior on RENAME COLUMN:**
- Index definitions auto-update to reference new column name ✓
- FK constraint definitions auto-update ✓
- The constraint/index object NAMES stay the same (cosmetic issue only)
- Optionally rename indexes for clarity: `ALTER INDEX old_name RENAME TO new_name`

**Composite PK tables** (`post_tag_assignments`, `post_group_assignments`):
- `RENAME COLUMN` works fine even for PK columns
- The PK constraint auto-updates to reference the new column name

### Step 2: Update `postgres.ex`

- Bump `@current_version` from 61 to 62
- Add V62 to the version docs in moduledoc

### Step 3: Update Schema Files

For each schema, update these elements:

1. **`belongs_to` declarations** — add/change `foreign_key: :new_name`
2. **`field` declarations** — rename field name
3. **`has_many` declarations** — update `foreign_key: :new_name`
4. **`many_to_many` join_keys** — update key names
5. **`cast()` lists** — update field name atoms
6. **`validate_required()` lists** — update field name atoms
7. **`foreign_key_constraint()` calls** — update field name atoms
8. **`unique_constraint()` calls** — update constraint names if they reference old column names
9. **`@type` definitions** — update field name atoms
10. **Module docs / `@moduledoc`** — update field references

### Step 4: Update Context/Query Files

Search all `.ex` files for references to old field names in Ecto queries:

```bash
# Find all references to renamed fields in Elixir code
ast-grep --lang elixir --pattern ':post_id' lib/modules/
ast-grep --lang elixir --pattern ':comment_id' lib/modules/
ast-grep --lang elixir --pattern ':ticket_id' lib/modules/
ast-grep --lang elixir --pattern ':file_id' lib/modules/
ast-grep --lang elixir --pattern ':bucket_id' lib/modules/
ast-grep --lang elixir --pattern ':tag_id' lib/modules/
ast-grep --lang elixir --pattern ':group_id' lib/modules/
ast-grep --lang elixir --pattern ':parent_id' lib/modules/
ast-grep --lang elixir --pattern ':resource_id' lib/modules/ lib/phoenix_kit/
ast-grep --lang elixir --pattern ':cover_image_id' lib/modules/
ast-grep --lang elixir --pattern ':image_id' lib/modules/
ast-grep --lang elixir --pattern ':featured_image_id' lib/modules/
ast-grep --lang elixir --pattern ':version_id' lib/modules/
ast-grep --lang elixir --pattern ':file_instance_id' lib/modules/
```

**Be careful to distinguish:**
- `:post_id` in a Posts context (UUID, needs rename) vs `:post_id` in another module referencing an integer FK (leave as-is)
- `:file_id` in Storage/Posts (UUID FK to files) vs other uses

### Step 5: Update Version

- `mix.exs` — bump version to 1.7.46
- `CHANGELOG.md` — add entry
- `CLAUDE.md` — update version reference

### Step 6: Compile & Test

```bash
mix compile --warnings-as-errors
mix format
mix credo --strict
mix test
```

---

## Schema File Reference

Complete list of schema files that need updating:

### Posts Module
| File | Fields to Rename |
|------|-----------------|
| `lib/modules/posts/schemas/post_comment.ex` | `post_id` → `post_uuid`, `parent_id` → `parent_uuid`; `has_many :children foreign_key:`, `has_many :likes foreign_key:`, `has_many :dislikes foreign_key:` |
| `lib/modules/posts/schemas/post_like.ex` | `post_id` → `post_uuid` |
| `lib/modules/posts/schemas/post_dislike.ex` | `post_id` → `post_uuid` |
| `lib/modules/posts/schemas/post_mention.ex` | `post_id` → `post_uuid` |
| `lib/modules/posts/schemas/post_media.ex` | `post_id` → `post_uuid`, `file_id` → `file_uuid` |
| `lib/modules/posts/schemas/post_view.ex` | `post_id` → `post_uuid` |
| `lib/modules/posts/schemas/post_tag_assignment.ex` | `post_id` → `post_uuid`, `tag_id` → `tag_uuid`; also update `cast()`, `validate_required()`, constraints |
| `lib/modules/posts/schemas/post_group_assignment.ex` | `post_id` → `post_uuid`, `group_id` → `group_uuid`; also update `cast()`, `validate_required()`, constraints |
| `lib/modules/posts/schemas/post_group.ex` | `cover_image_id` → `cover_image_uuid`; also update `cast()`, `many_to_many :posts join_keys:` |
| `lib/modules/posts/schemas/comment_like.ex` | `comment_id` → `comment_uuid` |
| `lib/modules/posts/schemas/comment_dislike.ex` | `comment_id` → `comment_uuid` |

### Comments Module
| File | Fields to Rename |
|------|-----------------|
| `lib/modules/comments/schemas/comment.ex` | `resource_id` → `resource_uuid`, `parent_id` → `parent_uuid`; `has_many :children foreign_key:` |
| `lib/modules/comments/schemas/comment_like.ex` | `comment_id` → `comment_uuid` |
| `lib/modules/comments/schemas/comment_dislike.ex` | `comment_id` → `comment_uuid` |

### Tickets Module
| File | Fields to Rename |
|------|-----------------|
| `lib/modules/tickets/ticket_comment.ex` | `ticket_id` → `ticket_uuid`, `parent_id` → `parent_uuid` |
| `lib/modules/tickets/ticket_attachment.ex` | `ticket_id` → `ticket_uuid`, `comment_id` → `comment_uuid`, `file_id` → `file_uuid` |
| `lib/modules/tickets/ticket_status_history.ex` | `ticket_id` → `ticket_uuid` |

### Storage Module
| File | Fields to Rename |
|------|-----------------|
| `lib/modules/storage/schemas/file_instance.ex` | `file_id` → `file_uuid` |
| `lib/modules/storage/schemas/file_location.ex` | `bucket_id` → `bucket_uuid`, `file_instance_id` → `file_instance_uuid` |

### Publishing Module
| File | Fields to Rename |
|------|-----------------|
| `lib/modules/publishing/schemas/publishing_content.ex` | `version_id` → `version_uuid`; also update `cast()`, `validate_required()`, `unique_constraint()`, `foreign_key_constraint()` |
| `lib/modules/publishing/schemas/publishing_post.ex` | `group_id` → `group_uuid` |
| `lib/modules/publishing/schemas/publishing_version.ex` | `post_id` → `post_uuid` |

### Shop Module
| File | Fields to Rename |
|------|-----------------|
| `lib/modules/shop/schemas/category.ex` | `image_id` → `image_uuid`; also update `cast()` |
| `lib/modules/shop/schemas/product.ex` | `featured_image_id` → `featured_image_uuid`, `file_id` → `file_uuid`; also update `cast()` |

### Scheduled Jobs
| File | Fields to Rename |
|------|-----------------|
| `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` | `resource_id` → `resource_uuid`; also update `cast()`, `validate_required()` |

---

## Context Files to Search

These context/query files likely reference the old field names and need updating:

```
lib/modules/posts/posts.ex                    — Main posts context
lib/modules/posts/web/*.ex                    — Posts LiveViews
lib/modules/comments/comments.ex              — Comments context
lib/modules/comments/web/*.ex                 — Comments LiveViews
lib/modules/tickets/tickets.ex                — Tickets context
lib/modules/tickets/web/*.ex                  — Tickets LiveViews
lib/modules/storage/storage.ex                — Storage context
lib/modules/storage/web/*.ex                  — Storage LiveViews
lib/modules/publishing/publishing.ex          — Publishing context
lib/modules/publishing/web/*.ex               — Publishing LiveViews
lib/modules/shop/shop.ex                      — Shop context
lib/modules/shop/web/*.ex                     — Shop LiveViews
lib/phoenix_kit/scheduled_jobs/*.ex           — Scheduled jobs
```

**Search method:** Use `ast-grep` for structural matches and `rg` for string matches:

```bash
# Example: find all :post_id references in posts module
rg ':post_id' lib/modules/posts/ --type elixir
rg 'post_id' lib/modules/posts/ --type elixir

# Find query fragments like "p.post_id" in raw SQL
rg 'post_id' lib/modules/posts/ --type elixir
```

---

## Special Cases & Warnings

### 1. Composite Primary Key Tables
`post_tag_assignments` and `post_group_assignments` use `@primary_key false` and `belongs_to ... primary_key: true`. The PK columns get renamed. PostgreSQL handles this correctly with `RENAME COLUMN`.

### 2. Self-Referencing FKs
`comments.parent_id`, `post_comments.parent_id`, `ticket_comments.parent_id` reference their own table's `id` column. The FK constraint auto-updates when the column is renamed.

### 3. `many_to_many` join_keys
`PostGroup.posts` uses `join_keys: [group_id: :uuid, post_id: :uuid]`. After rename, this becomes `join_keys: [group_uuid: :uuid, post_uuid: :uuid]`.

### 4. `has_many` foreign_key References
Several schemas specify explicit `foreign_key:` in `has_many`. These MUST be updated:
- `PostComment`: `has_many :children, __MODULE__, foreign_key: :parent_id` → `:parent_uuid`
- `PostComment`: `has_many :likes, CommentLike, foreign_key: :comment_id` → `:comment_uuid`
- `PostComment`: `has_many :dislikes, CommentDislike, foreign_key: :comment_id` → `:comment_uuid`
- `Comment`: `has_many :children, __MODULE__, foreign_key: :parent_id` → `:parent_uuid`
- `PostGroup`: `has_many`/`many_to_many` join_keys (see above)

### 5. Tables May Not Exist
Comments (V55) and Publishing (V59) tables only exist if those modules were enabled. All rename operations MUST be wrapped in `IF EXISTS` guards.

### 6. Unique Constraint Names in Code
Some schemas reference constraint names that include old column names:
- `phoenix_kit_post_group_assignments_post_id_group_id_index` → needs rename
- `phoenix_kit_post_tag_assignments_post_id_tag_id_index` → needs rename
- `uq_comments_likes_comment_user` (uses FK name, not column — OK as-is)
- `idx_publishing_contents_version_language` (index on `version_id` + `language`)
- `fk_publishing_contents_version` (FK constraint name — cosmetic)

### 7. Index Rename (Optional but Recommended)
After column renames, index NAMES still reference old columns (e.g., `idx_post_likes_post_id`). Consider renaming for clarity:
```sql
ALTER INDEX IF EXISTS idx_post_likes_post_id RENAME TO idx_post_likes_post_uuid;
```

### 8. No Views/Triggers/Functions to Worry About
PhoenixKit doesn't use PostgreSQL views, triggers, or stored functions that reference these columns.

### 9. `@foreign_key_type UUIDv7` Gotcha
Some schemas set `@foreign_key_type UUIDv7` (e.g., `PostGroup`). When this is set, `belongs_to` without explicit `foreign_key:` defaults to `<name>_id`. After this migration, ALL `belongs_to` on UUID FK columns must explicitly specify `foreign_key: :name_uuid`.

---

## V62 Migration Template

```elixir
defmodule PhoenixKit.Migrations.Postgres.V62 do
  @moduledoc """
  V62 — Rename UUID-type columns from `_id` suffix to `_uuid` suffix.

  Enforces the naming convention: `_id` = integer (legacy), `_uuid` = UUID.
  All operations are idempotent (guarded by column_exists? checks).
  """

  use Ecto.Migration

  @tables_and_columns [
    # {table, old_column, new_column}
    # Group A: Posts
    {"phoenix_kit_post_comments", "post_id", "post_uuid"},
    {"phoenix_kit_post_comments", "parent_id", "parent_uuid"},
    {"phoenix_kit_post_likes", "post_id", "post_uuid"},
    {"phoenix_kit_post_dislikes", "post_id", "post_uuid"},
    {"phoenix_kit_post_mentions", "post_id", "post_uuid"},
    {"phoenix_kit_post_media", "post_id", "post_uuid"},
    {"phoenix_kit_post_media", "file_id", "file_uuid"},
    {"phoenix_kit_post_views", "post_id", "post_uuid"},
    {"phoenix_kit_post_tag_assignments", "post_id", "post_uuid"},
    {"phoenix_kit_post_tag_assignments", "tag_id", "tag_uuid"},
    {"phoenix_kit_post_group_assignments", "post_id", "post_uuid"},
    {"phoenix_kit_post_group_assignments", "group_id", "group_uuid"},
    {"phoenix_kit_post_groups", "cover_image_id", "cover_image_uuid"},
    {"phoenix_kit_comment_likes", "comment_id", "comment_uuid"},
    {"phoenix_kit_comment_dislikes", "comment_id", "comment_uuid"},
    # Group B: Comments
    {"phoenix_kit_comments", "resource_id", "resource_uuid"},
    {"phoenix_kit_comments", "parent_id", "parent_uuid"},
    {"phoenix_kit_comments_likes", "comment_id", "comment_uuid"},
    {"phoenix_kit_comments_dislikes", "comment_id", "comment_uuid"},
    # Group C: Tickets
    {"phoenix_kit_ticket_comments", "ticket_id", "ticket_uuid"},
    {"phoenix_kit_ticket_comments", "parent_id", "parent_uuid"},
    {"phoenix_kit_ticket_attachments", "ticket_id", "ticket_uuid"},
    {"phoenix_kit_ticket_attachments", "comment_id", "comment_uuid"},
    {"phoenix_kit_ticket_attachments", "file_id", "file_uuid"},
    {"phoenix_kit_ticket_status_history", "ticket_id", "ticket_uuid"},
    # Group D: Storage
    {"phoenix_kit_file_instances", "file_id", "file_uuid"},
    {"phoenix_kit_file_locations", "bucket_id", "bucket_uuid"},
    {"phoenix_kit_file_locations", "file_instance_id", "file_instance_uuid"},
    # Group E: Publishing
    {"phoenix_kit_publishing_posts", "group_id", "group_uuid"},
    {"phoenix_kit_publishing_versions", "post_id", "post_uuid"},
    {"phoenix_kit_publishing_contents", "version_id", "version_uuid"},
    # Group F: Shop
    {"phoenix_kit_shop_categories", "image_id", "image_uuid"},
    {"phoenix_kit_shop_products", "featured_image_id", "featured_image_uuid"},
    {"phoenix_kit_shop_products", "file_id", "file_uuid"},
    # Group G: Scheduled Jobs
    {"phoenix_kit_scheduled_jobs", "resource_id", "resource_uuid"}
  ]

  def up(%{prefix: prefix} = _opts) do
    escaped_prefix = if prefix && prefix != "public", do: prefix, else: "public"
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # CRITICAL: flush pending migration commands
    flush()

    for {table, old_col, new_col} <- @tables_and_columns do
      execute("""
      DO $$ BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{escaped_prefix}'
          AND table_name = '#{table}'
          AND column_name = '#{old_col}'
        ) THEN
          ALTER TABLE #{prefix_str}#{table} RENAME COLUMN #{old_col} TO #{new_col};
        END IF;
      END $$;
      """)
    end
  end

  def down(%{prefix: prefix} = _opts) do
    # Reverse renames
    escaped_prefix = if prefix && prefix != "public", do: prefix, else: "public"
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    flush()

    for {table, old_col, new_col} <- @tables_and_columns do
      execute("""
      DO $$ BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{escaped_prefix}'
          AND table_name = '#{table}'
          AND column_name = '#{new_col}'
        ) THEN
          ALTER TABLE #{prefix_str}#{table} RENAME COLUMN #{new_col} TO #{old_col};
        END IF;
      END $$;
      """)
    end
  end
end
```

---

## Execution Order

1. **Create V62 migration file** (`lib/phoenix_kit/migrations/postgres/v62.ex`)
2. **Update `postgres.ex`** — bump `@current_version` to 62, add V62 docs
3. **Update ALL schema files** (see Schema File Reference above)
4. **Search & update ALL context/query files** (use ast-grep + rg)
5. **Update unique constraint names in schemas** that reference old column names
6. **Compile** — `mix compile --warnings-as-errors` (will catch missed references)
7. **Format** — `mix format`
8. **Credo** — `mix credo --strict`
9. **Test** — `mix test`
10. **Update version** — `mix.exs` to 1.7.46, `CHANGELOG.md`, `CLAUDE.md`

**Important:** Steps 2-4 must happen together. The migration renames DB columns, and the schema/context changes match. If only one side is updated, the app breaks.

---

## Post-Deployment (Parent App)

After merging to main/dev:

1. Update parent app dependency: `mix deps.update phoenix_kit`
2. Generate migration: `mix phoenix_kit.gen.migration` or `mix phoenix_kit.update`
3. Run migration: `mix ecto.migrate`
4. Verify: check that queries work, no column-not-found errors

---

## Verification Query

Run after migration to confirm no UUID columns with `_id` suffix remain:

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_name LIKE 'phoenix_kit_%'
  AND udt_name = 'uuid'
  AND column_name LIKE '%_id'
  AND column_name != 'uuid'
ORDER BY table_name, column_name;
```

Expected result: empty (or only `uuid` identity columns, which don't have `_id` suffix).

**Update 2026-02-26:** ✅ V62-V65 migrations completed successfully.

## Final Status

### Database Migration (V62)
- ✅ All 35 UUID-type columns renamed from `_id` to `_uuid` suffix
- ✅ All operations idempotent with existence checks
- ✅ Applied to 25 tables across 7 modules

### Codebase Cleanup (V63-V65)
- ✅ All legacy `_id` integer fields removed from schemas
- ✅ All dual-write code eliminated
- ✅ All pattern match bugs fixed
- ✅ All context functions updated to UUID-only
- ✅ All documentation updated

### Verification
- ✅ 485 tests passing
- ✅ Compilation with `--warnings-as-errors` clean
- ✅ Credo strict mode clean
- ✅ Code formatting applied

**Result:** PhoenixKit is now fully UUID-based with no legacy integer field dependencies.
