# PhoenixKit Modules - UUID Status

**Last Updated**: 2026-02-02
**Reference PRs**: #311, #312, #313

This document tracks UUID implementation status across all PhoenixKit modules with database schemas.

## Status Overview

| Module | DB Schemas | UUID Status | Notes |
|--------|------------|-------------|-------|
| **AI** | 3 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Entities** | 2 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Billing** | 10 | ⚠️ Old Pattern | Has UUID, uses `maybe_generate_uuid` |
| **Shop** | 8 | ⚠️ Old Pattern | Has UUID, uses `maybe_generate_uuid` |
| **Emails** | 4 | ⚠️ Old Pattern | Has UUID, uses `maybe_generate_uuid` |
| **Sync** | 2 | ⚠️ Old Pattern | Has UUID, uses `maybe_generate_uuid` |
| **Referrals** | 2 | ⚠️ Old Pattern | Has UUID, uses `maybe_generate_uuid` |
| **Legal** | 1 | ⚠️ Old Pattern | Has UUID, uses `maybe_generate_uuid` |
| **Posts** | 13 | ❌ No UUID | Integer ID only |
| **Connections** | 6 | ❌ No UUID | Integer ID only |
| **Storage** | 5 | ❌ No UUID | Integer ID only |
| **Tickets** | 4 | ❌ No UUID | Integer ID only |
| **DB** | 0 | — | Utility module (no schemas) |
| **Languages** | 0 | — | Utility module (no schemas) |
| **Maintenance** | 0 | — | Uses Settings table |
| **Publishing** | 0 | — | File-based storage |
| **SEO** | 0 | — | Utility module (no schemas) |
| **Sitemap** | 0 | — | File-based generation |
| **Blogging** | 0 | — | Wrapper module |

## Legend

| Status | Meaning |
|--------|---------|
| ✅ New Standard | DB-generated UUID, `read_after_writes: true`, flexible `get/1` lookups |
| ⚠️ Old Pattern | Has UUID field but uses app-side `maybe_generate_uuid` |
| ❌ No UUID | No UUID field, uses integer ID only |
| — | No database schemas |

## Summary

| Category | Modules | Schemas |
|----------|---------|---------|
| ✅ New Standard | 2 | 5 |
| ⚠️ Old Pattern | 6 | 27 |
| ❌ No UUID | 4 | 28 |
| — No schemas | 7 | 0 |
| **Total** | **19** | **60** |

---

## New Standard Pattern

