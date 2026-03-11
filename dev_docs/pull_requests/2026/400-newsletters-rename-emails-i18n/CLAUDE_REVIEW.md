# PR #400 Review — Card/Table Toggle, Emails i18n, Newsletters Rename, Flash Improvements

**Author:** Tymofii Shapovalov (`timujinne`)
**Merged:** 2026-03-10
**Files changed:** 70 (49,807 additions, 3,324 deletions)

## Summary

Large PR with four features:
1. **Mailing → Newsletters rename** — full module rename with new tables, routes, schemas, workers.
2. **Email templates i18n** — JSONB fields for locale-aware template content, locale tab UI in editor.
3. **Card/table toggle** — for User Management and Email Templates pages.
4. **Flash auto-dismiss** — animated progress bar with 5s auto-close.

## Bugs

### 1. `template.html_body` is now a map — newsletters `DeliveryWorker` will crash (High)

**File:** `lib/modules/newsletters/workers/delivery_worker.ex:116`

```elixir
template -> String.replace(template.html_body, "{{content}}", content)
```

V80 migration converts `html_body` to JSONB (`%{"en" => "..."}`). `String.replace/3` on a map raises `FunctionClauseError`. Same issue in `broadcast_editor.ex:237`.

**Fix:** Use `Template.get_translation(template.html_body, locale)` with the appropriate locale.

### 2. `template.display_name` renders as raw map in newsletters templates (High)

**Files:**
- `lib/modules/newsletters/web/broadcast_editor.html.heex:52` — `{template.display_name || template.name}`
- `lib/modules/newsletters/web/broadcast_details.html.heex:83` — `@broadcast.template.display_name || @broadcast.template.name`

These render `%{"en" => "Welcome"}` as literal text. Must use `Template.get_translation(template.display_name, locale)`.

### 3. Merge conflict marker in CHANGELOG.md (Medium)

**File:** `CHANGELOG.md:71`

```
>>>>>>> upstream/dev
```

Visible to users and breaks markdown rendering.

### 4. `clone_template/3` only clones "en" locale, drops other translations (Medium)

**File:** `lib/modules/emails/templates.ex` (clone logic)

When cloning a template, `display_name` is hardcoded to `%{"en" => ...}` only, discarding other locale translations from the source template.

### 5. Flash auto-dismiss applies to error messages (Medium)

**File:** `lib/phoenix_kit_web/components/core/flash.ex:25,91`

`autoclose` defaults to `5000` for all flash kinds including `:error`. Error flashes typically need to persist until the user dismisses them — a 5-second timeout means users may miss important error messages.

**Fix:** In `flash_group/1`, pass `autoclose={false}` for the error flash:
```elixir
<.flash kind={:error} title="Error!" flash={@flash} autoclose={false} />
```

### 6. `DeliveryWorker` sets `message_id: nil` — SES webhook correlation broken (Medium)

**File:** `lib/modules/newsletters/workers/delivery_worker.ex:71-73`

After sending, the delivery record gets `message_id: nil`. The actual SES message ID from `deliver_email()` is discarded, so `sqs_processor.ex:find_delivery_by_message_id/1` will never match — bounce/open/delivery tracking for newsletters won't work.

### 7. `.mcp.json` committed with local dev endpoints (Medium)

Contains `localhost:4000`, `localhost:4001`, and internal docker hostname `openmemory-mcp:8765`. This is developer-specific config. Should be in `.gitignore` or use a `.mcp.json.example` pattern.

## Medium Issues

### 8. V80 migration: NULL columns produce invalid JSONB

**File:** `lib/phoenix_kit/migrations/postgres/v80.ex:37-39`

The `subject` USING clause is `jsonb_build_object('en', subject)`. If any row has NULL `subject`, this produces `{"en": null}` which will fail the `validate_i18n_map(:subject, min_length: 1)` changeset validation. Only `description` has NULL-safe handling.

### 9. V80 migration is not idempotent

Running V80 twice wraps already-JSONB values again: `{"en": {"en": "..."}}`). Should guard with a column type check.

### 10. `DeliveryWorker.send_email/4` bypasses email interceptor

**File:** `lib/modules/newsletters/workers/delivery_worker.ex:120-130`

Builds `Swoosh.Email` directly and calls `PhoenixKit.Mailer.deliver_email()`, bypassing the interceptor logging pipeline. Newsletter sends won't appear in email logs.

### 11. Template search only matches English locale

**File:** `lib/modules/emails/templates.ex` (search query)

```elixir
ilike(fragment("?->>'en'", t.display_name), ^search_term)
```

Templates with content only in non-English locales won't be searchable. Consider `fragment("?::text", t.display_name)`.

### 12. `Broadcaster.do_send/1` crashes on Earmark failure

**File:** `lib/modules/newsletters/broadcaster.ex:51`

```elixir
{:ok, html, _warnings} = Earmark.as_html(broadcast.markdown_body || "")
```

Match error if Earmark returns `{:error, ...}`. Should use `case`.

### 13. `PhoenixKitWeb.Endpoint` hardcoded in `DeliveryWorker`

**File:** `lib/modules/newsletters/workers/delivery_worker.ex:93`

```elixir
Phoenix.Token.sign(PhoenixKitWeb.Endpoint, ...)
```

Parent apps with different endpoint names will crash. Should use `PhoenixKit.endpoint()`.

### 14. Version mismatch: `mix.exs` says 1.7.68, CHANGELOG goes to 1.7.69

`mix.exs` `@version` should be `"1.7.69"` to match the latest CHANGELOG entry.

## Low / Nitpick

### 15. Newsletters module has no gettext wrapping

All `.heex` templates in `lib/modules/newsletters/web/` have hardcoded English strings — inconsistent with the emails module which was wrapped in this same PR.

### 16. `unsubscribe_from_all/1` uses `DateTime.utc_now()` instead of `PhoenixKit.Utils.Date.utc_now()`

**File:** `lib/modules/newsletters/newsletters.ex:208`

### 17. Comment still says "mailing" in `sqs_processor.ex`

**File:** `lib/modules/emails/sqs_processor.ex:1399`

### 18. `get_translation/3` skips empty strings via `||` chain

**File:** `lib/modules/emails/template.ex:186-190`

If a user saves `%{"uk" => "", "en" => "Hello"}` and requests `"uk"`, the empty string is treated as falsy and English is returned instead. May be intentional fallback but could surprise users.

## Migration Safety

**V79** (newsletters tables): Safe — uses `IF NOT EXISTS` throughout. Clean up/down.

**V80** (template i18n): Forward migration is safe for non-NULL data. Rollback loses non-English translations permanently. Not idempotent — running twice nests JSON objects.

## Verdict

This is a big PR that would benefit from being split (rename, i18n, UI changes, flash). The i18n architecture is sound but the newsletters module wasn't updated for the new JSONB fields — **bugs #1 and #2 will crash in production** when sending newsletters with templates. The merge conflict marker (#3) and version mismatch (#14) should be quick fixes. The flash auto-dismiss for errors (#5) is a UX regression.

Priority fixes: #1, #2 (crashes), #3 (conflict marker), #5 (error flash), #6 (SES tracking broken), #14 (version).
