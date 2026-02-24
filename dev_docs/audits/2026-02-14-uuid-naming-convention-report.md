# UUID Naming Convention Report

**Date:** 2026-02-14
**Status:** Analysis Complete — Decision Required

---

## Executive Summary

PhoenixKit has **two distinct primary key patterns** across its schemas. The project convention states that `id` = integer column and `uuid` = UUID column. However, 25 schemas created with UUID-native primary keys use `id` as the UUID column name, violating this convention. This report documents the affected schemas, explains the connections module situation (raised by leadership), and provides options for resolution.

---

## 1. The Two Primary Key Patterns

### Pattern 1: Migrated Tables (Convention-Compliant)

Tables that existed before the UUID migration. They have both column types:

| Column | Type | Role |
|--------|------|------|
| `id` | `BIGSERIAL` | Legacy integer PK (auto-increment) |
| `uuid` | `UUID` | New UUID PK (UUIDv7) |

**Schema declaration:**
```elixir
@primary_key {:uuid, UUIDv7, autogenerate: true}
```

**Modules using this pattern:** Billing, Emails, Entities, AI, Shop, Sync, Referrals, Legal

These tables follow the naming convention correctly.

### Pattern 2: UUID-Native Tables (Convention Violation)

Tables created after the UUID migration decision. The `id` column IS a UUID:

| Column | Type | Role |
|--------|------|------|
| `id` | `UUID` | UUID primary key (no integer column exists) |

**Schema declaration:**
```elixir
@primary_key {:id, UUIDv7, autogenerate: true}
```

**These tables have NO integer `id` column.** The naming is misleading because `record.id` returns a UUID, not an integer.

---

## 2. All 25 Affected Schemas (Pattern 2)

### Comments Module (3 schemas)
| Schema | File | Migration |
|--------|------|-----------|
| `Comment` | `lib/modules/comments/comment.ex` | V55 |
| `CommentLike` | `lib/modules/comments/comment_like.ex` | V55 |
| `CommentDislike` | `lib/modules/comments/comment_dislike.ex` | V55 |

### Posts Module (10 schemas)
| Schema | File | Migration |
|--------|------|-----------|
| `Post` | `lib/modules/posts/post.ex` | V29 |
| `PostComment` | `lib/modules/posts/post_comment.ex` | V29 |
| `PostGroup` | `lib/modules/posts/post_group.ex` | V29 |
| `PostTag` | `lib/modules/posts/post_tag.ex` | V29 |
| `PostMedia` | `lib/modules/posts/post_media.ex` | V29 |
| `PostMention` | `lib/modules/posts/post_mention.ex` | V29 |
| `PostView` | `lib/modules/posts/post_view.ex` | V29 |
| `PostLike` | `lib/modules/posts/post_like.ex` | V29 |
| `PostDislike` | `lib/modules/posts/post_dislike.ex` | V29 |

### Connections Module (6 schemas)
| Schema | File | Migration |
|--------|------|-----------|
| `Connection` | `lib/modules/connections/connection.ex` | V36 |
| `ConnectionHistory` | `lib/modules/connections/connection_history.ex` | V36 |
| `Follow` | `lib/modules/connections/follow.ex` | V36 |
| `FollowHistory` | `lib/modules/connections/follow_history.ex` | V36 |
| `Block` | `lib/modules/connections/block.ex` | V36 |
| `BlockHistory` | `lib/modules/connections/block_history.ex` | V36 |

### Storage Module (5 schemas)
| Schema | File | Migration |
|--------|------|-----------|
| `Bucket` | `lib/modules/storage/bucket.ex` | V20 |
| `Dimension` | `lib/modules/storage/dimension.ex` | V20 |
| `File` | `lib/modules/storage/file.ex` | V20 |
| `FileInstance` | `lib/modules/storage/file_instance.ex` | V20 |
| `FileLocation` | `lib/modules/storage/file_location.ex` | V20 |

### Tickets Module (4 schemas)
| Schema | File | Migration |
|--------|------|-----------|
| `Ticket` | `lib/modules/tickets/ticket.ex` | V35 |
| `TicketAttachment` | `lib/modules/tickets/ticket_attachment.ex` | V35 |
| `TicketComment` | `lib/modules/tickets/ticket_comment.ex` | V35 |
| `TicketStatusHistory` | `lib/modules/tickets/ticket_status_history.ex` | V35 |

