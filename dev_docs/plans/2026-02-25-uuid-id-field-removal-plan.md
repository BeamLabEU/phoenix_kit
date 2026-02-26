# Plan: Remove All Legacy `_id` Fields from Code

**Date:** 2026-02-25
**Updated:** 2026-02-26
**Goal:** Remove all integer `_id` field usage so we can drop `_id` columns from DB in a few weeks
**Audit:** `dev_docs/audits/2026-02-25-uuid-cleanup-remaining-id-fields-audit.md` (verified)
**Approach:** No backward compatibility. UUID-only. Delete integer code paths entirely.

---

## Completion Status

| Work Item | Commit | Status |
|-----------|--------|--------|
| Phase 1: Schema `_id` FK field removal (listed schemas) | `f98159cc` | **DONE** |
| PK `field :id` removal + all `.id` access migration | `ca43e3f7` | **DONE** |
| Phase 2: Context function integer overload cleanup | `5a957918` | **DONE** |
| Phase 3: Callers and references | `5a957918` | **DONE** |
| Phase 4: Verify | `5a957918` | **DONE** |
| Phase 5: Final cleanup of remaining legacy `_id` fields | `CURRENT` | **DONE** |

### Additional completed work (commit `ca43e3f7`):
- Removed `field :id, :integer, read_after_writes: true` from ALL 40 schemas
- Converted ALL `.id` struct accesses to `.uuid` across entire codebase
- Deleted `lib/phoenix_kit/uuid.ex` (temporary dual-lookup module)
- Deleted `resolve_user_id` and `resolve_role_id` from `permissions.ex`
- Rewrote `ScopeNotifier` for UUID-based PubSub topics
- Changed `Scope.user_id/1` to return UUID instead of integer
- Updated all `count(x.id)` → `count(x.uuid)` in Ecto queries
- Changed integer overloads in core `get_*` functions to use `fragment("id = ?", ^id)`

### Final cleanup work (current session):
- Removed legacy integer `_id` fields from 17 additional schemas across 7 modules
- Updated corresponding `@type` specs, `cast()` calls, and documentation
- Fixed function implementations that were accessing removed fields
- Verified compilation, tests (485 passing), formatting, and static analysis

---

## Phase 1: Schema Cleanup — Remove `_id` from field declarations and cast()

For each file: remove `field :*_id, :integer` declarations AND remove `_id` atoms from `cast()` calls.

**All items below completed in commit `f98159cc`.**

### Billing Schemas

- [x] `lib/modules/billing/schemas/invoice.ex`
- [x] `lib/modules/billing/schemas/billing_profile.ex`
- [x] `lib/modules/billing/schemas/payment_method.ex`
- [x] `lib/modules/billing/schemas/subscription.ex`
- [x] `lib/modules/billing/schemas/transaction.ex`
- [x] `lib/modules/billing/schemas/order.ex`

### Shop Schemas

- [x] `lib/modules/shop/schemas/cart.ex`
- [x] `lib/modules/shop/schemas/cart_item.ex`
- [x] `lib/modules/shop/schemas/category.ex`
- [x] `lib/modules/shop/schemas/product.ex`
- [x] `lib/modules/shop/schemas/import_log.ex`

### Comments Schemas

- [x] `lib/modules/comments/schemas/comment.ex`
- [x] `lib/modules/comments/schemas/comment_dislike.ex`
- [x] `lib/modules/comments/schemas/comment_like.ex`

### Posts Schemas

- [x] `lib/modules/posts/schemas/post.ex`
- [x] `lib/modules/posts/schemas/post_group.ex`
- [x] `lib/modules/posts/schemas/post_comment.ex`
- [x] `lib/modules/posts/schemas/post_like.ex`
- [x] `lib/modules/posts/schemas/post_dislike.ex`
- [x] `lib/modules/posts/schemas/post_mention.ex`
- [x] `lib/modules/posts/schemas/post_view.ex`
- [x] `lib/modules/posts/schemas/comment_dislike.ex`
- [x] `lib/modules/posts/schemas/comment_like.ex`

### Other Module Schemas

- [x] `lib/modules/legal/schemas/consent_log.ex`
- [x] `lib/modules/referrals/schemas/referral_code_usage.ex`
- [x] `lib/modules/publishing/schemas/publishing_post.ex`
- [x] `lib/modules/publishing/schemas/publishing_version.ex`
- [x] `lib/modules/storage/schemas/file.ex`

