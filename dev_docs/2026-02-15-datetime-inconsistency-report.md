# DateTime Inconsistency Report

**Date:** 2026-02-15
**Severity:** Medium (already caused a production bug)
**Recommendation:** Standardize on `:utc_datetime` + `DateTime.utc_now()` everywhere (existing `:utc_datetime_usec` schemas left as-is)

---

## The Bug That Triggered This Audit

On 2026-02-15 we discovered that creating any Entity (e.g., "Plugin") crashes with an `Ecto.ChangeError`. Root cause: commit `e5c7d73f` (V56 UUID migration, 2026-02-13) rewrote the `maybe_set_timestamps/1` function and accidentally replaced `DateTime.utc_now()` with `NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)`. The schema fields are typed `:utc_datetime_usec` (expects `DateTime`), so Ecto rejected the `NaiveDateTime` value.

The original code (commit `b09a209f`, 2025-10-05) was correct. The regression was introduced during a large refactor where a timestamp pattern was copy-pasted from a module that uses `:naive_datetime` fields.

**This bug exists because we have inconsistent datetime conventions.** A developer copying patterns from one module to another will hit this mismatch.

---

## Current State: 3 Different Conventions

### In the Database (PostgreSQL)

**Every single timestamp column** in the database is `timestamp without time zone`. There are **zero** `timestamptz` columns. The only difference is precision:

| PostgreSQL Type | Precision | Column Count | Table Count |
|-----------------|-----------|-------------|-------------|
| `timestamp without time zone` | 0 (seconds) | 64 | 34 |
| `timestamp without time zone` | 6 (microseconds) | 135 | 43 |
| `timestamp with time zone` | — | **0** | **0** |

### In Ecto Schemas

| Ecto Type | Expects | Columns | Used In |
|-----------|---------|---------|---------|
| `timestamps()` / `:naive_datetime` | `NaiveDateTime` | ~28 | Users, Roles, Connections, Storage |
| `:utc_datetime` | `DateTime` (seconds) | 12 | Billing subscriptions, Shop carts, Webhooks |
| `:utc_datetime_usec` | `DateTime` (microseconds) | 50+ | Entities, Emails, AI, Posts, Sync, Tickets, Settings, Referrals |

### In Application Code

| Pattern | Used In |
|---------|---------|
| `NaiveDateTime.utc_now() \|> NaiveDateTime.truncate(:second)` | Users, Connections, Storage, Permissions |
| `NaiveDateTime.utc_now()` | Sessions, Comments |
| `DateTime.utc_now()` | Entities (after fix), Settings, newer modules |

---

## Tables Using Seconds Precision (precision=0)

These 34 tables have `timestamp(0)` columns that lose sub-second precision:

