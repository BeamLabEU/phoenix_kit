# LiveView Form Save Handlers: Silent Crash & Data Loss Problem

**Date:** 2026-02-21
**Updated:** 2026-02-22 (PR #355 + post-review fixes)
**Status:** ✅ COMPLETE — All handlers covered and correctly placed.
**Severity:** High — users lose form data without any error message

---

## Problem

When a LiveView form `handle_event("save", ...)` handler encounters an **unexpected exception** during a DB operation, the LiveView process crashes. Phoenix automatically replaces it with a fresh process, but:

1. The user's form data is **silently lost**
2. No error message is shown — the form just resets to its initial state
3. The error only appears in server logs, invisible to the user

### Why This Happens

All our form handlers use this pattern:

```elixir
def handle_event("save", %{"entity" => params}, socket) do
  case save_record(socket, params) do
    {:ok, record} ->
      {:noreply, socket |> put_flash(:info, "Saved") |> push_navigate(...)}

    {:error, %Ecto.Changeset{} = changeset} ->
      {:noreply, assign(socket, :changeset, changeset)}
  end
end
```

This handles **expected** outcomes (`{:ok, _}` and `{:error, changeset}`), but does **not** handle exceptions raised inside `save_record`. When an exception occurs (e.g., `ArgumentError`, `DBConnection.ConnectionError`, `Ecto.ConstraintError` not caught by changeset validations), it bypasses the `case` entirely and kills the process.

### Real-World Example

The DateTime microseconds bug (`ArgumentError: :utc_datetime expects microseconds to be empty`) hit the Entity edit form. The `Repo.update()` call raised an exception instead of returning `{:error, changeset}`. Users could fill out the entire entity form, click save, and have everything vanish with no feedback.

---

## The Fix Pattern

Wrap the save operation in `try/rescue`:

```elixir
def handle_event("save", %{"entity" => params}, socket) do
  try do
    case save_record(socket, params) do
      {:ok, record} ->
        {:noreply, socket |> put_flash(:info, "Saved") |> push_navigate(...)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  rescue
    e ->
      require Logger
      Logger.error("Save failed: #{Exception.message(e)}")
      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end
end
```

This ensures:
- The LiveView process **survives** the error
- The user's form data is **preserved** in the socket
- A flash message tells the user something went wrong
- The actual error is logged for debugging

---

## Status: All Handlers Fixed (PR #355)

PR #355 (merged 2026-02-22) added try/rescue to all 15 identified handlers plus the 2 already-fixed entity forms.

| File | Form | Fixed | Notes |
|------|------|-------|-------|
| `lib/modules/entities/web/entity_form.ex` | Entity add/edit | PR pre-#355 | |
| `lib/modules/entities/web/data_form.ex` | Entity data add/edit | PR pre-#355 | |
| `lib/modules/ai/web/endpoint_form.ex` | AI endpoint | PR #355 | Correct (fn-level rescue, fixed post-review) |
| `lib/modules/ai/web/prompt_form.ex` | AI prompt | PR #355 | Correct (fn-level rescue, fixed post-review) |
| `lib/modules/billing/web/order_form.ex` | Billing order | PR #355 | Correct (fn-level rescue, fixed post-review) |
| `lib/modules/billing/web/subscription_form.ex` | Subscription | PR #355 | Correct |
| `lib/modules/shop/web/product_form.ex` | Product | PR #355 | Correct (fn-level rescue) |
| `lib/modules/shop/web/category_form.ex` | Category options | PR #355 | Correct |
| `lib/phoenix_kit_web/live/modules/posts/edit.ex` | Post create | PR #355 | Correct |
| `lib/phoenix_kit_web/live/modules/posts/edit.ex` | Post update | PR #355 | Correct (fn-level rescue, fixed post-review) |
| `lib/modules/publishing/web/editor.ex` | Publishing editor | PR #355 | Correct (fn-level rescue) |
| `lib/modules/publishing/web/edit.ex` | Group edit | PR #355 | Correct (fn-level rescue) |
| `lib/modules/emails/web/template_editor.ex` | Email template | PR #355 | Correct |
| `lib/modules/tickets/web/new.ex` | Ticket create | PR #355 | Correct |
| `lib/modules/tickets/web/edit.ex` | Ticket edit | PR #355 | Correct (fn-level rescue) |
| `lib/modules/comments/web/settings.ex` | Comment settings | PR #355 | Correct |
| `lib/modules/entities/web/entities_settings.ex` | Entity settings | PR #355 | Correct |
| `lib/modules/pages/web/editor.ex` | Page editor | PR #355 | Correct |

---

## Resolved: 4 Misplaced try/rescue Blocks (Fixed 2026-02-22)

PR #355 originally placed the `try` block around only the `case result do` in 4 handlers, leaving the DB operation outside the rescue scope. Post-review, these were converted to function-level `rescue` (which covers the entire function body including the DB call) and flash messages were updated to use `gettext()`:

| File | Original Issue | Resolution |
|------|---------------|------------|
| `ai/web/endpoint_form.ex` | DB call outside `try` | Converted to fn-level `rescue` |
| `ai/web/prompt_form.ex` | DB call outside `try` | Converted to fn-level `rescue` |
| `billing/web/order_form.ex` | DB call outside `try` | Converted to fn-level `rescue` |
| `posts/web/edit.ex` (update) | DB call outside `try` | Converted to fn-level `rescue` |

---

## Additional Considerations

### Don't Over-Rescue

The `rescue` block should be a safety net, not a replacement for proper error handling. The normal `{:ok, _}` / `{:error, changeset}` flow should still handle all expected cases. The rescue is for genuinely unexpected failures.

### What Exceptions Can Occur?

Common exceptions that bypass `{:error, changeset}`:

| Exception | Cause |
|-----------|-------|
| `ArgumentError` | Type mismatch (e.g., microseconds in `:utc_datetime`) |
| `DBConnection.ConnectionError` | Database connection lost |
| `Postgrex.Error` | Constraint violations not covered by changeset validations |
| `Ecto.StaleEntryError` | Record was deleted between load and update |
| `Ecto.ConstraintError` | Unique/FK violations without matching changeset `unique_constraint` |
| `FunctionClauseError` | Unexpected nil or wrong data shape passed to context functions |

### Non-Save Handlers

This audit focuses on `handle_event("save", ...)`, but the same problem can affect any `handle_event` that does DB writes — delete handlers, status toggles, bulk operations, etc. A broader audit of all `handle_event` + `Repo.*` call sites would be thorough but lower priority since save handlers carry the most user data at risk.

---

## Verification

After applying fixes, verify with:

```bash
# Find all handle_event("save") handlers
ast-grep --lang elixir --pattern 'def handle_event("save", $$$) do $$$BODY end' lib/

# Confirm each has try/rescue wrapping the DB call
# Each match should contain "rescue" in its body
```