### Core PhoenixKit Schemas

- [x] `lib/phoenix_kit/users/oauth_provider.ex`
- [x] `lib/phoenix_kit/users/admin_note.ex`
- [x] `lib/phoenix_kit/users/role_permission.ex`
- [x] `lib/phoenix_kit/audit_log/entry.ex`
- [x] `lib/phoenix_kit/users/auth/user_token.ex`

### Special Case: Missing UUID Field

- [x] `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` — `created_by_id` removed, `created_by_uuid` added

---

## Schemas NOT in original plan that still have `_id` fields

These were not covered by Phase 1 and still have `field :*_id, :integer` declarations:

### AI Module
- [x] `lib/modules/ai/request.ex` — `endpoint_id`, `prompt_id`, `account_id`, `user_id` ✓

### Entities Module
- [x] `lib/modules/entities/entity_data.ex` — `entity_id` ✓

### Emails Module
- [x] `lib/modules/emails/log.ex` — `user_id` ✓
- [x] `lib/modules/emails/rate_limiter.ex` — `user_id` ✓
- [x] `lib/modules/emails/event.ex` — `email_log_id` ✓
- [x] `lib/modules/emails/template.ex` — `created_by_user_id`, `updated_by_user_id` ✓

### Tickets Module
- [x] `lib/modules/tickets/ticket.ex` — `user_id`, `assigned_to_id` ✓
- [x] `lib/modules/tickets/ticket_comment.ex` — `user_id` ✓
- [x] `lib/modules/tickets/ticket_status_history.ex` — `changed_by_id` ✓

### Connections Module
- [x] `lib/modules/connections/connection.ex` — `requester_id`, `recipient_id` ✓
- [x] `lib/modules/connections/connection_history.ex` — `user_a_id`, `user_b_id`, `actor_id` ✓
- [x] `lib/modules/connections/follow.ex` — `follower_id`, `followed_id` ✓
- [x] `lib/modules/connections/follow_history.ex` — `follower_id`, `followed_id` ✓
- [x] `lib/modules/connections/block.ex` — `blocker_id`, `blocked_id` ✓
- [x] `lib/modules/connections/block_history.ex` — `blocker_id`, `blocked_id` ✓

### Sync Module
- [x] `lib/modules/sync/transfer.ex` — `connection_id`, `approved_by` ✓

---

## Phase 2: Context Function Cleanup — Remove integer ID support

Delete integer overloads and ID-to-UUID resolution functions entirely.

### Billing Context

- [x] `billing.ex` — `extract_user_uuid` integer overloads removed (commit `5a957918`)
- [x] `billing.ex` — `resolve_plan_uuid/1` integer overload removed (commit `5a957918`)

### Shop Context

- [x] `shop.ex` — `category_product_options_query/1` — integer overload removed (now UUID-only)
- [x] `shop.ex` — `filter_by_category/2` — integer overload removed (now UUID-only)
- [x] `shop.ex` — `filter_by_parent/2` — integer overload removed (commit `5a957918`)

### AI Context

- [x] `ai.ex` — `maybe_filter_by/3` `:endpoint_id` — integer overload removed (now UUID-only)
- [x] `ai.ex` — `maybe_filter_by/3` `:user_id` — integer overload removed (now UUID-only)

### Sync Context

- [x] `transfers.ex` — `filter_by_connection/2` — integer overload removed (`5a957918`)

### Entities Context

- [x] `entity_data.ex` — `list_by_entity/1` — integer overload removed (`5a957918`)
- [x] `entity_data.ex` — `list_by_entity_and_status/2` — integer overload removed (`5a957918`)
- [x] `entity_data.ex` — `count_by_entity/1` — integer overload removed (`5a957918`)

### Other Context Functions (not in original plan)

- [x] `comments/comments.ex` — `resolve_user_uuid` integer overload + entire function removed (`5a957918`)
- [x] `publishing/dual_write.ex` — `resolve_user_ids` integer overloads removed (current session)

---

## Phase 3: Callers and References

- [x] Check `@type` specs on schemas — removed `id: integer()` from typespecs
- [x] Search for remaining `extract_user_uuid` calls in billing and eliminate them (current session)
- [x] Search for `Integer.parse` patterns used for ID fallback and remove them (`5a957918`)
- [x] Search for remaining `_id` usage in LiveViews, controllers, templates (current session)

