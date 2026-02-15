# PR #331: Fix 8 UUID migration bugs found in PR #330 post-merge review

**Author**: @mdon
**Reviewer**: Claude Opus 4.6
**Status**: Merged to `dev` (post-merge review found 3 additional bugs, fixed in PR #332)
**Date**: 2026-02-13
**Impact**: +119 / -88 across 19 files
**Commits**: 1

## Goal

Replace `.id` with `.uuid` in 15 template locations across billing, emails, roles, referrals, entities, and tickets. Update event handlers to remove `Integer.parse` wrappers and fix plan/payment comparisons in subscription forms. Add template/handler UUID checklist to migration documentation.

## Review Scope

Post-merge review of the full PR diff (19 files), focusing on:
- Template `.id` → `.uuid` completeness across all form inputs, selects, and display values
- Event handler type consistency (no leftover `Integer.parse` on UUID strings)
- Lookup/comparison consistency between assigns and schema fields
- Summary/preview sections that re-find selected items from lists

## What PR #331 Fixed Correctly

All 8 originally reported bugs were correctly fixed:

| # | Category | Files | Fix |
|---|----------|-------|-----|
| 1 | Select option values | billing_profile_form, order_form, subscription_form | `value={user.id}` → `value={user.uuid}` |
| 2 | Selected comparisons | billing_profile_form, order_form, subscription_detail | `to_string(x.id) == y` → `to_string(x.uuid) == y` |
| 3 | phx-value attributes | roles, queue | `phx-value-id={item.id}` → `phx-value-id={item.uuid}` |
| 4 | URL interpolation | order_detail, email details | `"/path/#{item.id}"` → `"#{item.uuid}"` |
| 5 | Display text | subscription_detail, subscriptions, subscription_form, user_details | `ID: {item.id}` → `ID: {item.uuid}` |
| 6 | Integer.parse removal | emails/queue, roles | Removed unnecessary integer parsing from UUID string handlers |
| 7 | Form field names | tickets/edit, order_form | `name="ticket[user_id]"` → `name="ticket[user_uuid]"` |
| 8 | Enum.map for selection | emails/queue select_all_failed | `& &1.id` → `& &1.uuid` |

### Verification of Compatibility

All changes were verified against schemas and context functions:

| Function/Field | Accepts UUID? | Verified |
|----------------|---------------|----------|
| `Permissions.get_permissions_for_role/1` | Yes — `resolve_role_uuid/1` handles both integer and binary | Pass |
| `Billing.create_subscription/2` first arg | Yes — `extract_user_uuid/1` handles UUID strings | Pass |
| `reload_subscription/1` → `Billing.get_subscription/2` | Yes — handles both types | Pass |
| `retry_failed_email/1` → `Emails.get_log!/1` → `Log.get_log!/1` | Yes — binary clause checks `UUIDUtils.valid?/1` | Pass |
| Subscription schema: `plan_uuid`, `payment_method_uuid` | Exist and cast in changeset | Pass |
| Ticket schema: `user_uuid`, `assigned_to_uuid` | Exist and cast in changeset | Pass |
| BillingProfile schema: `user_uuid` | Exists, required in changeset | Pass |
| Order schema: `user_uuid`, `billing_profile_uuid` | Exist and cast in changeset | Pass |

### Documentation Addition

The PR added a valuable "Template & Handler UUID Checklist" to `dev_docs/uuid_migration_instructions_v3.md` covering:
- Pattern 1 vs Pattern 2 schema identification (48 vs 27 schemas)
- Template usage priority table (URL interpolation, phx-value, select options, etc.)
- Handler patterns to fix (Integer.parse, Enum.find by .id, Repo.get on UUID-PK)
- Common mistakes that slip through

## Bugs Found by This Review

3 additional bugs were identified in the **summary preview** and **auto-select** logic — areas not covered by the original fix pass. All three cause silent runtime failures where UI elements fail to render or select correctly.

---

### Bug #1 — HIGH: Plan summary lookup always returns nil

**File**: `lib/modules/billing/web/subscription_form.html.heex` (line 258)

**Problem**: The subscription creation form has a "Review" sidebar that displays the selected plan details. After PR #331, `@selected_plan_id` contains a UUID string (set from the form event), but the lookup still searches by `&1.id` (the legacy integer field). The `Enum.find` never matches, so the plan summary always shows "Not selected" even after choosing a plan.

**Root cause**: The primary `<select>` element was migrated to `.uuid` (line 128), but the summary preview section that re-finds the plan from the list was missed.

**Fix**:
```heex
<%!-- BEFORE — &1.id is integer, @selected_plan_id is UUID string --%>
<% plan = Enum.find(@plans, &(to_string(&1.id) == to_string(@selected_plan_id))) %>

<%!-- AFTER --%>
<% plan = Enum.find(@plans, &(to_string(&1.uuid) == to_string(@selected_plan_id))) %>
```

---

### Bug #2 — HIGH: Payment method summary lookup always returns nil

**File**: `lib/modules/billing/web/subscription_form.html.heex` (line 288)

**Problem**: Same pattern as Bug #1. The payment method preview in the sidebar uses `&1.id` to find the selected payment method, but `@selected_payment_method_id` now contains a UUID string. The lookup never matches, so the payment method preview never renders.

**Fix**:
```heex
<%!-- BEFORE --%>
&(to_string(&1.id) == to_string(@selected_payment_method_id))

<%!-- AFTER --%>
&(to_string(&1.uuid) == to_string(@selected_payment_method_id))
```

---

### Bug #3 — HIGH: Auto-selected billing profile never appears selected in dropdown

**File**: `lib/modules/billing/web/order_form.ex` (line 132)

**Problem**: When creating an order and selecting a user, the `select_user` event handler auto-selects the user's default billing profile (or first profile). It stores `selected_profile.id` (integer) in the `selected_billing_profile_id` assign. But the template (line 71) compares this value against `profile.uuid` in the `<option>` tags. Since an integer like `42` never equals a UUID string like `019...-...`, the dropdown never shows the auto-selected profile.

**Root cause**: The `select_user` handler was updated to use `.uuid` for `selected_user_id` (line 144 uses the UUID from the form event), but the auto-select logic for billing profiles on line 132 still read `.id`.

**Fix**:
```elixir
# BEFORE — .id is the legacy integer
selected_profile_id = if selected_profile, do: selected_profile.id, else: nil

# AFTER
selected_profile_id = if selected_profile, do: selected_profile.uuid, else: nil
```

---

## Why These Were Missed

All three bugs sit in **secondary UI paths** rather than the primary form controls:

1. **Bugs #1 and #2** are in the "Review" summary sidebar of the subscription form — a read-only preview panel that re-finds the selected item from the list to display its details. The primary `<select>` elements were correctly migrated, but the preview lookups were not.

2. **Bug #3** is in auto-select logic that runs when a user is chosen — it pre-populates the billing profile dropdown. The dropdown `<option>` values were migrated to `.uuid`, but the code that decides *which* profile to pre-select still read `.id`.

This matches the pattern documented in PR #331's own checklist:

> **Helper functions one layer deep** — snapshot builders, validation functions, and notifier helpers that load a record but don't propagate its UUID to attrs

## Verification

All fixes verified with:

| Check | Result |
|-------|--------|
| `mix compile --force` | Clean, no warnings |
| `mix format --check-formatted` | Pass |
| `mix credo --strict` | No issues found |

## Files Modified by This Review

| File | Change |
|------|--------|
| `lib/modules/billing/web/subscription_form.html.heex` | Bugs #1, #2 — plan and payment method summary lookups use `.uuid` |
| `lib/modules/billing/web/order_form.ex` | Bug #3 — auto-selected billing profile uses `.uuid` |

## Recommendations

### 1. Rename `*_id` assigns that now store UUIDs

Multiple assigns retain `_id` naming but store UUID values. This is cosmetic but misleading:

| Assign | File(s) | Stores |
|--------|---------|--------|
| `selected_user_id` | billing_profile_form, order_form, subscription_form | UUID string |
| `selected_billing_profile_id` | order_form | UUID string |
| `selected_plan_id` | subscription_form | UUID string |
| `selected_payment_method_id` | subscription_form | UUID string |
| `selected_new_plan_id` | subscription_detail | UUID string |

Renaming to `selected_user_uuid`, `selected_plan_uuid`, etc. would prevent future confusion about the expected type.

### 2. Grep for remaining `.id` lookups in preview/summary sections

```bash
# Find Enum.find lookups using .id on Pattern 1 schemas
grep -rn '&1\.id)' lib/modules/billing/web/*.heex lib/modules/billing/web/*.ex
```

Primary form inputs are now correct, but any summary, preview, or confirmation section that re-finds an item from a list could still have stale `.id` references.

### 3. Consider shorter UUID display format

`subscription_detail.html.heex` now shows `Subscription #{@subscription.uuid}` as the page heading — a 36-character UUID string. Consider a truncated display format for user-facing headings:

```heex
<%!-- Option A: Short prefix --%>
<h1>Subscription #{String.slice(@subscription.uuid, 0..7)}</h1>

<%!-- Option B: Human-readable reference number field --%>
<h1>Subscription #{@subscription.reference_number}</h1>
```

### 4. Add migration pass for auto-select/default logic

Beyond form inputs and URLs, search for patterns like:
```elixir
# Any code that reads .id from a loaded record to set a "selected" value
selected_x = if record, do: record.id, else: nil
```

These are easy to miss because they compile and run without errors — they just silently produce incorrect UI state.