| Table | Timestamp Columns |
|-------|-------------------|
| `phoenix_kit_users` | `confirmed_at`, `inserted_at`, `updated_at` |
| `phoenix_kit_users_tokens` | `inserted_at` |
| `phoenix_kit_user_roles` | `inserted_at`, `updated_at` |
| `phoenix_kit_user_role_assignments` | `assigned_at`, `inserted_at` |
| `phoenix_kit_admin_notes` | `inserted_at`, `updated_at` |
| `phoenix_kit_user_blocks` | `inserted_at` |
| `phoenix_kit_user_blocks_history` | `inserted_at` |
| `phoenix_kit_user_connections` | `inserted_at`, `updated_at`, `requested_at`, `responded_at` |
| `phoenix_kit_user_connections_history` | `inserted_at` |
| `phoenix_kit_user_follows` | `inserted_at` |
| `phoenix_kit_user_follows_history` | `inserted_at` |
| `phoenix_kit_posts` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_comments` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_likes` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_dislikes` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_views` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_mentions` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_tags` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_tag_assignments` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_groups` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_group_assignments` | `inserted_at`, `updated_at` |
| `phoenix_kit_post_media` | `inserted_at`, `updated_at` |
| `phoenix_kit_tickets` | `inserted_at`, `updated_at` |
| `phoenix_kit_ticket_comments` | `inserted_at`, `updated_at` |
| `phoenix_kit_ticket_attachments` | `inserted_at`, `updated_at` |
| `phoenix_kit_ticket_status_history` | `inserted_at` |
| `phoenix_kit_comment_likes` | `inserted_at`, `updated_at` |
| `phoenix_kit_comment_dislikes` | `inserted_at`, `updated_at` |
| `phoenix_kit_files` | `inserted_at`, `updated_at` |
| `phoenix_kit_file_instances` | `inserted_at`, `updated_at` |
| `phoenix_kit_file_locations` | `inserted_at`, `updated_at`, `last_verified_at` |
| `phoenix_kit_storage_dimensions` | `inserted_at`, `updated_at` |
| `phoenix_kit_buckets` | `inserted_at`, `updated_at` |
| `phoenix_kit` | `migrated_at` |

---

## Why This Matters

### 1. Copy-Paste Bugs (Already Happened)
Different modules use different patterns. Copying timestamp code between modules causes runtime crashes when `NaiveDateTime` meets a `:utc_datetime_usec` field. This is exactly what caused the Entities bug.

### 2. No Timezone Safety
All 199 timestamp columns are `timestamp without time zone`. PostgreSQL stores them as-is with no timezone context. If any code ever passes a non-UTC time, it gets stored silently without conversion. Using `timestamptz` would let PostgreSQL normalize to UTC automatically.

### 3. Precision Loss
64 columns truncate to whole seconds. For most use cases this is fine, but it creates inconsistency when joining or comparing timestamps from different tables (e.g., a post's `published_at` has microseconds but `inserted_at` doesn't).

### 4. Ecto Type Confusion
Three different Ecto types that produce three different Elixir structs:
- `:naive_datetime` returns `NaiveDateTime` (no timezone info)
- `:utc_datetime` returns `DateTime` with `time_zone: "Etc/UTC"` (seconds)
- `:utc_datetime_usec` returns `DateTime` with `time_zone: "Etc/UTC"` (microseconds)

Code that receives values from different schemas needs to handle all three, or risk comparison/formatting bugs.

---

## Recommendation: Standardize on `:utc_datetime` + `DateTime.utc_now()`

### Target State

| Layer | Standard | Notes |
|-------|----------|-------|
| **Ecto Schema** | `:utc_datetime` | Returns `DateTime` with second precision |
| **Application Code** | `DateTime.utc_now()` | Consistent everywhere, already returns second precision |
| **Default timestamps** | `timestamps(type: :utc_datetime)` | Override Ecto's default |
| **Existing `:utc_datetime_usec`** | Leave as-is | Already works correctly, no need to downgrade |

### Why `:utc_datetime` (not `:utc_datetime_usec`)

- Microsecond precision is not needed for this application
- Second precision matches the existing `timestamp(0)` database columns — no DB migration required
- **IMPORTANT:** `DateTime.utc_now()` returns **microsecond** precision — all DB writes MUST use `DateTime.truncate(DateTime.utc_now(), :second)`. See `2026-02-17-datetime-standardization-plan.md` Step 5 for the full list of call sites.
- Simpler migration path: only schema + application code changes, no database column alterations

### Why not `:naive_datetime`

- `NaiveDateTime` has no timezone information, making it easy to misuse
- `DateTime` with UTC timezone is explicit about the timezone context
- Copying `DateTime.utc_now()` between any modules (`:utc_datetime` or `:utc_datetime_usec`) works correctly
- Ecto automatically handles `DateTime` → `:utc_datetime_usec` promotion (adds zero microseconds)

### Database Migration (Deferred)

Converting `timestamp(0)` → `timestamptz` columns is deferred to a separate V58 migration. The schema-level change to `:utc_datetime` is safe with existing `timestamp(0)` columns because Ecto handles the conversion transparently.

---

## Migration Plan

### Phase 1: Standardize Schemas and Application Code (COMPLETED 2026-02-17)

All schemas and application code have been updated:

1. **Schema timestamps:** All `timestamps()` and `timestamps(type: :naive_datetime)` → `timestamps(type: :utc_datetime)`
2. **Individual fields:** All `field :name, :naive_datetime` → `field :name, :utc_datetime`
3. **Application code:** All `NaiveDateTime.utc_now()` → `DateTime.utc_now()` in non-display code
4. **Convention added to CLAUDE.md** to prevent future regressions

**Files updated:** ~38 schema files, 9 field type files, 14 application code files

**What was NOT changed:**
- Schemas already on `:utc_datetime_usec` (left as-is, they work correctly)
- Schemas already on `:utc_datetime` (already correct)
- Display/formatter code in `time_display.ex` and `file_display.ex` (handles both DateTime and NaiveDateTime)

### Phase 2: Database Migration (Deferred)

Converting `timestamp(0)` → `timestamptz` columns deferred to a separate V58 migration. The schema-level changes are safe with existing columns.

### Phase 3: Verify and Clean Up

- Compile with `--warnings-as-errors` — no type warnings
- Run `mix test`, `mix format`, `mix credo --strict`
- Verify no remaining `NaiveDateTime.utc_now()` in application code (only in display utilities)

---

## Effort Estimate

| Phase | Scope | Risk |
|-------|-------|------|
| Phase 1 — Conventions | Documentation only | None |
| Phase 2 — Schema + Code | ~20 files, ~30 line changes | Low (backwards-compatible) |
| Phase 3 — DB Migration | 1 migration file, 34+ tables | Medium (requires testing) |
| Phase 4 — Verification | Testing and cleanup | Low |

---

## Appendix: Column Inventory

**Total PhoenixKit timestamp columns:** 199
- Precision 0 (seconds): 64 columns across 34 tables
- Precision 6 (microseconds): 135 columns across 43 tables
- `timestamptz`: 0 columns

**Ecto schema type distribution:**
- `timestamps()` / `:naive_datetime`: ~28 fields (expects `NaiveDateTime`)
- `:utc_datetime`: 12 fields (expects `DateTime`, seconds)
- `:utc_datetime_usec`: 50+ fields (expects `DateTime`, microseconds)


---

## Verification Findings (Added 2026-02-15)

### Codebase Analysis Summary

All major findings in this report have been **verified against the current codebase**. The datetime inconsistency is confirmed to be a real issue with concrete examples of mixed patterns across modules.

---

### Cross-Reference: Schema Types vs Application Code

| Module | Schema Type | Application Code Pattern | Status |
|--------|-------------|--------------------------|--------|
| `Entities` | `:utc_datetime_usec` | `DateTime.utc_now()` | ✅ Consistent |
| `EntityData` | `:utc_datetime_usec` | `DateTime.utc_now()` | ✅ Consistent |
| `User` | `:naive_datetime` | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `UserToken` | `:naive_datetime` | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `Role` | `:naive_datetime` (default) | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `RoleAssignment` | `:naive_datetime` (default) | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `RolePermission` | `:naive_datetime` (migration) | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `Connections.Connection` | `:naive_datetime` | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `Connections.Follow` | `:naive_datetime` | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `Connections.Block` | `:naive_datetime` | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `Comments` | `:naive_datetime` | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `Storage` | `:naive_datetime` | `NaiveDateTime.utc_now()` | ✅ Consistent |
| `Emails.Log` | `:utc_datetime_usec` | `DateTime.utc_now()` | ✅ Consistent |
| `Sync.Connection` | `:utc_datetime_usec` | `DateTime.utc_now()` | ✅ Consistent |
| `Billing.Subscription` | `:utc_datetime` | `DateTime.utc_now()` | ✅ Consistent |
| `Billing.WebhookEvent` | `:utc_datetime` | `DateTime.utc_now()` | ✅ Consistent |
| `Shop.Cart` | `:utc_datetime` | `DateTime.utc_now()` | ✅ Consistent |

**Key Finding:** All modules are internally consistent, but **copying code between modules causes crashes** because the type expectations differ.

---

### Copy-Paste Danger Zones

These are specific examples where copying code from one module to another will cause runtime crashes:

#### ❌ DANGER: Copying from Users to Entities
```elixir
# From lib/phoenix_kit/users/auth/user.ex:322 (NAIVE_DATETIME schema)
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
change(user, confirmed_at: now)

