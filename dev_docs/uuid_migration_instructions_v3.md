# UUID Migration Guide for PhoenixKit

This document gives a new AI full context on the UUIDv7 migration: what we're doing, why, what's done, what remains, and the code patterns to follow.

> **V3 changes from V2:**
> - Fixed "Dual-write is only for creates" — updates that change FK values also need dual-write
> - Added update and multi-FK dual-write patterns with real codebase examples
>
> **V3.1 corrections:**
> - Web layer migration IS complete — `phx-value-uuid` standardization done across all modules
> - All `uuid_remaining_fixes.md` items resolved (String.to_integer, routes, phx-value, binary overloads)
>
> **V3.2 additions:**
> - Integer `id` column is now officially **deprecated** — will be removed in a future major version
> - All `belongs_to` with UUID foreign keys MUST include `references: :uuid` (Ecto defaults to `:id`)
> - Deprecation warning added to `mix phoenix_kit.update`

## Deprecation Notice

> **The integer `id` column is deprecated as of V56.** It will be removed in a future major version.
> All schemas now use `@primary_key {:uuid, UUIDv7, autogenerate: true}`. The `field :id, :integer, read_after_writes: true`
> is kept only for backward compatibility with parent apps that may reference integer FKs.
> New code should use `.uuid` exclusively for lookups, URLs, associations, and event handlers.

## Goal

PhoenixKit is migrating from integer primary keys to UUIDv7. The end state: **delete all integer `id` columns with minimal disruption**. We're keeping integer columns for now so external tables (in parent apps) don't break, but all PhoenixKit-internal code uses UUIDs.

## Naming Convention (CRITICAL)

`id` and `uuid` are **separate, distinct concepts** throughout the codebase:

| Concept | Field | Type | Example |
|---------|-------|------|---------|
| Legacy integer | `.id` | integer | `user.id` → `42` |
| UUID identifier | `.uuid` | UUIDv7 string | `user.uuid` → `"019b5704-..."` |

This distinction applies everywhere:
- **Schema fields**: `field :id, :integer` vs `field :uuid, UUIDv7` (or `@primary_key {:uuid, UUIDv7, ...}`)
- **FK columns**: `user_id` (integer FK) vs `user_uuid` (UUID FK)
- **Template attributes**: `phx-value-id` passes an integer, `phx-value-uuid` passes a UUID
- **Handler patterns**: `%{"id" => id}` receives an integer string, `%{"uuid" => uuid}` receives a UUID string
- **Route params**: URLs use `.uuid` values

**Never conflate them.** If a value is a UUID, the variable/key/attribute must say `uuid`, not `id`.

---

## Schema Patterns

There are three primary key patterns in the codebase. You must know which one a schema uses before writing queries.

### Pattern 1: UUID PK with legacy integer (most schemas)

Used by: users, billing, shop, emails, AI, entities, sync, referrals, legal, core

```elixir
@primary_key {:uuid, UUIDv7, autogenerate: true}

schema "phoenix_kit_users" do
  field :id, :integer, read_after_writes: true  # legacy, DB generates via SERIAL
  # ...
end
```

- `user.uuid` — the Ecto primary key (UUIDv7)
- `user.id` — legacy integer, populated by DB after insert
- `Repo.get(User, "019b...")` — works (matches UUID PK)
- `Repo.get(User, 42)` — **CRASHES** (tries to cast integer to UUID)
- `Repo.get_by(User, id: 42)` — works (queries integer column)

### belongs_to with Pattern 1 parents (CRITICAL)

When a parent schema uses `@primary_key {:uuid, UUIDv7, ...}`, Ecto's `belongs_to` defaults `references` to `:id` — **NOT** to the parent's `@primary_key`. This causes `bigint = uuid` type mismatch errors at runtime. You **MUST** add `references: :uuid` explicitly:

```elixir
# CORRECT
belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7

# WRONG — joins on users.id (bigint) = child.user_uuid (uuid) → crash
belongs_to :user, User, foreign_key: :user_uuid, type: UUIDv7
```

This applies to ALL `belongs_to` associations where the parent uses Pattern 1.

### Pattern 2: Native UUID PK, no integer (newer modules)

Used by: tickets, posts, comments, connections, storage (files/buckets)

```elixir
@primary_key {:id, UUIDv7, autogenerate: true}

schema "phoenix_kit_tickets" do
  # id IS the UUID — no separate uuid field
  belongs_to :user, User, type: :integer
  field :user_uuid, UUIDv7
  # ...
end
```

- `ticket.id` — IS the UUID (the only PK)
- No `.uuid` field — `.id` serves that purpose
- `phx-value-id={ticket.id}` is correct here (`.id` IS the UUID)

**`@foreign_key_type` varies across Pattern 2 schemas — don't assume it's always `UUIDv7`.**

| Variant | Schemas | `@foreign_key_type` | Effect |
|---------|---------|---------------------|--------|
| Full UUID FKs | Post, PostTag, PostGroup, PostMedia, Ticket, TicketAttachment, File, FileInstance, Bucket, Dimension, FileLocation | `UUIDv7` | `belongs_to` defaults to UUID type |
| No declaration | Comment, CommentLike, CommentDislike, Connection, Block, Follow, TicketComment, TicketStatusHistory | *(none)* | `belongs_to` defaults to `:id` type; user FKs use explicit `type: :integer` |
| Explicit `:id` | ConnectionHistory, FollowHistory, BlockHistory | `:id` | Same as no declaration — user FKs use explicit `type: :integer` |

**In practice this doesn't affect the UUID migration pattern.** All Pattern 2 schemas reference users the same way regardless of `@foreign_key_type`:
```elixir
belongs_to :user, User, type: :integer   # explicit integer FK to users table
field :user_uuid, UUIDv7                  # UUID FK for dual-write
```

The `@foreign_key_type` setting only matters for self-referencing FKs (e.g., `parent_id` on comments, `replied_to` on ticket comments) — those automatically match the schema's own PK type.

### Pattern 3: Integer PK with secondary UUID (being migrated away)

Some schemas may still be mid-migration. Check `@primary_key` to know which pattern you're dealing with.

---

## FK Dual-Write

Any operation that **sets or changes** a FK value must write BOTH the integer FK and UUID FK. This includes creates AND updates.

### Create pattern

```elixir
def create_ticket(user, attrs) do
  attrs
  |> Map.put(:user_id, user.id)
  |> Map.put(:user_uuid, user.uuid)
  |> then(&Ticket.changeset(%Ticket{}, &1))
  |> repo().insert()
end
```

### Update pattern — changing a FK value on an existing record

When an operation changes which user/record a FK points to, set both columns:

```elixir
# Real example from tickets.ex
def assign_ticket(ticket, handler_id) do
  update_ticket(ticket, %{
    assigned_to_id: handler_id,
    assigned_to_uuid: resolve_user_uuid(handler_id)
  })
end
```

If you only set `assigned_to_id`, the `assigned_to_uuid` column goes stale — it keeps the old user's UUID (or NULL). Any code reading `assigned_to_uuid` returns wrong data.

### Multi-FK pattern — records with multiple user references

History and audit tables often reference several users on one record. Resolve ALL of them:

```elixir
# Real example from connections.ex — three user FKs on one record
defp log_connection_history(user_a_id, user_b_id, actor_id, action) do
  %ConnectionHistory{}
  |> ConnectionHistory.changeset(%{
    user_a_id: user_a_id,
    user_b_id: user_b_id,
    actor_id: actor_id,
    user_a_uuid: resolve_user_uuid(user_a_id),
    user_b_uuid: resolve_user_uuid(user_b_id),
    actor_uuid: resolve_user_uuid(actor_id),
    action: action
  })
  |> repo().insert()
end
```

