# PR #363 — Improve entity and data form UX, fix multilang save bugs

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/363
**Author:** @mdon
**Merged:** 2026-02-24 into `dev`
**Additions:** +264 | **Deletions:** -156

---

## Goal

Fix a cluster of related bugs in the entity and data forms that emerged from multilang editing: skeleton loading ghosts on active tab click, multilang saves silently wiping primary-tab fields, spurious "updated in another session" alerts triggered by one's own save, and awkward post-save navigation. Also ports UX improvements (skeleton loading, top submit button, unified tab styling) from `entity_form` to `data_form`, and hides the Custom Fields section when no fields are defined.

---

## What Changed

### 1. `switch_lang_js` skeleton ghost fix (both forms)

**Problem:** Clicking the already-active language tab called `JS.add_class("hidden", to: "[data-translatable=fields]")` + `JS.remove_class("hidden", to: "[data-translatable=skeletons]")` even though no actual language switch was happening. The skeleton appeared and never disappeared because no server round-trip followed.

**Fix:** `switch_lang_js/1` → `switch_lang_js/2` (takes `current_lang`). If `lang_code == current_lang`, returns `%JS{}` (no-op). Applied to `entity_form.ex` + `entity_form.html.heex` and newly implemented in `data_form.ex` + `data_form.html.heex`.

---

### 2. Skeleton loading + tab styling ported to `data_form`

`data_form.html.heex` previously used raw `phx-click="switch_language"` events with no JS skeleton animation. This PR brings it to parity with `entity_form`:

- Language tab buttons now use `switch_lang_js/2` for immediate skeleton feedback.
- Skeleton placeholder div added: `id={"translatable-skeletons-#{@current_lang}"}`, hidden by default, shown by JS on tab click.
- Translatable content wrapped in `id={"translatable-fields-#{@current_lang}"}` div.
- **Critical morphdom detail:** IDs include `@current_lang` so morphdom treats them as new elements on language switch. Static IDs would preserve JS-modified class state across LiveView patches, causing skeletons to permanently stick.
- Tab styling unified with `entity_form`: custom `inline-flex` pill buttons with `bg-base-100 shadow-sm` for active state instead of daisyUI `tab`/`tab-active`. Separators changed from `<div class="divider divider-horizontal">` to a thin `<span class="w-px h-4 bg-base-content/20">`.
- Per-tab info text (different messages for primary vs. secondary tabs) replaced with a single persistent `alert alert-info` banner above the tabs.

---

### 3. Top submit button added to `data_form`

A `<button type="submit" class="btn btn-primary">` is added at the top of the form (before the language tabs). Button text adapts: "Update %{entity}" when editing, "Create %{entity}" when creating. Consistent with the save handler's `@data_record.id` check.

---

### 4. Stay on page after update; navigate to edit URL after create

**Both forms, same pattern:**

- **Update (existing record):** Save handler stays on the page and refreshes assigns from the saved record. `entity_form` calls `reply_with_broadcast(socket)`; `data_form` reassigns `data_record` + `changeset` then calls `broadcast_data_form_state(socket, params)`.
- **Create (new record):** Save handler navigates to the edit URL of the new record (`/admin/entities/:uuid/edit` or `/admin/entities/:name/data/:uuid/edit`) instead of the list page. This lets the user continue editing the record they just created without having to find it in the list.

Previously both forms always redirected to the list after any save.

---

### 5. Preserve primary-tab fields on entity form save

**Problem:** When saving from the translations tab, `entity_params` only contained the fields visible on that tab. The primary-tab fields (`display_name`, `fields_definition`, etc.) were absent, causing the changeset to clear or ignore them on save.

**Fix:** In `handle_event("save", ...)`, the save handler now merges existing changeset data into params before saving:

```elixir
current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)

existing_data =
  current_data
  |> Map.from_struct()
  |> Map.drop([:__meta__, :creator, :entity_data, :id, :uuid, :date_created, :date_updated])
  |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

entity_params = Map.merge(existing_data, entity_params)
```

Submitted params take precedence over existing data (they override the base), so the merge only fills in fields that aren't present in the current form submission.

---

### 6. `Map.drop` field names corrected

Two locations in `entity_form.ex` previously dropped `[:inserted_at, :updated_at]`. The Entity schema uses `date_created`/`date_updated` (UTC datetime fields, renamed during UUID migration) — not `inserted_at`/`updated_at`. Those atoms were no-ops in `Map.drop`, meaning the timestamp values were leaking into the string-key merge map.

Updated drop list: `[:__meta__, :creator, :entity_data, :id, :uuid, :date_created, :date_updated]`

| Added to drop list | Why |
|--------------------|-----|
| `:date_created`, `:date_updated` | Correct field names (were `:inserted_at`, `:updated_at` — no-ops) |
| `:entity_data` | `has_many` association — `%Ecto.Association.NotLoaded{}` shouldn't enter params |
| `:id`, `:uuid` | Primary keys shouldn't be in update params |

---

### 7. Skip self-triggered PubSub notifications

**Problem:** After saving, both forms broadcasted an `entity_updated`/`data_updated` event over PubSub. Their own `handle_info` handler received the broadcast and showed "Entity updated in another session." — a false alarm that also fetched and re-applied entity state unnecessarily (immediately after the save handler already did so).

**Fix:** Both `handle_info` implementations now check `socket.assigns[:lock_owner?]` and return `{:noreply, socket}` immediately if true.

---

### 8. Hide empty Custom Fields section

Both multilang and non-multilang branches of `data_form.html.heex` now gate the Custom Fields card on `@entity.fields_definition != nil and @entity.fields_definition != []`. When an entity has no custom fields defined, the section is omitted entirely.

---

### 9. `catalog_product.ex` — `featured_image_id` → `featured_image_uuid`

Duplicate of the fix in PR #362 (`cc572af4`), applied independently in parallel. Git merge resolved correctly since both sides made the same change to the same line.

---

## Files Changed

| File | Change |
|------|--------|
| `lib/modules/entities/web/entity_form.ex` | `switch_lang_js/2`, changeset merge, stay-on-page save, PubSub self-skip, Map.drop fix |
| `lib/modules/entities/web/entity_form.html.heex` | Pass `@current_lang` to `switch_lang_js/2` on all tab buttons |
| `lib/modules/entities/web/data_form.ex` | Port `switch_lang_js/2`, stay-on-page save, PubSub self-skip |
| `lib/modules/entities/web/data_form.html.heex` | Skeleton loading, tab styling, top submit button, hide empty Custom Fields, persistent info alert |
| `lib/modules/shop/web/catalog_product.ex` | `featured_image_id` → `featured_image_uuid` (parallel fix with #362) |