The new UUID standard (established in PR #311/#312, refined in #313) uses:

```elixir
schema "phoenix_kit_*" do
  # UUID for external references (URLs, APIs) - DB generates UUIDv7
  field :uuid, Ecto.UUID, read_after_writes: true
  # ... other fields
end
```

### Key Characteristics

1. **DB-generated UUIDs** - Database generates UUIDv7 via DEFAULT/trigger
2. **`read_after_writes: true`** - Ecto reads UUID back after INSERT
3. **No `maybe_generate_uuid/1`** - Removed from changeset pipeline
4. **Flexible lookups** - `get/1` accepts integer, UUID string, or string-integer
5. **Shared validation** - Uses `PhoenixKit.Utils.UUID.valid?/1`

### Lookup Function Pattern

```elixir
def get(id) when is_integer(id) do
  repo().get(__MODULE__, id) |> preload_associations()
end

def get(id) when is_binary(id) do
  if UUIDUtils.valid?(id) do
    repo().get_by(__MODULE__, uuid: id) |> preload_associations()
  else
    case Integer.parse(id) do
      {int_id, ""} -> get(int_id)
      _ -> nil
    end
  end
end

def get(_), do: nil
```

### ID Usage Rules

| Use Case | Field | Example |
|----------|-------|---------|
| URLs and external APIs | `.uuid` | `/items/#{item.uuid}/edit` |
| Foreign keys | `.id` | `parent_id: item.id` |
| Database queries | `.id` | `repo.get(Item, id)` |
| Stats map keys | `.id` | `Map.get(stats, item.id)` |
| Event handlers (phx-value) | `.id` | `phx-value-id={item.id}` |

---

## Detailed Schema Listing

### ✅ New Standard (5 schemas)

#### AI Module
- `lib/modules/ai/endpoint.ex` - `phoenix_kit_ai_endpoints`
- `lib/modules/ai/prompt.ex` - `phoenix_kit_ai_prompts`
- `lib/modules/ai/request.ex` - `phoenix_kit_ai_requests`

#### Entities Module
- `lib/modules/entities/entities.ex` - `phoenix_kit_entities`
- `lib/modules/entities/entity_data.ex` - `phoenix_kit_entity_data`

### ⚠️ Old Pattern (27 schemas)

#### Billing Module (10 schemas)
- `billing_profile.ex` - `phoenix_kit_billing_profiles`
- `currency.ex` - `phoenix_kit_currencies`
- `invoice.ex` - `phoenix_kit_invoices`
- `order.ex` - `phoenix_kit_orders`
- `payment_method.ex` - `phoenix_kit_payment_methods`
- `payment_option.ex` - `phoenix_kit_payment_options`
- `subscription.ex` - `phoenix_kit_subscriptions`
- `subscription_plan.ex` - `phoenix_kit_subscription_plans`
- `transaction.ex` - `phoenix_kit_transactions`
- `webhook_event.ex` - `phoenix_kit_webhook_events`

#### Shop Module (7 schemas with UUID)
- `cart.ex` - `phoenix_kit_shop_carts`
- `cart_item.ex` - `phoenix_kit_shop_cart_items`
- `category.ex` - `phoenix_kit_shop_categories`
- `import_config.ex` - `phoenix_kit_shop_import_configs`
- `import_log.ex` - `phoenix_kit_shop_import_logs`
- `product.ex` - `phoenix_kit_shop_products`
- `shipping_method.ex` - `phoenix_kit_shop_shipping_methods`

#### Emails Module (4 schemas)
- `event.ex` - `phoenix_kit_email_events`
- `log.ex` - `phoenix_kit_email_logs`
- `rate_limiter.ex` - `phoenix_kit_email_blocklist`
- `template.ex` - `phoenix_kit_email_templates`

#### Sync Module (2 schemas)
- `connection.ex` - `phoenix_kit_sync_connections`
- `transfer.ex` - `phoenix_kit_sync_transfers`

#### Referrals Module (2 schemas)
- `referrals.ex` - `phoenix_kit_referral_codes`
- `referral_code_usage.ex` - `phoenix_kit_referral_code_usage`

#### Legal Module (1 schema)
- `consent_log.ex` - `phoenix_kit_consent_logs`

### ❌ No UUID (28 schemas)

#### Posts Module (13 schemas)
- `post.ex` - `phoenix_kit_posts`
- `post_comment.ex` - `phoenix_kit_post_comments`
- `post_like.ex` - `phoenix_kit_post_likes`
- `post_dislike.ex` - `phoenix_kit_post_dislikes`
- `post_media.ex` - `phoenix_kit_post_media`
- `post_tag.ex` - `phoenix_kit_post_tags`
- `post_tag_assignment.ex` - `phoenix_kit_post_tag_assignments`
- `post_view.ex` - `phoenix_kit_post_views`
- `post_group.ex` - `phoenix_kit_post_groups`
- `post_mention.ex` - `phoenix_kit_post_mentions`
- `post_group_assignment.ex` - `phoenix_kit_post_group_assignments`
- `comment_like.ex` - `phoenix_kit_comment_likes`
- `comment_dislike.ex` - `phoenix_kit_comment_dislikes`

#### Connections Module (6 schemas)
- `block.ex` - `phoenix_kit_user_blocks`
- `block_history.ex` - `phoenix_kit_user_blocks_history`
- `connection.ex` - `phoenix_kit_user_connections`
- `connection_history.ex` - `phoenix_kit_user_connections_history`
- `follow.ex` - `phoenix_kit_user_follows`
- `follow_history.ex` - `phoenix_kit_user_follows_history`

#### Storage Module (5 schemas)
- `bucket.ex` - `phoenix_kit_buckets`
- `dimension.ex` - `phoenix_kit_storage_dimensions`
- `file.ex` - `phoenix_kit_files`
- `file_instance.ex` - `phoenix_kit_file_instances`
- `file_location.ex` - `phoenix_kit_file_locations`

#### Tickets Module (4 schemas)
- `ticket.ex` - `phoenix_kit_tickets`
- `ticket_attachment.ex` - `phoenix_kit_ticket_attachments`
- `ticket_comment.ex` - `phoenix_kit_ticket_comments`
- `ticket_status_history.ex` - `phoenix_kit_ticket_status_history`

#### Shop Module (1 schema without UUID)
- `shop_config.ex` - `phoenix_kit_shop_config` (config table, no UUID needed)

---

## Migration Priority

### High Priority
1. **Billing** (10 schemas) - Financial data benefits from non-enumerable UUIDs in URLs
2. **Posts** (13 schemas) - User content often exposed in public URLs

### Medium Priority
3. **Tickets** (4 schemas) - Support tickets may have shareable URLs
4. **Storage** (5 schemas) - File references often used in external APIs

### Low Priority
5. **Connections** (6 schemas) - Mostly internal relationship tracking
6. **Old Pattern modules** (27 schemas) - Already have UUIDs, just need pattern update

---

## Update Checklist

When updating a module to the new UUID standard:

- [ ] Add `read_after_writes: true` to UUID field
- [ ] Remove `maybe_generate_uuid/1` function
- [ ] Add `:id, :uuid` to `Jason.Encoder` (if applicable)
- [ ] Update `get/1` to accept integer, UUID, or string-integer
- [ ] Update `get!/1` to delegate to `get/1`
- [ ] Remove `String.to_integer` calls from web layer
- [ ] Use `UUIDUtils.valid?/1` for UUID validation
- [ ] Update docstrings to document UUID support
- [ ] Test backward compatibility with integer IDs

---

## References

- PR #311: Initial AI module UUID implementation
- PR #312: AI module UUID fixes and `UUIDUtils` creation
- PR #313: Entities module UUID update
- UUID Utility: `lib/phoenix_kit/utils/uuid.ex`
- CLAUDE.md: "Adding UUID Fields to Existing Schemas" section