### Resolving UUIDs from integers

When you only have an integer ID and need to populate the UUID FK:

```elixir
defp resolve_user_uuid(user_id) when is_integer(user_id) do
  import Ecto.Query, only: [from: 2]
  repo().one(from(u in User, where: u.id == ^user_id, select: u.uuid))
end

defp resolve_user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
defp resolve_user_uuid(_), do: nil
```

### FK naming convention

Integer FK → UUID FK:
- `user_id` → `user_uuid`
- `assigned_to_id` → `assigned_to_uuid`
- `blocker_id` → `blocker_uuid`
- `created_by` → `created_by_uuid`

Reference: `lib/phoenix_kit/migrations/uuid_fk_columns.ex` has the complete list of all ~80 UUID FK columns added by V56.

---

## Lookup Functions

Every lookup function handles both integer and UUID inputs:

```elixir
# Integer lookup — use get_by, NOT get (get crashes on UUID-PK schemas)
def get_thing(id) when is_integer(id) do
  repo().get_by(Thing, id: id)
end

# Binary lookup — could be UUID string or integer-as-string
def get_thing(id) when is_binary(id) do
  case Integer.parse(id) do
    {int_id, ""} -> get_thing(int_id)
    _ -> repo().get(Thing, id)  # UUID string — matches UUID PK
  end
end
```

Or use the built-in helper:
```elixir
def get_thing(id), do: PhoenixKit.UUID.get(Thing, id)
```

`PhoenixKit.UUID.get/2` handles integer, integer-string, UUID string, and invalid input automatically.

### Bang variants

```elixir
def get_thing!(id) do
  case get_thing(id) do
    nil -> raise Ecto.NoResultsError, queryable: Thing
    thing -> thing
  end
end
```

---

## Query Filters

When filtering by user and the caller might pass either type:

```elixir
defp maybe_filter_by_user(query, nil), do: query

defp maybe_filter_by_user(query, user_id) when is_integer(user_id) do
  where(query, [p], p.user_id == ^user_id)
end

defp maybe_filter_by_user(query, user_id) when is_binary(user_id) do
  case Integer.parse(user_id) do
    {int_id, ""} -> where(query, [p], p.user_id == ^int_id)
    _ -> where(query, [p], p.user_uuid == ^user_id)
  end
end
```

**When integers are dropped**: Delete the integer clause. The binary clause queries `user_uuid` directly.

---

## Templates and Event Handlers

### Target convention

```heex
<%!-- Passing a UUID value → use phx-value-uuid --%>
<button phx-click="delete" phx-value-uuid={record.uuid}>Delete</button>

<%!-- Passing a native UUID PK (tickets/posts/comments where .id IS the UUID) → phx-value-id is fine --%>
<button phx-click="delete" phx-value-id={ticket.id}>Delete</button>
```

**Current state**: The codebase has been fully migrated to this convention. All modules use `phx-value-uuid={record.uuid}` with corresponding `%{"uuid" => uuid}` handler patterns. The only places using `phx-value-id` are native UUID PK schemas (tickets, posts, comments) where `.id` IS the UUID.

### Handler pattern

```elixir
# Record with .uuid field
def handle_event("delete", %{"uuid" => uuid}, socket) do
  record = MyModule.get_thing!(uuid)
  # ...
end

# Record where .id IS the UUID (native UUID PK schemas)
def handle_event("delete", %{"id" => id}, socket) do
  record = MyModule.get_thing!(id)
  # ...
end
```

### `phx-value-*` always delivers strings

LiveView `phx-value-*` attributes always deliver **string** values. Never use `String.to_integer()` on values that might be UUIDs — it crashes with `ArgumentError`. Use `Integer.parse/1` which returns `:error` safely.

### `to_string()` for type-safe comparisons

When comparing IDs from different sources:

