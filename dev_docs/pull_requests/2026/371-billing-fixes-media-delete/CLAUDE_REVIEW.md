# PR #371 Review: Fix 3 billing bugs from PR #370 review + delete button for Media Detail

**Reviewer:** Claude
**Date:** 2026-02-26
**Author:** @timujinne
**Base:** dev
**Commits:** 3

## Overall Assessment

Mixed PR — the housekeeping (.beam cleanup, .gitignore) and AWS trim fixes are clean. The billing bugfixes address real issues but **leave behind legacy `_id` naming in the web layer** that should have been cleaned up in the same pass. The media delete feature works but has a minor issue. The storage orphan detection fix references a table/column that needs verification.

**Verdict: Request Changes** — primarily to clean up the `_id` → `_uuid` naming inconsistency in billing web forms.

---

## File-by-File Review

### `.gitignore` — OK

Adding `*.beam` glob is correct. Prevents accidental commits of compiled artifacts.

### `Elixir.TestDeprecated.beam`, `Elixir.TestUsage.beam` — OK

Good cleanup. These should never have been committed.

### `lib/modules/billing/billing.ex` — Issues

**Good:**
- Removing the dead `subscription_type_id: type.id` line (SubscriptionType uses UUID primary key, `.id` was always nil).
- `change_subscription_type/3` now reads `subscription_type_uuid` instead of the always-nil `subscription_type_id` — correct fix.
- `create_subscription/2` accepting both `:subscription_type_uuid` and legacy `:subscription_type_id` as fallback is reasonable for backward compat.

**Issue 1 — Legacy `_id` naming still in web layer (HIGH):**

The backend (`billing.ex`) was fixed to prefer `subscription_type_uuid`, but the HTML forms and event handlers still use `subscription_type_id` as the param name:

| File | Line | Uses `_id` |
|------|------|------------|
| `subscription_form.html.heex` | 114 | `name="subscription_type_id"` |
| `subscription_form.ex` | 95 | `%{"subscription_type_id" => type_id}` |
| `subscription_detail.html.heex` | 357 | `name="subscription_type_id"` |
| `subscription_detail.ex` | 124 | `%{"subscription_type_id" => type_id}` |

Since the form submit path in `subscription_form.ex:157` already correctly builds `subscription_type_uuid: type_id` before calling `Billing.create_subscription/2`, the code **works** — but only because the form's `_id` param gets manually translated to `_uuid` in the `save` handler. This is fragile and contradicts the migration away from `_id`.

**Recommendation:** Rename the HTML `name=` attributes and event handler pattern matches from `subscription_type_id` to `subscription_type_uuid` across all 4 locations. Same for `payment_method_id` in `subscription_form.html.heex:183` and `subscription_form.ex:117`.

**Issue 2 — Variable naming (LOW):**

`billing.ex:2749` still names the local variable `type_id` when it holds a UUID:
```elixir
type_id =
  attrs[:subscription_type_uuid] || attrs["subscription_type_uuid"] ||
    attrs[:subscription_type_id] || attrs["subscription_type_id"] ||
    attrs[:plan_uuid] || attrs["plan_uuid"]
```
Should be `type_uuid` for consistency.

### `lib/modules/emails/sqs_polling_job.ex`, `sqs_worker.ex`, `web/settings.ex` — OK

Adding `String.trim/1` to AWS credentials is a good defensive fix. Trailing whitespace from copy-paste in admin UI settings would cause silent auth failures. Applied consistently across all three credential-usage sites.

### `lib/phoenix_kit/aws/infrastructure_setup.ex` — OK

Same `String.trim/1` treatment for AWS credentials. Consistent with the email module changes.

### `lib/modules/storage/storage.ex` — Needs Verification

**The change:** Adds a `NOT EXISTS` check against `phoenix_kit_posts.metadata->>'featured_image_id'` to the orphan detection query.

**Concern:** The `phoenix_kit_posts` table uses a JSONB `metadata` column, and the orphan query checks `metadata->>'featured_image_id'`. This is correct if posts actually store the file UUID in `metadata.featured_image_id` — which they do (confirmed by `pages/storage.ex` and `pages/metadata.ex`). So the fix is valid.

However, the existing query already checks `phoenix_kit_publishing_contents` and `phoenix_kit_publishing_posts` — the `phoenix_kit_posts` table is from the Pages module (V29), which is a separate module from Publishing. Having all three checks is correct for complete orphan coverage.

**Minor:** The orphan query is accumulating many `NOT EXISTS` subqueries. This may become a performance concern on large media libraries. Not a blocker, but worth noting for future optimization (could use a CTE or a single `NOT IN` with a UNION).

### `lib/phoenix_kit_web/live/users/media_detail.ex` — Minor Issue

**Good:** Clean implementation of confirm → delete flow. Uses `Storage.delete_file_completely/1` which handles S3 deletion + all variants. Navigates back to media list on success.

**Issue 3 — Logger not aliased/required (MEDIUM):**

Line uses `Logger.error/1` but the module doesn't appear to `require Logger` or `alias Logger`. This will either fail at compile time or use `Kernel.Logger` if available. Needs verification.

**Issue 4 — No permission check (LOW):**

The delete handler doesn't verify the user has admin/media permissions. The page itself is presumably behind `:phoenix_kit_ensure_admin` on_mount, so this is likely fine, but worth confirming.

### `lib/phoenix_kit_web/live/users/media_detail.html.heex` — OK

Clean modal implementation using daisyUI patterns. Uses `<%!-- --%>` server-side comments (correct per CLAUDE.md). Backdrop click dismisses modal. No hardcoded colors.

One nit: `@file_data && @file_data.filename` could use `@file_data[:filename]` or a guard, but this is fine since the modal only shows when a file is loaded.

---

## Summary of Required Changes

| Priority | Issue | Action |
|----------|-------|--------|
| HIGH | `subscription_type_id` in billing web forms/handlers | Rename to `subscription_type_uuid` in 4 files (form.html.heex, form.ex, detail.html.heex, detail.ex) |
| HIGH | `payment_method_id` in subscription_form | Rename to `payment_method_uuid` in form.html.heex and form.ex |
| MEDIUM | `Logger.error` in media_detail.ex | Ensure `require Logger` is present |
| LOW | `type_id` variable name in billing.ex:2749 | Rename to `type_uuid` |

## What's Good

- `.beam` cleanup + `.gitignore` — overdue, well done
- AWS `String.trim/1` — defensive fix that prevents real-world issues
- Billing bugfixes address genuine bugs from PR #370
- Media delete UX is clean (confirm modal, error handling, flash messages)
- Orphan detection gap fix is valid
