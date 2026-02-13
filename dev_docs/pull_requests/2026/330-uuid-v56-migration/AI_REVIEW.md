# PR #330: Add UUIDv7 migration V56 with dual-write support

**Author**: @alexdont
**Reviewer**: Claude Opus 4.6
**Status**: Merged to `dev` (post-merge review + fixes)
**Date**: 2026-02-13
**Impact**: +5,678 / -1,511 across 199 files
**Commits**: 18

## Goal

Introduce UUIDv7 foreign key columns alongside existing integer FKs across ~40 tables, enabling gradual migration from `bigserial` to UUID-based references. This is the largest single step in the UUID migration journey (V40 added UUID PKs; V56 adds UUID FKs + dual-write plumbing).

## Review Scope

Deep-dive review of the full PR diff (199 files), focusing on:
- Migration correctness and idempotency
- Schema `belongs_to` / `references` correctness
- Dual-write completeness across all context modules
- Template/LiveView consistency (URLs, phx-value attributes)
- Query correctness with UUID-native PKs

## Bugs Found & Fixed

8 bugs were identified and fixed across 10 files. All fixes compile cleanly, pass `mix credo --strict`, and pass all 35 tests.

---

### Bug #1 — HIGH: billing_profile_uuid not dual-written in order snapshots

**File**: `lib/modules/billing/billing.ex` (lines 996-1040)

**Problem**: `maybe_set_billing_snapshot/1` and `maybe_update_billing_snapshot/2` load a billing profile and write the snapshot JSON, but never set `billing_profile_uuid` in the attrs. This means orders created/updated through these paths would have `billing_profile_uuid = NULL` even though the profile is known.

**Root cause**: The snapshot functions were written before the UUID FK columns were added. When V56 added `billing_profile_uuid` to the order schema, these functions weren't updated.

**Fix**:
```elixir
# maybe_set_billing_snapshot — BEFORE:
profile = get_billing_profile!(id)
Map.put(attrs, "billing_snapshot", BillingProfile.to_snapshot(profile))

# AFTER:
profile = get_billing_profile!(id)
attrs
|> Map.put("billing_snapshot", BillingProfile.to_snapshot(profile))
|> Map.put("billing_profile_uuid", profile.uuid)
```

Same pattern applied to `maybe_update_billing_snapshot/2` — the branch that detects `profile.uuid != order.billing_profile_uuid` now also writes the new UUID back.

---

### Bug #2 — HIGH: Event.get_event/1 crashes on integer lookup

**File**: `lib/modules/emails/event.ex` (lines 199-203)

**Problem**: The integer clause used `repo().get(id)` which queries by primary key. But Event's PK is `{:uuid, UUIDv7, autogenerate: true}`, so passing an integer to `Repo.get/2` causes a type mismatch error (trying to cast an integer to UUID).

**Root cause**: `Repo.get/2` always queries by the schema's `@primary_key`. After V56 changed the PK to `:uuid`, the integer `id` field became a secondary column — but this function wasn't updated.

**Fix**:
```elixir
# BEFORE:
def get_event(id) when is_integer(id) do
  __MODULE__
  |> preload([:email_log])
  |> repo().get(id)        # Tries to match integer against UUID PK
end

# AFTER:
def get_event(id) when is_integer(id) do
  __MODULE__
  |> where([e], e.id == ^id)   # Explicitly queries the integer id column
  |> preload([:email_log])
  |> repo().one()
end
```

The binary clause was already correct — it checks `e.uuid == ^id` via `where`.

---

### Bug #3 — MEDIUM: EntityData validation skipped when only entity_uuid is set

**File**: `lib/modules/entities/entity_data.ex` (lines 187-230)

**Problem**: Both `sanitize_rich_text_data/1` and `validate_data_against_entity/1` only checked `get_field(changeset, :entity_id)`. If a record was created with only `entity_uuid` set (no integer `entity_id`), the validation and sanitization were silently skipped.

**Root cause**: These functions predate the UUID migration and only looked for the integer FK.