```elixir
# Finding a record by UUID from a phx-value (always a string)
role = Enum.find(roles, &(to_string(&1.uuid) == uuid_string))

# Conditional classes
class={if to_string(selected_id) == to_string(profile.uuid), do: "selected", else: ""}
```

---

## PubSub Topics

Topics must resolve to the **same string** regardless of input type:

```elixir
# Always normalize to integer for topic consistency
defp user_topic(id) when is_integer(id), do: "tickets:user:#{id}"

defp user_topic(id) when is_binary(id) do
  case Integer.parse(id) do
    {int_id, ""} -> user_topic(int_id)
    _ ->
      case Auth.get_user(id) do
        %{id: int_id} -> user_topic(int_id)
        nil -> "tickets:user:unknown"
      end
  end
end
```

---

## Oban Worker Backward Compatibility

Workers may have old jobs queued with integer IDs while new jobs use UUIDs. Handle both:

```elixir
defp get_subscription_with_preloads(id) when is_integer(id) do
  from(s in Subscription, where: s.id == ^id, preload: [:plan, :payment_method])
  |> repo().one()
end

defp get_subscription_with_preloads(id) when is_binary(id) do
  from(s in Subscription, where: s.uuid == ^id, preload: [:plan, :payment_method])
  |> repo().one()
end
```

---

## Detecting New vs Existing Records

With UUID PKs and `field :id, :integer, read_after_writes: true`, `is_nil(record.id)` is unreliable.

```elixir
# WRONG
if is_nil(record.id), do: :new, else: :existing

# RIGHT — use Ecto metadata
if record.__meta__.state == :built, do: :new, else: :existing
```

---

## Common Pitfalls

### 1. `Repo.get(Schema, integer)` crash on UUID-PK schemas
```elixir
Repo.get(EmailLog, 42)           # CRASHES
Repo.get_by(EmailLog, id: 42)    # CORRECT
```

### 2. Setting a field that doesn't exist in the schema
Cast silently drops unknown fields. Always verify the schema has the field AND it's in the `cast` list.

### 3. `String.to_integer` on UUID strings
```elixir
String.to_integer("019b5704-...")  # CRASHES with ArgumentError
Integer.parse("019b5704-...")      # Returns :error safely
```

### 4. Returning UUID from `get_user_id` to an integer FK field
```elixir
# WRONG — returns UUID string, caller passes to changed_by_id (integer field)
defp get_user_id(id) when is_binary(id), do: id

# CORRECT — always resolve to integer for integer FK fields
defp get_user_id(id) when is_binary(id) do
  case Integer.parse(id) do
    {int_id, ""} -> int_id
    _ ->
      case Auth.get_user(id) do
        %{id: int_id} -> int_id
        nil -> nil
      end
  end
end
```

### 5. Unfiltered query fallback for UUID strings
```elixir
# WRONG — returns ALL records when UUID can't be parsed as integer
_ -> query

# CORRECT — query the UUID FK column
_ -> where(query, [p], p.user_uuid == ^user_id)
```

