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
>
> **V3.3 corrections (2026-02-16):**
> - Pattern 2 schemas migrated: all 29 schemas now use `.uuid` as the Elixir field name (legacy DB column name bridged via `source: :id` where needed; the `id` column will be dropped later)
> - **Parameter naming convention** clarified and enforced: `_uuid` for UUID params, `_id` only for legacy integer params — applies to function parameters, variables, and map keys, not just schema fields
> - All code examples updated to follow the naming convention

## Deprecation Notice

> **The integer `id` column is deprecated as of V56.** It will be removed in a future major version.
> All schemas now use `@primary_key {:uuid, UUIDv7, autogenerate: true}`. The `field :id, :integer, read_after_writes: true`
> is kept only for backward compatibility with parent apps that may reference integer FKs.
> New code should use `.uuid` exclusively for lookups, URLs, associations, and event handlers.

## Goal

PhoenixKit is migrating from integer primary keys to UUIDv7. The end state: **delete all integer `id` columns with minimal disruption**. We're keeping integer columns for now so external tables (in parent apps) don't break, but all PhoenixKit-internal code uses UUIDs.

### Why UUIDv7?

PhoenixKit uses **UUIDv7** (RFC 9562, finalized 2024) exclusively:

| Feature | UUIDv4 | UUIDv7 |
|---------|--------|--------|
| Format | Random 128-bit | Time-ordered (48-bit timestamp + random) |
| Index Performance | Poor (random inserts) | Excellent (sequential inserts) |
| Sortable | No | Yes (chronologically) |
| Example | `a1b2c3d4-e5f6-4210-a1b2-c3d4e5f6a1b2` | `019b5704-3680-7b95-9d82-ef16127f1fd2` |

UUIDv7 provides better database index locality because the first 48 bits are a Unix timestamp, making inserts sequential.

| Context | Correct | Wrong |
|---------|---------|-------|
| SQL migration DEFAULT | `uuid_generate_v7()` | `gen_random_uuid()` |
| Elixir code generation | `UUIDv7.generate()` | `Ecto.UUID.generate()` |
| Schema PK declaration | `@primary_key {:uuid, UUIDv7, autogenerate: true}` | `@primary_key {:id, :binary_id, autogenerate: true}` |

## Naming Convention (CRITICAL)

`id` and `uuid` are **separate, distinct concepts** throughout the codebase:

| Concept | Field | Type | Example |
|---------|-------|------|---------|
| Legacy integer (deprecated) | `.id` | integer | `user.id` → `42` |
| UUID identifier | `.uuid` | UUIDv7 string | `user.uuid` → `"019b5704-..."` |

This distinction applies **everywhere** — schema fields, DB columns, function parameters, variables, map keys, template attributes:

- **Schema fields**: `field :id, :integer` (deprecated) vs `field :uuid, UUIDv7`
- **FK columns**: `user_id` (deprecated integer FK) vs `user_uuid` (UUID FK)
- **Function parameters**: `user_uuid` for UUID values, `user_id` only in legacy helpers that explicitly handle integers
- **Template attributes**: `phx-value-uuid` passes a UUID (preferred), `phx-value-id` is deprecated
- **Handler patterns**: `%{"uuid" => uuid}` receives a UUID string
- **Route params**: URLs use `.uuid` values
- **Variables and map keys**: `user_uuid` holds a UUID string, `user_id` only for legacy integer values

**Never conflate them.** If a value is a UUID, the variable/key/parameter/attribute must say `uuid`, not `id`.

### Function parameter naming

Public API functions use `_uuid` parameter names. Integer arguments raise `ArgumentError` to catch stale callers:

```elixir
# Public API — UUID-only, integers are rejected
def like_post(post_uuid, user_uuid) when is_binary(user_uuid) do
  if UUIDUtils.valid?(user_uuid) do
    do_like_post(post_uuid, user_uuid, resolve_user_id(user_uuid))
  else
    {:error, :invalid_user_uuid}
  end
end

def like_post(_post_uuid, user_uuid) when is_integer(user_uuid) do
  raise ArgumentError,
    "like_post/2 expects a UUID string for user_uuid, got integer: #{user_uuid}. " <>
    "Use user.uuid instead of user.id"
end
```

Private helpers that resolve between types use the matching name:

```elixir
defp resolve_user_uuid(user_id) when is_integer(user_id) do ...   # takes integer, returns UUID
defp resolve_user_id(user_uuid) when is_binary(user_uuid) do ...  # takes UUID, returns integer
```

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

### Pattern 2: Native UUID PK, no legacy integer (newer modules)

Used by: tickets, posts, comments, connections, storage (files/buckets)

These tables were created after the UUID decision and never had an integer `id` column. The DB column is named `id` (UUID type), but the Elixir field is `:uuid` via `source: :id`:

```elixir
@primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

schema "phoenix_kit_tickets" do
  # .uuid is the PK — maps to DB column "id" which holds a UUID
  # user FKs use dual-write (integer + UUID) during migration
  belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
  field :user_id, :integer  # legacy dual-write, will be dropped
  # ...
end
```

- `ticket.uuid` — the UUID primary key
- `ticket.id` — does NOT exist (no integer column on these tables)
- `Repo.get(Ticket, "019b...")` — works (matches UUID PK)
- `phx-value-uuid={ticket.uuid}` — correct

**Note:** The `source: :id` option is a bridge — the DB column is still named `id` on these legacy tables. New tables should name the column `uuid` directly and won't need `source:`.

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
def assign_ticket(ticket, handler_uuid) do
  update_ticket(ticket, %{
    assigned_to_uuid: handler_uuid,
    assigned_to_id: resolve_user_id(handler_uuid)
  })
end
```

If you only set one FK column, the other goes stale. Always write both during the dual-write period.

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

Public lookup functions accept UUID strings. Integer arguments raise to catch stale callers:

```elixir
def get_thing(uuid) when is_binary(uuid) do
  PhoenixKit.UUID.get(Thing, uuid)
end

def get_thing(id) when is_integer(id) do
  raise ArgumentError,
    "get_thing/1 expects a UUID string, got integer: #{id}. Use record.uuid instead of record.id"
end

def get_thing(_), do: nil
```

`PhoenixKit.UUID.get/2` handles UUID strings, integer-as-strings (backward compat for URL params), and invalid input automatically.

### Bang variants

```elixir
def get_thing!(uuid) do
  case get_thing(uuid) do
    nil -> raise Ecto.NoResultsError, queryable: Thing
    thing -> thing
  end
end
```

---

## Query Filters

Filter by user UUID. Query the `user_uuid` column directly:

```elixir
defp maybe_filter_by_user(query, nil), do: query

defp maybe_filter_by_user(query, user_uuid) when is_binary(user_uuid) do
  where(query, [p], p.user_uuid == ^user_uuid)
end
```

If you still need backward compat for integer-as-string from URL params:

```elixir
defp maybe_filter_by_user(query, user_uuid) when is_binary(user_uuid) do
  if UUIDUtils.valid?(user_uuid) do
    where(query, [p], p.user_uuid == ^user_uuid)
  else
    # backward compat: integer-as-string from old URL params
    case Integer.parse(user_uuid) do
      {int_id, ""} -> where(query, [p], p.user_id == ^int_id)
      _ -> query
    end
  end
end
```

---

## Templates and Event Handlers

### Target convention

All schemas now use `.uuid` — use `phx-value-uuid` everywhere:

```heex
<%!-- CORRECT — always use phx-value-uuid with record.uuid --%>
<button phx-click="delete" phx-value-uuid={record.uuid}>Delete</button>

<%!-- WRONG — even if .id is a UUID on Pattern 2 schemas, use .uuid --%>
<button phx-click="delete" phx-value-id={ticket.id}>Don't do this</button>
```

### Handler pattern

```elixir
def handle_event("delete", %{"uuid" => uuid}, socket) do
  record = MyModule.get_thing!(uuid)
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

Topics use UUID strings directly:

```elixir
defp user_topic(user_uuid) when is_binary(user_uuid), do: "tickets:user:#{user_uuid}"
```

If you need backward compat during migration, normalize to UUID:

```elixir
defp user_topic(user_uuid) when is_binary(user_uuid), do: "tickets:user:#{user_uuid}"

defp user_topic(user_id) when is_integer(user_id) do
  case resolve_user_uuid(user_id) do
    nil -> "tickets:user:unknown"
    uuid -> user_topic(uuid)
  end
end
```

---

## Oban Worker Backward Compatibility