**Fix**:
```elixir
# BEFORE:
entity_id = get_field(changeset, :entity_id)

# AFTER (both functions):
entity_id = get_field(changeset, :entity_id) || get_field(changeset, :entity_uuid)
```

This works because `Entities.get_entity!/1` already handles both integer IDs and UUID strings via its binary clause with `UUIDUtils.valid?/1` detection.

---

### Bug #4 — MEDIUM: Admin "View Profile" links use integer .id in URLs

**Files**:
- `lib/modules/billing/web/invoice_detail.html.heex` (line 490)
- `lib/modules/billing/web/subscription_detail.html.heex` (line 256)

**Problem**: The "View Profile" links in invoice and subscription detail pages used `@invoice.user.id` / `@subscription.user.id` to build admin URLs. The admin user edit route expects a UUID identifier (the User schema's PK is now UUID).

**Fix**:
```heex
<%!-- BEFORE --%>
Routes.path("/admin/users/edit/#{@invoice.user.id}")

<%!-- AFTER --%>
Routes.path("/admin/users/edit/#{@invoice.user.uuid}")
```

Same change in `subscription_detail.html.heex`.

---

### Bug #5 — MEDIUM: Subscription and PaymentMethod missing belongs_to :user

**Files**:
- `lib/modules/billing/schemas/subscription.ex` (lines 75-77)
- `lib/modules/billing/schemas/payment_method.ex` (lines 60-62)

**Problem**: Both schemas had `field :user_uuid, UUIDv7` as a plain field instead of `belongs_to :user`. This means:
- `subscription.user` and `payment_method.user` associations don't exist
- Preloading `:user` would fail
- No FK constraint validation in changesets

All other billing schemas (Order, Invoice, Transaction, BillingProfile) already had proper `belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7`.

**Fix** (`subscription.ex`):
```elixir
# BEFORE:
field :user_id, :integer
field :user_uuid, UUIDv7

# AFTER:
field :user_id, :integer
belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
```

Same pattern for `payment_method.ex`. Added `alias PhoenixKit.Users.Auth.User` to subscription.ex (payment_method.ex uses the full module path inline).

---

### Bug #6 — LOW: phx-value attributes pass integer .id instead of UUID

**Files**:
- `lib/phoenix_kit_web/live/users/users.html.heex` — 4 instances
- `lib/modules/billing/web/subscription_form.html.heex` — 1 instance
- `lib/modules/referrals/web/form.html.heex` — 1 instance
- `lib/modules/referrals/web/form.ex` — handler comparison

**Problem**: LiveView `phx-value-*` attributes always deliver string values. These templates sent `user.id` (integer), which would arrive as `"123"` — still parseable but inconsistent with UUID-first conventions. More critically, if integer IDs are eventually dropped, these would break.

**Fix**: Changed all instances to `user.uuid`:
```heex
<%!-- BEFORE (4 instances in users.html.heex) --%>
phx-value-user_id={user.id}

<%!-- AFTER --%>
phx-value-user_id={user.uuid}
```

The event handlers (`Auth.get_user!/1`, `Auth.get_user/1`) already handle UUID strings, so no handler changes were needed for users.html.heex or subscription_form.html.heex.

For `referrals/form.ex`, the handler used `to_string(user.id) == user_id` to match the selected user in search results — updated to `to_string(user.uuid) == user_id`.

---

### Bug #7 — LOW: aggregate(:count, :id) uses deprecated integer column

**File**: `lib/modules/billing/billing.ex` (lines 337, 439, 658, 1108)

**Problem**: Four pagination/count queries used `:id` as the count column:
- `count(o.id)` in `order_count_for_currency/1`
- `repo().aggregate(base_query, :count, :id)` in `list_billing_profiles/1`, `list_orders/1`, `list_invoices/1`

With UUID-native PKs, `:id` is a secondary `read_after_writes` column. While functionally equivalent (both are NOT NULL), counting on the PK column (`:uuid`) is semantically correct and avoids potential issues if `:id` is ever removed.

**Fix**: Changed all 4 instances from `:id` to `:uuid`.

---

### Bug #8 — LOW: Comments.create_comment rejects UUID user_id strings

**File**: `lib/modules/comments/comments.ex` (lines 120-125)

**Problem**: The binary `user_id` clause only tried `Integer.parse/1`. If a UUID string was passed (e.g., from a LiveView that now sends UUIDs per Bug #6 fixes), it returned `{:error, :invalid_user_id}`.

**Fix**:
```elixir
# BEFORE:
def create_comment(resource_type, resource_id, user_id, attrs) when is_binary(user_id) do
  case Integer.parse(user_id) do
    {int_id, ""} -> create_comment(resource_type, resource_id, int_id, attrs)
    _ -> {:error, :invalid_user_id}
  end
end

# AFTER:
def create_comment(resource_type, resource_id, user_id, attrs) when is_binary(user_id) do
  case Integer.parse(user_id) do
    {int_id, ""} ->
      create_comment(resource_type, resource_id, int_id, attrs)
    _ ->
      # Try UUID lookup
      case Auth.get_user(user_id) do
        %{id: int_id} -> create_comment(resource_type, resource_id, int_id, attrs)
        nil -> {:error, :invalid_user_id}
      end
  end
end
```

Added `alias PhoenixKit.Users.Auth` to the module's alias block (also resolves a Credo nested-module warning).

---

## Verification

All fixes verified with:

| Check | Result |
|-------|--------|
| `mix compile --force` | Clean, no warnings |
| `mix format --check-formatted` | Pass |
| `mix credo --strict` | No issues found |
| `mix test` | 35 tests, 0 failures |

## Files Modified by This Review

| File | Changes |
|------|---------|
| `lib/modules/billing/billing.ex` | Bugs #1, #7 — dual-write `billing_profile_uuid`, count by `:uuid` |
| `lib/modules/emails/event.ex` | Bug #2 — integer lookup via `where` instead of `Repo.get` |
| `lib/modules/entities/entity_data.ex` | Bug #3 — fall back to `entity_uuid` in validation |
| `lib/modules/billing/web/invoice_detail.html.heex` | Bug #4 — `.uuid` in admin URL |
| `lib/modules/billing/web/subscription_detail.html.heex` | Bug #4 — `.uuid` in admin URL |
| `lib/modules/billing/schemas/subscription.ex` | Bug #5 — `belongs_to :user` |
| `lib/modules/billing/schemas/payment_method.ex` | Bug #5 — `belongs_to :user` |
| `lib/phoenix_kit_web/live/users/users.html.heex` | Bug #6 — `phx-value` uses `.uuid` |
| `lib/modules/billing/web/subscription_form.html.heex` | Bug #6 — `phx-value` uses `.uuid` |
| `lib/modules/referrals/web/form.html.heex` | Bug #6 — `phx-value` uses `.uuid` |
| `lib/modules/referrals/web/form.ex` | Bug #6 — handler matches on `.uuid` |
| `lib/modules/comments/comments.ex` | Bug #8 — UUID user_id resolution + alias |

## Patterns to Watch in Future PRs

1. **Any function loading a related record should dual-write the UUID FK** — search for patterns like `get_billing_profile!` / `get_user!` where the loaded record's UUID isn't propagated to attrs.

2. **`Repo.get/2` on UUID-PK schemas** — after switching `@primary_key` to `{:uuid, UUIDv7, ...}`, any `Repo.get(schema, integer_id)` call will fail. Audit all `repo().get(` calls in modules with UUID PKs.

3. **Template URLs** — grep for `.id}` in `.heex` files to find remaining integer ID usage in URL interpolation. Prefer `.uuid` for all user-facing URLs.

4. **phx-value attributes** — always send `.uuid` values. Handlers that receive these strings should use `Auth.get_user/1` or `PhoenixKit.UUID.get/2` which auto-detect the identifier type.

5. **Count queries** — use `:uuid` (the PK) instead of `:id` for `aggregate(:count, ...)` on UUID-native schemas.

6. **Changeset validation fallbacks** — any validation that resolves a parent record by FK should check both `*_id` and `*_uuid` fields during the transition period.
