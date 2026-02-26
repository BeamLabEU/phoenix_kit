# PR #363 Review — Entity and data form UX, multilang save bugs

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/363
**Author:** @mdon
**Merged:** 2026-02-24 into `dev`
**Reviewer:** Claude Sonnet 4.6

---

## Verdict: Correct and well-structured — no blocking issues

All nine changes are correct. The most impactful fix is the `Map.drop` field name correction (item 6), which was silently including timestamps and association structs in the changeset merge map. The skeleton ID morphdom trick (item 2) is non-obvious and correctly implemented. No issues found.

| Area | Assessment |
|------|------------|
| `switch_lang_js` no-op fix | Clean — `%JS{}` is the right no-op pattern |
| Skeleton loading in `data_form` | Correct; morphdom ID trick is critical and present |
| Tab styling unification | Visual parity achieved |
| Top submit button | Consistent with save handler logic |
| Stay-on-page save | Correct in both forms |
| Changeset merge for primary-tab preservation | Correct; `Map.merge(existing_data, entity_params)` order is right |
| `Map.drop` field names | Real bug fixed — timestamps were leaking |
| PubSub self-notification skip | Clean guard on `lock_owner?` |
| Hide empty Custom Fields | Correct nil/empty check |

---

## `switch_lang_js` no-op (entity_form.ex, data_form.ex, entity_form.html.heex)

Returning `%JS{}` for the no-op case is the correct pattern — it produces an empty JS command that LiveView executes harmlessly. The alternative (returning `nil` or omitting the binding) would either error or fall back to default click behavior.

The fix is applied consistently across all tab button variants: compact, primary, and non-primary in both forms. Three call sites in `entity_form.html.heex`, three in `data_form.html.heex`.

`data_form.ex` was missing `alias Phoenix.LiveView.JS` — added correctly.

**No concerns.**

---

## Skeleton loading + morphdom ID trick (data_form.html.heex)

The critical detail is the `@current_lang`-scoped IDs:

```heex
id={"translatable-skeletons-#{@current_lang}"}
id={"translatable-fields-#{@current_lang}"}
```

Without `@current_lang` in the ID, morphdom would patch the existing DOM node in place, preserving whatever `hidden` / visible class state JavaScript had set. The language-switch JS adds `hidden` to `[data-translatable=fields]` and removes it from `[data-translatable=skeletons]`. After the server patch arrives with a static ID, morphdom would update attributes and children but leave the element's class list in its JS-modified state — meaning skeletons would stay visible after the server response. Including `@current_lang` forces morphdom to treat the element as a new node and apply the server-rendered class list cleanly.

The comment in the template documents this explicitly, which is important since it looks like an unnecessary detail to a future reader.

**No concerns.**

---

## Stay-on-page save (entity_form.ex, data_form.ex)

Both forms use `record.id` as the create-vs-update discriminator. This is correct — a new record has `id == nil` before the first save; after create, navigation goes to the edit URL where `id` will be populated. The same `@data_record.id` check is used in the top submit button label, keeping the two in sync.

`entity_form.ex` update path calls `reply_with_broadcast(socket)` (an existing private helper at line 1122 that broadcasts state and returns `{:noreply, socket}`). `data_form.ex` update path manually reassigns `data_record` and `changeset` then calls `broadcast_data_form_state(socket, params)` (existing at line 857). The asymmetry is fine — the two forms have different state shapes and their existing broadcast helpers reflect that.

**No concerns.**

---

## Changeset merge for primary-tab field preservation (entity_form.ex)

The merge order `Map.merge(existing_data, entity_params)` is correct: `existing_data` is the base, `entity_params` overrides. This means fields present in the form submission (current tab) take precedence, while fields absent from the submission (other tabs) are filled from the in-memory changeset.

`Ecto.Changeset.apply_changes/1` is the right source for `existing_data` — it returns the full struct with all pending changes applied, which is what the user expects to be preserved.

One subtlety: if the changeset has failing validations at the time of save (a rare edge case since the save path already checks `lock_owner?`), `apply_changes/1` still returns the struct with changes applied regardless. In practice this is fine because the `save_entity/2` call that follows will revalidate and return `{:error, changeset}` if invalid.