Workers may have old jobs queued with integer IDs while new jobs use UUIDs. This is the one place where accepting both types in a private helper is acceptable — old jobs in the queue can't be changed:

```elixir
# Private helper — backward compat for queued jobs only
defp get_subscription_with_preloads(uuid) when is_binary(uuid) do
  from(s in Subscription, where: s.uuid == ^uuid, preload: [:plan, :payment_method])
  |> repo().one()
end

defp get_subscription_with_preloads(id) when is_integer(id) do
  # Legacy: old jobs may have integer IDs queued before migration
  from(s in Subscription, where: s.id == ^id, preload: [:plan, :payment_method])
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

### 4. Returning UUID from `resolve_user_id` to an integer FK field
```elixir
# WRONG — returns the input as-is, could be UUID string going to integer field
defp resolve_user_id(user_uuid) when is_binary(user_uuid), do: user_uuid

# CORRECT — look up the integer from the UUID
defp resolve_user_id(user_uuid) when is_binary(user_uuid) do
  from(u in Auth.User, where: u.uuid == ^user_uuid, select: u.id)
  |> repo().one()
end
```

### 5. Unfiltered query fallback for UUID strings
```elixir
# WRONG — returns ALL records when UUID can't be parsed as integer
_ -> query

# CORRECT — query the UUID FK column
_ -> where(query, [p], p.user_uuid == ^user_uuid)
```

### 6. Form params losing UUID fields on submit
UUID fields set programmatically on a changeset are lost when the HTML form submits (they aren't in form inputs). Re-add them in the save handler:
```elixir
code_params
|> Map.put("beneficiary_uuid", beneficiary.uuid)
|> Map.put("beneficiary", beneficiary.id)  # legacy dual-write
```

### 7. Inconsistent PubSub topics
Integer path subscribes to `"user:42"`, UUID path publishes to `"user:019b..."` — messages never arrive. Always normalize to UUID for topics (see PubSub section above).

### 8. Forgetting to dual-write on FK updates
```elixir
# WRONG — assigned_to_id stays stale
update_ticket(ticket, %{assigned_to_uuid: handler_uuid})

# CORRECT — update both columns
update_ticket(ticket, %{
  assigned_to_uuid: handler_uuid,
  assigned_to_id: resolve_user_id(handler_uuid)
})
```

### 9. Using `_id` parameter names for UUID values
```elixir
# WRONG — parameter name says "id" but value is a UUID
def like_post(post_id, user_id) when is_binary(user_id) do ...

