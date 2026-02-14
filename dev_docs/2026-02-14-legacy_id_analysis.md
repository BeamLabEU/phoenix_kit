# Legacy ID Field Analysis - PhoenixKit UUIDv7 Migration

**Last updated:** 2026-02-14 (post PR #337 merge)

## Executive Summary
Found multiple instances where the codebase still references the legacy `:id` field instead of `:uuid`. This analysis identifies all the problematic areas that need to be updated for complete UUIDv7 migration.

## Progress Update (PR #337 - Merged 2026-02-14)

PR #337 addressed several issues from this analysis and added critical clarification:

### Resolved / Clarified
- **Connections module `type: :integer`** — After investigation, this is **CORRECT**. The V36 migration created FK columns as BIGINT referencing `phoenix_kit_users(id)`. The `type: :integer` in `belongs_to` accurately reflects the DB schema. See `dev_docs/uuid_naming_convention_report.md` for full analysis.
- **Billing form assigns** — Renamed `*_id` assigns to `*_uuid` in `order_form.ex`, `subscription_form.ex`, `billing_profile_form.ex` and their templates.
- **13 LiveViews** — Applied `dashboard_assigns()` instead of passing raw assigns to `Layouts.dashboard`.
- **16 alias-in-function-body** instances moved to module level across publishing, shop, emails, and update task modules.

### New Finding: Two Primary Key Patterns
PR #337 added `dev_docs/uuid_naming_convention_report.md` identifying **25 schemas** that use `@primary_key {:id, UUIDv7, ...}` (Pattern 2) where the `id` column is actually a UUID. These are NOT the same issue as schemas with `field :id, :integer`. Decision pending on how to resolve (Options A-D in the report).

### Still Outstanding
All items below remain unfixed unless marked otherwise.

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

### ~~Connections Module - Using `type: :integer`~~ ✅ NOT A BUG (PR #337)
~~These relationships explicitly use `:integer` type instead of UUIDv7:~~

**Clarified by PR #337:** The `type: :integer` declarations are **correct**. The V36 migration created these FK columns as `BIGINT` referencing `phoenix_kit_users(id)`. The integer FKs coexist with dual-write `*_uuid` fields added by V56. These will be migrated to UUID FKs in Phase 4 of the UUID migration.

- `lib/modules/connections/follow.ex:45-46` — `type: :integer` is correct (FK is BIGINT)
- `lib/modules/connections/block_history.ex:22-23` — `type: :integer` is correct
- `lib/modules/connections/block.ex:50-51` — `type: :integer` is correct
- `lib/modules/connections/connection_history.ex:29-30` — `type: :integer` is correct

### Comments Module - Using `foreign_key: :parent_id`
- `lib/modules/comments/schemas/comment.ex:64`
  ```elixir
  has_many :children, __MODULE__, foreign_key: :parent_id
  ```
  Should use `foreign_key: :parent_uuid`

### Tickets Module - Using `foreign_key: :parent_id` and `foreign_key: :comment_id`
- `lib/modules/tickets/ticket_comment.ex:88-89`
  ```elixir
  has_many :children, __MODULE__, foreign_key: :parent_id
  has_many :attachments, PhoenixKit.Modules.Tickets.TicketAttachment, foreign_key: :comment_id
  ```
  Should use `foreign_key: :parent_uuid` and `foreign_key: :comment_uuid`

## 3. Direct .id Field Access in Code

### Email Export Task
- `lib/mix/tasks/phoenix_kit/email_export.ex:176,253`
  ```elixir
  events = Emails.list_events_for_log(log.id)
  log.id,
  ```

### Email Verify Config Task
- `lib/mix/tasks/phoenix_kit/email_verify_config.ex:297`
  ```elixir
  retrieved_log <- Emails.get_log!(log.id),
  ```

### Referrals Module
- `lib/modules/referrals/referrals.ex:415,819`
  ```elixir
  code_id: code.id,
  from(r in __MODULE__, where: r.created_by == ^user_id, select: count(r.id))
  ```

- `lib/modules/referrals/web/form.ex:49,80,105,249,252`
  ```elixir
  |> Map.put("beneficiary", beneficiary.id)
  |> Map.put("created_by", user.id)
  {params, user.id}
  ```

### Sync Module
- `lib/modules/sync/connection.ex:504`
  ```elixir
  from(u in User, where: u.id == ^user_id, select: u.uuid)
  ```

### Shop Deduplication Task
- `lib/mix/tasks/shop.deduplicate_products.ex:119,122,130,147`
  ```elixir
  products = repo.all(from(p in Product, where: p.id in ^ids))
  Mix.shell().info("    ID #{product.id}: #{inspect(product.title)}")
  remove_products = repo.all(from(p in Product, where: p.id in ^remove_ids))
  repo.delete_all(from(p in Product, where: p.id in ^remove_ids))
  ```

### Entities Export Task
- `lib/mix/tasks/phoenix_kit/entities/export.ex:137,157`
  ```elixir
  data_records = if include_data, do: EntityData.list_data_by_entity(entity.id), else: []
  ```

### Sync Email Status Task
- `lib/mix/tasks/phoenix_kit/sync_email_status.ex:155`
  ```elixir
  IO.puts("📧 Found existing email log: ID=#{log.id}, Status=#{log.status}")
  ```

### Admin Presence
- `lib/phoenix_kit/admin/simple_presence.ex:59`
  ```elixir
  key = "user:#{user.id}"
  ```

## 4. Additional Issues Found

### Sync Module - Missing `references: :uuid`
The sync connection module has several `belongs_to` relationships that use UUID foreign keys but don't specify `references: :uuid`:

- `lib/modules/sync/connection.ex:126-129,134-137,142-145,150-153`
  ```elixir
  belongs_to :approved_by_user, User,
    foreign_key: :approved_by_uuid,
    type: UUIDv7
  
  belongs_to :suspended_by_user, User,
    foreign_key: :suspended_by_uuid,
    type: UUIDv7
  
  belongs_to :revoked_by_user, User,
    foreign_key: :revoked_by_uuid,
    type: UUIDv7
  
  belongs_to :created_by_user, User,
    foreign_key: :created_by_uuid,
    type: UUIDv7
  ```

These should include `references: :uuid` to be explicit and avoid potential issues.

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

### High Priority
- ~~`lib/modules/connections/*.ex` - All connection schemas~~ ✅ `type: :integer` is correct (PR #337 clarification)
- `lib/modules/comments/schemas/comment.ex` - Comment relationships (`foreign_key: :parent_id`)
- `lib/modules/tickets/ticket_comment.ex` - Ticket comment relationships (`foreign_key: :parent_id`, `:comment_id`)
- `lib/modules/referrals/referrals.ex` and `lib/modules/referrals/web/form.ex` - Referral code `.id` usage

### Medium Priority
- All schema files that still have `field :id, :integer`
- Email export and verification tasks
- Shop deduplication task
- Entities export task
- ~~Billing form assigns using `*_id`~~ ✅ Fixed in PR #337

### Low Priority (but should be updated)
- Admin presence tracking
- Sync module relationship specifications (missing `references: :uuid`)

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

- [ ] All schemas use `field :uuid, UUIDv7` instead of `field :id, :integer`
- [ ] All `belongs_to` relationships specify `references: :uuid` when using UUID foreign keys
- [ ] All foreign key names use `_uuid` suffix instead of `_id`
- [ ] All direct field access uses `.uuid` instead of `.id`
- [ ] All database queries use `:uuid` instead of `:id`
- [ ] All Ecto queries updated to use UUID fields
- [ ] All admin interfaces tested with UUIDs
- [ ] Data migration scripts created and tested
- [ ] Decide on Pattern 2 resolution (see `dev_docs/uuid_naming_convention_report.md`, Options A-D)
- [x] Connections module `type: :integer` — confirmed correct (PR #337)
- [x] Billing form assigns renamed `*_id` → `*_uuid` (PR #337)
- [x] Dashboard assigns optimized with `dashboard_assigns()` (PR #337)
- [x] Alias-in-function-body instances moved to module level (PR #337)