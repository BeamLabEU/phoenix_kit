# REVIEW_KIMI.md — PR #350

**Reviewer:** Kimi (Claude Code CLI)
**Date:** 2026-02-19
**Verdict:** Approve with critical follow-up required

---

## Executive Summary

This PR fixes three real runtime crashes introduced by PR #347's schema migration from `:utc_datetime_usec` to `:utc_datetime`. The fixes are mechanically correct, but the DateTime truncation fix is incomplete — approximately 17 call sites remain unfixed and will crash when hit.

---

## 1. DateTime.utc_now() Truncation Fixes

### The Problem
`DateTime.utc_now()` returns microseconds (e.g., `2026-02-19T00:52:08.673151Z`), but `:utc_datetime` fields reject non-zero microseconds with `ArgumentError`.

### Verified Fixed Sites (19 files)

| Module | Fields |
|--------|--------|
| `Billing.Invoice` | `sent_at`, `paid_at`, `voided_at` |
| `Billing.Order` | `confirmed_at`, `paid_at`, `cancelled_at` |
| `Comments` | `updated_at` (bulk operations) |
| `Emails.Event` | `occurred_at` |
| `Emails.Log` | `queued_at` |
| `Emails.Templates` | `last_used_at` |
| `Referrals` | `date_created` |
| `Referrals.ReferralCodeUsage` | `date_used` |
| `Shop` | `updated_at` (3 bulk operations) |
| `Tickets` | `resolved_at`, `closed_at` |
| `ScheduledJobs` | `updated_at` |
| `ScheduledJobs.ScheduledJob` | `executed_at` |
| `Settings.Setting` | `date_added`, `date_updated` |
| `Users.Auth` | `anonymized_at` |
| `Users.Auth.User` | `confirmed_at` |
| `Users.MagicLinkRegistration` | `confirmed_at` |
| `Users.Permissions` | bulk insert timestamps |
| `Users.RoleAssignment` | `assigned_at` |
| `Users.Roles` | `confirmed_at` |

All fixes use the correct pattern:
```elixir
DateTime.truncate(DateTime.utc_now(), :second)
```

### Critical Gap: Missed Sites (Verified Independently)

These **will crash** when their code paths execute:

#### `lib/modules/sync/` — 11 sites

| File | Line(s) | Field(s) | Usage |
|------|---------|----------|-------|
| `connection.ex` | 219 | `approved_at` | Connection approval |
| `connection.ex` | 232 | `suspended_at` | Connection suspension |
| `connection.ex` | 246 | `revoked_at` | Connection revocation |
| `connections.ex` | 500 | `last_connected_at` | Stats update |
| `connections.ex` | 501 | `last_transfer_at` | Stats update |
| `connections.ex` | ~631 | `updated_at` | Bulk update_all |
| `transfer.ex` | 179 | `started_at` | Transfer start |
| `transfer.ex` | 219, 231, 242 | `completed_at` | Transfer completion |
| `transfer.ex` | 250 | `approval_expires_at` | Expiration (chains untruncated) |
| `transfer.ex` | 267 | `approved_at` | Transfer approval |
| `transfer.ex` | 280 | `denied_at` | Transfer denial |

**Note on line 250:** The calculation chains the untruncated value:
```elixir
expires_at = DateTime.utc_now() |> DateTime.add(expires_in_hours * 3600, :second)
```
This produces microseconds which will crash on write.

#### `lib/modules/connections/` — 6 sites

| File | Line | Field |
|------|------|-------|
| `follow.ex` | 116 | `inserted_at` |
| `block.ex` | 124 | `inserted_at` |
| `block_history.ex` | 59 | `inserted_at` |
| `connection.ex` | 170 | `requested_at` |
| `connection.ex` | 182 | `responded_at` |
| `connection_history.ex` | 98 | `inserted_at` |

#### `lib/modules/emails/` — 2 sites

| File | Line | Field | Context |
|------|------|-------|---------|
| `interceptor.ex` | 251 | `sent_at` | Writes to Emails.Log |
| `event.ex` | 917, 921 | `occurred_at` | parse_timestamp fallback |

---

## 2. Group Struct Conversion Fix

### The Bug
`Registry.handle_call({:register_groups, ...})` stored plain maps in ETS. Sidebar templates using dot syntax (`group.label`) crashed because maps don't enforce struct fields.

### The Fix (Verified Correct)
```elixir
converted =
  Enum.map(groups, fn
    %Group{} = g -> g
    map when is_map(map) -> Group.new(map)
  end)
```