---

## 3. Connections Module Deep-Dive (Boss Question)

### What the Boss Saw

The connections module schemas contain `belongs_to` associations with `type: :integer`:

```elixir
# From connection.ex
belongs_to :requester, User, type: :integer
belongs_to :recipient, User, type: :integer

# From follow.ex
belongs_to :follower, User, type: :integer
belongs_to :followed, User, type: :integer

# From block.ex
belongs_to :blocker, User, type: :integer
belongs_to :blocked, User, type: :integer
```

### Why This Is Correct

The `type: :integer` declaration is **accurate and required**. Here's why:

**The V36 migration (connections tables) created FK columns as BIGINT:**

```sql
-- From lib/phoenix_kit/migrations/postgres/v36.ex
create table(:phoenix_kit_connections, primary_key: false) do
  add(:id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
  add(:requester_id, references(:phoenix_kit_users, type: :bigint), null: false)
  add(:recipient_id, references(:phoenix_kit_users, type: :bigint), null: false)
  -- ...
end
```

**What this means in the database:**

| Column | DB Type | References | Purpose |
|--------|---------|------------|---------|
| `id` | `UUID` | (primary key) | Record identifier |
| `requester_id` | `BIGINT` | `phoenix_kit_users(id)` | Integer FK to users table |
| `recipient_id` | `BIGINT` | `phoenix_kit_users(id)` | Integer FK to users table |
| `requester_uuid` | `UUID` | (no FK constraint) | Dual-write UUID field (V56) |
| `recipient_uuid` | `UUID` | (no FK constraint) | Dual-write UUID field (V56) |

The `phoenix_kit_users` table has an integer `id` column (BIGSERIAL) and a separate `uuid` column. The connections FK columns point to the **integer** `id`, so `type: :integer` in the Ecto schema is the correct type declaration.

### The Dual-Write UUID Fields

V56 added `*_uuid` columns to connections tables for the UUID migration:

```elixir
# These are plain fields, NOT belongs_to associations
field :requester_uuid, UUIDv7
field :recipient_uuid, UUIDv7
```

These UUID fields:
- Have NO foreign key constraints in the database
- Cannot be used for Ecto `preload` (no `belongs_to` association)
- Are populated via dual-write triggers/callbacks
- Will eventually replace the integer FKs in Phase 4 of the UUID migration

### The Actual Naming Issue

The confusing part is **not** the `type: :integer` on FKs. The issue is that `connection.id` returns a UUID value despite being named `id`. This is the Pattern 2 violation described in this report.

---

## 4. How Each Module's DB Columns Actually Look

### Example: Connections `phoenix_kit_connections` Table

```
Column          | Type    | Notes
----------------|---------|----------------------------------
id              | UUID    | PK (UUIDv7) — naming violation
requester_id    | BIGINT  | FK → phoenix_kit_users(id) — correct integer
recipient_id    | BIGINT  | FK → phoenix_kit_users(id) — correct integer
requester_uuid  | UUID    | Dual-write field (V56) — no FK
recipient_uuid  | UUID    | Dual-write field (V56) — no FK
status          | VARCHAR |
inserted_at     | TIMESTAMP |
updated_at      | TIMESTAMP |
```

### Example: Tickets `phoenix_kit_tickets` Table

```
Column          | Type    | Notes
----------------|---------|----------------------------------
id              | UUID    | PK (UUIDv7) — naming violation
user_id         | BIGINT  | FK → phoenix_kit_users(id) — correct integer
user_uuid       | UUID    | Dual-write field (V56) — no FK
subject         | VARCHAR |
description     | TEXT    |
status          | VARCHAR |
priority        | VARCHAR |
inserted_at     | TIMESTAMP |
updated_at      | TIMESTAMP |
```

### Common Pattern Across All 25 Schemas

- **PK column:** `id` is UUID type (should be named `uuid` per convention)
- **User FKs:** `user_id` / `requester_id` etc. are BIGINT (correctly named, correctly typed)
- **Dual-write fields:** `*_uuid` columns are UUID (correctly named, added by V56)

---

## 5. What Fixing the Convention Would Require