**No concerns.**

---

## `Map.drop` field names (entity_form.ex, two locations)

This is the most significant correctness fix in the PR.

**Old drop list:** `[:__meta__, :creator, :inserted_at, :updated_at]`
**New drop list:** `[:__meta__, :creator, :entity_data, :id, :uuid, :date_created, :date_updated]`

The Entity schema defines `date_created` and `date_updated` as `:utc_datetime` fields. It does not have `inserted_at` or `updated_at`. Dropping `:inserted_at`/`:updated_at` from a struct that doesn't have those keys is silently a no-op in `Map.from_struct/1` + `Map.drop/2` — the keys simply aren't in the map, so nothing is dropped.

**Practical consequence of the old code:** `"date_created"` and `"date_updated"` (with `%DateTime{}` values) were included in the `existing_data` string map. After `Map.merge(existing_data, entity_params)`, they entered the changeset as `"date_created" => %DateTime{...}`. The `change_entity/2` changeset casts only the fields listed in `cast/3`; checking `entities.ex:166`, `date_created` is included in the cast list. So the old value was being re-cast into the changeset on every tab save — redundant and potentially overwriting any changeset-level timestamp logic.

**`:entity_data`** — the `has_many :entity_data` association would be `%Ecto.Association.NotLoaded{}` when the entity is loaded without preloading. This was being converted to `"entity_data" => %Ecto.Association.NotLoaded{}` and merged into params. The changeset's `cast/3` ignores unknown keys, so it was harmless in practice — but correct to exclude.

**`:id` and `:uuid`** — including `"id" => 123` in params is benign since Ecto doesn't cast PKs via `cast/3`, but it's still correct hygiene to exclude them.

The fix is applied in both locations that build `existing_data` (the `switch_language` handler at line ~213 and the `save` handler at line ~281 (new) / line ~1316).

**No concerns with the fix. The timestamp leak was a real bug corrected here.**

---

## PubSub self-notification skip (entity_form.ex, data_form.ex)

The `lock_owner?` assign is set to `true` when the current session acquires the edit lock and `false` when it loses it (see `presence_helpers.ex` integration in both forms). The guard is therefore accurate: the session that saved the record still holds the lock, so `lock_owner?` is `true` at the time the PubSub message arrives.

`data_form.ex` adds the guard as a new function clause before the `true` catch-all in the `handle_info` for data record updates:

```elixir
# Ignore our own saves — the save handler already refreshes state
socket.assigns[:lock_owner?] ->
  {:noreply, socket}

true ->
  # fetch and refresh from DB
```

`entity_form.ex` wraps the existing body in `if socket.assigns[:lock_owner?] do ... else ... end`. Both approaches are correct; the clause-based approach in `data_form.ex` is slightly more idiomatic for multi-guard `cond`-style `handle_info`, but the difference is cosmetic.

**No concerns.**

---

## `catalog_product.ex` — parallel fix with PR #362

PR #362 (`cc572af4`) and this PR both changed `first_image(%{featured_image_id: id})` → `first_image(%{featured_image_uuid: id})` in `catalog_product.ex`. These were developed in parallel. Git merge resolved correctly (both sides made the same change to the same line). The end result is correct and identical to what PR #362 intended.

**No concerns.**

---

## Minor Notes (non-blocking)

1. **`data_form.html.heex` info alert consolidation** — replacing the conditional per-tab messages (one for primary, one for secondary) with a single persistent banner is a UX improvement. The new text covers both cases in one sentence. Translations will need updating if the app has existing `.po` files for the old strings.

2. **Tab container `inline-flex`** — changed from `flex flex-wrap` to `inline-flex flex-wrap`. This causes the tab bar to shrink-wrap to its content width rather than spanning full width. With `mb-4` replacing the old bottom margin, the visual result is a more compact pill-style tab bar that doesn't stretch edge-to-edge. This matches `entity_form`'s style.

3. **Divider replacement** — `<div class="divider divider-horizontal mx-0.5 h-6 self-center">` replaced with `<span class="w-px h-4 bg-base-content/20 self-center">`. The old daisyUI divider component adds more DOM weight and has less predictable height in flex containers; the thin `<span>` is simpler and renders consistently.
