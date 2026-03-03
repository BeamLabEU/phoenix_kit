# UUIDv7 Migration Summary - Critical Issues Found

**Last updated:** 2026-03-03
**Status:** ALL PHASES COMPLETE — including Phase 4 (integer column removal, V72-V74)

> **Note:** This document is historical. The UUID migration is fully complete as of v1.7.57.
> All integer `id` columns, integer `_id` FK columns, `source: :id` mappings, dual-write code,
> `field :id, :integer, read_after_writes: true`, and `resolve_user_id`/`resolve_user_uuid`
> helpers have been removed. Every table uses `uuid` as PK. See
> `plans/2026-02-26-uuid-migration-completion-summary.md` for the final state.

## 🔍 Analysis Results

Found **50+ instances** of legacy `:id` field usage that need to be migrated to UUIDv7 across the PhoenixKit codebase. **All issues are now resolved**, including Pattern 2 and Phase 4 (integer column removal).

## ✅ Resolved by PR #337

- **Connections module `type: :integer`** — Confirmed CORRECT. DB FKs are BIGINT. Not a bug.
- **Billing form assigns** — Renamed `*_id` → `*_uuid` in 3 form modules + templates.
- **13 LiveViews** — Applied `dashboard_assigns()` optimization.
- **16 alias-in-function-body** instances moved to module level.
- **New analysis:** `dev_docs/uuid_naming_convention_report.md` documents 25 Pattern 2 schemas (`@primary_key {:id, UUIDv7}`) — decision pending.

## ✅ Resolved Post-PR #337 (2026-02-15)

### Connections Module (commit 8958ccbf)
- All 6 connection schemas migrated from `belongs_to :user, type: :integer` to UUID-based associations
- Context (`connections.ex`) updated: all queries filter by `*_uuid`, mutations use dual-write, history logging accepts both UUID + integer params
- Web layer (`user_connections.ex` + template) updated for UUID comparisons

### Referrals Module (commit a1130364)
- `referrals.ex`: `use_code/2` accepts UUID, `do_record_usage` dual-writes, added `resolve_user_id/1` and expanded `resolve_user_uuid/1`, `count_user_codes` uses `count(r.uuid)`
- `form.ex`: Fixed `select_beneficiary`, `load_form_data`, and `extract_user_info` for UUID

### Comments & Tickets Schemas (commit be76a2af)
- `comment.ex`, `comment_like.ex`, `comment_dislike.ex`, `ticket_comment.ex`: Swapped `belongs_to :user` from `type: :integer` to UUID-based
- `comments.ex` context: All CRUD operations accept UUID identifiers, added `resolve_user_uuid/1` and `resolve_user_id/1`
- `comments_component.ex`: Ownership check uses `user.uuid == comment.user_uuid`

### Mix Tasks & Admin Presence (commit e5a52a4c)
- `email_export.ex`: `log.id` → `log.uuid`
- `email_verify_config.ex`: `log.id` → `log.uuid`
- `entities/export.ex`: `entity.id` → `entity.uuid`
- `simple_presence.ex`: `user.id` → `user.uuid`
- `shop.deduplicate_products.ex`: Full rewrite — SQL aggregates UUIDs, queries by `p.uuid`, cart/order updates use `product_uuid`

### Posts, Tickets, Storage Schemas (commit ccd3f089)
- **Posts (9 files):** `post.ex`, `post_comment.ex`, `post_like.ex`, `post_dislike.ex`, `post_view.ex`, `post_mention.ex`, `post_group.ex`, `comment_like.ex`, `comment_dislike.ex`
- **Tickets (2 files):** `ticket.ex` (both `:user` and `:assigned_to`), `ticket_status_history.ex` (`:changed_by`)
- **Storage (1 file):** `file.ex`
- All swapped from `belongs_to :user, type: :integer` to `foreign_key: :user_uuid, references: :uuid, type: UUIDv7`

## ✅ Pattern 2 Resolved (2026-02-15)

Chose **Option B** (schema-only fix with `source: :id`) from `uuid_naming_convention_report.md`. No database migration needed — DB column stays `id`, Ecto maps it to the `:uuid` field via `source: :id`.

### Primary Key Migration (29 schemas)
`@primary_key {:id, UUIDv7, autogenerate: true}` → `{:uuid, UUIDv7, autogenerate: true, source: :id}`

| Module | Schemas | Count |
|--------|---------|-------|
| Comments | `comment`, `comment_dislike`, `comment_like` | 3 |
| Connections | `block`, `block_history`, `connection`, `connection_history`, `follow`, `follow_history` | 6 |
| Posts | `post`, `post_comment`, `post_like`, `post_dislike`, `post_view`, `post_mention`, `post_group`, `post_media`, `post_tag`, `comment_like`, `comment_dislike` | 11 |
| Storage | `bucket`, `dimension`, `file`, `file_instance`, `file_location` | 5 |
| Tickets | `ticket`, `ticket_attachment`, `ticket_comment`, `ticket_status_history` | 4 |