---

## Phase 4: Verify

- [x] `mix compile --warnings-as-errors` — no warnings (`5a957918`)
- [x] `mix format` (`5a957918`)
- [x] `mix credo --strict` (`5a957918`)
- [x] `mix test` — all 485 pass (`5a957918`)
- [x] `mix test` — all 485 pass (current session verification)
- [x] `mix format` (current session)
- [x] `mix credo --strict` (current session)
- [x] Grep: `grep -r '_id.*:integer' lib/ --include='*.ex' | grep -v '#'` returns only `product_ids` array field (intentional)

---

## Notes

- ~~`field :id, :integer, read_after_writes: true` on Pattern 1 tables is the **primary key** — leave it alone until the full PK migration~~ **DONE** — removed from all 40 schemas in commit `ca43e3f7`
- `session_id` in `post_view.ex` is a `:string` for deduplication — not an FK, leave it
- `webhook_event.ex` has no legacy `_id` FKs — clean
- `product_ids` in `import_log.ex` is an array field for tracking imported product IDs — intentional, not a foreign key relationship

---

## Final Summary (2026-02-26)

**Status:** ✅ **COMPLETE** (after 4 rounds of cleanup)

### Round 1 (Claude — commits `f98159cc`, `ca43e3f7`, `5a957918`):
- Removed `field :*_id, :integer` from 30+ schemas in Phase 1
- Removed `field :id, :integer, read_after_writes: true` from 40 schemas
- Removed integer overload function clauses in context files

### Round 2 (Mistral — uncommitted):
- Found 17 additional schemas still with legacy `_id` fields across 7 modules
- Removed 29 more `field :*_id, :integer` declarations + `@type` specs + `cast()` entries
- Fixed `Ticket.assigned?/1` to use `assigned_to_uuid` instead of removed `assigned_to_id`

### Round 3 (Claude — uncommitted, reviewing Mistral's work):
Fixed issues Mistral's changes introduced or missed:

**Bugs in Mistral's changes:**
- `template.ex` — `:created_by_user_id` left in `cast()` after field removal
- `ticket_comment.ex` — `parent_id: nil` in doc example not updated

**Dead code referencing removed fields (missed by both):**
- `connection_history.ex` — `normalize_user_ids` swapping non-existent `user_a_id`/`user_b_id`
- `entity_data.ex` — 3 validators referencing removed `entity_id` field (`validate_entity_reference`, `sanitize_rich_text_data`, `validate_data_against_entity`)
- `entity_data.ex` — `secondary_slug_exists?` had integer branch for `entity_id`
- `event.ex` — `validate_email_log_reference` checking removed `email_log_id`
- `data_form.ex` — `build_slug_params` reading `:entity_id` from changeset (always nil)

**Critical runtime bugs (would crash in production):**
- `tickets.ex:986` — Ecto query `is_nil(t.assigned_to_id)` on removed field
- `tickets/web/list.ex:316,319` — struct access `ticket.assigned_to_id` on removed field
- `tickets.ex` — keyword option `:assigned_to_id` renamed to `:assigned_to_uuid` across API

**Stale dual-write code:**
- `emails/templates.ex` — 4 sites passing `created_by_user_id`/`updated_by_user_id` to changesets (silently dropped since fields removed)

**Documentation fixes:**
- `ticket.ex`, `ticket_comment.ex`, `ticket_status_history.ex` — doc examples updated
- `event.ex`, `emails.ex` — doc references to `email_log_id` updated
- `entity_data.ex` — ~10 doc examples updated from integer to UUID

**Verification:**
- ✅ Compilation successful with `--warnings-as-errors`
- ✅ All 485 tests passing
- ✅ Code formatting applied
- ✅ Static analysis (Credo) clean

### Round 4 (Claude — fixing Kimi's audit findings):
Fixed all issues identified in Categories A-F from Kimi's post-commit audit:

**Category C — Critical pattern match bugs (6 locations):**
- `shop/web/checkout_page.ex:381` — `%{user: %{id: id}}` → `%{user: %{uuid: uuid}}`
- `shop/web/helpers.ex:39` — `%{user: %{id: _} = user}` → `%{user: %{uuid: _} = user}`
- `shop/shop.ex:2376,2384` — `%{id: user_id}` → `%{uuid: user_uuid}` (both functions)
- `billing/web/user_billing_profiles.ex:233` — `%{user: %{id: _} = user}` → `%{user: %{uuid: _} = user}`
- `billing/web/user_billing_profile_form.ex:529` — same pattern fix

