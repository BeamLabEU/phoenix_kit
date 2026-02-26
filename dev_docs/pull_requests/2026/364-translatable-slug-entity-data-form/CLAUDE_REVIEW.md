# PR #364 — Add translatable slug to entity data form and fix sidebar nav

**Author:** Max Don
**Merged:** 2026-02-24
**Files changed:** 3 (`entities.ex`, `data_form.ex`, `data_form.html.heex`)
**Lines:** +286 / -154

---

## Summary

Three changes in one PR:

1. **Translatable slug** — mirrors the `_title` multilang pattern. Primary language slug writes to the DB `slug` column; secondary language slugs store `_slug` overrides in `data[lang_code]["_slug"]` JSONB.
2. **Sidebar nav fix** — entities parent tab `match: :exact` → `match: :prefix`, so it stays highlighted on edit pages.
3. **Validate handler parity** — strips `lang_slug` (and the pre-existing `lang_title`) from `data_params` before passing to the changeset, consistent with the save handler.

---

## What Works Well

### Nav fix — clean and correct (`entities.ex:808`)

`match: :prefix` + `highlight_with_subtabs: false` is the right combination: parent tab stays lit but dims when a subtab is active. One-liner, no risk.

### `do_generate_slug` refactoring

The old `generate_slug` handler was a 40-line inline block. The refactoring into `do_generate_slug` → `slug_source_title` → `build_slug_params` → `compute_slug_and_data` cleanly satisfies Credo complexity constraints and reads well. Pattern-matched function heads (`true = _secondary` vs `_primary`) are idiomatic.

### `seed_slug_in_data` — correct backward-compat seeding

Called from `seed_title_in_data/2` on mount for existing records. Only seeds when `_slug` is absent and the DB `slug` column is non-empty. Reads from the changeset's data field correctly (picks up `put_change` from the preceding `do_seed_title` call).

### Secondary slug placeholder UX

`value={lang_data["_slug"]}` with `placeholder={Ecto.Changeset.get_field(@changeset, :slug) || ...}` is good — shows the primary slug as a hint when secondary is empty. The hint text "Leave empty to use the primary language slug" sets correct expectations.

### Skeleton loader updated correctly

The 2-column skeleton matches the new 2-column title+slug layout. `id` includes `@current_lang` so morphdom treats it as a new element on language switch — skeleton ghost prevention is preserved.

---

## Bug Found and Fixed: Secondary Language Slug (and Title) Silently Not Saved

**Status: FIXED** — see commit below.

This affected `_slug` introduced here and also the pre-existing `_title` mechanism.

### Root cause

Both `validate` and `save` handlers use a **double-injection** pattern:

```elixir
# Pass 1: inject before validation
form_data =
  form_data
  |> inject_title_into_form_data(data_params, ...)
  |> inject_slug_into_form_data(data_params, ...)

# Strip lang_title / lang_slug from data_params  <-- TOO EARLY
data_params =
  data_params
  |> Map.delete("lang_title")
  |> Map.delete("lang_slug")

case FormBuilder.validate_data(..., form_data, current_lang) do
  {:ok, validated_data} ->
    # Pass 2: re-inject after validation strips _title/_slug
    validated_data =
      validated_data
      |> inject_title_into_form_data(data_params, ...)   # <-- lang_title already gone
      |> inject_slug_into_form_data(data_params, ...)    # <-- lang_slug already gone
```

`FormBuilder.validate_data` builds `validated_data` from scratch using only `entity.fields_definition` keys (see `form_builder.ex:796` and `form_builder.ex:835`). `_title` and `_slug` are metadata keys, not schema fields — they are always stripped from `validated_data`.

Pass 2 must re-inject them. For **primary language** this worked because `data_params["slug"]` was still present (only `lang_slug` was deleted).

For **secondary language**, `data_params["lang_slug"]` was deleted before Pass 2, causing a fallback to the stale pre-event `assigns.changeset`:

| Scenario | Result (before fix) |
|----------|---------------------|
| New record, user types secondary slug | `_slug` absent from old changeset → fallback is no-op → never saved |
| Existing record, user edits secondary slug | fallback reads **old** value → edit silently reverted |

The "Generate" button bypassed this because `do_generate_slug/1` directly builds params and assigns the changeset, not going through the double-injection path.

### Fix applied

Moved the `Map.delete("lang_title")` / `Map.delete("lang_slug")` calls to **after** the second injection pass in both `validate` and `save` handlers (4 locations: success + error branches in each). Now the inject functions can read the user's current `lang_slug`/`lang_title` values during Pass 2, and the strip happens right before `EntityData.change` where `cast` would ignore unknown keys anyway.

This also fixes the pre-existing `_title` bug — secondary language titles typed manually were subject to the same silent revert.

---

## Minor: Secondary Slug Uniqueness Not Checked

`compute_slug_and_data` for secondary language calls `Slug.slugify(title)` directly (`data_form.ex:908`), while primary calls `auto_generate_entity_slug` which does uniqueness collision resolution.

Secondary slugs live in JSONB and are not enforced at the DB level, so this is likely intentional. If the consuming application uses secondary slugs for routing (e.g., `/fr/mon-article`), duplicate secondary slugs across records could cause routing ambiguity. Worth noting in the module README if per-language routing is a planned use case.

---

## Minor: `seed_title_in_data/2` Name

The function now seeds both `_title` and `_slug` via the newly-called `seed_slug_in_data/1`. The name is stale. Consider renaming to `seed_translatable_fields_in_data/2` in a future cleanup pass. Low priority.

---

## Minor: Template — "Slug" Label Inconsistency

The non-multilang slug label reads "Slug (URL-friendly identifier)" (line ~440 in heex), while the new multilang label reads just "Slug". Not introduced by this PR (non-multilang label predates it), but now the two labels diverge. Fine to leave for a polish pass.

---

## Final Verdict

| Area | Status |
|------|--------|
| Nav fix | ✅ Correct |
| `do_generate_slug` refactor | ✅ Clean |
| Primary language slug save | ✅ Works |
| `seed_slug_in_data` on mount | ✅ Works |
| Secondary language slug — Generate button | ✅ Works |
| Secondary language slug — manual typing | ✅ Fixed |
| Pre-existing secondary title — manual typing | ✅ Fixed (same patch) |
