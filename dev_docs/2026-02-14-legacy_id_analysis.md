# Legacy ID Field Analysis - PhoenixKit UUIDv7 Migration

**Last updated:** 2026-02-15 (all critical issues + Pattern 2 resolved)

## Executive Summary
Originally found 50+ instances where the codebase referenced the legacy `:id` field instead of `:uuid`. **All critical issues have been resolved** across 5 commits + Pattern 2 migration. Pattern 2 is now fully resolved (29 schemas migrated to `{:uuid, UUIDv7, source: :id}`). The only remaining work is Phase 4 integer column removal.

## Progress Update

### PR #337 (2026-02-14)
- **Connections module `type: :integer`** — Confirmed CORRECT per V36 migration. See `dev_docs/uuid_naming_convention_report.md`.
- **Billing form assigns** — Renamed `*_id` → `*_uuid` in 3 form modules + templates.
- **13 LiveViews** — Applied `dashboard_assigns()` optimization.
- **16 alias-in-function-body** instances moved to module level.
- **New Finding:** 25 Pattern 2 schemas (`@primary_key {:id, UUIDv7}`) — decision pending (Options A-D in `uuid_naming_convention_report.md`).

### Post-PR #337 Session (2026-02-15) — 5 commits
- **commit 8958ccbf** — Connections module: 6 schemas + context + web layer migrated to UUID
- **commit a1130364** — Referrals module: context + form migrated to UUID
- **commit be76a2af** — Comments/Tickets: 4 schemas + context + component migrated to UUID
- **commit e5a52a4c** — Mix tasks + admin presence: all `.id` → `.uuid`
- **commit ccd3f089** — Posts (9) + Tickets (2) + Storage (1): `belongs_to :user` migrated to UUID

### Pattern 2 Resolution (2026-02-15) — unstaged
Implemented **Option B** from `uuid_naming_convention_report.md`: schema-only fix with `source: :id`.

- **29 schemas** migrated: `@primary_key {:id, UUIDv7, autogenerate: true}` → `{:uuid, UUIDv7, autogenerate: true, source: :id}`
  - Comments: `comment.ex`, `comment_dislike.ex`, `comment_like.ex` (3)
  - Connections: `block.ex`, `block_history.ex`, `connection.ex`, `connection_history.ex`, `follow.ex`, `follow_history.ex` (6)
  - Posts: `post.ex`, `post_comment.ex`, `post_like.ex`, `post_dislike.ex`, `post_view.ex`, `post_mention.ex`, `post_group.ex`, `post_media.ex`, `post_tag.ex`, `comment_like.ex`, `comment_dislike.ex` (11)
  - Storage: `bucket.ex`, `dimension.ex`, `file.ex`, `file_instance.ex`, `file_location.ex` (5)
  - Tickets: `ticket.ex`, `ticket_attachment.ex`, `ticket_comment.ex`, `ticket_status_history.ex` (4)
- **2 composite-PK schemas discovered:** `post_group_assignment.ex`, `post_tag_assignment.ex` — added missing `references: :uuid` to `belongs_to` associations
- **10 `has_many` associations** received explicit `foreign_key:` — required because Ecto defaults to inferring FK from the parent's primary key name (now `:uuid` instead of `:id`)
  - `post.ex`: 5 (`:media`, `:likes`, `:dislikes`, `:comments`, `:mentions`)
  - `bucket.ex`: 1 (`:file_locations`)
  - `file.ex`: 1 (`:instances`)
  - `file_instance.ex`: 1 (`:locations`)
  - `ticket.ex`: 2 (`:comments`, `:attachments`)
- **Bug fix: `@foreign_key_type :id` → `UUIDv7`** in 3 history schemas (`block_history.ex`, `connection_history.ex`, `follow_history.ex`) — previously caused Ecto to default `belongs_to` types to `:id` instead of `UUIDv7`
- **Context/web layer updates:** `posts.ex`, `comments.ex`, `tickets.ex`, `storage.ex`, plus web layers — all `.id` access → `.uuid`
- **Additional fix:** `upload_controller.ex` — `existing_file.id` → `existing_file.uuid`

## 1. Schemas Still Using :id as Primary Key

The following schemas still define `field :id, :integer` instead of using UUIDv7:

### Core Modules
- `lib/phoenix_kit/settings/setting.ex`
- `lib/phoenix_kit/users/role_assignment.ex`
- `lib/phoenix_kit/users/oauth_provider.ex`
- `lib/phoenix_kit/users/admin_note.ex`
- `lib/phoenix_kit/users/role_permission.ex`
- `lib/phoenix_kit/users/role.ex`
- `lib/phoenix_kit/users/auth/user.ex`
- `lib/phoenix_kit/users/auth/user_token.ex`
- `lib/phoenix_kit/audit_log/entry.ex`

### AI Module
- `lib/modules/ai/prompt.ex`
- `lib/modules/ai/endpoint.ex`
- `lib/modules/ai/request.ex`

### Entities Module
- `lib/modules/entities/entities.ex`
- `lib/modules/entities/entity_data.ex`

### Legal Module
- `lib/modules/legal/schemas/consent_log.ex`

### Shop Module
- `lib/modules/shop/schemas/cart_item.ex`
- `lib/modules/shop/schemas/shipping_method.ex`
- `lib/modules/shop/schemas/cart.ex`
- `lib/modules/shop/schemas/product.ex`

## 2. Relationships Still Referencing Legacy ID Field

### ~~Connections Module - Using `type: :integer`~~ ✅ MIGRATED TO UUID (commit 8958ccbf)
All 6 connection schemas migrated from `belongs_to :user, type: :integer` to UUID-based associations. Context module updated for UUID-primary queries with dual-write.

### ~~Comments Module - Using `foreign_key: :parent_id`~~ ✅ FIXED (Pattern 2 Resolution)
- `has_many :children, __MODULE__, foreign_key: :parent_id` — was correct before, still correct after. `parent_id` IS a UUID column in DB.
- `belongs_to :parent` now includes `references: :uuid` to match renamed primary key field.

### ~~Tickets Module - Using `foreign_key: :parent_id` and `foreign_key: :comment_id`~~ ✅ FIXED (Pattern 2 Resolution)
- Same as comments — `parent_id` and `comment_id` columns store UUIDs.
- All `has_many` associations received explicit `foreign_key:` to prevent Ecto from inferring `:uuid_id` as the FK name.

## 3. ~~Direct .id Field Access in Code~~ ✅ ALL FIXED

All instances below have been resolved:

- ~~`email_export.ex:176,253`~~ — ✅ Fixed (commit e5a52a4c): `log.id` → `log.uuid`
- ~~`email_verify_config.ex:297`~~ — ✅ Fixed (commit e5a52a4c): `log.id` → `log.uuid`
- ~~`referrals.ex:415,819`~~ — ✅ Fixed (commit a1130364): UUID-primary with dual-write
- ~~`referrals/web/form.ex:49,80,105,249,252`~~ — ✅ Fixed (commit a1130364): UUID identifiers
- ~~`shop.deduplicate_products.ex:119,122,130,147`~~ — ✅ Fixed (commit e5a52a4c): Full UUID rewrite
- ~~`entities/export.ex:137,157`~~ — ✅ Fixed (commit e5a52a4c): `entity.id` → `entity.uuid`
- ~~`simple_presence.ex:59`~~ — ✅ Fixed (commit e5a52a4c): `user.id` → `user.uuid`
- ~~`sync_email_status.ex:155`~~ — File no longer exists
- `sync/connection.ex:504` — `from(u in User, where: u.id == ^user_id, select: u.uuid)` — This is a `resolve_user_uuid` helper that intentionally queries by integer id. Correct behavior.

## 4. ~~Additional Issues Found~~ ✅ VERIFIED

### ~~Sync Module - Missing `references: :uuid`~~ ✅ NOT A BUG
Verified that `lib/modules/sync/connection.ex` and `transfer.ex` already include `references: :uuid` on all 4 `belongs_to` User relationships. The original report was incorrect.

## Migration Recommendations

### Phase 1: Schema Updates
1. **Update all schemas** to replace `field :id, :integer` with `field :uuid, UUIDv7`
2. **Add UUIDv7 fields** to all schemas that don't have them yet
3. **Update primary key** references in all schemas

### Phase 2: Relationship Updates
1. **Update all `belongs_to` relationships** to use `references: :uuid` where appropriate
2. **Update foreign key names** from `_id` to `_uuid`
3. **Update `has_many` relationships** to use UUID foreign keys

### Phase 3: Code Updates
1. **Replace all `.id` access** with `.uuid`
2. **Update database queries** to use `:uuid` instead of `:id`
3. **Update Ecto queries** in tasks and modules