Renaming `id` → `uuid` on Pattern 2 tables is a **heavy database migration**:

### Per Table:
1. Drop all FK constraints from child tables pointing to `table(id)`
2. Rename column: `ALTER TABLE table RENAME COLUMN id TO uuid`
3. Add new integer column: `ALTER TABLE table ADD COLUMN id BIGSERIAL`
4. Recreate all FK constraints pointing to `table(uuid)` instead of `table(id)`
5. Update all Ecto schemas: `@primary_key {:uuid, UUIDv7, ...}`
6. Update all `belongs_to` references in child schemas
7. Update all queries, routes, and templates using `.id`

### Scale of Impact:

| Module | Tables | Child FK References |
|--------|--------|---------------------|
| Posts | 9 | PostComment, PostTag, PostMedia, PostMention, PostView, PostLike, PostDislike all reference Post |
| Connections | 6 | History tables reference main tables |
| Storage | 5 | FileInstance, FileLocation reference File; Dimension references Bucket |
| Tickets | 4 | TicketComment, TicketAttachment, TicketStatusHistory reference Ticket |
| Comments | 3 | CommentLike, CommentDislike reference Comment |
| **Total** | **27 tables** | **50+ FK relationships** |

### Additional Impact:
- All `phx-value-id` in templates need updating to `phx-value-uuid`
- All route params using `:id` need updating to `:uuid`
- All context functions using `get_by_id` need updating
- Parent app code referencing these schemas will break

---

## 6. Options

### Option A: Full Convention Fix (Heavy)
- Rename `id` → `uuid` in DB and schemas for all 25 schemas
- Add integer `id` columns for consistency with Pattern 1
- **Pros:** Single consistent convention across all schemas
- **Cons:** V57+ migration touching 27 tables and 50+ FKs; breaking change for parent apps

### Option B: Schema-Only Fix (Medium)
- Keep DB column named `id` but alias it in Ecto schema:
  ```elixir
  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  ```
- Elixir code uses `.uuid`, DB column stays `id`
- **Pros:** No DB migration needed; convention-compliant in code
- **Cons:** Schema/DB name mismatch can confuse debugging; `source: :id` adds cognitive overhead

### Option C: Document the Two Patterns (Light)
- Accept that Pattern 2 tables use `id` as UUID
- Document the convention clearly in CLAUDE.md and dev guides
- Add code comments in each Pattern 2 schema
- **Pros:** Zero migration risk; no breaking changes
- **Cons:** Two conventions in the codebase; ongoing confusion potential

### Option D: Fix Going Forward Only (Pragmatic)
- New tables follow Pattern 1 convention (integer `id` + UUID `uuid`)
- Existing Pattern 2 tables remain as-is but are documented
- **Pros:** Prevents further divergence; no migration risk
- **Cons:** Still two patterns, but clearly delineated by creation date

---

## 7. Recommendation

**Option B (Schema-Only Fix)** offers the best balance:

- No database migration required
- Code convention becomes consistent: `.uuid` always returns UUID
- Ecto's `source:` option is well-supported and commonly used
- Can be done incrementally, one module at a time
- No breaking changes to database or FK constraints

If Option B is chosen, each Pattern 2 schema changes from:
```elixir
@primary_key {:id, UUIDv7, autogenerate: true}
```
to:
```elixir
@primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
```

And all code referencing `record.id` changes to `record.uuid`.

---

## Appendix: Quick Reference

### Convention Rule
| Name | Type | Example Value |
|------|------|---------------|
| `id` | Integer (BIGSERIAL) | `42` |
| `uuid` | UUID (UUIDv7) | `019503a1-2b3c-7def-8012-3456789abcde` |

### Pattern 1 (Compliant) — 8 modules
Billing, Emails, Entities, AI, Shop, Sync, Referrals, Legal

### Pattern 2 (Violation) — 5 modules, 25 schemas
Comments (3), Posts (10), Connections (6), Storage (5), Tickets (4)

### Connections Module TL;DR for Leadership
- `belongs_to :requester, User, type: :integer` — **correct**, the DB FK column is BIGINT
- `connection.id` returning a UUID — **naming violation** of the convention (this report's main finding)
- The `*_uuid` dual-write fields are working correctly for the UUID migration
