# UUID Migration Guide

This guide explains PhoenixKit's graceful UUID migration strategy for transitioning from bigserial (incremental) to UUID primary keys.

## Overview

Starting with V40, PhoenixKit adds UUID columns to all legacy tables. This is a **non-breaking change** that allows parent applications to gradually transition from integer IDs to UUIDs at their own pace.

All UUIDs are generated using **UUIDv7** (time-ordered UUIDs), which provides better index performance than random UUIDv4.

## UUIDv7 Benefits

UUIDv7 is a time-ordered UUID format defined in RFC 9562:

- **Time-ordered**: First 48 bits contain Unix timestamp in milliseconds
- **Better index performance**: Sequential ordering improves B-tree index locality
- **Sortable by creation time**: Natural chronological ordering without extra columns
- **Standard UUID format**: Compatible with existing UUID infrastructure

Example UUIDv7: `019b5704-3680-7b95-9d82-ef16127f1fd2`

## Migration Strategy

### Phase 1: UUID Column Addition (V40) ✅ Current

- Adds `uuid` column to all 33 legacy tables
- Backfills existing records with generated UUIDv7 values
- Creates unique indexes on UUID columns
- Keeps DEFAULT for database-level inserts
- **Non-breaking**: Existing integer IDs continue to work
- **Zero downtime**: All operations are idempotent

### Phase 2: Configuration Option (Future)

- New installations can choose UUID-native mode
- Existing installations continue with dual-column approach

### Phase 3: UUID Default (2.0)

- UUID becomes the default for new installations
- Migration tooling provided for 1.x users

## Tables Affected

### Core Auth
- `phoenix_kit_users`
- `phoenix_kit_users_tokens`
- `phoenix_kit_user_roles`
- `phoenix_kit_user_role_assignments`

### Settings & Referrals
- `phoenix_kit_settings`
- `phoenix_kit_referral_codes`
- `phoenix_kit_referral_code_usage`

### Email System
- `phoenix_kit_email_logs`
- `phoenix_kit_email_events`
- `phoenix_kit_email_blocklist`
- `phoenix_kit_email_templates`
- `phoenix_kit_email_orphaned_events`
- `phoenix_kit_email_metrics`

### OAuth
- `phoenix_kit_user_oauth_providers`

### Entities
- `phoenix_kit_entities`
- `phoenix_kit_entity_data`

### Audit
- `phoenix_kit_audit_logs`

### Billing
- `phoenix_kit_currencies`
- `phoenix_kit_billing_profiles`
- `phoenix_kit_orders`
- `phoenix_kit_invoices`
- `phoenix_kit_transactions`
- `phoenix_kit_payment_methods`
- `phoenix_kit_subscription_plans`
- `phoenix_kit_subscriptions`
- `phoenix_kit_payment_provider_configs`
- `phoenix_kit_webhook_events`

### AI System
- `phoenix_kit_ai_endpoints`
- `phoenix_kit_ai_requests`
- `phoenix_kit_ai_prompts`

### DB Sync
- `phoenix_kit_db_sync_connections`
- `phoenix_kit_db_sync_transfers`

### Admin
- `phoenix_kit_admin_notes`

## Using the UUID Helper Module

PhoenixKit provides `PhoenixKit.UUID` for working with dual identifiers:

### Looking Up Records

```elixir
# Automatic detection - works with both ID types
user = PhoenixKit.UUID.get(User, "123")                    # integer lookup
user = PhoenixKit.UUID.get(User, "019b5704-3680-7b95-...")  # UUID lookup

# Explicit lookups
user = PhoenixKit.UUID.get_by_id(User, 123)
user = PhoenixKit.UUID.get_by_uuid(User, "019b5704-3680-7b95-...")

# With error raising
user = PhoenixKit.UUID.get!(User, identifier)

# With prefix for multi-tenant schemas
user = PhoenixKit.UUID.get(User, "123", prefix: "tenant_abc")
```

### Parsing Identifiers

```elixir
PhoenixKit.UUID.parse_identifier("123")
# => {:integer, 123}

PhoenixKit.UUID.parse_identifier("019b5704-3680-7b95-9d82-ef16127f1fd2")
# => {:uuid, "019b5704-3680-7b95-9d82-ef16127f1fd2"}

PhoenixKit.UUID.parse_identifier("invalid")
# => :invalid
```

### Generating UUIDs

```elixir
uuid = PhoenixKit.UUID.generate()
# => "019b5704-3680-7b95-9d82-ef16127f1fd2"  (UUIDv7)
```

### Working with Records