**Category A — Legacy fields in subscription.ex:**
- Removed `field :subscription_type_id, :integer` and `field :payment_method_id, :integer`

**Category B — Active dual-write code (all 4 locations):**
- B1: `billing/billing.ex` — Removed `subscription_type_id:` dual-write, fixed `subscription_type_id` read to use `subscription_type_uuid`
- B2: `sync/connection.ex` — Removed 4 legacy integer fields (`approved_by`, `suspended_by`, `revoked_by`, `created_by`) and dual-write in 4 changesets
- B3: `sync/transfer.ex` — Removed 2 legacy integer fields (`denied_by`, `initiated_by`), cleaned `cast()` and dual-write in 2 changesets
- B4: `entities/mirror/importer.ex` — Removed redundant `get_default_user_id/0` and 2 dual-write sites

**Category D — Referrals module:**
- `referrals/referrals.ex` — Removed `field :created_by, :integer` and `field :beneficiary, :integer`, cleaned `cast()`
- `referrals/schemas/referral_code_usage.ex` — Fixed all stale `code_id`/`user_id` doc examples to use `code_uuid`/`user_uuid`
- `referrals/referrals.ex` — Fixed 3 stale doc examples (`code_id` → `code_uuid`, `user_id` → `user_uuid`)

**Category E — Non-`_id` legacy integer fields in entities:**
- `entities/entities.ex` — Removed `field :created_by, :integer`, cleaned `cast()`, simplified `validate_creator_reference` (UUID-only), rewrote `maybe_add_created_by` (no dual-write), removed unused `resolve_user_uuid/1`
- `entities/entity_data.ex` — Removed `field :created_by, :integer`, cleaned `cast()`, rewrote `maybe_add_created_by` (no dual-write), removed `put_created_by_with_uuid/2`

**Verification:**
- ✅ Compilation successful with `--warnings-as-errors`
- ✅ All 485 tests passing
- ✅ Code formatting applied
- ✅ Static analysis (Credo strict) — no issues

### Next Steps
1. Database migration to drop the legacy integer columns (separate migration script)
2. Update `.md` documentation files (`OVERVIEW.md`, `DEEP_DIVE.md`) with UUID references
3. Monitor for any edge cases in production usage


---

## Post-Commit Audit (2026-02-26) - Remaining Issues Found

**Auditor:** Kimi (comprehensive review after commit `99a5135b`)
**Status:** ✅ **ALL ISSUES FIXED** in Round 4

This audit was conducted to ensure 100% confidence that no code references legacy `_id` columns before they are dropped from the database. Several categories of issues were found.

---

### Category A: Legacy `_id` Fields Still in Schemas (But Not in cast())

These fields are declared but not cast, so they don't affect changesets. They will become dead weight after DB column drop but won't cause runtime errors.

| Schema File | Field | Line | Status |
|-------------|-------|------|--------|
| `billing/schemas/subscription.ex` | `subscription_type_id` | 84 | Declared, dual-written in billing.ex:2767 |
| `billing/schemas/subscription.ex` | `payment_method_id` | 92 | Declared, no active write found |

---

### Category B: Active Dual-Write Code (MUST FIX Before DB Drop)

These locations actively write to both legacy integer fields AND UUID fields. When DB columns are dropped, these will cause Ecto errors.

#### B1. Billing Module (`billing/billing.ex`)

| Line | Code | Issue |
|------|------|-------|
| 2767 | `subscription_type_id: type.id,` | Writes integer ID to legacy field |
| 2768 | `subscription_type_uuid: type.uuid,` | Also writes UUID (correct) |
| 2850 | `old_type_id = subscription.subscription_type_id` | **Reads** legacy field - will return nil |
| 2861 | `Events.broadcast_subscription_type_changed(..., old_type_id, new_type_id)` | Passes nil for old_type_id |

**Note:** Line 2850-2861 reads `subscription_type_id` to broadcast old type in event. After DB column drop, this will always be `nil`.

#### B2. Sync Module (`sync/connection.ex`)