### Phase 4: Testing
1. **Run comprehensive tests** to ensure all relationships work correctly
2. **Test data migration** from legacy IDs to UUIDs
3. **Verify all admin interfaces** work with UUIDs

## Critical Files to Update

### ~~High Priority~~ ✅ ALL RESOLVED
- ~~`lib/modules/connections/*.ex`~~ ✅ Migrated to UUID (commit 8958ccbf)
- ~~`lib/modules/comments/schemas/comment.ex`~~ ✅ Not a bug (Pattern 2) + `belongs_to :user` fixed (commit be76a2af)
- ~~`lib/modules/tickets/ticket_comment.ex`~~ ✅ Not a bug (Pattern 2) + `belongs_to :user` fixed (commit be76a2af)
- ~~`lib/modules/referrals/referrals.ex` and `form.ex`~~ ✅ Fixed (commit a1130364)

### ~~Medium Priority~~ ✅ ALL RESOLVED
- ~~Email export and verification tasks~~ ✅ Fixed (commit e5a52a4c)
- ~~Shop deduplication task~~ ✅ Fixed (commit e5a52a4c)
- ~~Entities export task~~ ✅ Fixed (commit e5a52a4c)
- ~~Billing form assigns~~ ✅ Fixed in PR #337
- ~~Posts schemas (9 files)~~ ✅ Fixed (commit ccd3f089)
- ~~Tickets schemas (2 files)~~ ✅ Fixed (commit ccd3f089)
- ~~Storage file schema~~ ✅ Fixed (commit ccd3f089)

### ~~Low Priority~~ ✅ ALL RESOLVED
- ~~Admin presence tracking~~ ✅ Fixed (commit e5a52a4c)
- ~~Sync module~~ ✅ Already correct (verified)

### Still Remaining (Non-Critical)
- ~~Pattern 2 schemas~~ ✅ RESOLVED — all 29 Pattern 2 schemas migrated
- 20+ core/feature schemas still have `field :id, :integer` — these are NOT broken (dual columns), awaiting Phase 4 cleanup
- Dual-write integer fields will be removed in Phase 4

## Pattern for Correct UUID Relationships

```elixir
# Correct pattern for UUIDv7 relationships
belongs_to :user, User,
  foreign_key: :user_uuid,
  references: :uuid,
  type: UUIDv7

has_many :items, Item,
  foreign_key: :owner_uuid,
  references: :uuid
```

## Verification Checklist

### Completed
- [x] Connections module `type: :integer` — confirmed correct (PR #337), then migrated to UUID (commit 8958ccbf)
- [x] Billing form assigns renamed `*_id` → `*_uuid` (PR #337)
- [x] Dashboard assigns optimized with `dashboard_assigns()` (PR #337)
- [x] Alias-in-function-body instances moved to module level (PR #337)
- [x] Referrals module — UUID-primary with dual-write (commit a1130364)
- [x] Comments/Tickets schemas — `belongs_to :user` migrated to UUID (commit be76a2af)
- [x] Comments context — all CRUD operations accept UUID (commit be76a2af)
- [x] Mix tasks and admin presence — `.id` → `.uuid` (commit e5a52a4c)
- [x] Posts schemas (9 files) — `belongs_to :user` migrated to UUID (commit ccd3f089)
- [x] Tickets schemas (2 files) — `belongs_to :user` migrated to UUID (commit ccd3f089)
- [x] Storage file schema — `belongs_to :user` migrated to UUID (commit ccd3f089)
- [x] All `belongs_to` relationships specify `references: :uuid` when using UUID foreign keys
- [x] All foreign key names use `_uuid` suffix instead of `_id` for UUID associations
- [x] All direct field access uses `.uuid` instead of `.id` (where applicable)
- [x] All database queries in tasks updated to use UUID fields
- [x] Sync module verified correct (`references: :uuid` already present)
- [x] `has_many :children, foreign_key: :parent_id` verified correct (Pattern 2)

- [x] Pattern 2 resolved: 29 schemas migrated to `{:uuid, UUIDv7, source: :id}` (Option B)
- [x] 10 `has_many` associations updated with explicit `foreign_key:`
- [x] 3 history schemas: `@foreign_key_type :id` → `UUIDv7` bug fix
- [x] 2 composite-PK schemas: added `references: :uuid` to `belongs_to`
- [x] `upload_controller.ex`: `existing_file.id` → `existing_file.uuid`

### Remaining
- [ ] Remove dual-write integer columns (Phase 4 — requires DB migration)
- [ ] All admin interfaces tested with UUIDs