# If you copy this to Entities (UTC_DATETIME_USEC schema):
# => Ecto.ChangeError: value `#NaiveDateTime<...>` for field `date_created` 
#    in schema PhoenixKit.Modules.Entities does not match type :utc_datetime_usec
```

#### ❌ DANGER: Copying from Storage to Emails
```elixir
# From lib/modules/storage/storage.ex:238 (NAIVE_DATETIME)
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

# Emails.Log schema expects :utc_datetime_usec
# => Runtime crash on insert
```

#### ❌ DANGER: Bulk Updates with Wrong Type
```elixir
# From lib/modules/comments/comments.ex:302 (NAIVE_DATETIME schema)
|> repo().update_all(set: [status: status, updated_at: NaiveDateTime.utc_now()])

# If you copy this pattern to an entity with :utc_datetime_usec timestamps:
# => Ecto.Query.CastError: expected type :utc_datetime_usec
```

---

### Migration Version Quick Reference

Quick lookup for which migrations use which datetime types:

| DateTime Type | Migration Versions | Description |
|---------------|-------------------|-------------|
| `:naive_datetime` | V01, V20, V29, V35, V36, V39, V48 | Core users, roles, posts, tickets, comments, storage |
| `:utc_datetime` | V45 (Shop), Billing modules | Subscriptions, carts, webhooks - seconds precision |
| `:utc_datetime_usec` | V07, V15, V16, V22, V31-V34, V37, V38, V42-V43 | Emails, AI, Sync, Audit logs, Entities, newer modules |

**Pattern:** Earlier migrations (V01-V48) predominantly use `:naive_datetime`. Newer modules (V07+) shifted to `:utc_datetime_usec`.

---

### High-Risk Files List

These files have the highest copy-paste risk due to mixing with adjacent modules:

| File | Risk Level | Reason |
|------|------------|--------|
| `lib/phoenix_kit/users/permissions.ex:504` | 🔴 High | Sets timestamps manually for `role_permissions` table; adjacent to `Role`/`RoleAssignment` code that uses `:naive_datetime` |
| `lib/modules/comments/comments.ex:302` | 🔴 High | Bulk update pattern with `NaiveDateTime.utc_now()`; easily copied to modules with `:utc_datetime_usec` |
| `lib/modules/storage/storage.ex:238` | 🔴 High | Manual timestamp insertion; storage module sits alongside newer modules using `:utc_datetime_usec` |
| `lib/phoenix_kit/users/sessions.ex:234` | 🟡 Medium | Uses `NaiveDateTime.utc_now()` but only for query boundaries, not schema fields |
| `lib/phoenix_kit_web/components/core/time_display.ex:176` | 🟡 Medium | Uses `NaiveDateTime.utc_now()` for display logic; could be copied to schema code |
| `lib/phoenix_kit_web/components/core/file_display.ex:101` | 🟡 Medium | Uses `NaiveDateTime.utc_now()` for display logic |

---

### Verified Line Numbers (Phase 2)

All line numbers from Phase 2 of the original report have been verified and are accurate as of the report date:

```
lib/phoenix_kit/users/auth/user.ex:322                        ✅
lib/phoenix_kit/users/sessions.ex:234,290,294                ✅
lib/phoenix_kit/users/permissions.ex:504                     ✅
lib/phoenix_kit/users/magic_link_registration.ex:166         ✅
lib/phoenix_kit/users/roles.ex:783                           ✅
lib/phoenix_kit/users/role_assignment.ex:113                 ✅
lib/modules/storage/storage.ex:238                           ✅
lib/modules/connections/follow.ex:99                         ✅
lib/modules/connections/block.ex:110                         ✅
lib/modules/connections/block_history.ex:51                  ✅
lib/modules/connections/connection.ex:153,165                ✅
lib/modules/connections/connection_history.ex:83             ✅
lib/modules/connections/follow_history.ex:50                 ✅
lib/modules/comments/comments.ex:302                         ✅
```

---

### Current Codebase Statistics

| Metric | Count |
|--------|-------|
| Files with `NaiveDateTime.utc_now()` | 17 files (26 occurrences) |
| Files with `DateTime.utc_now()` | 100+ files (200+ occurrences) |
| Schema files with `:naive_datetime` | 28 files |
| Schema files with `:utc_datetime` | 7 files |
| Schema files with `:utc_datetime_usec` | 27 files |
| Migrations using `:naive_datetime` | 39 occurrences |
| Migrations using `:utc_datetime_usec` | 101 occurrences |
| Migrations using `timestamptz` | **0** |

---

### Recommendation Priority Update

**Status: Phase 1 COMPLETED (2026-02-17), Partial Truncation Fix (2026-02-18)**

All schema and application code standardized on `:utc_datetime` + `DateTime.utc_now()`. Convention added to CLAUDE.md.

**PR #350 Progress (2026-02-18):**
- Fixed 19/50+ truncation sites (38% complete)
- Fixed Group struct conversion bug
- Fixed live sessions UUID lookup bug

**Remaining Critical Work:**
1. **CRITICAL — DateTime truncation:** 31+ `DateTime.utc_now()` calls still need `DateTime.truncate(:second)` before writing to `:utc_datetime` fields. Highest risk modules: Emails (22 sites), Sync (15 sites), Connections (7 sites). Full inventory in `2026-02-17-datetime-standardization-plan.md` Step 5.
2. **Recommended:** Add centralized `UtilsDateTime.utc_now/0` helper that returns pre-truncated values
3. **Database migration (V58):** Convert `timestamp(0)` → `timestamptz` columns (deferred, requires downtime planning)
4. **Optional:** Add Credo check or compile-time warning for bare `DateTime.utc_now()` in DB-write contexts

## Post-PR #350 Status (Added 2026-02-19)

**Current State:**
- ✅ All schemas standardized to `:utc_datetime`
- ✅ All `NaiveDateTime.utc_now()` converted to `DateTime.utc_now()`
- ⚠️ Only 38% of truncation sites fixed (19/50+)
- ❌ 31+ crash sites remain unfixed

**Risk Assessment:**
- **CRITICAL:** Emails module (22 sites) - Email processing workflows will crash
- **CRITICAL:** Sync module (15 sites) - Data synchronization workflows will crash  
- **HIGH:** Connections module (7 sites) - User connection tracking will crash
- **HIGH:** Billing module (5 sites) - Subscription processing may crash
- **MEDIUM:** Shop, Entities, AI, Posts modules (10+ sites)

**Immediate Action Required:**
Complete Step 5 of the standardization plan by fixing all remaining truncation sites, prioritizing Emails and Sync modules first.