| Line | Code | Context |
|------|------|---------|
| 220 | `approved_by: admin_user_id,` | In `approve_connection/2` |
| 221 | `approved_by_uuid: resolve_user_uuid(admin_user_id)` | Dual-write pattern |
| 233 | `suspended_by: admin_user_id,` | In `suspend_connection/2` |
| 234 | `suspended_by_uuid: resolve_user_uuid(admin_user_id)` | Dual-write pattern |
| 247 | `revoked_by: admin_user_id,` | In `revoke_connection/2` |
| 248 | `revoked_by_uuid: resolve_user_uuid(admin_user_id)` | Dual-write pattern |
| 261 | `suspended_by: nil,` | In `unsuspend_connection/1` - clears both fields |
| 262 | `suspended_by_uuid: nil,` | Clears both fields |

#### B3. Sync Transfer Module (`sync/transfer.ex`)

| Line | Code | Context |
|------|------|---------|
| 261 | `approved_by: admin_user_id,` | In approve function |
| 274 | `denied_by: admin_user_id,` | In deny function |

**Note:** `transfer.ex` also casts `:initiated_by` at line 153-154 (in `changeset/2`), which writes the legacy field on create.

#### B4. Entities Mirror Importer (`entities/mirror/importer.ex`)

| Line | Code | Context |
|------|------|---------|
| 127 | `created_by: get_default_user_id(),` | When creating entity from import |
| 128 | `created_by_uuid: get_default_user_uuid()` | Dual-write pattern |
| 212 | `created_by: get_default_user_id(),` | When updating entity from import |
| 213 | `created_by_uuid: get_default_user_uuid()` | Dual-write pattern |

**Note:** Lines 672-684 define `get_default_user_id/0` which returns `user.uuid` (not integer id), so this is actually writing UUID to the `created_by` field. This is a naming confusion bug.

---

### Category C: Broken Pattern Matches (CRITICAL BUGS)

These pattern matches try to access `%{id: ...}` on User structs, but User no longer has an `id` field. These will fail and return `nil`.

