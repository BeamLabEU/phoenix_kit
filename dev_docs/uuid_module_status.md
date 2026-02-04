# PhoenixKit Modules - UUID Status

**Last Updated**: 2026-02-04
**Reference PRs**: #311, #312, #313, #314, #315, #316

This document tracks UUID implementation status across all PhoenixKit modules with database schemas.

## Status Overview

| Module | DB Schemas | UUID Status | Notes |
|--------|------------|-------------|-------|
| **AI** | 3 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Entities** | 2 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Billing** | 10 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Shop** | 7 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Emails** | 4 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Sync** | 2 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Legal** | 1 | ✅ New Standard | `read_after_writes: true`, flexible lookups |
| **Referrals** | 2 | ⚠️ Old Pattern | Has UUID, uses `maybe_generate_uuid` |
| **Posts** | 13 | ✅ Native UUID PK | `@primary_key {:id, UUIDv7, autogenerate: true}` |
| **Connections** | 6 | ✅ Native UUID PK | `@primary_key {:id, UUIDv7, autogenerate: true}` |
| **Storage** | 5 | ✅ Native UUID PK | `@primary_key {:id, UUIDv7, autogenerate: true}` |
| **Tickets** | 4 | ✅ Native UUID PK | `@primary_key {:id, UUIDv7, autogenerate: true}` |
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
| ✅ Native UUID PK | UUID as primary key (`@primary_key {:id, UUIDv7, autogenerate: true}`) |
| ⚠️ Old Pattern | Has UUID field but uses app-side `maybe_generate_uuid` |
| — | No database schemas |

## Summary

| Category | Modules | Schemas |
|----------|---------|---------|
| ✅ New Standard | 7 | 29 |
| ✅ Native UUID PK | 4 | 28 |
| ⚠️ Old Pattern | 1 | 2 |
| ❌ No UUID | 0 | 0 |
| — No schemas | 7 | 0 |
| **Total** | **19** | **59** |

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

### ✅ New Standard (29 schemas)

#### AI Module (3 schemas)
- `lib/modules/ai/endpoint.ex` - `phoenix_kit_ai_endpoints`
- `lib/modules/ai/prompt.ex` - `phoenix_kit_ai_prompts`
- `lib/modules/ai/request.ex` - `phoenix_kit_ai_requests`

#### Entities Module (2 schemas)
- `lib/modules/entities/entities.ex` - `phoenix_kit_entities`
- `lib/modules/entities/entity_data.ex` - `phoenix_kit_entity_data`

#### Billing Module (10 schemas) - PR #314
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

#### Shop Module (7 schemas)
- `cart.ex` - `phoenix_kit_shop_carts`
- `cart_item.ex` - `phoenix_kit_shop_cart_items`
- `category.ex` - `phoenix_kit_shop_categories`
- `product.ex` - `phoenix_kit_shop_products`
- `shipping_method.ex` - `phoenix_kit_shop_shipping_methods`
- `import_config.ex` - `phoenix_kit_shop_import_configs`
- `import_log.ex` - `phoenix_kit_shop_import_logs`

#### Emails Module (4 schemas)
- `event.ex` - `phoenix_kit_email_events`
- `log.ex` - `phoenix_kit_email_logs`
- `rate_limiter.ex` - `phoenix_kit_email_blocklist`
- `template.ex` - `phoenix_kit_email_templates`

#### Sync Module (2 schemas)
- `connection.ex` - `phoenix_kit_sync_connections`
- `transfer.ex` - `phoenix_kit_sync_transfers`

#### Legal Module (1 schema)
- `consent_log.ex` - `phoenix_kit_consent_logs`

### ✅ Native UUID PK (28 schemas)

Uses `@primary_key {:id, UUIDv7, autogenerate: true}` - the `id` field itself is a UUID.

#### Posts Module (13 schemas)
- `post.ex` - `phoenix_kit_posts`
- `post_comment.ex` - `phoenix_kit_post_comments`
- `post_like.ex` - `phoenix_kit_post_likes`
- `post_dislike.ex` - `phoenix_kit_post_dislikes`
- `post_media.ex` - `phoenix_kit_post_media`
- `post_tag.ex` - `phoenix_kit_post_tags`
- `post_view.ex` - `phoenix_kit_post_views`
- `post_group.ex` - `phoenix_kit_post_groups`
- `post_mention.ex` - `phoenix_kit_post_mentions`
- `comment_like.ex` - `phoenix_kit_comment_likes`
- `comment_dislike.ex` - `phoenix_kit_comment_dislikes`
- `post_tag_assignment.ex` - `phoenix_kit_post_tag_assignments` (composite key, no PK)
- `post_group_assignment.ex` - `phoenix_kit_post_group_assignments` (composite key, no PK)

#### Storage Module (5 schemas)
- `bucket.ex` - `phoenix_kit_buckets`
- `dimension.ex` - `phoenix_kit_storage_dimensions`
- `file.ex` - `phoenix_kit_files`
- `file_instance.ex` - `phoenix_kit_file_instances`
- `file_location.ex` - `phoenix_kit_file_locations`

#### Connections Module (6 schemas)
- `block.ex` - `phoenix_kit_user_blocks`
- `block_history.ex` - `phoenix_kit_user_blocks_history`
- `connection.ex` - `phoenix_kit_user_connections`
- `connection_history.ex` - `phoenix_kit_user_connections_history`
- `follow.ex` - `phoenix_kit_user_follows`
- `follow_history.ex` - `phoenix_kit_user_follows_history`

#### Tickets Module (4 schemas)
- `ticket.ex` - `phoenix_kit_tickets`
- `ticket_attachment.ex` - `phoenix_kit_ticket_attachments`
- `ticket_comment.ex` - `phoenix_kit_ticket_comments`
- `ticket_status_history.ex` - `phoenix_kit_ticket_status_history`

### ⚠️ Old Pattern (2 schemas)

#### Referrals Module (2 schemas)
- `referrals.ex` - `phoenix_kit_referral_codes`
- `referral_code_usage.ex` - `phoenix_kit_referral_code_usage`

### Other

#### Shop Module (1 schema without UUID)
- `shop_config.ex` - `phoenix_kit_shop_config` (config table, uses string key as PK)

---

## Migration Priority

These modules have UUID fields but use the old `maybe_generate_uuid` pattern.
Update them to use `read_after_writes: true` for DB-generated UUIDs.

### Low Priority
1. **Referrals** (2 schemas) - Referral tracking

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
- PR #314: Billing module UUID update (10 schemas)
- PR #315: Shop, Emails, Sync modules UUID update (13 schemas)
- PR #316: Legal module UUID update (1 schema)
- UUID Utility: `lib/phoenix_kit/utils/uuid.ex`
- CLAUDE.md: "Adding UUID Fields to Existing Schemas" section