### Additional Fixes Discovered During Migration

- **2 composite-PK schemas** (`post_group_assignment.ex`, `post_tag_assignment.ex`): Added missing `references: :uuid` to `belongs_to` associations — without this, Ecto referenced the integer `:id` instead of UUID
- **10 `has_many` associations** received explicit `foreign_key:`: When the parent PK field is renamed from `:id` to `:uuid`, Ecto infers the FK as `:xxx_uuid_id` instead of `:xxx_id`. Added `foreign_key: :post_id`, `:bucket_id`, `:file_id`, `:file_instance_id`, `:ticket_id` as needed.
- **Bug fix: `@foreign_key_type :id` → `UUIDv7`** in 3 connection history schemas — `@foreign_key_type :id` caused Ecto to use `:id` type for `belongs_to` defaults instead of `UUIDv7`
- **`upload_controller.ex`**: `existing_file.id` → `existing_file.uuid` — was returning integer ID instead of UUID to caller
- **Context modules** (`posts.ex`, `comments.ex`, `tickets.ex`, `storage.ex`): All `.id` access → `.uuid`, query filters updated
- **Web layer** (details, edit LiveViews + templates): All route params and assigns updated from `.id` to `.uuid`

## ✅ Verified Not Bugs

- **`has_many :children, foreign_key: :parent_id`** in comments, tickets, posts — CORRECT. These are Pattern 2 schemas where `id` IS a UUIDv7. The `parent_id` column stores UUIDs, no `parent_uuid` column exists.
- **Sync module `references: :uuid`** — Already present on all 4 `belongs_to` User relationships in `connection.ex` and `transfer.ex`.
- **`sync_email_status.ex`** — File no longer exists.

## ✅ Phase 4: Integer Column Removal — COMPLETE (2026-03-03)

All items completed across V72-V74 (v1.7.54-v1.7.57):
- All `field :id, :integer, read_after_writes: true` removed from schemas
- All dual-write code removed from context modules
- All `resolve_user_id`/`resolve_user_uuid` helpers removed
- All integer `id` and `_id` columns dropped from database
- All `uuid` columns promoted to PK
- Presence helpers fixed to use `user_uuid` keys

## 📋 Migration Checklist

- [x] ~~Fix Connections module~~ — NOT A BUG (PR #337), then migrated to UUID (commit 8958ccbf)
- [x] Billing form assigns renamed `*_id` → `*_uuid` (PR #337)
- [x] 13 LiveViews: `dashboard_assigns()` optimization (PR #337)
- [x] 16 alias-in-function-body instances moved to module level (PR #337)
- [x] Fix Referrals module (`.id` access → `.uuid`) — commit a1130364
- [x] Fix Comments/Tickets schemas (`belongs_to :user, type: :integer`) — commit be76a2af
- [x] Fix Comments context for UUID identifiers — commit be76a2af
- [x] Replace `.id` with `.uuid` in mix tasks and admin presence — commit e5a52a4c
- [x] Fix Posts schemas (9 files, `belongs_to :user, type: :integer`) — commit ccd3f089
- [x] Fix Tickets schemas (2 files) — commit ccd3f089
- [x] Fix Storage file schema — commit ccd3f089
- [x] Verify `has_many :children, foreign_key: :parent_id` is correct (Pattern 2) — confirmed
- [x] Verify Sync module has `references: :uuid` — confirmed correct
- [x] Pattern 2 resolved: 29 schemas migrated to `{:uuid, UUIDv7, source: :id}` (Option B)
- [x] 10 `has_many` associations updated with explicit `foreign_key:`
- [x] 3 history schemas: `@foreign_key_type :id` → `UUIDv7` bug fix
- [x] 2 composite-PK schemas: added `references: :uuid`
- [x] `upload_controller.ex`: `.id` → `.uuid` fix
- [x] Drop integer columns and remove dual-write code (Phase 4) — V72-V74, v1.7.57

## ⚠️ Key Decisions Pending

### ~~Pattern 2 Primary Key Naming~~ ✅ RESOLVED
Chose **Option B** — schema-only fix with `source: :id`. All 29 Pattern 2 schemas migrated. See "Pattern 2 Resolved" section above.

### ~~Integer Column Removal (Phase 4)~~ — DONE (V72-V74, v1.7.57)

All integer columns dropped, all schemas cleaned, all dual-write removed. See `plans/2026-03-02-drop-integer-id-columns-plan.md`.

## 🔧 Quick Fix Pattern

**Before:**
```elixir
belongs_to :user, User, type: :integer
field :user_uuid, UUIDv7
```

**After:**
```elixir
belongs_to :user, User,
  foreign_key: :user_uuid,
  references: :uuid,
  type: UUIDv7

field :user_id, :integer
```