| File | Line | Code | Impact |
|------|------|------|--------|
| `shop/web/checkout_page.ex` | 381 | `%{user: %{id: id}} -> id` | `user_id` becomes `nil` for logged-in users |
| `shop/web/helpers.ex` | 39 | `%{user: %{id: _} = user} -> user` | `get_current_user/1` returns `nil` always |
| `shop/shop.ex` | 2376 | `%{id: user_id} = user` | Pattern match may fail |
| `shop/shop.ex` | 2384 | `%{id: user_id, uuid: user_uuid}` | Pattern match will fail (id doesn't exist) |
| `billing/web/user_billing_profiles.ex` | 233 | `%{user: %{id: _} = user} -> user` | Returns `nil` always |
| `billing/web/user_billing_profile_form.ex` | 529 | `%{user: %{id: _} = user} -> user` | Returns `nil` always |

**Impact:** Functions relying on `get_current_user/1` from Shop.Helpers or Billing will always return `nil`, breaking user detection.

---

### Category D: Legacy Integer Fields in Referrals Module

The referrals module has dual-write for `created_by` and `beneficiary`:

| File | Fields | Status |
|------|--------|--------|
| `referrals/referrals.ex` | `created_by`, `beneficiary` | Both declared with `_uuid` companions |

The `referrals.ex` casts both `created_by` and `created_by_uuid` (lines 127-128), but web form only passes `created_by_uuid`. The `created_by` field receives `nil` from form, so no dual-write occurs in practice.

**Documentation Issue:** `referrals/schemas/referral_code_usage.ex` doc example at line 30 still references `code_id` in query example:
```elixir
from(usage in ReferralCodeUsage, where: usage.code_id == ^code_id)
```
The schema does NOT have `code_id` field - this is stale documentation.

---

### Category E: Non-`_id` Legacy Integer Fields (Active Dual-Write)

These fields don't have `_id` suffix but are legacy integer fields with active dual-write:

| Module | Schema | Field | UUID Companion | Active Dual-Write |
|--------|--------|-------|----------------|-------------------|
| Sync | `connection.ex` | `approved_by` | `approved_by_uuid` | ✅ Yes |
| Sync | `connection.ex` | `suspended_by` | `suspended_by_uuid` | ✅ Yes |
| Sync | `connection.ex` | `revoked_by` | `revoked_by_uuid` | ✅ Yes |
| Sync | `connection.ex` | `created_by` | `created_by_uuid` | ✅ Yes |
| Sync | `transfer.ex` | `denied_by` | `denied_by_uuid` | ✅ Yes |
| Sync | `transfer.ex` | `initiated_by` | `initiated_by_uuid` | ✅ Yes (via cast) |
| Entities | `entity_data.ex` | `created_by` | `created_by_uuid` | ✅ Yes (via changeset) |
| Entities | `entities.ex` | `created_by` | `created_by_uuid` | ✅ Yes (via changeset) |
| Referrals | `referrals.ex` | `created_by` | `created_by_uuid` | ⚠️ Cast but no value passed |
| Referrals | `referrals.ex` | `beneficiary` | `beneficiary_uuid` | ⚠️ Cast but no value passed |

---

### Category F: Intentional Integer Fields (NOT Legacy)

These are legitimate integer fields, not legacy IDs:

| Schema | Field | Purpose |
|--------|-------|---------|
| `shop/import_log.ex` | `product_ids` | Array of imported product IDs (tracking) |
| Various | `sort_order`, `position`, `depth` | Ordering/positioning |
| Various | `*_count` | Counters (like_count, comment_count) |
| Various | `width`, `height`, `size` | Dimensions |
| AI/Emails | `tokens`, `cost_cents`, `latency_ms` | Metrics |

---

### Pre-DB-Drop Checklist (Updated — ALL COMPLETE)

All items completed in Round 4:

#### Critical (Will Cause Runtime Errors)

- [x] Fix `shop/web/checkout_page.ex:381` - pattern match on `%{user: %{id: id}}` ✅
- [x] Fix `shop/web/helpers.ex:39` - pattern match in `get_current_user/1` ✅
- [x] Fix `shop/shop.ex:2376,2384` - pattern matches on User struct with `id` ✅
- [x] Fix `billing/web/user_billing_profiles.ex:233` - pattern match in `get_current_user/1` ✅
- [x] Fix `billing/web/user_billing_profile_form.ex:529` - pattern match in `get_current_user/1` ✅
- [x] Fix `billing/billing.ex:2850` - reading `subscription.subscription_type_id` ✅

#### Cleanup (Will Cause Compiler Warnings or Dead Code)

- [x] Remove `subscription_type_id` field from `subscription.ex` schema ✅
- [x] Remove `payment_method_id` field from `subscription.ex` schema ✅
- [x] Remove `created_by` field from `entities.ex`, `entity_data.ex` ✅
- [x] Remove `approved_by`, `suspended_by`, `revoked_by`, `created_by` from `sync/connection.ex` ✅
- [x] Remove `denied_by`, `initiated_by` from `sync/transfer.ex` ✅
- [x] Remove dual-write code from all locations listed in Category B ✅
- [x] Remove `created_by`, `beneficiary` from `referrals/referrals.ex` ✅
- [x] Update `referrals/schemas/referral_code_usage.ex` documentation ✅
- [x] Update `referrals/referrals.ex` documentation ✅

#### Verification Commands

```bash
# Ensure no pattern matching on User.id remains
grep -rn "%{user: %{id:" lib/ --include="*.ex"
grep -rn "%{id:.*user\|user.*%{id:" lib/modules --include="*.ex"

# Ensure no struct field access on legacy _id fields
grep -rn "\.subscription_type_id\|\.payment_method_id" lib/modules --include="*.ex"
grep -rn "\.created_by\b\|\.approved_by\b\|\.suspended_by\b\|\.revoked_by\b\|\.denied_by\b\|\.initiated_by\b" lib/modules --include="*.ex"

# Ensure no legacy _id fields in cast()
grep -rn "cast.*:.*_id" lib/modules --include="*.ex" | grep -v "uuid"

# Full test suite
mix test
mix compile --warnings-as-errors
mix credo --strict
```

---

### Summary

**Current Status:** The code compiles and tests pass, but there are **hidden runtime bugs**:

1. **Pattern match bugs** (Category C) will cause `nil` returns where user data is expected
2. **Dual-write code** (Category B) will cause Ecto errors when DB columns are dropped
3. **Field reads** (billing.ex:2850) will return `nil` instead of actual values

**Recommendation:** Fix all Critical and Cleanup items before running DB migration to drop `_id` columns.

**Risk Level:** MEDIUM - Some features may silently fail (user detection) but won't crash until DB columns are dropped.