```elixir
# Get preferred identifier (UUID if available, else ID)
identifier = PhoenixKit.UUID.preferred_identifier(user)

# Extract specific identifiers
uuid = PhoenixKit.UUID.extract_uuid(user)
id = PhoenixKit.UUID.extract_id(user)

# Check identifier type
PhoenixKit.UUID.uuid?("019b5704-...")       # => true
PhoenixKit.UUID.integer_id?(123)            # => true
```

## Transitioning Your Application

### Step 1: Update PhoenixKit

```elixir
# mix.exs
def deps do
  [{:phoenix_kit, "~> 1.8"}]
end
```

### Step 2: Run Migrations

```bash
mix ecto.migrate
```

### Step 3: Update URLs (Optional)

Start using UUIDs in user-facing URLs for security:

```elixir
# Before (enumerable integer IDs)
"/users/123"

# After (non-enumerable UUIDs)
"/users/019b5704-3680-7b95-9d82-ef16127f1fd2"
```

### Step 4: Update Controllers/LiveViews

```elixir
# Before
def show(conn, %{"id" => id}) do
  user = Repo.get!(User, id)
  # ...
end

# After (supports both ID types)
def show(conn, %{"id" => identifier}) do
  user = PhoenixKit.UUID.get!(User, identifier)
  # ...
end
```

### Step 5: Update API Responses (Optional)

Include UUIDs in API responses:

```elixir
def render("user.json", %{user: user}) do
  %{
    id: user.id,           # Keep for backward compatibility
    uuid: user.uuid,       # Add UUID
    email: user.email
  }
end
```

## Why UUIDs?

### Security Benefits

- **Non-enumerable**: UUIDs can't be guessed or iterated
- **No information leakage**: Don't reveal record counts
- **Distributed-friendly**: No central ID coordination needed

### Technical Benefits (UUIDv7)

- **Time-sortable**: UUIDv7 maintains insertion order naturally
- **Better index performance**: Sequential ordering reduces index fragmentation
- **Merge-friendly**: No conflicts when syncing databases
- **Future-proof**: Industry standard for modern applications

## FAQ

### Will my existing code break?

No. Integer IDs continue to work exactly as before. The UUID column is additive.

### Do I need to update my foreign keys?

Not in Phase 1. Foreign keys still use integer IDs internally. The UUID column is for external reference.

### Can I use UUIDs in URLs immediately?

Yes! After running the V40 migration, all records have UUIDs. Use `PhoenixKit.UUID.get/2` for lookups.

### What about performance?

- UUID columns add ~16 bytes per row
- Unique indexes are created for efficient lookups
- UUIDv7 provides better index locality than random UUIDs
- Integer foreign keys remain for join performance

### How do I generate UUIDs for new records?

New user records automatically get UUIDs via the `registration_changeset`. The database also has a DEFAULT that generates UUIDv7 for any direct SQL inserts.

For other schemas, add UUID generation to your changesets:

```elixir
|> maybe_generate_uuid()

defp maybe_generate_uuid(changeset) do
  case get_field(changeset, :uuid) do
    nil -> put_change(changeset, :uuid, UUIDv7.generate())
    _ -> changeset
  end
end
```

Or use `PhoenixKit.UUID.generate()`:

```elixir
defp maybe_generate_uuid(changeset) do
  case get_field(changeset, :uuid) do
    nil -> put_change(changeset, :uuid, PhoenixKit.UUID.generate())
    _ -> changeset
  end
end
```

### What's the difference between UUIDv4 and UUIDv7?

| Feature | UUIDv4 | UUIDv7 |
|---------|--------|--------|
| Generation | Random | Time-ordered |
| Index performance | Poor (random distribution) | Good (sequential) |
| Sortable by time | No | Yes |
| Format | `xxxxxxxx-xxxx-4xxx-...` | `xxxxxxxx-xxxx-7xxx-...` |

PhoenixKit uses UUIDv7 exclusively for better performance.

## Multi-Tenant Support

For multi-tenant applications using PostgreSQL schema prefixes:

```elixir
# Lookup with prefix
user = PhoenixKit.UUID.get(User, "123", prefix: "tenant_abc")

# All lookup functions support prefix
user = PhoenixKit.UUID.get_by_id(User, 123, prefix: "tenant_abc")
user = PhoenixKit.UUID.get_by_uuid(User, uuid, prefix: "tenant_abc")
```

## Rollback

If needed, the V40 migration can be rolled back:

```bash
mix ecto.rollback
```

This removes all UUID columns and indexes, restoring the schema to V39 state.