# CORRECT — parameter name matches the type
def like_post(post_uuid, user_uuid) when is_binary(user_uuid) do ...
```

---

## Migration SQL Patterns

**All UUID defaults MUST use `uuid_generate_v7()`** (PostgreSQL function created in V40). Never use `gen_random_uuid()`.

### Which pattern for new tables?

| Scenario | Primary Key | UUID Column |
|----------|-------------|-------------|
| **New standalone module** | `id UUID PRIMARY KEY DEFAULT uuid_generate_v7()` | Not needed (PK is UUID) |
| **New table with FK to integer-PK tables** | `id BIGSERIAL PRIMARY KEY` | `uuid UUID DEFAULT uuid_generate_v7() NOT NULL UNIQUE` |
| **Adding uuid to existing table** | Keep existing PK | `ALTER TABLE ... ADD COLUMN uuid UUID DEFAULT uuid_generate_v7() NOT NULL` |

**Rule of thumb:** New modules that don't heavily FK into legacy integer-PK tables should use **Native UUID PK**.

### Migration checklist

- [ ] Use `uuid_generate_v7()` for DEFAULT (not `gen_random_uuid()`)
- [ ] Add NOT NULL constraint on uuid columns
- [ ] Add unique index on secondary uuid columns (not needed for UUID PKs)
- [ ] For optional module tables, wrap in `IF EXISTS` table checks
- [ ] Schema uses `read_after_writes: true` for secondary uuid columns
- [ ] Record correct version in `COMMENT ON TABLE phoenix_kit IS '<version>'`

**Reference migrations:** V40 (function creation), V56 (comprehensive FK columns + backfill)
**Anti-patterns to avoid:** V45, V46, V53 (used `gen_random_uuid()` — fixed by V56)

---

## What's Done

### Database (V56)
- ~80 UUID FK columns added across ~40 tables
- `uuid_generate_v7()` PostgreSQL function for defaults
- All existing data backfilled via JOIN queries

### Elixir Schemas
- All schemas have UUID PK (`@primary_key {:uuid, UUIDv7, ...}` — Pattern 2 uses `source: :id` for legacy DB column name)
- UUID FK fields (`user_uuid`, etc.) added to schemas
- Changesets cast UUID FK fields
- Dual-write on creates and FK updates (both integer FK and UUID FK populated)
- Lookup functions accept UUID strings; integer arguments raise `ArgumentError`
- `resolve_user_uuid` and `resolve_user_id` helpers in context modules

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

### V62: Column naming cleanup — COMPLETE ✓
35 UUID-typed FK columns renamed from `_id` suffix to `_uuid` suffix (e.g. `post_comments.post_id`, `file_instances.file_id`, `ticket_attachments.comment_id`). These store UUID values but violate the naming convention (`_id` = integer, `_uuid` = UUID).

This is a **naming convention enforcement pass** — data is correct, queries work. The renames are DB-only + schema/context code updates, no data migration needed.

Full plan: `dev_docs/plans/2026-02-23-v62-uuid-column-rename-plan.md` (25 tables, 35 column renames across Posts, Comments, Tickets, Storage, Publishing, Shop, and Scheduled Jobs modules).

### Future: Drop integer columns
- Add NOT NULL constraints and FK constraints on UUID FK columns
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
| `dev_docs/plans/2026-02-23-v62-uuid-column-rename-plan.md` | V62 plan: rename UUID-typed `_id` columns to `_uuid` |
| `dev_docs/audits/2026-02-23-uuid_migration_audit_corrected.md` | Root cause analysis of V40 buffering bug + V61 fixes |

## Template & Handler UUID Checklist

When migrating templates from `.id` to `.uuid`, check each usage category:

### All Schemas Use `.uuid`

Both patterns now expose `.uuid` as the primary identifier:

- **Pattern 1** (`@primary_key {:uuid, UUIDv7, autogenerate: true}` + `field :id, :integer`):
  `.id` is the deprecated integer. Always use `.uuid`.
- **Pattern 2** (`@primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}`):
  `.uuid` is the PK (maps to DB column `id`). There is no `.id` field.

**In both cases:** use `record.uuid` in templates, routes, `phx-value-uuid`, and handler patterns.

### What to Check in Templates

| Usage | Priority | Example |
|-------|----------|---------|
| URL interpolation | **Critical** | `"/admin/users/#{user.id}"` → `user.uuid` |
| `phx-value-*` attributes | **High** | `phx-value-id={item.id}` → `item.uuid` |
| `<option value={..}>` in selects | **High** | `value={user.id}` → `user.uuid` |
| `selected=` comparisons | **High** | `to_string(x.id) == y` → `to_string(x.uuid) == y` |
| Display text ("ID: ...") | **Low** | `ID: {user.id}` → `user.uuid` |
| `checked={x.id in @list}` | **High** | Use `.uuid` and store UUIDs in the list |

### What to Check in Handlers

| Pattern | Fix |
|---------|-----|
| `Integer.parse(id_string)` | Remove, pass UUID string directly to context |
| `to_string(&1.id) == param` | Change to `to_string(&1.uuid) == param` |
| `Enum.find(list, &(&1.id == id))` | Use `&(to_string(&1.uuid) == id_str)` |
| `Enum.map(list, & &1.id)` for selection | Use `& &1.uuid` |
| `Repo.get(Schema, integer_id)` | Use `where([x], x.id == ^id)` for integer lookup |

### Common Mistakes That Slip Through

1. **Helper functions one layer deep** — snapshot builders, validation functions,
   and notifier helpers that load a record but don't propagate its UUID to attrs
2. **`Repo.get/2` on UUID-PK schemas** — silently breaks when `@primary_key` changes
   from `:id` to `:uuid`, since `Repo.get` always queries by the PK field name
3. **`Integer.parse` in event handlers** — works today with integer `.id` values,
   crashes when templates switch to `.uuid` strings
4. **Form select `selected=` comparisons** — `to_string(x.id) == param` won't match
   when param becomes a UUID string

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
6. Grep for remaining `.id}` in `.heex` files — ALL should use `.uuid` now (Pattern 2 schemas included)
7. Grep for `_id)` parameter names in public function signatures — should be `_uuid)` unless it's a `resolve_*` helper
