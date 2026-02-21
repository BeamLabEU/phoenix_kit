# LiveView Form Save Handlers: Silent Crash & Data Loss Problem

**Date:** 2026-02-21
**Status:** Discovery — needs project-wide audit and fix
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

## Already Fixed

| File | Form | Fixed |
|------|------|-------|
| `lib/modules/entities/web/entity_form.ex` | Entity add/edit | Yes |
| `lib/modules/entities/web/data_form.ex` | Entity data add/edit | Yes |

---

## Needs Audit & Fix

The following form handlers use the unprotected `case` pattern and need the `try/rescue` wrapper added. This list covers `handle_event("save", ...)` handlers that call DB operations.

### AI Module

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/modules/ai/web/endpoint_form.ex` | `save_endpoint/2` | `AI.create_endpoint/1`, `AI.update_endpoint/2` |
| `lib/modules/ai/web/prompt_form.ex` | `handle_event("save")` | `AI.create_prompt/1`, `AI.update_prompt/2` |

### Billing Module

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/modules/billing/web/order_form.ex` | `save_order/2` | `Billing.create_order/1`, `Billing.update_order/2` |
| `lib/modules/billing/web/subscription_form.ex` | `handle_event("save")` | `Billing.create_subscription/1` |

### Shop Module

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/modules/shop/web/product_form.ex` | `handle_event("save")` | `Shop.create_product/1`, `Shop.update_product/2` |
| `lib/modules/shop/web/category_form.ex` | `handle_event("save_category_option")` | `Options.update_category_options/2` |

### Posts Module

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/phoenix_kit_web/live/modules/posts/edit.ex` | `handle_event("save")` | `Posts.create_post/1`, `Posts.update_post/2` |

### Publishing Module

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/modules/publishing/web/editor.ex` | `handle_event("save")` | `Persistence.perform_save/1` |
| `lib/modules/publishing/web/edit.ex` | `handle_event("save")` | `Publishing.update_group/2` |

### Emails Module

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/modules/emails/web/template_editor.ex` | `handle_event("save")` | `Emails.create_template/1`, `Emails.update_template/2` |

### Tickets Module

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/modules/tickets/web/new.ex` | `handle_event("save")` | `Tickets.create_ticket/1` |
| `lib/modules/tickets/web/edit.ex` | `handle_event("save")` | `Tickets.update_ticket/2` |

### Settings

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/modules/comments/web/settings.ex` | `handle_event("save")` | `Settings.update_setting/3` |
| `lib/modules/entities/web/entities_settings.ex` | `handle_event("save")` | `Settings.update_setting/3` |

### Pages Module

| File | Handler | DB Operation |
|------|---------|-------------|
| `lib/modules/pages/web/editor.ex` | `handle_event("save")` | `FileOperations.write_file/2` (filesystem, not DB — but can still raise) |

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