**Pattern Match:** Mirrors `load_from_config_internal/0` exactly.
**Key Handling:** `Group.new/1` normalizes both atom and string keys.
**Edge Case:** Non-maps will raise `FunctionClauseError` — acceptable for invalid input.

---

## 3. Live Sessions UUID Fix

### The Bug
`SimplePresence.track_user` stores `user.uuid` in `session.user_id`, but `preload_users_for_sessions/1` queried by integer `id`, causing `Ecto.Query.CastError`.

### The Fix (Verified Correct)

**New function:** `Auth.get_users_by_uuids/1`
```elixir
def get_users_by_uuids([]), do: []

def get_users_by_uuids(uuids) when is_list(uuids) do
  from(u in User, where: u.uuid in ^uuids)
  |> Repo.all()
end
```

**Updated preloading:**
```elixir
defp preload_users_for_sessions(sessions) do
  user_uuids =
    sessions
    |> Enum.filter(&(&1.type == :authenticated))
    |> Enum.map(& &1.user_id)  # Actually contains UUID
    |> Enum.uniq()

  case user_uuids do
    [] -> %{}
    uuids -> Auth.get_users_by_uuids(uuids) |> Map.new(&{&1.uuid, &1})
  end
end
```

**Data Flow Verified:**
```
SimplePresence.track_user (stores user.uuid as user_id)
  → preload_users_for_sessions (extracts UUID)
    → get_users_by_uuids (queries by UUID)
      → Map keyed by uuid
        → Template lookup: Map.get(@users_map, session.user_id) ✓
```

**Minor Issue:** The `session.user_id` field name is misleading (contains UUID, not integer ID). Consider renaming to `user_uuid` in future refactor.

---

## 4. Code Quality Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Correctness | ✅ | All 21 fixes are mechanically correct |
| Completeness | ⚠️ | DateTime fix misses ~17 critical sites |
| Minimality | ✅ | No scope creep, surgical changes |
| Style | ✅ | Order case reformatting improves readability |
| Documentation | ⚠️ | `get_users_by_uuids/1` has stub doc, no examples |
| Commit Quality | ✅ | Clean separation, clear messages |

---

## 5. Critical Recommendations

### 5.1 Immediate: Follow-up PR Required

**Priority: Critical**

A follow-up PR must:
1. Fix the ~17 remaining DateTime sites in `sync/`, `connections/`, `emails/`
2. Add a centralized helper function
3. Migrate all existing `DateTime.truncate(DateTime.utc_now(), :second)` to use the helper

**Risk Assessment:**
- `sync` module: **High risk** — used in production data synchronization
- `connections` module: **High risk** — social features likely actively used
- `emails` module: **Medium risk** — interceptor runs on every email send

### 5.2 Add Centralized Helper

Create `PhoenixKit.Utils.DateTime`:

```elixir
defmodule PhoenixKit.Utils.DateTime do
  @moduledoc """
  DateTime utilities for PhoenixKit.
  """

  @doc """
  Returns current UTC datetime truncated to seconds for `:utc_datetime` fields.
  
  ## Examples
  
      iex> utc_now()
      ~U[2026-02-19 00:52:08Z]
  """
  @spec utc_now() :: DateTime.t()
  def utc_now do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end
end
```

**Benefits:**
- Single source of truth
- Self-documenting
- Prevents future bugs
- Testable/movable

### 5.3 Consider Credo Check

Add a custom credo check to warn on direct `DateTime.utc_now()` in schema changesets:

```elixir
# Conceptual
defmodule PhoenixKit.Credo.Check.Warning.UtcNowInSchema do
  # Warns if DateTime.utc_now() is used without truncation in schema contexts
end
```

---

## 6. Testing Observations

No new tests were added for these fixes. Recommended regression tests:

1. **Group struct conversion:**
   ```elixir
   test "register_groups converts plain maps to Group structs" do
     :ok = Registry.register_groups([%{id: :test, label: "Test"}])
     [%Group{} = group] = Registry.get_groups()
     assert group.label == "Test"
   end
   ```

2. **UUID lookup in sessions:** Test that authenticated sessions correctly display user info

3. **DateTime truncation:** Integration tests that trigger writes to the affected schema fields

---

## Final Verdict

**Approve and merge this PR** — it fixes immediate crash vectors and the changes are correct.

**However, prioritize an immediate follow-up PR** to fix the remaining ~17 DateTime sites. The `sync` module in particular is high-risk for production data synchronization workflows.

---

## Related

- Parent PR #347 — The `:utc_datetime_usec` → `:utc_datetime` schema migration
- CLAUDE.md — Should reference truncation requirement once helper is implemented
- `dev_docs/audits/2026-02-15-datetime-inconsistency-report.md` — Related datetime analysis