### 6. Form params losing UUID fields on submit
UUID fields set programmatically on a changeset are lost when the HTML form submits (they aren't in form inputs). Re-add them in the save handler:
```elixir
code_params
|> Map.put("beneficiary", beneficiary.id)
|> Map.put("beneficiary_uuid", beneficiary.uuid)
```

### 7. Inconsistent PubSub topics
Integer path subscribes to `"user:42"`, UUID path publishes to `"user:019b..."` — messages never arrive. Always normalize to integer for topics (see PubSub section above).

### 8. Forgetting to dual-write on FK updates
```elixir
# WRONG — assigned_to_uuid stays stale
update_ticket(ticket, %{assigned_to_id: new_handler_id})

# CORRECT — update both columns
update_ticket(ticket, %{
  assigned_to_id: new_handler_id,
  assigned_to_uuid: resolve_user_uuid(new_handler_id)
})
```

---

## What's Done

### Database (V56)
- ~80 UUID FK columns added across ~40 tables
- `uuid_generate_v7()` PostgreSQL function for defaults
- All existing data backfilled via JOIN queries

### Elixir Schemas
- All schemas have UUID PK (`@primary_key {:uuid, UUIDv7, ...}` or `@primary_key {:id, UUIDv7, ...}`)
- UUID FK fields (`user_uuid`, etc.) added to schemas
- Changesets cast UUID FK fields
- Dual-write on creates and FK updates (both integer FK and UUID FK populated)
- Lookup functions handle both integer and UUID inputs
- Binary overloads added for `when is_integer(id)` functions
- `resolve_user_uuid` helpers in context modules

### Web Layer
- Templates use `.uuid` in routes and links
- `phx-value-uuid={record.uuid}` standardized across all modules (AI, entities, emails, sync, billing, shop, referrals, core web)
- Event handlers extract `%{"uuid" => uuid}` and pass to lookup functions
- `String.to_integer()` calls removed from handlers receiving UUIDs
- `~45 String.to_integer`, `~28 route paths`, `~80 phx-value`, `~35 binary overloads` — all resolved (see `dev_docs/uuid_remaining_fixes.md` for historical inventory)

### Oban Workers
- `subscription_dunning_worker.ex` — handles both integer and UUID job args
- `subscription_renewal_worker.ex` — handles both

## What Remains

### Phase 2 audit — COMPLETED
Cross-referenced every schema against `uuid_fk_columns.ex`. Found and fixed 15 issues:
- Added 9 missing UUID FK columns (ai_requests.prompt_uuid, subscriptions.user_uuid, payment_methods.user_uuid, subscriptions.payment_method_uuid, email_blocklist.user_uuid, email_templates.created_by_user_uuid, email_templates.updated_by_user_uuid, entities.created_by_uuid, referral_codes.beneficiary_uuid)
- Fixed 3 wrong column mappings (transactions.order_uuid→invoice_uuid, referral_code_usage column names, removed bogus referral_codes.user_id entry)
- Added shop_carts.merged_into_cart_uuid + updated shop.ex merge flow
- Fixed role_permission.ex unique constraint name to match V56 index
- All quality checks pass: format, compile (0 warnings), credo --strict (0 issues), dialyzer (0 new errors)

### Future: Drop integer columns
- V57+: Add NOT NULL constraints and FK constraints on UUID FK columns
- Deprecation warnings for parent apps using integer `.id` field
- Eventually drop integer FK columns and integer `id` columns in a 2.0 release

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/phoenix_kit/migrations/uuid_fk_columns.ex` | Authoritative list of all UUID FK columns (V56) |
| `lib/phoenix_kit/migrations/postgres/v56.ex` | The migration that added UUID columns |
| `lib/phoenix_kit/uuid.ex` | `PhoenixKit.UUID.get/2` — universal lookup helper |
| `lib/phoenix_kit/users/auth/user.ex` | User schema — most-referenced, Pattern 1 |
| `dev_docs/uuid_remaining_fixes.md` | Phase 3 inventory (all items resolved, historical reference) |
| `dev_docs/uuid_migration_instructions.md` | V1 of this document (detailed reference) |
| `dev_docs/uuid_migration_instructions_v2.md` | V2 of this document |

## Verification

After any migration-related changes:
1. `mix compile --warnings-as-errors` — catches type mismatches
2. `mix format && mix credo --strict`
3. Test in parent app: `cd phoenix_kit_parent && mix deps.compile phoenix_kit --force && mix ecto.migrate`
4. Verify data integrity:
   ```sql
   -- No orphaned UUID FKs (should be 0)
   SELECT COUNT(*) FROM phoenix_kit_users_tokens
   WHERE user_id IS NOT NULL AND user_uuid IS NULL;
   ```
5. `mix test` — smoke tests pass
