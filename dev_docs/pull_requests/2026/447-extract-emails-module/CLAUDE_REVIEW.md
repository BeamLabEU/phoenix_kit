# PR #447: Extract Emails Module to Standalone Package

**Author**: @timujinne (Tymofii Shapovalov)
**Reviewer**: @claude
**Status**: Merged
**Commits**: `e7b0ef6..4c38e91` (12 commits)
**Date**: 2026-03-23

## Goal

Extract the Emails module (~29k lines) from PhoenixKit core into a standalone `phoenix_kit_emails` hex package. This follows the same pattern as the earlier Posts (#442) and Newsletters extractions — making PhoenixKit slimmer by moving heavyweight, optional functionality into separate packages that can be added as dependencies when needed.

## What Was Changed

### New Files

| File | Purpose |
|------|---------|
| `lib/phoenix_kit/email/provider.ex` | Unified `PhoenixKit.Email.Provider` behaviour (14 callbacks) |
| `lib/phoenix_kit/email/default_provider.ex` | No-op implementation — used when `phoenix_kit_emails` is not installed |
| `lib/phoenix_kit_web/helpers/admin_edit_helper.ex` | Universal admin edit URL helper for controllers and LiveViews |

### Modified Files

| File | Change |
|------|--------|
| `lib/phoenix_kit/mailer.ex` | Replaced hard `Emails.*` aliases with `email_provider()` dynamic dispatch; removed `send_test_tracking_email`, HTML fallback templates, and `handle_delivery_result` private functions (~320 lines removed) |
| `lib/phoenix_kit/users/auth/user_notifier.ex` | Same `email_provider()` pattern; stripped HTML fallbacks for confirmation/reset/update emails (~230 lines removed) |
| `lib/phoenix_kit/migrations/postgres/v15.ex` | Dynamic dispatch for `SeedTemplates` via `Code.ensure_loaded` + `apply/3` |
| `lib/phoenix_kit/migrations/postgres/v31.ex` | Dynamic dispatch for `Emails.Templates` via `Code.ensure_loaded` + `apply/3` |
| `lib/phoenix_kit_web/integration.ex` | Removed `EmailsRoutes` alias and `safe_route_call` references |
| `lib/phoenix_kit_web/live/dashboard.html.heex` | Guarded `Emails.enabled?()` with `Code.ensure_loaded?` + `apply` |
| `lib/phoenix_kit_web/live/modules.ex` | Enriched external module cards with config stats, settings links; `extract_admin_links/1` now skips parent tabs and deduplicates |
| `lib/phoenix_kit_web/live/modules.html.heex` | Removed hardcoded Emails card; external modules now render as enriched cards |
| `lib/phoenix_kit_web/components/core/module_card.ex` | Fixed hero-* icon rendering |
| `lib/phoenix_kit_web/components/core/cookie_consent.ex` | Dynamic legal links, theme-aware backdrop, daisyUI toggle |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | Minor addition |
| `lib/phoenix_kit_web/users/auth.ex` | Minor addition |
| `lib/modules/billing/billing.ex` | Uses `Mailer.send_from_template` instead of `Templates.send_email` |
| `lib/modules/legal/legal.ex` | Added `legal_links` for cookie consent widget |
| `lib/modules/publishing/web/controller.ex` | Admin edit links via `AdminEditHelper` |
| `lib/modules/publishing/web/templates/*.html.heex` | Conditional Edit buttons for admins |
| `lib/modules/shop/web/catalog_*.ex` | Admin edit URL only assigned for admin users (was assigned to all) |
| `lib/modules/sitemap/sources/publishing.ex` | `lastmod` dates from most recent published post |
| `lib/modules/sitemap/sources/static.ex` | `lastmod` for homepage and static pages |
| `.dialyzer_ignore.exs` | Cleaned up entries for removed files |
| `test/phoenix_kit/module_test.exs` | Removed 1 line |

### Deleted (35+ source files, 15 mix tasks, 1 route module)

All files under `lib/modules/emails/` (emails core, web views, templates, SQS workers, rate limiter, archiver, metrics, blocklist, webhook controller, etc.) and `lib/phoenix_kit_web/routes/emails.ex` plus 15 email-related mix tasks.

## Architecture

The extraction uses a **behaviour + provider** pattern:

```
PhoenixKit.Email.Provider (behaviour — 14 callbacks)
├── PhoenixKit.Email.DefaultProvider (no-op, ships with core)
└── PhoenixKit.Modules.Emails.Provider (full impl, ships with phoenix_kit_emails)
```

The active provider is resolved at runtime via:
```elixir
Application.get_env(:phoenix_kit, :email_provider, PhoenixKit.Email.DefaultProvider)
```

This is clean and consistent. The `phoenix_kit_emails` package registers its provider on startup, and the core gracefully falls back to no-op when the package is absent.

## Review Notes

### Looks Good

1. **Provider behaviour is well-designed** — 14 callbacks covering interception, templates, AWS config, and provider detection. The `DefaultProvider` returns safe no-op values (nil for templates triggers fallback, false for `aws_configured?` skips AWS override). Clean separation of concerns.

2. **Migration safety** — V15 and V31 use `Code.ensure_loaded` + `apply/3` for optional template seeding, so migrations won't fail when the emails package is absent. This is the correct approach for optional dependencies in migrations.

3. **Dashboard guard** — The `dashboard.html.heex` Emails card uses `Code.ensure_loaded?(PhoenixKit.Modules.Emails) and apply(...)`, preventing crashes when the module is not available.

4. **AdminEditHelper is a nice addition** — Polymorphic over `Plug.Conn` and `LiveView.Socket`, cleanly guarded by admin role check. Good reusable pattern.

5. **Shop catalog fix** — Admin edit URL was previously assigned to all visitors; now correctly scoped to admin users only. This is a security-relevant improvement.

6. **Commit organization** — Logical progression: behaviour first, then core refactor, then file deletion, then UI cleanup, then fixes. Each commit is independently reviewable.

### Issues

1. **`PhoenixKit.Modules.Emails` still in `internal_modules` list** (module_registry.ex:409) — The PR description says "Remove PhoenixKit.Modules.Emails from module_registry internal_modules" but the module is still listed in the `internal_modules/0` function. This was likely lost during the merge conflict resolution (commit `6b43427` resolves conflicts in `module_registry.ex`). Since the source files are deleted, this module will fail `Code.ensure_loaded?` at runtime and be silently skipped by most registry queries, but it's incorrect and should be removed. **Additionally, `Emails` is not listed in `known_external_packages/0` either** — so it won't appear as an installable package on the admin Modules page. Both need fixing.

2. **Email/SQS queues still in ObanConfig** — `lib/phoenix_kit/install/oban_config.ex` still includes `emails: 50` and `sqs_polling: 1` in the default queue configuration (line ~119-124), and `ensure_sqs_polling_queue/2` still exists. The PR description says "removed email queues from core install" but this was also likely lost in the merge conflict (commit `6b43427` resolves conflicts in `oban_config.ex`). New installations will create email queues that have no workers in core. The `add_oban_queue/3` helper mentioned in the PR description is also missing.

3. **Double `get_active_template_by_name` calls** — In `mailer.ex` (magic link) and `user_notifier.ex` (register, reset_password, update_email), the template is fetched once for rendering and then fetched *again* for `track_usage`. This was inherited from the pre-extraction code, but the extraction was a good opportunity to fix it. Example from the magic link flow:
   ```elixir
   case email_provider().get_active_template_by_name("magic_link") do ...end
   # ... later ...
   case email_provider().get_active_template_by_name("magic_link") do
     nil -> :ok
     template -> email_provider().track_usage(template)
   end
   ```
   The template variable from the first match could simply be reused.

4. **`email_provider()` is duplicated** — Both `Mailer` and `UserNotifier` define their own private `email_provider/0` function with identical implementation. This could be a single function in `PhoenixKit.Email.Provider` (e.g., `Provider.current/0`) to avoid drift.

5. **Bundled unrelated changes** — This PR includes several changes unrelated to the Emails extraction:
   - Sitemap `lastmod` improvements (commit `e7b0ef6`)
   - AdminEditHelper + publishing/shop edit links (commit `af6af2ea`)
   - Cookie consent overhaul (commit `04510813`)
   - Legal module `legal_links` addition

   These would be cleaner as separate PRs for independent review and easier revert.

### Non-blocking Suggestions

- The `DefaultProvider.render_template/2,3` returns `%{subject: "", html_body: "", text_body: ""}` — empty strings rather than nil. Since the template path is guarded by `get_active_template_by_name` returning nil first, these functions should never be called on the DefaultProvider. But if they somehow are, sending an email with empty subject/body would be worse than raising. Consider raising `RuntimeError` instead, since reaching this code path indicates a bug.

- The `extract_admin_links/1` filter `tab.parent != nil` (line 497) means only subtabs are shown as admin links on module cards. This is probably intentional (top-level tabs are already in the sidebar), but it's worth a comment since the filter reads counterintuitively.

- Consider adding a `@type t :: module()` to `PhoenixKit.Email.Provider` and using it in the `email_provider()` return spec for better dialyzer coverage.

---

## Post-merge Fixes

**Date**: 2026-03-23
**Fixed by**: @claude

Issues 1–4 from the review above were fixed after merge. All changes pass `mix compile`, `mix format`, `mix credo --strict`, and 200 unit tests (0 failures).

### Fix 1: ModuleRegistry — remove Emails from internal, add to external

**Problem**: Merge conflict resolution (commit `6b43427`) re-added `PhoenixKit.Modules.Emails` to `internal_modules/0`. Since the source files were deleted, the module silently failed `Code.ensure_loaded?` at runtime — harmless but incorrect. Additionally, Emails was missing from `known_external_packages/0`, so it wouldn't appear on the admin Modules page as an installable package.

**Files changed**:
- `lib/phoenix_kit/module_registry.ex` — removed Emails from `internal_modules`, added entry to `known_external_packages`
- `test/phoenix_kit/module_registry_test.exs` — updated counts: 20→18 modules, 19→17 feature keys (reflects both Emails and Posts extractions from PRs #447 and #442)
- `test/phoenix_kit/users/permissions_test.exs` — updated counts: 19→17 feature keys, 24→22 total keys; removed `assert "emails" in keys`

### Fix 2: ObanConfig — remove email/SQS queues from core install

**Problem**: Same merge conflict re-added `emails: 50` and `sqs_polling: 1` to the default Oban queue config. New installations would create queues with no workers in core.

**Files changed**:
- `lib/phoenix_kit/install/oban_config.ex`:
  - Removed `emails: 50` and `sqs_polling: 1` from default queue list
  - Removed `ensure_sqs_polling_queue/2` function and its call in the update pipeline
  - Removed its `@dialyzer {:nowarn_function, ensure_sqs_polling_queue: 2}` suppress
  - Updated moduledoc, comments, manual config notice, and footer warning to no longer reference email/SQS queues

### Fix 3: Eliminate double template fetches

**Problem**: In `mailer.ex` (magic_link) and `user_notifier.ex` (register, reset_password, update_email, magic_link_registration), the template was fetched via `Provider.current().get_active_template_by_name(name)` once for rendering, then fetched *again* identically just to call `track_usage`. This was inherited from pre-extraction code.

**Fix**: Refactored all 5 functions to capture the template in a 4-element tuple from the first fetch:
```elixir
# Before: two separate fetches
{subject, html_body, text_body} = case Provider.current().get_active_template_by_name("register") do ...end
case Provider.current().get_active_template_by_name("register") do
  nil -> :ok
  template -> Provider.current().track_usage(template)
end

# After: single fetch, reuse template
{subject, html_body, text_body, db_template} = case Provider.current().get_active_template_by_name("register") do
  nil -> {"Confirm your account", nil, fallback_text, nil}
  template -> {rendered.subject, rendered.html_body, rendered.text_body, template}
end
if db_template, do: Provider.current().track_usage(db_template)
```

**Files changed**:
- `lib/phoenix_kit/mailer.ex` — `send_magic_link_email/2`
- `lib/phoenix_kit/users/auth/user_notifier.ex` — `deliver_confirmation_instructions/2`, `deliver_reset_password_instructions/2`, `deliver_update_email_instructions/2`, `deliver_magic_link_registration/2`

### Fix 4: Centralize `email_provider/0` as `Provider.current/0`

**Problem**: Both `Mailer` and `UserNotifier` had identical private `email_provider/0` functions calling `Application.get_env(:phoenix_kit, :email_provider, PhoenixKit.Email.DefaultProvider)`. Duplication risks drift.

**Fix**: Added `PhoenixKit.Email.Provider.current/0` as a public function with `@spec current() :: module()`. Replaced private functions in both modules with `alias PhoenixKit.Email.Provider` + `Provider.current()`.

**Files changed**:
- `lib/phoenix_kit/email/provider.ex` — added `current/0`
- `lib/phoenix_kit/mailer.ex` — removed private `email_provider/0`, alias `Provider`, use `Provider.current()`
- `lib/phoenix_kit/users/auth/user_notifier.ex` — same
